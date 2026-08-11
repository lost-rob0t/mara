;;; mara-ui.el --- Org-native gptel conversation UI for Mara -*- lexical-binding: t; -*-

;;; Commentary:
;; Mara's primary conversation surface is an ordinary Org buffer with
;; `gptel-mode' enabled.  gptel owns prompt/response insertion, streaming,
;; reasoning display, tool continuation, and chat-state restoration.  Mara
;; layers dynamic identity/relationship/memory context, persistent session
;; mirroring, capability-controlled tools, and visual reactions around it.

;;; Code:

(require 'gptel)
(require 'org)
(require 'subr-x)
(require 'mara-context)
(require 'mara-gptel-native)
(require 'mara-relationship)
(require 'mara-run)
(require 'mara-session)
(require 'mara-visual)

(defvar mara-ui-buffer-name "*Mara*"
  "Canonical buffer name used by the active Mara conversation.")

(defvar mara-ui-provider nil
  "Compatibility provider handle for the legacy Mara run loop.")

(defcustom mara-ui-directory nil
  "Directory containing persistent Mara Org chats.

When nil, store chats under the `chats/' directory inside
`mara-data-directory'."
  :type '(choice (const :tag "Use Mara data directory" nil)
                 directory)
  :group 'mara)

(defvar-local mara-ui--pending-user-text nil
  "User text mirrored for the currently active gptel request.")

(defvar-local mara-ui--configured nil
  "Non-nil after Mara-specific gptel configuration is installed.")

(define-derived-mode mara-mode org-mode "Mara"
  "Org-native gptel conversation mode for Mara."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t))

(defun mara-ui--directory ()
  "Return the directory used for persistent Mara Org chats."
  (file-name-as-directory
   (expand-file-name
    (or mara-ui-directory
        (expand-file-name "chats/" mara-data-directory)))))

(defun mara-ui--chat-path ()
  "Return the persistent Org path for `mara-session-current'."
  (unless mara-session-current
    (mara-session-new))
  (expand-file-name
   (format "%s.org" (mara-session-id mara-session-current))
   (mara-ui--directory)))

(defun mara-ui--prompt-prefix ()
  "Return Mara's visible Org prompt prefix."
  "* You\n")

(defun mara-ui--response-prefix ()
  "Return Mara's visible Org response prefix."
  "* Mara\n")

(defun mara-ui--current-user-text (&optional position)
  "Return the current Mara user prompt ending at POSITION.

POSITION defaults to point.  The prompt is delimited by the nearest
Mara user heading, which is cosmetic to gptel but gives the Org chat a
stable human-readable structure."
  (let ((end (or position (point))))
    (save-excursion
      (goto-char end)
      (when (re-search-backward "^\\* You[ \t]*$" nil t)
        (forward-line 1)
        (string-trim
         (buffer-substring-no-properties (point) end))))))

(defun mara-ui--ensure-header ()
  "Ensure the current Mara Org chat has persistent metadata."
  (save-excursion
    (goto-char (point-min))
    (unless (looking-at-p "#\\+title:")
      (insert
       (format "#+title: Mara — %s\n" mara-profile-current-name)
       "#+category: mara\n"
       "#+filetags: :mara:gptel:\n"
       (format "#+property: mara_session %s\n\n"
               (mara-session-id mara-session-current))))))

(defun mara-ui--insert-session-history ()
  "Render the current JSON session into an empty Org chat.

This is a one-time compatibility migration for sessions created by the
older bespoke Mara transcript UI."
  (dolist (message (mara-session-messages mara-session-current))
    (let ((role (mara--alist-get 'role message))
          (content (mara--alist-get 'content message)))
      (when (stringp content)
        (pcase role
          ("user"
           (insert (mara-ui--prompt-prefix) content "\n\n"))
          ("assistant"
           (insert (mara-ui--response-prefix))
           (let ((start (point)))
             (insert content)
             (add-text-properties
              start (point)
              '(gptel response front-sticky (gptel))))
           (insert "\n\n"))))))
  (insert (mara-ui--prompt-prefix)))

(defun mara-ui--ensure-chat-content ()
  "Initialize the current Mara Org file when it has no conversation yet."
  (mara-ui--ensure-header)
  (save-excursion
    (goto-char (point-min))
    (unless (re-search-forward "^\\* \\(?:You\\|Mara\\)[ \t]*$" nil t)
      (goto-char (point-max))
      (mara-ui--insert-session-history))))

(defun mara-ui--configure-prefixes ()
  "Install Mara's cosmetic Org speaker prefixes buffer-locally."
  (setq-local gptel-prompt-prefix-alist
              (copy-tree gptel-prompt-prefix-alist))
  (setq-local gptel-response-prefix-alist
              (copy-tree gptel-response-prefix-alist))
  (setf (alist-get 'mara-mode gptel-prompt-prefix-alist)
        (mara-ui--prompt-prefix))
  (setf (alist-get 'mara-mode gptel-response-prefix-alist)
        (mara-ui--response-prefix))
  ;; Keep Mara's conversation linear even when the user enables Org branching
  ;; for other gptel buffers.
  (setq-local gptel-org-branching-context nil))

(defun mara-ui--configure-buffer ()
  "Configure the current Org buffer as Mara's native gptel chat."
  (unless (derived-mode-p 'mara-mode)
    (mara-mode))
  (setq-local gptel-backend (or mara-gptel-backend gptel-backend))
  (setq-local gptel-model (or mara-gptel-model gptel-model))
  (setq-local gptel-system-prompt (mara-context-system-prompt))
  (setq-local gptel-tools (mara-gptel-native-tools))
  (setq-local gptel-use-tools t)
  (setq-local gptel-confirm-tool-calls 'auto)
  (setq-local gptel-include-tool-results t)
  (setq-local gptel-use-context 'system)
  (setq-local gptel-track-media t)
  (setq-local gptel-include-reasoning 'ignore)
  (setq-local gptel-stream t)
  (setq-local org-startup-with-inline-images t)
  (mara-ui--configure-prefixes)
  (gptel-mode 1)
  (when (fboundp 'gptel-highlight-mode)
    (gptel-highlight-mode 1))
  (unless mara-ui--configured
    (add-hook 'gptel-prompt-transform-functions
              #'mara-ui--prepare-request nil t)
    (add-hook 'gptel-post-response-functions #'mara-ui--after-response nil t)
    (setq mara-ui--configured t))
  (define-key mara-mode-map (kbd "C-c RET") #'mara-send)
  (define-key mara-mode-map (kbd "C-c C-c") #'mara-cancel)
  (define-key mara-mode-map (kbd "C-c C-v") #'mara-visual-render-scene))

(defun mara-ui--prepare-request (info)
  "Inject Mara state into the gptel request described by INFO.

This runs in gptel's prompt-construction buffer.  The source Mara
buffer is available through INFO, so the current user turn can drive
memory retrieval while the durable session mirror is updated once."
  (when-let* ((source-ref (plist-get info :buffer))
              (source (get-buffer source-ref)))
    (when (buffer-live-p source)
      (let ((query
             (with-current-buffer source
               (mara-ui--current-user-text
                (when-let ((position (plist-get info :position)))
                  (and (markerp position)
                       (marker-position position)))))))
        (when (and (stringp query)
                   (not (string-empty-p query)))
          (with-current-buffer source
            (unless (equal query mara-ui--pending-user-text)
              (setq mara-ui--pending-user-text query)
              (mara-session-add-message "user" query)
              (mara-relationship-note-session-interaction)))
          (setq-local gptel-system-prompt
                      (mara-context-system-prompt query)))))))

(defun mara-ui--response-text (start end)
  "Return only normal assistant response text between START and END.

gptel watermarks reasoning and tool records separately.  Mara's JSON
session mirror keeps the conversational answer while the Org file keeps
gptel's richer reasoning/tool UI."
  (let ((position start)
        chunks)
    (while (< position end)
      (let* ((kind (get-text-property position 'gptel))
             (next (or (next-single-property-change
                        position 'gptel nil end)
                       end)))
        (when (eq kind 'response)
          (push (buffer-substring-no-properties position next) chunks))
        (setq position next)))
    (string-trim (apply #'concat (nreverse chunks)))))

(defun mara-ui--strip-visual-marker (start end)
  "Consume and remove trailing visual metadata between START and END.

Return the clean response text for session persistence."
  (let* ((raw (mara-ui--response-text start end))
         (visible (mara-visual-consume-response raw)))
    (unless (equal raw visible)
      (save-restriction
        (narrow-to-region start end)
        (save-excursion
          (goto-char (point-min))
          (when (re-search-forward
                 "\\(?:\n\\)?\\[\\[mara-expression:[[:alnum:]-]+\\]\\][[:space:]]*\\'"
                 nil t)
            (let ((inhibit-read-only t)
                  (inhibit-modification-hooks t))
              (delete-region (match-beginning 0) (match-end 0)))))))
    visible))

(defun mara-ui--save ()
  "Persist the current Mara Org chat and gptel state."
  (when buffer-file-name
    (save-buffer)))

(defun mara-ui--after-response (start end)
  "Mirror a completed gptel response from START to END into Mara state."
  ;; gptel has already inserted the next prompt prefix by the time this hook
  ;; runs.  Move there before stripping metadata so point tracks the deletion.
  (when (fboundp 'gptel-end-of-response)
    (gptel-end-of-response start end))
  (unwind-protect
      (when (< start end)
        (let ((text (mara-ui--strip-visual-marker start end)))
          (unless (string-empty-p (string-trim text))
            (mara-session-add-message "assistant" text))))
    (setq mara-ui--pending-user-text nil)
    (when (derived-mode-p 'org-mode)
      (condition-case nil
          (org-display-inline-images)
        (error nil)))
    (mara-ui--save)
    (when (and (mara-visual-ready-p)
               (mara-visual-current-expression))
      (ignore-errors (mara-visual-display)))))

(defun mara-ui-open ()
  "Open Mara's persistent Org-native gptel conversation."
  (make-directory (mara-ui--directory) t)
  (let* ((path (mara-ui--chat-path))
         (buffer (find-file-noselect path)))
    (with-current-buffer buffer
      (mara-mode)
      (mara-ui--configure-buffer)
      (mara-ui--ensure-chat-content)
      (mara-ui--save)
      (rename-buffer mara-ui-buffer-name t)
      (goto-char (point-max)))
    (pop-to-buffer buffer)
    (when (mara-visual-ready-p)
      (ignore-errors (mara-visual-display)))
    buffer))

(defun mara-send (&optional text)
  "Send the current Org prompt through gptel.

When TEXT is non-nil, append it to the current Mara prompt before
sending.  Empty prompts are ignored."
  (interactive)
  (when (derived-mode-p 'mara-mode)
    (when (and (stringp text)
               (not (string-empty-p (string-trim text))))
      (goto-char (point-max))
      (insert text))
    (let ((message-text (mara-ui--current-user-text)))
      (when (and (stringp message-text)
                 (not (string-empty-p message-text)))
        (gptel-send)
        t))))

(defun mara-cancel ()
  "Abort the active gptel request in the current Mara chat."
  (interactive)
  (when (derived-mode-p 'mara-mode)
    (gptel-abort (current-buffer))
    (setq mara-ui--pending-user-text nil)))

(with-eval-after-load 'evil
  (evil-set-initial-state 'mara-mode 'insert)
  (evil-define-key '(insert normal) mara-mode-map
    (kbd "C-c RET") #'mara-send)
  (evil-define-key '(insert normal) mara-mode-map
    (kbd "C-c C-c") #'mara-cancel)
  (evil-define-key '(insert normal) mara-mode-map
    (kbd "C-c C-v") #'mara-visual-render-scene))

(provide 'mara-ui)
;;; mara-ui.el ends here
