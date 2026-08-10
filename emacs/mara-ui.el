;;; mara-ui.el --- Native conversation UI for Mara -*- lexical-binding: t; -*-

;;; Code:

(require 'mara-run)

(defvar mara-ui-buffer-name "*Mara*")
(defvar mara-ui-provider nil)

(define-derived-mode mara-mode special-mode "Mara"
  "Major mode for a Mara conversation."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (define-key mara-mode-map (kbd "RET") #'mara-send)
  (define-key mara-mode-map (kbd "C-c C-c") #'mara-cancel))

(defun mara-ui-open ()
  "Open and render Mara's conversation buffer."
  (let ((buffer (get-buffer-create mara-ui-buffer-name)))
    (with-current-buffer buffer
      (mara-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Mara — profile: %s — phase: %s%s\n\n"
                        mara-profile-current-name
                        (mara-relationship-effective-phase)
                        (if (mara-relationship-override) " [OVERRIDE]" "")))
        (dolist (message (mara-session-messages mara-session-current))
          (let ((content (mara--alist-get 'content message)))
            (when (stringp content)
              (insert (format "%s: %s\n\n"
                              (capitalize (mara--alist-get 'role message))
                              content)))))))
    (pop-to-buffer buffer)))

(defun mara-ui--insert (speaker text)
  "Insert SPEAKER and TEXT in the Mara buffer."
  (with-current-buffer (get-buffer-create mara-ui-buffer-name)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (format "%s: %s\n\n" speaker text)))))

(defun mara-send (text)
  "Send TEXT to Mara asynchronously."
  (interactive (list (read-string "You: ")))
  (unless (and (stringp text) (not (string-empty-p text)))
    (user-error "Message cannot be empty"))
  (mara-ui--insert "You" text)
  (mara-run-start
   mara-ui-provider text
   (lambda (chunk) (mara-ui--insert "Mara" chunk))
   (lambda (_response) (message "Mara finished"))
   (lambda (error-value)
     (mara-ui--insert "Mara error" (format "%S" error-value)))))

(defun mara-cancel ()
  "Cancel Mara's active request."
  (interactive)
  (mara-run-cancel))

(provide 'mara-ui)
;;; mara-ui.el ends here

