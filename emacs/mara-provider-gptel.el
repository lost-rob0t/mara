;;; mara-provider-gptel.el --- gptel provider for Mara -*- lexical-binding: t; -*-

;;; Commentary:
;; gptel owns model transport, backend selection, authentication and protocol
;; details.  Mara continues to own persistent state, context construction and
;; capability enforcement.  Tool calls are always surfaced to Mara's broker;
;; gptel never executes a Mara tool directly.

;;; Code:

(require 'gptel-request)
(require 'mara-provider)
(require 'mara-tools)

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
  "Convert Mara MESSAGES to gptel's alternating conversation list."
  (mapcar
   (lambda (message)
     (let ((content (mara--alist-get 'content message)))
       (if (stringp content) content (format "%s" content))))
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

(cl-defmethod mara-provider-send ((_provider mara-gptel-provider)
                                  request on-success on-error)
  "Send REQUEST through the user's configured gptel backend."
  (unless (bound-and-true-p gptel-backend)
    (user-error "Configure a gptel backend before starting Mara"))
  (let ((request-buffer (generate-new-buffer " *mara-gptel-request*")))
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
        :stream nil
        :callback
        (lambda (response info)
          (cond
           ((stringp response)
            ;; Some backends return a short preamble alongside tool calls.
            ;; gptel will surface those calls on its next FSM transition, so a
            ;; text fragment in that state is not the final assistant answer.
            (unless (plist-get info :tool-use)
              (funcall on-success
                       (list :text response
                             :tool-calls nil
                             :stop-reason "end_turn"
                             :usage (plist-get info :tokens)))
              (when (buffer-live-p request-buffer)
                (kill-buffer request-buffer))))
           ((eq response 'abort)
            (funcall on-error "gptel request aborted")
            (when (buffer-live-p request-buffer)
              (kill-buffer request-buffer)))
           ((eq (car-safe response) 'tool-call)
            (funcall on-success
                     (list :text ""
                           :tool-calls
                           (mapcar #'mara-gptel--normalize-tool-call
                                   (cdr response))
                           :stop-reason "tool_use")))
           ;; gptel reports tool results before it continues its own FSM.
           ((eq (car-safe response) 'tool-result) nil)
           ((eq (car-safe response) 'reasoning) nil)
           ((null response)
            (funcall on-error
                     (or (plist-get info :status) "gptel request failed"))
            (when (buffer-live-p request-buffer)
              (kill-buffer request-buffer)))))))
    request-buffer))

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
    (when (buffer-live-p handle) (kill-buffer handle))))

(provide 'mara-provider-gptel)
;;; mara-provider-gptel.el ends here
