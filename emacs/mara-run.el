;;; mara-run.el --- Multi-turn agent loop for Mara -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'mara-context)
(require 'mara-provider)
(require 'mara-session)
(require 'mara-tools)
(require 'mara-visual)
(require 'subr-x)

(defconst mara-run--visual-marker-prefixes
  '("[[mara-expression:" "\n[[mara-expression:")
  "Prefixes reserved for trailing visual-reaction metadata.")

(cl-defstruct mara-run
  id provider messages turns tool-count seen-calls timer handle cancelled
  stream-text stream-emitted on-text on-done on-error)

(defvar mara-run-active nil)

(defun mara-run-start (provider user-text on-text on-done on-error)
  "Start an asynchronous run through PROVIDER for USER-TEXT."
  (when mara-run-active
    (user-error "Mara already has an active run; cancel it first"))
  (mara-session-add-message "user" user-text)
  (setq mara-run-active
        (make-mara-run
         :id (mara--uuid)
         :provider provider
         :messages (copy-tree (mara-session-messages mara-session-current))
         :turns 0 :tool-count 0
         :seen-calls (make-hash-table :test #'equal)
         :cancelled nil
         :stream-text ""
         :stream-emitted 0
         :on-text on-text :on-done on-done :on-error on-error))
  (setf (mara-run-timer mara-run-active)
        (run-at-time mara-run-timeout nil #'mara-run--timeout mara-run-active))
  (mara-run--step mara-run-active)
  mara-run-active)

(defun mara-run--step (run)
  "Perform the next provider turn for RUN."
  (unless (mara-run-cancelled run)
    (if (>= (mara-run-turns run) mara-run-max-turns)
        (mara-run--fail run "Maximum provider turns exceeded")
      (cl-incf (mara-run-turns run))
      (condition-case err
          (setf (mara-run-handle run)
                (mara-provider-stream
                 (mara-run-provider run)
                 (list :system (mara-context-system-prompt)
                       :messages (mara-run-messages run))
                 (lambda (chunk) (mara-run--stream-chunk run chunk))
                 (lambda (response) (mara-run--response run response))
                 (lambda (error-value) (mara-run--fail run error-value))))
        (error
         (mara-run--fail
          run
          (format "Provider dispatch failed: %s"
                  (error-message-string err))))))))

(defun mara-run--marker-prefix-hold (text)
  "Return length of TEXT suffix that may start visual metadata."
  (let ((best 0))
    (dolist (prefix mara-run--visual-marker-prefixes best)
      (let ((candidate (min (length text) (length prefix))))
        (while (and (> candidate 0)
                    (not (string-suffix-p
                          (substring prefix 0 candidate) text)))
          (setq candidate (1- candidate)))
        (setq best (max best candidate))))))

(defun mara-run--stream-safe-end (run)
  "Return end offset in RUN's stream safe to display immediately."
  (let* ((text (mara-run-stream-text run))
         (emitted (mara-run-stream-emitted run))
         (marker-start
          (string-match "\n?\\[\\[mara-expression:" text emitted)))
    (if marker-start
        marker-start
      (- (length text) (mara-run--marker-prefix-hold text)))))

(defun mara-run--stream-chunk (run chunk)
  "Accumulate and safely emit streaming CHUNK for RUN."
  (when (and (stringp chunk)
             (not (mara-run-cancelled run)))
    (setf (mara-run-stream-text run)
          (concat (mara-run-stream-text run) chunk))
    (let ((safe-end (mara-run--stream-safe-end run))
          (emitted (mara-run-stream-emitted run)))
      (when (> safe-end emitted)
        (funcall (mara-run-on-text run)
                 (substring (mara-run-stream-text run) emitted safe-end))
        (setf (mara-run-stream-emitted run) safe-end)))))

(defun mara-run--flush-stream (run visible-text)
  "Emit the unshown suffix of VISIBLE-TEXT for RUN."
  (let ((emitted (min (mara-run-stream-emitted run)
                      (length visible-text))))
    (when (< emitted (length visible-text))
      (funcall (mara-run-on-text run) (substring visible-text emitted)))
    (setf (mara-run-stream-emitted run) (length visible-text))))

(defun mara-run--response (run response)
  "Handle normalized provider RESPONSE for RUN."
  (unless (mara-run-cancelled run)
    (let* ((calls (plist-get response :tool-calls))
           (streamed (plist-get response :streamed))
           (raw-text (if streamed
                         (mara-run-stream-text run)
                       (plist-get response :text))))
      (if calls
          (mara-run--execute-calls run calls)
        (let ((text (mara-visual-consume-response (or raw-text ""))))
          (if streamed
              (mara-run--flush-stream run text)
            (when (and text (not (string-empty-p text)))
              (funcall (mara-run-on-text run) text)))
          (mara-session-add-message "assistant" text)
          (mara-run--finish run (plist-put response :text text)))))))

(defun mara-run--execute-calls (run calls)
  "Execute CALLS serially for RUN and continue the loop."
  (cond
   ((> (+ (mara-run-tool-count run) (length calls)) mara-run-tool-budget)
    (mara-run--fail run "Tool budget exceeded"))
   ((>= (mara-run-turns run) mara-run-max-turns)
    (mara-run--fail run "Maximum provider turns exceeded"))
   (t
    ;; gptel owns the network continuation, but this still represents another
    ;; model/tool turn for Mara's run budget.
    (cl-incf (mara-run-turns run))
    (mara-run--execute-call-queue run calls nil))))

(defun mara-run--execute-call-queue (run calls _results)
  "Execute pending CALLS for RUN through Mara's broker.
gptel continuation callbacks carry results back into gptel's own FSM."
  (if (null calls)
      nil
    (let* ((call (car calls))
           (name (mara--alist-get 'name call))
           (input (mara--alist-get 'input call))
           (continuation (mara--alist-get 'continuation call))
           (fingerprint (secure-hash 'sha256 (prin1-to-string (list name input))))
           (seen (gethash fingerprint (mara-run-seen-calls run) 0)))
      (if (>= seen 2)
          (mara-run--fail run (format "Repeated tool call detected: %s" name))
        (puthash fingerprint (1+ seen) (mara-run-seen-calls run))
        (cl-incf (mara-run-tool-count run))
        (mara-tools-execute
         name input
         (lambda (result errorp)
           (funcall continuation
                    (if errorp
                        (format "Mara capability/tool error: %s" result)
                      result))
           (mara-run--execute-call-queue
            run (cdr calls) nil)))))))

(defun mara-run-cancel ()
  "Cancel the active Mara run."
  (interactive)
  (when mara-run-active
    (setf (mara-run-cancelled mara-run-active) t)
    (when-let ((timer (mara-run-timer mara-run-active)))
      (cancel-timer timer))
    (mara-provider-cancel (mara-run-provider mara-run-active)
                          (mara-run-handle mara-run-active))
    (setq mara-run-active nil)
    (message "Mara run cancelled")))

(defun mara-run--timeout (run)
  "Cancel RUN after its deadline."
  (when (eq run mara-run-active)
    (mara-run--fail run "Run timed out")))

(defun mara-run--finish (run response)
  "Finish RUN successfully with RESPONSE."
  (when-let ((timer (mara-run-timer run)))
    (cancel-timer timer))
  (setq mara-run-active nil)
  (funcall (mara-run-on-done run) response))

(defun mara-run--fail (run error-value)
  "Finish RUN with ERROR-VALUE."
  (unless (mara-run-cancelled run)
    (setf (mara-run-cancelled run) t)
    (when-let ((timer (mara-run-timer run)))
      (cancel-timer timer))
    (setq mara-run-active nil)
    (funcall (mara-run-on-error run) error-value)))

(provide 'mara-run)
;;; mara-run.el ends here
