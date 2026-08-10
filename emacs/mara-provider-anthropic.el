;;; mara-provider-anthropic.el --- Anthropic adapter for Mara -*- lexical-binding: t; -*-

;;; Commentary:
;; Implements the current Anthropic Messages API directly with asynchronous
;; `url-retrieve'.  The normalized response keeps Anthropic content blocks so
;; the run loop can send tool results back without lossy reconstruction.

;;; Code:

(require 'auth-source)
(require 'url)
(require 'url-http)
(require 'mara-provider)

(defcustom mara-anthropic-endpoint "https://api.anthropic.com/v1/messages"
  "Anthropic Messages API endpoint."
  :type 'string)

(defcustom mara-anthropic-model "claude-sonnet-5"
  "Anthropic model ID used for Mara requests."
  :type 'string)

(defcustom mara-anthropic-max-tokens 4096
  "Maximum output tokens requested from Anthropic."
  :type 'integer)

(defcustom mara-anthropic-api-key-function #'mara-anthropic-api-key
  "Function returning the Anthropic API key without persisting it."
  :type 'function)

(defun mara-anthropic-api-key ()
  "Read the Anthropic API key from the environment or auth-source."
  (or (getenv "ANTHROPIC_API_KEY")
      (auth-source-pick-first-password :host "api.anthropic.com")
      (user-error "Configure ANTHROPIC_API_KEY or auth-source for api.anthropic.com")))

(cl-defstruct mara-anthropic-provider)

(defun mara-anthropic--request-body (request)
  "Convert provider-neutral REQUEST to an Anthropic JSON object."
  `((model . ,(or (plist-get request :model) mara-anthropic-model))
    (max_tokens . ,(or (plist-get request :max-tokens) mara-anthropic-max-tokens))
    (system . ,(or (plist-get request :system) ""))
    (messages . ,(vconcat (plist-get request :messages)))
    (tools . ,(vconcat (or (plist-get request :tools) nil)))))

(cl-defmethod mara-provider-send ((_provider mara-anthropic-provider)
                                  request on-success on-error)
  "Asynchronously send REQUEST to Anthropic."
  (let* ((url-request-method "POST")
         (url-request-extra-headers
          `(("content-type" . "application/json")
            ("anthropic-version" . "2023-06-01")
            ("x-api-key" . ,(funcall mara-anthropic-api-key-function))))
         (url-request-data
          (encode-coding-string
           (json-serialize (mara-anthropic--request-body request)
                           :null-object nil :false-object :json-false)
           'utf-8)))
    (url-retrieve
     mara-anthropic-endpoint
     (lambda (status)
       (let ((buffer (current-buffer)))
         (unwind-protect
             (condition-case err
                 (if (plist-get status :error)
                     (funcall on-error (plist-get status :error))
                   (goto-char (or url-http-end-of-headers (point-min)))
                   (let ((payload (json-parse-buffer :object-type 'alist
                                                     :array-type 'list
                                                     :null-object nil
                                                     :false-object :json-false)))
                     (if (and url-http-response-status
                              (>= url-http-response-status 400))
                         (funcall on-error payload)
                       (funcall on-success (mara-anthropic--normalize payload)))))
               (error (funcall on-error err)))
           (when (buffer-live-p buffer) (kill-buffer buffer)))))
     nil t t)))

(defun mara-anthropic--normalize (payload)
  "Normalize Anthropic PAYLOAD for the Mara run loop."
  (let* ((blocks (mara--alist-get 'content payload))
         (tool-blocks
          (seq-filter (lambda (block)
                        (equal (mara--alist-get 'type block) "tool_use"))
                      blocks))
         (texts
          (delq nil
                (mapcar (lambda (block)
                          (when (equal (mara--alist-get 'type block) "text")
                            (mara--alist-get 'text block)))
                        blocks))))
    (list :content blocks
          :text (string-join texts "")
          :tool-calls tool-blocks
          :stop-reason (mara--alist-get 'stop_reason payload)
          :usage (mara--alist-get 'usage payload))))

(cl-defmethod mara-provider-cancel ((_provider mara-anthropic-provider) handle)
  "Cancel an outstanding url-retrieve HANDLE."
  (when (buffer-live-p handle)
    (let ((process (get-buffer-process handle)))
      (when (process-live-p process) (delete-process process)))
    (kill-buffer handle)))

(provide 'mara-provider-anthropic)
;;; mara-provider-anthropic.el ends here

