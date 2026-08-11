;;; mara-ui.el --- Native conversation UI for Mara -*- lexical-binding: t; -*-

;;; Code:

(require 'subr-x)
(require 'mara-run)

(defvar mara-ui-buffer-name "*Mara*")
(defvar mara-ui-provider nil)

(defvar-local mara-ui-prompt-start nil)
(defvar-local mara-ui-input-start nil)

(define-derived-mode mara-mode text-mode "Mara"
  "Major mode for a Mara conversation."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local buffer-read-only nil)
  (define-key mara-mode-map (kbd "RET") #'mara-send)
  (define-key mara-mode-map (kbd "C-c C-c") #'mara-cancel))

(defun mara-ui--insert-read-only (text)
  "Insert TEXT as protected transcript content."
  (let ((start (point)))
    (insert text)
    (add-text-properties
     start (point)
     '(read-only t
       rear-nonsticky (read-only)))))

(defun mara-ui--remove-prompt ()
  "Remove the current editable prompt, when present."
  (when (and (markerp mara-ui-prompt-start)
             (marker-position mara-ui-prompt-start))
    (let ((inhibit-read-only t))
      (delete-region mara-ui-prompt-start (point-max))))
  (setq mara-ui-prompt-start nil
        mara-ui-input-start nil))

(defun mara-ui--prompt ()
  "Insert a fresh editable input prompt and move point there."
  (goto-char (point-max))
  (setq mara-ui-prompt-start (copy-marker (point) t))
  (mara-ui--insert-read-only "You: ")
  (setq mara-ui-input-start (copy-marker (point) t))
  (goto-char (point-max)))

(defun mara-ui--input-text ()
  "Return the current editable input text, or nil when unavailable."
  (when (and (markerp mara-ui-input-start)
             (marker-position mara-ui-input-start))
    (string-trim
     (buffer-substring-no-properties mara-ui-input-start (point-max)))))

(defun mara-ui--append (speaker text)
  "Append SPEAKER and TEXT to the protected Mara transcript."
  (with-current-buffer (get-buffer-create mara-ui-buffer-name)
    (let ((inhibit-read-only t))
      (mara-ui--remove-prompt)
      (goto-char (point-max))
      (mara-ui--insert-read-only
       (format "%s: %s\n\n" speaker text)))))

(defun mara-ui-open ()
  "Open and render Mara's conversation buffer."
  (let ((buffer (get-buffer-create mara-ui-buffer-name)))
    (with-current-buffer buffer
      (mara-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (mara-ui--insert-read-only
         (format "Mara — profile: %s — phase: %s%s\n\n"
                 mara-profile-current-name
                 (mara-relationship-effective-phase)
                 (if (mara-relationship-override) " [OVERRIDE]" "")))
        (dolist (message (mara-session-messages mara-session-current))
          (let ((content (mara--alist-get 'content message)))
            (when (stringp content)
              (mara-ui--insert-read-only
               (format "%s: %s\n\n"
                       (capitalize (mara--alist-get 'role message))
                       content)))))
        (mara-ui--prompt)))
    (pop-to-buffer buffer)
    (with-current-buffer buffer
      (goto-char (point-max))
      (when (fboundp 'evil-insert-state)
        (evil-insert-state)))))

(defun mara-send (&optional text)
  "Send TEXT to Mara asynchronously.
When TEXT is nil, send the contents of Mara's editable input region.
Empty input and submits while no prompt is available are ignored."
  (interactive)
  (let ((message-text
         (or text
             (if (eq major-mode 'mara-mode)
                 (mara-ui--input-text)
               (read-string "You: ")))))
    (if (or (not (stringp message-text))
            (string-empty-p message-text))
        nil
      (when (eq major-mode 'mara-mode)
        (mara-ui--remove-prompt))
      (mara-ui--append "You" message-text)
      (mara-run-start
       mara-ui-provider message-text
       (lambda (chunk)
         (mara-ui--append "Mara" chunk))
       (lambda (_response)
         (with-current-buffer (get-buffer-create mara-ui-buffer-name)
           (mara-ui--prompt)
           (when (fboundp 'evil-insert-state)
             (evil-insert-state)))
         (message "Mara finished"))
       (lambda (error-value)
         (mara-ui--append "Mara error" (format "%S" error-value))
         (with-current-buffer (get-buffer-create mara-ui-buffer-name)
           (mara-ui--prompt)
           (when (fboundp 'evil-insert-state)
             (evil-insert-state))))))))

(defun mara-cancel ()
  "Cancel Mara's active request and restore the input prompt."
  (interactive)
  (mara-run-cancel)
  (with-current-buffer (get-buffer-create mara-ui-buffer-name)
    (unless (and (markerp mara-ui-input-start)
                 (marker-position mara-ui-input-start))
      (mara-ui--prompt))
    (when (fboundp 'evil-insert-state)
      (evil-insert-state))))

(with-eval-after-load 'evil
  (evil-set-initial-state 'mara-mode 'insert)
  (evil-define-key 'insert mara-mode-map (kbd "RET") #'mara-send)
  (evil-define-key 'normal mara-mode-map (kbd "RET") #'mara-send)
  (evil-define-key '(insert normal) mara-mode-map
    (kbd "C-c C-c") #'mara-cancel))

(provide 'mara-ui)
;;; mara-ui.el ends here
