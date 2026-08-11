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
(require 'mara-provider-gptel)
(require 'mara-ui)

(defconst mara-source-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the loaded Mara Emacs runtime.")

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

(defun mara--initialize (&optional profile)
  "Initialize persistent state for PROFILE."
  (mara-profile-load profile)
  (mara-relationship-load)
  (mara-session-load-current)
  (setq mara-ui-provider (make-mara-gptel-provider)))

;;;###autoload
(defun mara (&optional profile)
  "Open Mara using optional PROFILE."
  (interactive)
  (mara--initialize profile)
  (mara-ui-open))

;;;###autoload
(defun mara-work ()
  "Open Mara's default work profile."
  (interactive)
  (mara "default"))

;;;###autoload
(defun mara-red-room ()
  "Open Mara's red-room profile without silently changing relationship state."
  (interactive)
  (mara "red-room"))

;;;###autoload
(defun update-mara ()
  "Fast-forward the local Mara checkout with Git.

This resolves the checkout from the loaded Mara library rather than the
current buffer's directory.  It never creates a merge commit.  Restart Emacs
after a successful update so the new runtime is loaded cleanly."
  (interactive)
  (unless (executable-find "git")
    (user-error "git is not available in PATH"))
  (let* ((root (mara--checkout-root))
         (buffer (get-buffer-create "*Mara Update*")))
    (with-current-buffer buffer
      (erase-buffer))
    (let ((status (process-file "git" nil buffer t
                                "-C" root "pull" "--ff-only")))
      (if (zerop status)
          (progn
            (message "Mara updated in %s; restart Emacs to load changes" root)
            (when (called-interactively-p 'interactive)
              (display-buffer buffer)))
        (display-buffer buffer)
        (user-error "Mara update failed; see %s" (buffer-name buffer))))))

;;;###autoload
(defun mara-enable-relationship-override (phase reason)
  "Explicitly enable relationship override PHASE for REASON."
  (interactive
   (list (completing-read "Override phase: "
                          '("dating" "established-relationship") nil t)
         (read-string "Visible reason: " "user-selected practice mode")))
  (unless mara-relationship-current (mara--initialize))
  (mara-relationship-set-override phase reason mara-profile-current-name)
  (message "Relationship override enabled visibly for %s" phase)
  (when (get-buffer mara-ui-buffer-name) (mara-ui-open)))

;;;###autoload
(defun mara-disable-relationship-override ()
  "Disable the active relationship override."
  (interactive)
  (unless mara-relationship-current (mara--initialize))
  (mara-relationship-disable-override)
  (message "Relationship override disabled; organic state is unchanged")
  (when (get-buffer mara-ui-buffer-name) (mara-ui-open)))

;;;###autoload
(defun mara-status ()
  "Display Mara's inspectable runtime status."
  (interactive)
  (unless mara-relationship-current (mara--initialize))
  (message "Mara profile=%s phase=%s override=%s session=%s"
           mara-profile-current-name
           (mara-relationship-effective-phase)
           (if (mara-relationship-override) "active" "none")
           (mara-session-id mara-session-current)))

(provide 'mara)
;;; mara.el ends here
