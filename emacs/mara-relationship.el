;;; mara-relationship.el --- Relationship state for Mara -*- lexical-binding: t; -*-

;;; Code:

(require 'mara-state)

(defconst mara-relationship--default
  '((organicRelationshipState
     . ((phase . "acquaintance")
        (userInterest . "unknown")
        (maraInterest . "unknown")
        (mutualInterest . :json-false)
        (updatedAt . nil)))
    (activeRelationshipOverride . nil))
  "Initial relationship state.")

(defvar mara-relationship-current nil)

(defun mara-relationship-load ()
  "Load persistent relationship state."
  (let ((path (mara-state-path "relationship")))
    (setq mara-relationship-current
          (if (file-exists-p path)
              (mara-state-read path mara-relationship--default)
            (mara-state-write path mara-relationship--default)))))

(defun mara-relationship-save ()
  "Persist the current relationship state."
  (mara-state-write (mara-state-path "relationship")
                    mara-relationship-current))

(defun mara-relationship-organic ()
  "Return the organic relationship state."
  (mara--alist-get 'organicRelationshipState mara-relationship-current))

(defun mara-relationship-override ()
  "Return the active relationship override, or nil."
  (mara--alist-get 'activeRelationshipOverride mara-relationship-current))

(defun mara-relationship-effective-override ()
  "Return the enabled override when it applies to the active profile/session."
  (let* ((override (mara-relationship-override))
         (scope (and override (mara--alist-get 'scope override))))
    (when (and override
               (eq t (mara--alist-get 'enabled override))
               (or (null scope)
                   (equal scope mara-profile-current-name)
                   (and (boundp 'mara-session-current)
                        mara-session-current
                        (fboundp 'mara-session-id)
                        (equal scope (mara-session-id mara-session-current)))))
      override)))

(defun mara-relationship-effective-phase ()
  "Return the visibly effective relationship phase."
  (let ((override (mara-relationship-effective-override)))
    (if override
        (mara--alist-get 'phase override)
      (mara--alist-get 'phase (mara-relationship-organic) "acquaintance"))))

(defun mara-relationship-set-override (phase reason &optional scope)
  "Explicitly enable PHASE override for REASON and optional SCOPE.
This never changes organic relationship history."
  (unless (member phase '("dating" "established-relationship"))
    (user-error "Override phase must be dating or established-relationship"))
  (unless (and (stringp reason) (not (string-empty-p reason)))
    (user-error "A visible override reason is required"))
  (setf (alist-get 'activeRelationshipOverride mara-relationship-current)
        `((enabled . t)
          (phase . ,phase)
          (reason . ,reason)
          (scope . ,(or scope mara-profile-current-name))
          (enabledAt . ,(mara--now))))
  (mara-relationship-save))

(defun mara-relationship-disable-override ()
  "Disable the active override without changing organic history."
  (setf (alist-get 'activeRelationshipOverride mara-relationship-current) nil)
  (mara-relationship-save))

(defun mara-relationship-set-interest (party value)
  "Set PARTY interest to VALUE and recompute explicit mutual interest."
  (unless (memq party '(userInterest maraInterest))
    (user-error "Party must be userInterest or maraInterest"))
  (unless (member value '("unknown" "friendly" "curious" "affirmative" "uncertain" "declined"))
    (user-error "Invalid interest value"))
  (let ((organic (mara-relationship-organic)))
    (setf (alist-get party organic) value
          (alist-get 'mutualInterest organic)
          (if (and (equal (mara--alist-get 'userInterest organic) "affirmative")
                   (equal (mara--alist-get 'maraInterest organic) "affirmative"))
              t :json-false)
          (alist-get 'updatedAt organic) (mara--now)))
  (mara-relationship-save))

(provide 'mara-relationship)
;;; mara-relationship.el ends here
