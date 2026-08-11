;;; mara-session.el --- Persistent Mara sessions -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'mara-state)

(cl-defstruct mara-session id profile created-at updated-at messages usage)

(defvar mara-session-current nil)

(defcustom mara-session-previous-day-context-limit 24000
  "Maximum number of characters from the previous day's chat to review."
  :type 'integer
  :group 'mara)

(defun mara-session--directory ()
  "Return the session state directory."
  (expand-file-name "sessions/" mara-data-directory))

(defun mara-session--path (id)
  "Return the state path for session ID."
  (expand-file-name (concat id ".json") (mara-session--directory)))

(defun mara-session--local-date (&optional time)
  "Return local calendar date for TIME as YYYY-MM-DD."
  (format-time-string "%Y-%m-%d" time))

(defun mara-session--today ()
  "Return today's local calendar date."
  (mara-session--local-date (current-time)))

(defun mara-session--yesterday ()
  "Return yesterday's local calendar date."
  (mara-session--local-date
   (time-subtract (current-time) (days-to-time 1))))

(defun mara-session--profile-slug (&optional profile)
  "Return filesystem-safe slug for PROFILE."
  (replace-regexp-in-string
   "[^[:alnum:]._-]+" "_"
   (or profile mara-profile-current-name mara-default-profile)))

(defun mara-session--daily-id (&optional date profile)
  "Return deterministic session ID for DATE and PROFILE."
  (format "%s--%s"
          (or date (mara-session--today))
          (mara-session--profile-slug profile)))

(defun mara-session--from-raw (id raw)
  "Build a session with ID from persisted RAW state."
  (make-mara-session
   :id id
   :profile (mara--alist-get 'profile raw)
   :created-at (mara--alist-get 'createdAt raw)
   :updated-at (mara--alist-get 'updatedAt raw)
   :messages (mara--alist-get 'messages raw)
   :usage (mara--alist-get 'usage raw)))

(defun mara-session--timestamp-local-date (timestamp)
  "Return local date represented by RFC3339 TIMESTAMP, or nil."
  (when (stringp timestamp)
    (ignore-errors
      (mara-session--local-date (date-to-time timestamp)))))

(defun mara-session--raw-date (raw)
  "Return the best local calendar date represented by RAW session state."
  (or (mara-session--timestamp-local-date (mara--alist-get 'updatedAt raw))
      (mara-session--timestamp-local-date (mara--alist-get 'createdAt raw))))

(defun mara-session-new (&optional profile)
  "Load or create today's daily session for PROFILE without erasing it."
  (let* ((date (mara-session--today))
         (id (mara-session--daily-id date profile))
         (raw (mara-state-read (mara-session--path id) nil)))
    (if raw
        (setq mara-session-current (mara-session--from-raw id raw))
      (mara-session-new-daily date profile))))

(defun mara-session-new-daily (&optional date profile)
  "Create and persist the daily session for DATE and PROFILE."
  (setq mara-session-current
        (make-mara-session :id (mara-session--daily-id date profile)
                           :profile (or profile mara-profile-current-name)
                           :created-at (mara--now)
                           :updated-at (mara--now)
                           :messages nil
                           :usage nil))
  (mara-session-save)
  mara-session-current)

(defun mara-session-add-message (role content)
  "Append a message with ROLE and CONTENT to the current session."
  (unless mara-session-current (mara-session-new))
  (setf (mara-session-messages mara-session-current)
        (append (mara-session-messages mara-session-current)
                (list `((role . ,role) (content . ,content)))))
  (setf (mara-session-updated-at mara-session-current) (mara--now))
  (mara-session-save))

(defun mara-session-save ()
  "Persist `mara-session-current'."
  (when mara-session-current
    (let ((value `((id . ,(mara-session-id mara-session-current))
                   (profile . ,(mara-session-profile mara-session-current))
                   (createdAt . ,(mara-session-created-at mara-session-current))
                   (updatedAt . ,(mara-session-updated-at mara-session-current))
                   (messages . ,(vconcat (mara-session-messages mara-session-current)))
                   (usage . ,(mara-session-usage mara-session-current)))))
      (mara-state-write (mara-session--path (mara-session-id mara-session-current)) value)
      (mara-state-write (mara-state-path "current-session")
                        `((id . ,(mara-session-id mara-session-current)))))))

(defun mara-session-load-current ()
  "Load today's profile-specific session, creating or migrating it as needed."
  (let* ((today (mara-session--today))
         (daily-id (mara-session--daily-id today))
         (daily-raw (mara-state-read (mara-session--path daily-id) nil))
         (pointer (mara-state-read (mara-state-path "current-session") nil))
         (pointer-id (and pointer (mara--alist-get 'id pointer)))
         (pointer-raw
          (and pointer-id
               (not (equal pointer-id daily-id))
               (mara-state-read (mara-session--path pointer-id) nil))))
    (cond
     (daily-raw
      (setq mara-session-current (mara-session--from-raw daily-id daily-raw)))
     ((and pointer-raw
           (equal (mara--alist-get 'profile pointer-raw mara-profile-current-name)
                  mara-profile-current-name)
           (equal (mara-session--raw-date pointer-raw) today))
      ;; First daily-session rollout: preserve today's legacy UUID conversation
      ;; by copying its persisted state into today's deterministic daily ID.
      (setq mara-session-current (mara-session--from-raw daily-id pointer-raw))
      (setf (mara-session-profile mara-session-current) mara-profile-current-name)
      (mara-session-save))
     (t
      (mara-session-new-daily today mara-profile-current-name)))
    mara-session-current))

(defun mara-session--previous-day-raw ()
  "Return persisted session state for yesterday and the active profile."
  (mara-state-read
   (mara-session--path (mara-session--daily-id (mara-session--yesterday)))
   nil))

(defun mara-session--message-line (message)
  "Render one persisted MESSAGE as readable transcript text."
  (let ((role (mara--alist-get 'role message))
        (content (mara--alist-get 'content message)))
    (when (stringp content)
      (format "%s: %s\n"
              (if (equal role "assistant") "Mara" "User")
              content))))

(defun mara-session--bounded-transcript (messages limit)
  "Render newest MESSAGES within LIMIT characters, preserving order."
  (let ((remaining (max 0 limit))
        (chunks nil)
        (truncated nil))
    (dolist (message (reverse messages))
      (let ((line (mara-session--message-line message)))
        (when line
          (cond
           ((<= (length line) remaining)
            (push line chunks)
            (setq remaining (- remaining (length line))))
           ((> remaining 0)
            (push (concat "…" (substring line (- (length line) remaining))) chunks)
            (setq remaining 0
                  truncated t))
           (t
            (setq truncated t))))))
    (concat
     (when truncated "[Earlier previous-day messages omitted for context budget.]\n")
     (apply #'concat chunks))))

(defun mara-session-previous-day-context ()
  "Return bounded previous-day conversation review text, or nil."
  (let* ((raw (mara-session--previous-day-raw))
         (messages (and raw (mara--alist-get 'messages raw)))
         (transcript
          (and messages
               (mara-session--bounded-transcript
                messages mara-session-previous-day-context-limit))))
    (when (and transcript (not (string-empty-p transcript)))
      (format
       (concat "Previous-day conversation review (%s). Use this as conversational "
               "history for continuity; current-turn instructions take precedence:\n%s")
       (mara-session--yesterday)
       transcript))))

(provide 'mara-session)
;;; mara-session.el ends here
