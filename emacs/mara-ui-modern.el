;;; mara-ui-modern.el --- Compact metadata presentation for Mara -*- lexical-binding: t; -*-

;;; Commentary:
;; gptel persists its backend/model/system/tool state in an Org property
;; drawer.  Keep that state intact, but make it read like compact metadata
;; instead of a wall of serialized prompt text.  This module also repairs the
;; duplicate preamble bug caused when Mara looked only at point-min for its
;; #+title while gptel legitimately kept a property drawer there.

;;; Code:

(require 'org)
(require 'mara-ui)

(defface mara-ui-metadata-key-face
  '((t :inherit org-date :weight bold))
  "Face for Mara/gptel metadata keys."
  :group 'mara)

(defface mara-ui-metadata-value-face
  '((t :inherit shadow))
  "Face for Mara/gptel metadata values."
  :group 'mara)

(defface mara-ui-metadata-chip-face
  '((t :inherit org-date))
  "Face for compact Mara/gptel metadata summaries."
  :group 'mara)

(defface mara-ui-metadata-boundary-face
  '((t :inherit shadow))
  "Face for property-drawer boundaries."
  :group 'mara)

(defconst mara-ui-modern--font-lock-keywords
  '((mara-ui-modern--match-compact-gptel
     (1 'mara-ui-metadata-key-face t)
     (2 'mara-ui-metadata-value-face t))
    ("^:\\(GPTEL_[[:upper:]_]+\\):[ \t]*\\(.*\\)$"
     (1 'mara-ui-metadata-key-face t)
     (2 'mara-ui-metadata-value-face t))
    ("^:\\(?:PROPERTIES\\|END\\):[ \t]*$"
     (0 'mara-ui-metadata-boundary-face t))
    ("^#\\+\\(title\\|category\\|filetags\\|property\\):[ \t]*\\(.*\\)$"
     (1 'mara-ui-metadata-key-face t)
     (2 'mara-ui-metadata-value-face t)))
  "Extra font-lock rules used in `mara-mode'.")

(defun mara-ui-modern--preamble-end ()
  "Return a marker at the end of Mara's metadata preamble."
  (save-excursion
    (goto-char (point-min))
    (copy-marker
     (if (re-search-forward "^\\* \\(?:You\\|Mara\\)[ \t]*$" nil t)
         (match-beginning 0)
       (point-max))
     t)))

(defun mara-ui-modern--gptel-drawer-end-at-point ()
  "Return end position of a gptel property drawer at point, or nil.

Point must be at the beginning of a :PROPERTIES: line."
  (when (looking-at-p "^:PROPERTIES:[ \t]*$")
    (let ((start (point)))
      (save-excursion
        (when (re-search-forward "^:END:[ \t]*$" nil t)
          (let* ((end (line-end-position))
                 (block (buffer-substring-no-properties start end)))
            (when (string-match-p "^:GPTEL_[[:upper:]_]+:" block)
              (min (point-max) (1+ end)))))))))

(defun mara-ui-modern--dedupe-gptel-drawers (end)
  "Keep the first gptel property drawer before END and delete later copies."
  (save-excursion
    (goto-char (point-min))
    (let ((seen nil))
      (while (re-search-forward "^:PROPERTIES:[ \t]*$" end t)
        (goto-char (match-beginning 0))
        (if-let ((drawer-end (mara-ui-modern--gptel-drawer-end-at-point)))
            (if seen
                (delete-region (point) drawer-end)
              (setq seen t)
              (goto-char drawer-end))
          (forward-line 1))))))

(defun mara-ui-modern--dedupe-line (regexp end)
  "Keep the first preamble line matching REGEXP before END."
  (save-excursion
    (goto-char (point-min))
    (let ((seen nil))
      (while (re-search-forward regexp end t)
        (if seen
            (let ((start (line-beginning-position))
                  (finish (min (point-max) (1+ (line-end-position)))))
              (delete-region start finish)
              (goto-char start))
          (setq seen t))))))

(defun mara-ui-modern--normalize-preamble ()
  "Repair duplicate gptel and Mara metadata in the current chat preamble."
  (let ((end (mara-ui-modern--preamble-end)))
    (unwind-protect
        (progn
          (mara-ui-modern--dedupe-gptel-drawers end)
          (dolist (regexp
                   '("^#\\+title:.*$"
                     "^#\\+category:.*$"
                     "^#\\+filetags:.*$"
                     "^#\\+property:[ \t]+mara_session\\(?:[ \t]+.*\\)?$"))
            (mara-ui-modern--dedupe-line regexp end)))
      (set-marker end nil))))

(defun mara-ui-modern--header-present-p ()
  "Return non-nil when a Mara #+title exists in the preamble."
  (let ((end (mara-ui-modern--preamble-end)))
    (unwind-protect
        (save-excursion
          (goto-char (point-min))
          (re-search-forward "^#\\+title:[ \t]*Mara\\b" end t))
      (set-marker end nil))))

(defun mara-ui-modern--header-insertion-point ()
  "Return where Mara metadata should be inserted without displacing gptel."
  (save-excursion
    (goto-char (point-min))
    (or (mara-ui-modern--gptel-drawer-end-at-point)
        (point-min))))

(defun mara-ui-modern--ensure-header (_original &rest _args)
  "Around advice that keeps one stable Mara/gptel metadata preamble."
  (mara-ui-modern--normalize-preamble)
  (if (mara-ui-modern--header-present-p)
      nil
    (save-excursion
      (goto-char (mara-ui-modern--header-insertion-point))
      (unless (bolp)
        (insert "\n"))
      (insert
       (format "#+title: Mara — %s — %s\n"
               mara-profile-current-name
               (mara-session-chat-slug mara-session-current))
       "#+category: mara\n"
       "#+filetags: :mara:gptel:\n"
       (format "#+property: mara_session %s\n\n"
               (mara-session-id mara-session-current))))
    nil))

(defun mara-ui-modern--compact-summary (key value)
  "Return compact display string for gptel metadata KEY with VALUE."
  (pcase key
    ("GPTEL_SYSTEM"
     (format "system prompt · %d chars" (length value)))
    ("GPTEL_TOOLS"
     (format "%d tools enabled"
             (length (split-string value "[ \t]+" t))))
    (_ value)))

(defun mara-ui-modern--match-compact-gptel (limit)
  "Font-lock matcher that compacts large gptel metadata values up to LIMIT."
  (when (re-search-forward
         "^:\\(GPTEL_\\(?:SYSTEM\\|TOOLS\\)\\):[ \t]*\\(.*\\)$"
         limit t)
    (let* ((key (match-string-no-properties 1))
           (value (match-string-no-properties 2))
           (start (match-beginning 2))
           (end (match-end 2))
           (summary (mara-ui-modern--compact-summary key value)))
      (when (< start end)
        (put-text-property
         start end 'display
         (propertize summary 'face 'mara-ui-metadata-chip-face)))
      t)))

(defun mara-ui-modern--enable-font-lock ()
  "Install Mara's compact metadata font locking in the current buffer."
  (font-lock-add-keywords nil mara-ui-modern--font-lock-keywords 'append)
  (when (boundp 'font-lock-extra-managed-props)
    (add-to-list (make-local-variable 'font-lock-extra-managed-props) 'display))
  (when (fboundp 'font-lock-flush)
    (font-lock-flush)))

(defun mara-ui-modern--configure ()
  "Normalize and style a freshly entered `mara-mode' buffer."
  (mara-ui-modern--normalize-preamble)
  (mara-ui-modern--enable-font-lock))

(add-hook 'mara-mode-hook #'mara-ui-modern--configure)

(unless (advice-member-p #'mara-ui-modern--ensure-header
                         'mara-ui--ensure-header)
  (advice-add 'mara-ui--ensure-header :around #'mara-ui-modern--ensure-header))

(provide 'mara-ui-modern)
;;; mara-ui-modern.el ends here
