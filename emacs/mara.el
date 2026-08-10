;;; mara.el --- Persistent companion and Emacs agent -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Entry points for the Emacs-only Mara v0.1 runtime.

;;; Code:

(require 'mara-core)
(require 'mara-profile)
(require 'mara-relationship)
(require 'mara-session)
(require 'mara-provider-anthropic)
(require 'mara-ui)

(defun mara--initialize (&optional profile)
  "Initialize persistent state for PROFILE."
  (mara-profile-load profile)
  (mara-relationship-load)
  (mara-session-load-current)
  (setq mara-ui-provider (make-mara-anthropic-provider)))

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

