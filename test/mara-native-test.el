;;; mara-native-test.el --- Tests for Mara's native gptel UI -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'mara)
(require 'mara-gptel)

(ert-deftest mara-native-mode-is-org-native ()
  (with-temp-buffer
    (mara-mode)
    (should (derived-mode-p 'org-mode))
    (should (equal "* You\n" (mara-ui--prompt-prefix)))
    (should (equal "* Mara\n" (mara-ui--response-prefix)))))

(ert-deftest mara-native-named-chats-use-separate-org-buffers ()
  (mara-test-with-state
    (let ((mara-ui-buffer-name "*Mara named-chat test*")
          (today (mara-session--today))
          first second)
      (unwind-protect
          (save-window-excursion
            (cl-letf (((symbol-function 'gptel-mode) #'ignore)
                      ((symbol-function 'mara-ui--save) #'ignore))
              (mara--initialize "default" "project-alpha")
              (setq first (mara-ui-open))
              (should (string-suffix-p
                       (format "%s--project-alpha.org" today)
                       (buffer-file-name first)))
              (mara--initialize "default" "default")
              (setq second (mara-ui-open))
              (should-not (eq first second))
              (should (string-suffix-p
                       (format "%s--default.org" today)
                       (buffer-file-name second)))
              (should (equal mara-ui-buffer-name (buffer-name second)))
              (should (string-match-p "project-alpha" (buffer-name first)))))
        (dolist (buffer (list first second))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (set-buffer-modified-p nil))
            (kill-buffer buffer)))))))

(ert-deftest mara-native-request-info-accepts-current-gptel-fsm-shape ()
  (let* ((expected '(:buffer "*Mara*" :dry-run t))
         (fsm (gptel-make-fsm :info expected)))
    (should (eq expected (mara-ui--request-info fsm)))))

(ert-deftest mara-native-prepare-request-injects-query-once ()
  (mara-test-with-state
    (mara-profile-load)
    (mara-relationship-load)
    (mara-session-new)
    (with-temp-buffer
      (mara-mode)
      (insert "* You\nremember emacs")
      (let ((source (current-buffer))
            (position (copy-marker (point)))
            queries
            (interactions 0))
        (cl-letf (((symbol-function 'mara-context-system-prompt)
                   (lambda (&optional query)
                     (push query queries)
                     (format "context:%s" query)))
                  ((symbol-function 'mara-relationship-note-session-interaction)
                   (lambda () (cl-incf interactions))))
          ;; Query inspection still receives Mara's dynamic prompt, but must not
          ;; mutate the durable relationship/session state.
          (with-temp-buffer
            (mara-ui--prepare-request
             (list :buffer source :position position :dry-run t))
            (should (equal "context:remember emacs"
                           gptel-system-prompt)))
          (should (= 0 interactions))
          (should-not (mara-session-messages mara-session-current))
          ;; Real dispatch mirrors the user once.  Re-running the transform for
          ;; a tool continuation must not duplicate that turn.
          (with-temp-buffer
            (mara-ui--prepare-request
             (list :buffer source :position position)))
          (with-temp-buffer
            (mara-ui--prepare-request
             (list :buffer source :position position))))
        (should (= 1 interactions))
        (should (= 1 (length (mara-session-messages mara-session-current))))
        (should
         (equal "remember emacs"
                (mara--alist-get
                 'content
                 (car (mara-session-messages mara-session-current)))))
        (should (equal '("remember emacs" "remember emacs" "remember emacs")
                       queries))))))

(ert-deftest mara-native-tool-runs-through-capability-broker ()
  (let ((mara-tools-registry (make-hash-table :test #'equal))
        executed
        callback-value)
    (mara-tools-register
     (make-mara-tool
      :name "native_echo"
      :description "Echo one value."
      :capability "test.echo"
      :input-schema
      '((type . "object")
        (properties . ((value . ((type . "string")
                                  (description . "Value to echo")))))
        (required . ["value"]))
      :function #'ignore))
    (cl-letf (((symbol-function 'mara-tools-authorized-p)
               (lambda (_capability) t))
              ((symbol-function 'mara-tools-execute)
               (lambda (name input callback)
                 (setq executed (list name input))
                 (funcall callback "ok" nil))))
      (let* ((tool (car (mara-gptel-tools)))
             (function (gptel-tool-function tool)))
        (should (gptel-tool-async tool))
        (should-not (gptel-tool-confirm tool))
        (funcall function
                 (lambda (value) (setq callback-value value))
                 "hello")))
    (should (equal "ok" callback-value))
    (should
     (equal '("native_echo" (("value" . "hello")))
            executed))))

(ert-deftest mara-native-tool-decodes-unibyte-utf8-result ()
  (let ((mara-tools-registry (make-hash-table :test #'equal))
        (raw-result
         (encode-coding-string
          "{\"summary\":\"hello — babe\"}"
          'utf-8))
        callback-value)
    (should-not (multibyte-string-p raw-result))
    (mara-tools-register
     (make-mara-tool
      :name "native_unicode"
      :description "Return Unicode JSON text."
      :capability "test.unicode"
      :input-schema '((type . "object"))
      :function #'ignore))
    (cl-letf (((symbol-function 'mara-tools-authorized-p)
               (lambda (_capability) t))
              ((symbol-function 'mara-tools-execute)
               (lambda (_name _input callback)
                 (funcall callback raw-result nil))))
      (let* ((tool (car (mara-gptel-tools)))
             (function (gptel-tool-function tool)))
        (funcall function
                 (lambda (value) (setq callback-value value)))))
    (should (multibyte-string-p callback-value))
    (should (equal "{\"summary\":\"hello — babe\"}" callback-value))))

(ert-deftest mara-native-response-keeps-reasoning-out-of-session-text ()
  (with-temp-buffer
    (mara-mode)
    (let ((start (point)))
      (insert (propertize "private reasoning\n" 'gptel 'ignore))
      (insert
       (propertize
        "Visible answer.\n[[mara-expression:amused]]"
        'gptel 'response))
      (let ((end (point)))
        (insert "\n\n* You\n")
        (should
         (equal "Visible answer."
                (mara-ui--strip-visual-marker start end)))
        (should-not
         (string-match-p
          "mara-expression"
          (buffer-substring-no-properties (point-min) (point-max))))
        (should
         (string-match-p
          "private reasoning"
          (buffer-substring-no-properties (point-min) (point-max))))))))

(ert-deftest mara-native-has-no-legacy-chat-libraries ()
  (should-not (locate-library "mara-run"))
  (should-not (locate-library "mara-provider"))
  (should-not (locate-library "mara-provider-gptel"))
  (should-not (locate-library "mara-gptel-native")))

(ert-deftest mara-doctor-reports-native-chat-state ()
  (let ((mara-ui-buffer-name " *mara-doctor-native-test*"))
    (unwind-protect
        (progn
          (should (equal "closed" (mara--chat-state)))
          (with-current-buffer (get-buffer-create mara-ui-buffer-name)
            (mara-mode)
            (gptel-mode 1))
          (should (equal "open (gptel-native)" (mara--chat-state))))
      (when-let ((buffer (get-buffer mara-ui-buffer-name)))
        (kill-buffer buffer)))))

(provide 'mara-native-test)
;;; mara-native-test.el ends here
