;;; mara-session.el --- Persistent Mara sessions -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'mara-state)

(cl-defstruct mara-session id profile created-at updated-at messages usage)

(defvar mara-session-current nil)

(defun mara-session--directory ()
  "Return the session state directory."
  (expand-file-name "sessions/" mara-data-directory))

(defun mara-session--path (id)
  "Return the state path for session ID."
  (expand-file-name (concat id ".json") (mara-session--directory)))

(defun mara-session-new (&optional profile)
  "Create and persist a session for PROFILE."
  (setq mara-session-current
        (make-mara-session :id (mara--uuid)
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
  "Load the last current session, or create a new one."
  (let* ((pointer (mara-state-read (mara-state-path "current-session") nil))
         (id (and pointer (mara--alist-get 'id pointer)))
         (raw (and id (mara-state-read (mara-session--path id) nil))))
    (if (not raw)
        (mara-session-new)
      (setq mara-session-current
            (make-mara-session
             :id id
             :profile (mara--alist-get 'profile raw)
             :created-at (mara--alist-get 'createdAt raw)
             :updated-at (mara--alist-get 'updatedAt raw)
             :messages (mara--alist-get 'messages raw)
             :usage (mara--alist-get 'usage raw))))))

(provide 'mara-session)
;;; mara-session.el ends here

