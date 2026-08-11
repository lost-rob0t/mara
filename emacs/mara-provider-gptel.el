;;; mara-provider-gptel.el --- gptel provider for Mara -*- lexical-binding: t; -*-

;;; Commentary:
;; gptel owns model transport, backend selection, authentication and protocol
;; details.  Mara continues to own persistent state, context construction and
;; capability enforcement.  Tool calls are always surfaced to Mara's broker;
;; gptel never executes a Mara tool directly.

;;; Code:

(require 'cl-lib)
(require 'gptel-request)
(require 'mara-provider)
(require 'mara-tools)
(require 'subr-x)

(defcustom mara-gptel-backend nil
  "gptel backend used by Mara.
When nil, inherit the user's current `gptel-backend'."
  :type '(choice (const :tag "Inherit gptel backend" nil) sexp))

(defcustom mara-gptel-model nil
  "gptel model used by Mara.
When nil, inherit the user's current `gptel-model'."
  :type '(choice (const :tag "Inherit gptel model" nil) symbol))

(cl-defstruct mara-gptel-provider)

(defun mara-gptel--conversation (messages)
  "Convert Mara MESSAGES to gptel's explicit-role conversation format.

Do not infer roles from list position.  Failed or cancelled runs may leave two
consecutive user messages in persistent history, and flattening that history to
an alternating string list would cause gptel to interpret the second user
message as an assistant response."
  (mapcar
   (lambda (message)
     (let* ((role (mara--alist-get 'role message))
            (raw-content (mara--alist-get 'content message))
            (content (if (stringp raw-content)
                         raw-content
                       (format "%s" raw-content))))
       (pcase role
         ("user" `(prompt . ,content))
         ("assistant" `(response . ,content))
         (_ `(prompt . ,(format "[%s] %s" role content))))))
   messages))

(defun mara-gptel--tool-args (schema)
  "Convert JSON input SCHEMA to gptel argument specifications."
  (let ((properties (mara--alist-get 'properties schema))
        (required (append (mara--alist-get 'required schema []) nil))
        arguments)
    (dolist (property properties (nreverse arguments))
      (let* ((name (if (symbolp (car property))
                       (symbol-name (car property))
                     (car property)))
             (spec (cdr property))
             (type-name (mara--alist-get 'type spec "string")))
        (push (append
               (list :name name
                     :type (intern type-name)
                     :description (mara--alist-get 'description spec name))
               (unless (member name required) (list :optional t))
               (when-let ((values (mara--alist-get 'enum spec)))
                 (list :enum (vconcat values)))
               (when-let ((items (mara--alist-get 'items spec)))
                 (list :items items)))
              arguments)))))

(defun mara-gptel--tools ()
  "Build gptel tool specifications from Mara's authorized registry."
  (let (tools)
    (maphash
     (lambda (_name tool)
       (when (mara-tools-authorized-p (mara-tool-capability tool))
         (push
          (gptel-make-tool
           :name (mara-tool-name tool)
           :description (mara-tool-description tool)
           :args (mara-gptel--tool-args (mara-tool-input-schema tool))
           ;; This function is deliberately unreachable.  :confirm forces
           ;; gptel to surface the call to Mara's capability broker instead.
           :function (lambda (&rest _args)
                       (error "Mara tools must run through the capability broker"))
           :category "mara"
           :confirm t
           :include nil)
          tools)))
     mara-tools-registry)
    (nreverse tools)))

(defun mara-gptel--cleanup-request-buffer (buffer)
  "Kill gptel request BUFFER when it is still live."
  (when (buffer-live-p buffer)
    (kill-buffer buffer)))

(defun mara-gptel--schedule-cleanup (buffer)
  "Schedule cleanup of gptel request BUFFER after its callback returns."
  (when (buffer-live-p buffer)
    ;; gptel transitions its FSM after invoking the callback.  Deferring cleanup
    ;; avoids invalidating the request buffer while gptel is still unwinding the
    ;; current transition.
    (run-at-time 0 nil #'mara-gptel--cleanup-request-buffer buffer)))

(defun mara-gptel--status (info)
  "Return a useful status string from gptel callback INFO."
  (or (plist-get info :status)
      (when-let ((error-value (plist-get info :error)))
        (format "%s" error-value))
      "unknown gptel status"))

(defun mara-gptel--stream-text (state)
  "Return accumulated streamed text from mutable STATE."
  (apply #'concat (nreverse (copy-sequence (plist-get state :chunks)))))

(defun mara-gptel--dispatch-callback
    (response info request-buffer state on-event on-success on-error)
  "Dispatch gptel RESPONSE and INFO to Mara callbacks.

STATE holds accumulated streaming chunks.  Any Mara-side callback exception is
converted into ON-ERROR instead of being silently swallowed by gptel's callback
error demotion."
  (condition-case err
      (cond
       ((stringp response)
        (if (plist-get info :stream)
            (progn
              (setf (plist-get state :chunks)
                    (cons response (plist-get state :chunks)))
              (funcall on-event response))
          ;; Streaming can be requested but unavailable for a backend or when
          ;; Curl is disabled.  In that case gptel falls back to one final
          ;; string callback, so complete the request here.
          (if (string-empty-p (string-trim response))
              (funcall on-error
                       (format "gptel returned an empty response (%s)"
                               (mara-gptel--status info)))
            (funcall on-success
                     (list :text response
                           :tool-calls nil
                           :streamed nil
                           :stop-reason "end_turn"
                           :usage (plist-get info :tokens))))
          (mara-gptel--schedule-cleanup request-buffer)))
       ((eq response t)
        ;; gptel signals successful completion of a streaming HTTP request with
        ;; a final t callback after all string chunks have been delivered.
        (funcall on-success
                 (list :text (mara-gptel--stream-text state)
                       :tool-calls nil
                       :streamed t
                       :stop-reason "end_turn"
                       :usage (plist-get info :tokens)))
        (mara-gptel--schedule-cleanup request-buffer))
       ((eq response 'abort)
        (funcall on-error "gptel request aborted")
        (mara-gptel--schedule-cleanup request-buffer))
       ((eq (car-safe response) 'tool-call)
        (funcall on-success
                 (list :text ""
                       :tool-calls
                       (mapcar #'mara-gptel--normalize-tool-call
                               (cdr response))
                       :streamed (and (plist-get info :stream) t)
                       :stop-reason "tool_use")))
       ;; gptel reports tool results and reasoning before continuing its FSM.
       ((memq (car-safe response) '(tool-result reasoning)) nil)
       ((null response)
        (funcall on-error
                 (format "gptel request failed: %s"
                         (mara-gptel--status info)))
        (mara-gptel--schedule-cleanup request-buffer))
       (t
        (funcall on-error
                 (format "Unexpected gptel callback response: %S (%s)"
                         response (mara-gptel--status info)))
        (mara-gptel--schedule-cleanup request-buffer)))
    (error
     (funcall on-error
              (format "Mara gptel callback failed: %s"
                      (error-message-string err)))
     (mara-gptel--schedule-cleanup request-buffer))))

(defun mara-gptel--request
    (request on-event on-success on-error stream)
  "Send REQUEST through gptel.

When STREAM is non-nil, invoke ON-EVENT for each text chunk and ON-SUCCESS once
gptel signals completion."
  (unless (bound-and-true-p gptel-backend)
    (user-error "Configure a gptel backend before starting Mara"))
  (let ((request-buffer (generate-new-buffer " *mara-gptel-request*"))
        (state (list :chunks nil)))
    (with-current-buffer request-buffer
      (setq-local gptel-backend (or mara-gptel-backend gptel-backend))
      (setq-local gptel-model (or mara-gptel-model gptel-model))
      (setq-local gptel-tools (mara-gptel--tools))
      (setq-local gptel-use-tools t)
      ;; Mara, not gptel's global preference, must authorize each tool call.
      (setq-local gptel-confirm-tool-calls 'auto)
      (gptel-request
          (mara-gptel--conversation (plist-get request :messages))
        :buffer request-buffer
        :system (plist-get request :system)
        :stream stream
        :callback
        (lambda (response info)
          (mara-gptel--dispatch-callback
           response info request-buffer state
           on-event on-success on-error))))
    request-buffer))

(cl-defmethod mara-provider-send ((_provider mara-gptel-provider)
                                  request on-success on-error)
  "Send REQUEST through gptel without requesting streaming."
  (mara-gptel--request request #'ignore on-success on-error nil))

(cl-defmethod mara-provider-stream ((_provider mara-gptel-provider)
                                    request on-event on-success on-error)
  "Stream REQUEST through gptel when the active backend supports it."
  (mara-gptel--request request on-event on-success on-error t))

(defun mara-gptel--normalize-tool-call (call)
  "Normalize one gptel pending tool CALL for Mara's run loop."
  (pcase-let ((`(,tool ,arguments ,continuation) call))
    `((name . ,(gptel-tool-name tool))
      (input . ,arguments)
      (continuation . ,continuation))))

(cl-defmethod mara-provider-cancel ((_provider mara-gptel-provider) handle)
  "Cancel gptel request associated with buffer HANDLE."
  (when (buffer-live-p handle)
    (gptel-abort handle)
    (when (buffer-live-p handle)
      (kill-buffer handle))))

(provide 'mara-provider-gptel)
;;; mara-provider-gptel.el ends here
