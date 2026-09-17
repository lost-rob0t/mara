;;; mara-zara-dialogue.el --- Typed Zara dialogue events for Mara -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Listen to Mara's localhost Zara bridge for typed input requests.  This is
;; intentionally orthogonal to gptel: ordinary assistant/conversation events
;; are ignored, while explicit `user.input_required' events become inspectable
;; dialogue state and may prompt the user for a correlated follow-up turn.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)

(defgroup mara-zara-dialogue nil
  "Typed Zara dialogue integration."
  :group 'mara)

(defcustom mara-zara-dialogue-host "127.0.0.1"
  "Host for Mara's local Zara bridge."
  :type 'string
  :group 'mara-zara-dialogue)

(defcustom mara-zara-dialogue-port 7319
  "Port for Mara's local Zara bridge."
  :type 'integer
  :group 'mara-zara-dialogue)

(defcustom mara-zara-dialogue-auto-prompt t
  "When non-nil, prompt for typed Zara input requests as they arrive."
  :type 'boolean
  :group 'mara-zara-dialogue)

(defcustom mara-zara-dialogue-reconnect-delay 2.0
  "Seconds before reconnecting the local event stream."
  :type 'number
  :group 'mara-zara-dialogue)

(defvar mara-zara-dialogue-input-request-hook nil
  "Hook run with one normalized input-request plist argument.")

(defvar mara-zara-dialogue--process nil)
(defvar mara-zara-dialogue--wire-buffer "")
(defvar mara-zara-dialogue--headers-complete nil)
(defvar mara-zara-dialogue--pending nil)
(defvar mara-zara-dialogue--reconnect-timer nil)

(defun mara-zara-dialogue--alist-get (key alist)
  "Return KEY from ALIST accepting symbol or string JSON keys."
  (or (alist-get key alist)
      (alist-get (symbol-name key) alist nil nil #'equal)))

(defun mara-zara-dialogue--bounded-string-p (value maximum)
  "Return non-nil when VALUE is a nonempty string of at most MAXIMUM bytes."
  (and (stringp value)
       (not (string-empty-p value))
       (<= (string-bytes value) maximum)))

(defun mara-zara-dialogue--input-request (document)
  "Normalize typed input request DOCUMENT, or return nil for unrelated events."
  (when (and (listp document)
             (equal "user.input_required"
                    (mara-zara-dialogue--alist-get 'type document)))
    (let* ((data (mara-zara-dialogue--alist-get 'data document))
           (kind (and (listp data)
                      (mara-zara-dialogue--alist-get 'kind data)))
           (prompt (and (listp data)
                        (mara-zara-dialogue--alist-get 'prompt data)))
           (question-id (and (listp data)
                             (mara-zara-dialogue--alist-get 'question_id data)))
           (turn-id (and (listp data)
                         (mara-zara-dialogue--alist-get 'turn_id data)))
           (conversation-id
            (and (listp data)
                 (mara-zara-dialogue--alist-get 'conversation_id data)))
           (raw-choices (and (listp data)
                             (mara-zara-dialogue--alist-get 'choices data)))
           (choices (cond
                     ((vectorp raw-choices) (append raw-choices nil))
                     ((listp raw-choices) raw-choices)
                     (t nil))))
      (when (and (mara-zara-dialogue--bounded-string-p kind 64)
                 (mara-zara-dialogue--bounded-string-p prompt 2048)
                 (or (null question-id)
                     (mara-zara-dialogue--bounded-string-p question-id 128))
                 (or (null turn-id)
                     (mara-zara-dialogue--bounded-string-p turn-id 128))
                 (or (null conversation-id)
                     (mara-zara-dialogue--bounded-string-p conversation-id 128))
                 (<= (length choices) 16)
                 (cl-every
                  (lambda (choice)
                    (mara-zara-dialogue--bounded-string-p choice 128))
                  choices))
        (list :conversation-id conversation-id
              :turn-id turn-id
              :kind kind
              :question-id question-id
              :prompt prompt
              :choices choices)))))

(defun mara-zara-dialogue--answer-payload (request answer)
  "Build a Zara follow-up payload for REQUEST and ANSWER."
  (unless (mara-zara-dialogue--bounded-string-p answer 4096)
    (user-error "Zara dialogue answer must be nonempty and bounded"))
  (let ((payload `((text . ,answer)))
        (conversation-id (plist-get request :conversation-id)))
    (when conversation-id
      (setq payload (append payload `((conversationId . ,conversation-id)))))
    payload))

(defun mara-zara-dialogue--bridge-url (path)
  "Return local bridge URL for PATH."
  (format "http://%s:%d%s"
          mara-zara-dialogue-host mara-zara-dialogue-port path))

(defun mara-zara-dialogue--post-turn (request answer)
  "Post ANSWER for REQUEST to Zara's normal turn endpoint."
  (let* ((url-request-method "POST")
         (url-request-extra-headers '(('Content-Type' . "application/json")))
         (url-request-data
          (encode-coding-string
           (json-serialize
            (mara-zara-dialogue--answer-payload request answer))
           'utf-8))
         (buffer (url-retrieve-synchronously
                  (mara-zara-dialogue--bridge-url "/v1/turn")
                  t t 5.0)))
    (unless buffer
      (user-error "Zara bridge did not answer the dialogue follow-up"))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (unless (re-search-forward "^HTTP/[0-9.]+ 2[0-9][0-9]" nil t)
            (user-error "Zara bridge rejected the dialogue follow-up")))
      (kill-buffer buffer))))

;;;###autoload
(defun mara-zara-dialogue-answer (&optional answer)
  "Answer Mara's pending typed Zara request with ANSWER.

When called interactively, use completion for enumerated choices and free-form
input otherwise.  The answer is submitted as a normal Zara turn using the
request's conversation id, so Prolog dialogue never creates a parallel chat
transport."
  (interactive)
  (let* ((request (or mara-zara-dialogue--pending
                      (user-error "No Zara dialogue question is pending")))
         (choices (plist-get request :choices))
         (prompt (plist-get request :prompt))
         (value (or answer
                    (if choices
                        (completing-read (concat prompt " ") choices nil t)
                      (read-string (concat prompt " "))))))
    (mara-zara-dialogue--post-turn request value)
    (setq mara-zara-dialogue--pending nil)
    (message "Zara dialogue answer sent")
    value))

(defun mara-zara-dialogue--handle-document (document)
  "Handle one decoded bridge event DOCUMENT."
  (when-let ((request (mara-zara-dialogue--input-request document)))
    (setq mara-zara-dialogue--pending request)
    (run-hook-with-args 'mara-zara-dialogue-input-request-hook request)
    (when mara-zara-dialogue-auto-prompt
      (run-at-time 0 nil #'mara-zara-dialogue-answer))
    request))

(defun mara-zara-dialogue--consume-frame (frame)
  "Consume one SSE FRAME."
  (let ((event nil)
        (data-lines nil))
    (dolist (line (split-string frame "\r?\n" t))
      (cond
       ((string-prefix-p "event:" line)
        (setq event (string-trim (substring line 6))))
       ((string-prefix-p "data:" line)
        (push (string-trim-left (substring line 5)) data-lines))))
    (when (and event data-lines)
      (condition-case nil
          (let ((document
                 (json-parse-string
                  (string-join (nreverse data-lines) "\n")
                  :object-type 'alist
                  :array-type 'vector
                  :null-object nil
                  :false-object nil)))
            ;; The SSE event name and JSON document type must agree.  A bridge
            ;; mismatch fails closed instead of presenting arbitrary text.
            (when (equal event (mara-zara-dialogue--alist-get 'type document))
              (mara-zara-dialogue--handle-document document)))
        (error nil)))))

(defun mara-zara-dialogue--drain-wire-buffer ()
  "Drain complete HTTP/SSE records from the current wire buffer."
  (unless mara-zara-dialogue--headers-complete
    (when (string-match "\r?\n\r?\n" mara-zara-dialogue--wire-buffer)
      (setq mara-zara-dialogue--wire-buffer
            (substring mara-zara-dialogue--wire-buffer (match-end 0))
            mara-zara-dialogue--headers-complete t)))
  (when mara-zara-dialogue--headers-complete
    (let ((continue t))
      (while continue
        (if (string-match "\r?\n\r?\n" mara-zara-dialogue--wire-buffer)
            (let ((frame (substring mara-zara-dialogue--wire-buffer 0 (match-beginning 0))))
              (setq mara-zara-dialogue--wire-buffer
                    (substring mara-zara-dialogue--wire-buffer (match-end 0)))
              (unless (or (string-empty-p frame)
                          (string-prefix-p ":" frame))
                (mara-zara-dialogue--consume-frame frame)))
          (setq continue nil))))))

(defun mara-zara-dialogue--filter (_process chunk)
  "Process Zara event-stream CHUNK."
  (setq mara-zara-dialogue--wire-buffer
        (concat mara-zara-dialogue--wire-buffer chunk))
  (mara-zara-dialogue--drain-wire-buffer))

(defun mara-zara-dialogue--schedule-reconnect ()
  "Schedule a bounded dialogue event-stream reconnect."
  (when (and mara-zara-dialogue-mode
             (not (timerp mara-zara-dialogue--reconnect-timer)))
    (setq mara-zara-dialogue--reconnect-timer
          (run-at-time
           mara-zara-dialogue-reconnect-delay nil
           (lambda ()
             (setq mara-zara-dialogue--reconnect-timer nil)
             (when mara-zara-dialogue-mode
               (mara-zara-dialogue--connect)))))))

(defun mara-zara-dialogue--sentinel (_process event)
  "Handle event-stream process EVENT."
  (when (and mara-zara-dialogue-mode
             (string-match-p "\(closed\|failed\|deleted\|finished\)" event))
    (setq mara-zara-dialogue--process nil)
    (mara-zara-dialogue--schedule-reconnect)))

(defun mara-zara-dialogue--connect ()
  "Connect to the local Mara Zara event stream."
  (when (process-live-p mara-zara-dialogue--process)
    (delete-process mara-zara-dialogue--process))
  (setq mara-zara-dialogue--wire-buffer ""
        mara-zara-dialogue--headers-complete nil
        mara-zara-dialogue--process
        (make-network-process
         :name "mara-zara-events"
         :host mara-zara-dialogue-host
         :service mara-zara-dialogue-port
         :family 'ipv4
         :coding 'utf-8-unix
         :nowait nil
         :noquery t
         :filter #'mara-zara-dialogue--filter
         :sentinel #'mara-zara-dialogue--sentinel))
  (process-send-string
   mara-zara-dialogue--process
   (format
    "GET /v1/events HTTP/1.1\r\nHost: %s:%d\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n"
    mara-zara-dialogue-host mara-zara-dialogue-port)))

;;;###autoload
(define-minor-mode mara-zara-dialogue-mode
  "Global typed Zara dialogue integration for Mara."
  :global t
  :group 'mara-zara-dialogue
  (if mara-zara-dialogue-mode
      (condition-case error
          (mara-zara-dialogue--connect)
        (error
         (message "Mara Zara dialogue bridge unavailable: %s" (error-message-string error))
         (mara-zara-dialogue--schedule-reconnect)))
    (when (timerp mara-zara-dialogue--reconnect-timer)
      (cancel-timer mara-zara-dialogue--reconnect-timer))
    (setq mara-zara-dialogue--reconnect-timer nil
          mara-zara-dialogue--pending nil)
    (when (process-live-p mara-zara-dialogue--process)
      (delete-process mara-zara-dialogue--process))
    (setq mara-zara-dialogue--process nil
          mara-zara-dialogue--wire-buffer ""
          mara-zara-dialogue--headers-complete nil)))

(provide 'mara-zara-dialogue)
;;; mara-zara-dialogue.el ends here
