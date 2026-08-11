;;; mara-relationship.el --- Relationship state for Mara -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'mara-state)
(require 'mara-memory)
(require 'mara-brain)

(defconst mara-relationship--default
  '((organicRelationshipState
     . ((phase . "acquaintance")
        (userInterest . "unknown")
        (maraInterest . "unknown")
        (mutualInterest . :json-false)
        (familiarityScore . 0.0)
        (affinityScore . 0.5)
        (trustScore . 0.5)
        (phaseEvidence . [])
        (evidence . [])
        (updatedAt . nil)))
    (activeRelationshipOverride . nil))
  "Initial relationship state.")

(defvar mara-relationship-current nil)

(defun mara-relationship--seed-legacy-memory ()
  "Seed pre-Prolog relationship fields into memory once when needed."
  (when (null (mara-memory-records))
    (let* ((organic (mara-relationship-organic))
           (user-interest (mara--alist-get 'userInterest organic "unknown"))
           (mara-interest (mara--alist-get 'maraInterest organic "unknown"))
           (phase (mara--alist-get 'phase organic "acquaintance")))
      (unless (equal user-interest "unknown")
        (mara-memory-add-relationship-signal
         "user" "relationship_interest" user-interest
         "Migrated legacy user relationship interest"))
      (unless (equal mara-interest "unknown")
        (mara-memory-add-relationship-signal
         "mara" "relationship_interest" mara-interest
         "Migrated legacy Mara relationship interest"))
      (when (member phase '("dating" "established-relationship"))
        (mara-memory-add-relationship-signal
         "dyad" "relationship_status" phase
         "Migrated legacy organic relationship phase")))))

(defun mara-relationship-load ()
  "Load persistent relationship state and refresh its organic Prolog view."
  (let* ((path (mara-state-path "relationship"))
         (fallback (copy-tree mara-relationship--default t)))
    (setq mara-relationship-current
          (if (file-exists-p path)
              (mara-state-read path fallback)
            (mara-state-write path fallback))))
  (mara-memory-load)
  (mara-relationship--seed-legacy-memory)
  (when (mara-brain-available-p)
    (condition-case err
        (mara-relationship-refresh-organic)
      (error
       (display-warning 'mara
                        (format "Could not refresh Prolog relationship state: %s" err)))))
  mara-relationship-current)

(defun mara-relationship-save ()
  "Persist the current relationship state cache and override."
  (mara-state-write (mara-state-path "relationship")
                    mara-relationship-current))

(defun mara-relationship-organic ()
  "Return the organic relationship state cache."
  (mara--alist-get 'organicRelationshipState mara-relationship-current))

(defun mara-relationship-refresh-organic ()
  "Recompute organic relationship state from Prolog-backed memories."
  (unless mara-relationship-current
    (error "Relationship state is not loaded"))
  (let ((snapshot (mara-brain-relationship-snapshot)))
    (setf (alist-get 'updatedAt snapshot) (mara--now)
          (alist-get 'organicRelationshipState mara-relationship-current) snapshot)
    (mara-relationship-save)
    snapshot))

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

(defun mara-relationship--fallback-set-interest (party value)
  "Update cached legacy interest PARTY to VALUE when Prolog is unavailable."
  (let ((organic (mara-relationship-organic)))
    (setf (alist-get party organic) value
          (alist-get 'mutualInterest organic)
          (if (and (equal (mara--alist-get 'userInterest organic) "affirmative")
                   (equal (mara--alist-get 'maraInterest organic) "affirmative"))
              t :json-false)
          (alist-get 'updatedAt organic) (mara--now)))
  (mara-relationship-save))

(defun mara-relationship-set-interest (party value)
  "Record current PARTY relationship interest as VALUE.
The durable memory supersedes the prior value; Prolog derives reciprocity."
  (unless (memq party '(userInterest maraInterest))
    (user-error "Party must be userInterest or maraInterest"))
  (unless (member value '("unknown" "friendly" "curious" "affirmative" "uncertain" "declined"))
    (user-error "Invalid interest value"))
  (unless mara-memory-current
    (mara-memory-load))
  (mara-memory-add-relationship-signal
   (if (eq party 'userInterest) "user" "mara")
   "relationship_interest"
   value)
  (if (mara-brain-available-p)
      (mara-relationship-refresh-organic)
    (mara-relationship--fallback-set-interest party value)))

(defun mara-relationship-set-organic-status (status)
  "Record explicit organic relationship STATUS for Prolog to gate.
A dating or established status only becomes effective with reciprocal interest."
  (unless (member status '("acquaintance" "dating" "established-relationship"))
    (user-error "Invalid organic relationship status"))
  (unless mara-memory-current
    (mara-memory-load))
  (mara-memory-add-relationship-signal
   "dyad" "relationship_status" status
   (format "Explicit organic relationship status: %s" status))
  (when (mara-brain-available-p)
    (mara-relationship-refresh-organic)))

(defun mara-relationship-record-interaction (predicate value &optional importance)
  "Append a dyadic relationship event PREDICATE VALUE.
PREDICATE is one of interaction_quality, trust_signal, or boundary_signal."
  (unless (member predicate '("interaction_quality" "trust_signal" "boundary_signal"))
    (user-error "Invalid relationship interaction predicate"))
  (mara-memory-add
   :kind "event"
   :subject "dyad"
   :predicate predicate
   :object value
   :summary (format "Relationship signal: %s=%s" predicate value)
   :confidence 1.0
   :importance (or importance 0.6)
   :source-session
   (when (and (boundp 'mara-session-current)
              mara-session-current
              (fboundp 'mara-session-id))
     (mara-session-id mara-session-current))
   :tags '("relationship" "interaction"))
  (when (and mara-relationship-current
             (mara-brain-available-p))
    (mara-relationship-refresh-organic)))

(defun mara-relationship--session-event-p (record session-id)
  "Return non-nil when RECORD already marks SESSION-ID interaction."
  (and (equal "event" (mara--alist-get 'kind record))
       (equal "dyad" (mara--alist-get 'subject record))
       (equal "session_interaction" (mara--alist-get 'predicate record))
       (equal session-id (mara--alist-get 'sourceSession record))))

(defun mara-relationship-note-session-interaction ()
  "Record one relationship interaction event for the current session.
Repeated turns in the same session do not increase familiarity."
  (when (and (boundp 'mara-session-current)
             mara-session-current
             (fboundp 'mara-session-id))
    (let ((session-id (mara-session-id mara-session-current)))
      (unless (cl-some
               (lambda (record)
                 (mara-relationship--session-event-p record session-id))
               (mara-memory-records))
        (mara-memory-add
         :kind "event"
         :subject "dyad"
         :predicate "session_interaction"
         :object "occurred"
         :summary "A Mara conversation session occurred"
         :confidence 1.0
         :importance 0.2
         :source-session session-id
         :tags '("relationship" "session"))
        (when (and mara-relationship-current
                   (mara-brain-available-p))
          (mara-relationship-refresh-organic))))))

(provide 'mara-relationship)
;;; mara-relationship.el ends here
