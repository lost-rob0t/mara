;;; mara-zara.el --- Install Mara's Zara bridge -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Ownership-safe installation commands for Mara's external Zara plugin.

;;; Code:

(require 'subr-x)

(defconst mara-zara--emacs-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing Mara's loaded Emacs libraries.")

(defcustom mara-zara-plugin-directory
  (expand-file-name "~/.zarathushtra/plugins/")
  "Directory where Zara discovers user-installed plugins."
  :type 'directory
  :group 'mara)

(defconst mara-zara--plugin-file-name "mara_bridge.py")
(defconst mara-zara--ownership-marker "MARA_ZARA_BRIDGE = True")

(defun mara-zara--source-file ()
  "Return Mara's repository-owned Zara plugin source path."
  (expand-file-name
   (concat "../zara-plugin/" mara-zara--plugin-file-name)
   mara-zara--emacs-directory))

(defun mara-zara--installed-file ()
  "Return the configured installed Zara plugin path."
  (expand-file-name mara-zara--plugin-file-name mara-zara-plugin-directory))

(defun mara-zara--owned-file-p (path)
  "Return non-nil when PATH contains Mara's bridge ownership marker."
  (and (file-regular-p path)
       (with-temp-buffer
         (insert-file-contents-literally path nil 0 4096)
         (goto-char (point-min))
         (search-forward mara-zara--ownership-marker nil t))))

(defun mara-zara--file-digest (path)
  "Return PATH's SHA-256 digest."
  (with-temp-buffer
    (insert-file-contents-literally path)
    (secure-hash 'sha256 (current-buffer))))

(defun mara-zara--state ()
  "Return the current bridge installation state."
  (let ((source (mara-zara--source-file))
        (installed (mara-zara--installed-file)))
    (cond
     ((not (file-exists-p source)) 'source-missing)
     ((not (file-exists-p installed)) 'not-installed)
     ((not (mara-zara--owned-file-p installed)) 'foreign)
     ((equal (mara-zara--file-digest source)
             (mara-zara--file-digest installed))
      'current)
     (t 'outdated))))

;;;###autoload
(defun mara-zara-install ()
  "Install or update Mara's bridge in Zara's user-plugin directory."
  (interactive)
  (let ((source (mara-zara--source-file))
        (installed (mara-zara--installed-file))
        temporary)
    (unless (file-regular-p source)
      (user-error "Mara Zara bridge source is missing: %s" source))
    (when (and (file-exists-p installed)
               (not (mara-zara--owned-file-p installed)))
      (user-error "Refusing to replace non-Mara plugin: %s" installed))
    (make-directory mara-zara-plugin-directory t)
    (setq temporary
          (make-temp-file
           (expand-file-name ".mara-zara-install-" mara-zara-plugin-directory)))
    (unwind-protect
        (progn
          (copy-file source temporary t)
          (set-file-modes temporary #o644)
          (rename-file temporary installed t)
          (setq temporary nil))
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))
    (message "Installed Mara Zara bridge at %s; restart Zara to load it" installed)
    installed))

;;;###autoload
(defun mara-zara-uninstall ()
  "Remove Mara's bridge from Zara's user-plugin directory."
  (interactive)
  (let ((installed (mara-zara--installed-file)))
    (cond
     ((not (file-exists-p installed))
      (message "Mara Zara bridge is not installed"))
     ((not (mara-zara--owned-file-p installed))
      (user-error "Refusing to remove non-Mara plugin: %s" installed))
     (t
      (delete-file installed)
      (message "Removed Mara Zara bridge; restart Zara to unload it")))
    installed))

;;;###autoload
(defun mara-zara-status ()
  "Report Mara's Zara bridge installation status and return its details."
  (interactive)
  (let* ((source (mara-zara--source-file))
         (installed (mara-zara--installed-file))
         (state (mara-zara--state))
         (details (list :state state :source source :installed installed)))
    (message "Mara Zara bridge: %s (%s)" state installed)
    details))

(provide 'mara-zara)
;;; mara-zara.el ends here
