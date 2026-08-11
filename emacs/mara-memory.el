;;; mara-memory.el --- Durable memory records for Mara -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'mara-core)
(require 'mara-state)

(defconst mara-memory--default
  '((version . 1)
    (memories . []))
  "Initial memory store.")

(defvar mara-memory-current nil
  "Loaded durable memory store.")

(defun mara-memory-path ()
  "Return the durable memory store path."
  (mara-state-path "memory"))

(defun mara-memory-load ()
  "Load Mara's durable memory store."
  (let ((path (mara-memory-path)))
    (setq mara-memory-current
          (if (file-exists-p path)
              (mara-state-read path mara-memory--default)
            (mara-state-write path mara-memory--default)))))

(defun mara-memory-save ()
  "Persist Mara's durable memory store."
  (unless mara-memory-current
    (mara-memory-load))
  (mara-state-write (mara-memory-path) mara-memory-current))

(defun mara-memory-records ()
  "Return loaded memory records as a list."
  (unless mara-memory-current
    (mara-memory-load))
  (let ((records (mara--alist-get 'memories mara-memory-current)))
    (cond
     ((vectorp records) (append records nil))
     ((listp records) records)
     (t nil))))

(defun mara-memory-find-latest (subject predicate)
  "Return the newest record matching SUBJECT and PREDICATE, or nil."
  (car
   (sort
    (cl-remove-if-not
     (lambda (record)
       (and (equal subject (mara--alist-get 'subject record))
            (equal predicate (mara--alist-get 'predicate record))))
     (copy-sequence (mara-memory-records)))
    (lambda (a b)
      (string> (mara--alist-get 'observedAt a "")
               (mara--alist-get 'observedAt b "")))))))

(defun mara-memory--score-p (value)
  "Return non-nil when VALUE is a valid normalized score."
  (and (numberp value) (<= 0.0 value) (<= value 1.0)))

(defun mara-memory--string-list-p (value)
  "Return non-nil when VALUE is a list of strings."
  (and (listp value) (cl-every #'stringp value)))

(defun mara-memory-validate (record)
  "Validate RECORD and return it, or signal `user-error'."
  (dolist (field '(id kind subject predicate object observedAt))
    (unless (stringp (mara--alist-get field record))
      (user-error "Memory field %s must be a string" field)))
  (unless (member (mara--alist-get 'kind record)
                  '("profile" "event" "record" "derived"))
    (user-error "Invalid memory kind: %S" (mara--alist-get 'kind record)))
  (dolist (field '(confidence importance))
    (unless (mara-memory--score-p (mara--alist-get field record))
      (user-error "Memory field %s must be between 0 and 1" field)))
  (dolist (field '(supports supersedes tags))
    (unless (mara-memory--string-list-p
             (or (mara--alist-get field record) '()))
      (user-error "Memory field %s must be a list of strings" field)))
  record)

(cl-defun mara-memory-add (&key kind subject predicate object
                                (summary "")
                                (confidence 0.7)
                                (importance 0.5)
                                observed-at valid-from valid-to
                                source-session source-message
                                supports supersedes tags)
  "Append one validated memory record and return its ID."
  (unless mara-memory-current
    (mara-memory-load))
  (let* ((id (format "mem-%s" (substring (mara--uuid) 0 24)))
         (record `((id . ,id)
                   (kind . ,kind)
                   (subject . ,subject)
                   (predicate . ,predicate)
                   (object . ,object)
                   (summary . ,summary)
                   (confidence . ,confidence)
                   (importance . ,importance)
                   (observedAt . ,(or observed-at (mara--now)))
                   (validFrom . ,valid-from)
                   (validTo . ,valid-to)
                   (sourceSession . ,source-session)
                   (sourceMessage . ,source-message)
                   (supports . ,(or supports '()))
                   (supersedes . ,(or supersedes '()))
                   (tags . ,(or tags '())))))
    (mara-memory-validate record)
    (setf (alist-get 'memories mara-memory-current)
          (append (mara-memory-records) (list record)))
    (mara-memory-save)
    id))

(defun mara-memory-add-relationship-signal (subject predicate object &optional summary)
  "Persist current relationship evidence for SUBJECT PREDICATE OBJECT.
A previous value for the same relation is explicitly superseded."
  (let* ((previous (mara-memory-find-latest subject predicate))
         (previous-id (and previous (mara--alist-get 'id previous))))
    (mara-memory-add
     :kind "event"
     :subject subject
     :predicate predicate
     :object object
     :summary (or summary (format "%s %s %s" subject predicate object))
     :confidence 1.0
     :importance 0.8
     :source-session
     (when (and (boundp 'mara-session-current)
                mara-session-current
                (fboundp 'mara-session-id))
       (mara-session-id mara-session-current))
     :supersedes (if previous-id (list previous-id) nil)
     :tags '("relationship"))))

(provide 'mara-memory)
;;; mara-memory.el ends here
