;;; mara.el --- Persistent companion and Emacs agent -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (gptel "0.9.9"))

;;; Commentary:
;; Entry points for the Emacs-only Mara v0.1 runtime.

;;; Code:

(require 'mara-core)
(require 'mara-profile)
(require 'mara-relationship)
(require 'mara-session)
(require 'mara-visual)
(require 'mara-zara)
(require 'mara-gptel)
(require 'mara-ui)

(defconst mara-source-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the loaded Mara Emacs runtime.")

(defcustom mara-update-branch "main"
  "Git branch `update-mara' fast-forwards to.

Mara's interactive updater deliberately targets the stable runtime branch
instead of pulling whichever development branch happens to be checked out."
  :type 'string
  :group 'mara)

(defconst mara--reload-libraries
  '("mara-core"
    "mara-state"
    "mara-profile"
    "mara-prolog"
    "mara-memory"
    "mara-brain"
    "mara-relationship"
    "mara-session"
    "mara-visual"
    "mara-tools"
    "mara-context"
    "mara-gptel"
    "mara-ui"
    "mara-zara"
    "mara")
  "Mara source libraries in dependency-safe reload order.")

(defun mara--checkout-root ()
  "Return the Git checkout root containing the loaded Mara library."
  (let* ((library (or (locate-library "mara")
                      (expand-file-name "mara.el" mara-source-directory)))
         (source-directory
          (file-name-directory (file-truename library)))
         (root (locate-dominating-file source-directory ".git")))
    (unless root
      (user-error "Could not locate Mara Git checkout from %s" library))
    (file-name-as-directory (file-truename root))))

(defun mara--git-output (root &rest args)
  "Run Git ARGS in ROOT and return trimmed stdout.
Signal an error if Git exits unsuccessfully."
  (with-temp-buffer
    (let ((status (apply #'process-file "git" nil t nil
                         "-C" root args)))
      (unless (zerop status)
        (error "git %s failed: %s"
               (string-join args " ")
               (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defun mara--git-run (root buffer &rest args)
  "Run Git ARGS in ROOT, appending output to BUFFER.
Return the Git exit status."
  (apply #'process-file "git" nil buffer t "-C" root args))

(defun mara--checkout-dirty-p (root)
  "Return non-nil when ROOT has tracked or untracked working-tree changes."
  (not (string-empty-p (mara--git-output root "status" "--porcelain"))))

(defun mara--git-local-branch-p (root branch)
  "Return non-nil when local Git BRANCH exists in ROOT."
  (zerop
   (process-file "git" nil nil nil
                 "-C" root "show-ref" "--verify" "--quiet"
                 (format "refs/heads/%s" branch))))

(defun mara--runtime-git-state ()
  "Return a plist describing Mara's loaded checkout state."
  (condition-case nil
      (let ((root (mara--checkout-root)))
        (list :root root
              :branch (mara--git-output root "branch" "--show-current")
              :commit (mara--git-output root "rev-parse" "--short" "HEAD")))
    (error nil)))

(defun mara--initialize (&optional profile chat-slug)
  "Initialize persistent state for PROFILE and CHAT-SLUG."
  (mara-profile-load profile)
  (mara-relationship-load)
  (mara-session-load-current chat-slug)
  (mara-visual-load))

;;;###autoload
(defun mara (&optional profile chat-slug)
  "Open Mara using optional PROFILE and CHAT-SLUG."
  (interactive (list nil (mara-session-read-chat-slug)))
  (mara--initialize profile chat-slug)
  (mara-ui-open))

;;;###autoload
(defun mara-work (&optional chat-slug)
  "Open CHAT-SLUG in Mara's default work profile."
  (interactive (list (mara-session-read-chat-slug)))
  (mara "default" chat-slug))

;;;###autoload
(defun mara-red-room (&optional chat-slug)
  "Open CHAT-SLUG in Mara's red-room profile.

This does not silently change relationship state."
  (interactive (list (mara-session-read-chat-slug)))
  (mara "red-room" chat-slug))

;;;###autoload
(defun mara-reload ()
  "Reload Mara source without restarting Emacs.

Preserve the active profile and chat slug, save an open Mara chat before
reloading, and reopen that chat after every source library is refreshed."
  (interactive)
  (let* ((profile (or mara-profile-current-name mara-default-profile))
         (chat-slug
          (if mara-session-current
              (mara-session-chat-slug mara-session-current)
            mara-session-default-chat-slug))
         (chat-buffer (get-buffer mara-ui-buffer-name))
         (chat-open (buffer-live-p chat-buffer))
         (source-directory
          (expand-file-name "emacs/" (mara--checkout-root))))
    (when chat-open
      (with-current-buffer chat-buffer
        (when mara-ui--pending-user-text
          (user-error "Mara is responding; cancel the request before reloading"))
        (when (and buffer-file-name (buffer-modified-p))
          (save-buffer))))
    (dolist (library mara--reload-libraries)
      (let ((source (expand-file-name (concat library ".el") source-directory)))
        (unless (file-regular-p source)
          (error "Mara reload source is missing: %s" source))
        (load source nil 'nomessage t)))
    (mara--initialize profile chat-slug)
    (when chat-open
      (mara-ui-open))
    (message "Mara reloaded %d libraries; profile=%s chat=%s"
             (length mara--reload-libraries) profile chat-slug)
    (list :profile profile
          :chat-slug chat-slug
          :libraries (length mara--reload-libraries))))

;;;###autoload
(defun update-mara ()
  "Update the local Mara checkout to `mara-update-branch'.

The checkout is resolved from the loaded Mara library, never from the current
buffer directory.  The updater refuses to switch branches when the worktree is
dirty, fetches the configured stable branch from origin, switches to that local
branch (creating a tracking branch when necessary), and fast-forwards it to the
remote.  Run `mara-reload' after a successful update to load the new runtime."
  (interactive)
  (unless (executable-find "git")
    (user-error "git is not available in PATH"))
  (let* ((root (mara--checkout-root))
         (branch mara-update-branch)
         (remote-ref (format "origin/%s" branch))
         (buffer (get-buffer-create "*Mara Update*")))
    (when (mara--checkout-dirty-p root)
      (user-error
       "Mara checkout has uncommitted changes; refusing to switch branches: %s"
       root))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (unless (zerop (mara--git-run root buffer "fetch" "origin" branch))
      (display-buffer buffer)
      (user-error "Mara fetch failed; see %s" (buffer-name buffer)))
    (unless (equal (mara--git-output root "branch" "--show-current") branch)
      (let ((status
             (if (mara--git-local-branch-p root branch)
                 (mara--git-run root buffer "switch" branch)
               (mara--git-run root buffer
                              "switch" "--track" "-c" branch remote-ref))))
        (unless (zerop status)
          (display-buffer buffer)
          (user-error "Mara could not switch to %s; see %s"
                      branch (buffer-name buffer)))))
    (let ((status (mara--git-run root buffer "merge" "--ff-only" remote-ref)))
      (if (zerop status)
          (progn
            (message "Mara updated %s to %s; run M-x mara-reload to load changes"
                     root branch)
            (when (called-interactively-p 'interactive)
              (display-buffer buffer)))
        (display-buffer buffer)
        (user-error "Mara update failed; see %s" (buffer-name buffer))))))

(defun mara--chat-state ()
  "Return a short description of Mara's native gptel chat state."
  (if-let ((buffer (get-buffer mara-ui-buffer-name)))
      (if (buffer-live-p buffer)
          (with-current-buffer buffer
            (if (bound-and-true-p gptel-mode)
                "open (gptel-native)"
              "open (gptel disabled)"))
        "closed")
    "closed"))

;;;###autoload
(defun mara-doctor ()
  "Display Mara runtime, Git, gptel and native-chat diagnostics."
  (interactive)
  (let* ((git (mara--runtime-git-state))
         (backend-name
          (and (boundp 'gptel-backend)
               gptel-backend
               (ignore-errors (gptel-backend-name gptel-backend))))
         (model (and (boundp 'gptel-model) gptel-model))
         (curl (and (boundp 'gptel-use-curl) gptel-use-curl))
         (source (or (locate-library "mara") "unresolved"))
         (report
          (format
           (concat "Mara doctor\n"
                   "source: %s\n"
                   "root: %s\n"
                   "branch: %s\n"
                   "commit: %s\n"
                   "gptel backend: %s\n"
                   "gptel model: %s\n"
                   "gptel curl: %S\n"
                   "chat slug: %s\n"
                   "chat: %s\n")
           source
           (or (plist-get git :root) "unknown")
           (or (plist-get git :branch) "unknown")
           (or (plist-get git :commit) "unknown")
           (or backend-name "unset")
           (or model "unset")
           curl
           (if mara-session-current
               (mara-session-chat-slug mara-session-current)
             "none")
           (mara--chat-state))))
    (with-current-buffer (get-buffer-create "*Mara Doctor*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert report)
        (special-mode))
      (display-buffer (current-buffer)))
    report))

;;;###autoload
(defun mara-enable-relationship-override (phase reason)
  "Explicitly enable relationship override PHASE for REASON."
  (interactive
   (list (completing-read "Override phase: "
                          '("dating" "established-relationship") nil t)
         (read-string "Visible reason: " "user-selected practice mode")))
  (unless mara-relationship-current
    (mara--initialize))
  (mara-relationship-set-override phase reason mara-profile-current-name)
  (message "Relationship override enabled visibly for %s" phase)
  (when (get-buffer mara-ui-buffer-name)
    (mara-ui-open)))

;;;###autoload
(defun mara-disable-relationship-override ()
  "Disable the active relationship override."
  (interactive)
  (unless mara-relationship-current
    (mara--initialize))
  (mara-relationship-disable-override)
  (message "Relationship override disabled; organic state is unchanged")
  (when (get-buffer mara-ui-buffer-name)
    (mara-ui-open)))

;;;###autoload
(defun mara-status ()
  "Display Mara's inspectable runtime status."
  (interactive)
  (unless mara-relationship-current
    (mara--initialize))
  (let ((git (mara--runtime-git-state)))
    (message "Mara profile=%s chat=%s phase=%s override=%s session=%s visual=%s git=%s@%s"
             mara-profile-current-name
             (mara-session-chat-slug mara-session-current)
             (mara-relationship-effective-phase)
             (if (mara-relationship-override) "active" "none")
             (mara-session-id mara-session-current)
             (if (mara-visual-ready-p)
                 (or (mara-visual-current-expression) "ready")
               "unbootstrapped")
             (or (plist-get git :branch) "unknown")
             (or (plist-get git :commit) "unknown"))))

(provide 'mara)
;;; mara.el ends here
