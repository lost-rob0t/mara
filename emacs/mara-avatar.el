;;; mara-avatar.el --- Emacs client for Mara's 3D avatar plugin -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Deterministic Emacs client for the mara-avatar plugin. Emacs is a client
;; only: avatar state is authoritative inside the plugin's AvatarActor, never
;; here. All commands call the Mara-owned localhost HTTP API.

;;; Code:

(require 'json)
(require 'url)

(defconst mara-avatar--emacs-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing Mara's loaded Emacs libraries.")

(defcustom mara-avatar-base-url "http://127.0.0.1:7321"
  "Base URL of the mara-avatar plugin's local HTTP API."
  :type 'string
  :group 'mara)

(defcustom mara-avatar-plugin-directory
  (expand-file-name "~/.zarathushtra/plugins/")
  "Directory where Zara discovers user-installed plugins."
  :type 'directory
  :group 'mara)

(defconst mara-avatar--plugin-file-name "mara_avatar.py")
(defconst mara-avatar--ownership-marker "MARA_ZARA_AVATAR = True")

(defun mara-avatar--source-file ()
  "Return Mara's repository-owned avatar plugin source path."
  (expand-file-name
   (concat "../zara-plugin/" mara-avatar--plugin-file-name)
   mara-avatar--emacs-directory))

(defun mara-avatar--installed-file ()
  "Return the configured installed avatar plugin path."
  (expand-file-name mara-avatar--plugin-file-name mara-avatar-plugin-directory))

(defun mara-avatar--owned-file-p (path)
  "Return non-nil when PATH contains Mara's avatar ownership marker."
  (and (file-regular-p path)
       (with-temp-buffer
         (insert-file-contents-literally path nil 0 4096)
         (goto-char (point-min))
         (search-forward mara-avatar--ownership-marker nil t))))

(defun mara-avatar--file-digest (path)
  "Return PATH's SHA-256 digest."
  (with-temp-buffer
    (insert-file-contents-literally path)
    (secure-hash 'sha256 (current-buffer))))

(defun mara-avatar--state ()
  "Return the current avatar plugin installation state."
  (let ((source (mara-avatar--source-file))
        (installed (mara-avatar--installed-file)))
    (cond
     ((not (file-exists-p source)) 'source-missing)
     ((not (file-exists-p installed)) 'not-installed)
     ((not (mara-avatar--owned-file-p installed)) 'foreign)
     ((equal (mara-avatar--file-digest source)
             (mara-avatar--file-digest installed))
      'current)
     (t 'outdated))))

;;;###autoload
(defun mara-avatar-install ()
  "Install or update Mara's avatar plugin in Zara's user-plugin directory."
  (interactive)
  (let ((source (mara-avatar--source-file))
        (installed (mara-avatar--installed-file))
        temporary)
    (unless (file-regular-p source)
      (user-error "Mara avatar plugin source is missing: %s" source))
    (when (and (file-exists-p installed)
               (not (mara-avatar--owned-file-p installed)))
      (user-error "Refusing to replace non-Mara plugin: %s" installed))
    (make-directory mara-avatar-plugin-directory t)
    (setq temporary
          (make-temp-file
           (expand-file-name ".mara-avatar-install-" mara-avatar-plugin-directory)))
    (unwind-protect
        (progn
          (copy-file source temporary t)
          (set-file-modes temporary #o644)
          (rename-file temporary installed t)
          (setq temporary nil))
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))
    (message "Installed Mara avatar plugin at %s; restart Zara to load it" installed)
    installed))

;;;###autoload
(defun mara-avatar-uninstall ()
  "Remove Mara's avatar plugin from Zara's user-plugin directory."
  (interactive)
  (let ((installed (mara-avatar--installed-file)))
    (cond
     ((not (file-exists-p installed))
      (message "Mara avatar plugin is not installed"))
     ((not (mara-avatar--owned-file-p installed))
      (user-error "Refusing to remove non-Mara plugin: %s" installed))
     (t
      (delete-file installed)
      (message "Removed Mara avatar plugin; restart Zara to unload it")))
    installed))

;;;###autoload
(defun mara-avatar-status ()
  "Report the avatar plugin status and return the status document."
  (interactive)
  (let ((document (mara-avatar--request "GET" "/v1/avatar/status" nil)))
    (message "Mara avatar: %s %s"
             (alist-get 'state document)
             (alist-get 'presence (alist-get 'avatar document)))
    document))

(defun mara-avatar--request (method path payload)
  "Send METHOD with PATH and JSON PAYLOAD to the avatar plugin."
  (let* ((url (concat mara-avatar-base-url path))
         (url-request-method method)
         (url-request-extra-headers
          (when payload '(("Content-Type" . "application/json"))))
         (url-request-data
          (when payload
            (encode-coding-string (json-encode payload) 'utf-8))))
    (with-current-buffer (url-retrieve-synchronously url t nil 5)
      (goto-char (point-min))
      (re-search-forward "\r?\n\r?\n" nil t)
      (let ((body (buffer-substring-no-properties (point) (point-max))))
        (kill-buffer)
        (json-read-from-string body)))))

(defun mara-avatar--post (path payload)
  "POST PATH with PAYLOAD to the avatar plugin and return the result."
  (alist-get 'result (mara-avatar--request "POST" path payload)))

;;;###autoload
(defun mara-avatar-show ()
  "Show the avatar window."
  (interactive)
  (mara-avatar--post "/v1/avatar/show" nil))

;;;###autoload
(defun mara-avatar-hide ()
  "Hide the avatar window."
  (interactive)
  (mara-avatar--post "/v1/avatar/hide" nil))

;;;###autoload
(defun mara-avatar-select (avatar-id)
  "Select and load AVATAR-ID as Mara's avatar."
  (interactive
   (let* ((document (mara-avatar--request "GET" "/v1/avatar/list" nil))
          (entries (alist-get 'avatars document))
          (names (mapcar (lambda (entry)
                           (alist-get 'avatarId entry))
                         entries)))
     (list (completing-read "Mara avatar: " names nil nil))))
  (mara-avatar--post "/v1/avatar/select" (list (cons "avatarId" avatar-id))))

;;;###autoload
(defun mara-avatar-emotion (emotion)
  "Present EMOTION (neutral happy sad annoyed excited embarrassed)."
  (interactive
   (list (completing-read
          "Mara emotion: "
          '("neutral" "happy" "sad" "annoyed" "excited" "embarrassed")
          nil t)))
  (mara-avatar--post "/v1/avatar/emotion" (list (cons "emotion" emotion))))

;;;###autoload
(defun mara-avatar-gesture (gesture)
  "Trigger GESTURE (wave nod shrug point)."
  (interactive
   (list (completing-read "Mara gesture: "
                          '("wave" "nod" "shrug" "point")
                          nil t)))
  (mara-avatar--post "/v1/avatar/gesture" (list (cons "gesture" gesture))))

(provide 'mara-avatar)
;;; mara-avatar.el ends here
