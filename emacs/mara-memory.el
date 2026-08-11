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

(defvar mara-memory-revision 0
  "Monotonic in-process revision of loaded or persisted memory state.")

(defun mara-memory-path ()
  "Return the durable memory store path."
  (mara-state-path "memory"))

(defun mara-memory-load ()
  "Load Mara's durable memory store."
  (let* ((path (mara-memory-path))
         (fallback (copy-tree mara-memory--default t)))
    (setq mara-memory-current
          (if (file-exists-p path)
              (mara-state-read path fallback)
            (mara-state-write path fallback)))
    (cl-incf mara-memory-revision)
    mara-memory-current))

(defun mara-memory-save ()
  "Persist Mara's durable memory store."
  (unless mara-memory-current
    (mara-memory-load))
  (prog1
      (mara-state-write (mara-memory-path) mara-memory-current)
    (cl-incf mara-memory-revision)))

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
               (mara--alist-get 'observedAt b ""))))))

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

(defun mara-memory-add (&rest plist)
  "Add a durable memory record from PLIST and return its ID."
  (unless mara-memory-current
    (mara-memory-load))
  (let* ((id (or (plist-get plist :id) (mara--uuid)))
         (record
          `((id . ,id)
            (kind . ,(or (plist-get plist :kind) "record"))
            (subject . ,(or (plist-get plist :subject) "user"))
            (predicate . ,(or (plist-get plist :predicate) "memory"))
            (object . ,(or (plist-get plist :object) ""))
            (summary . ,(or (plist-get plist :summary)
                            (plist-get plist :object)
                            ""))
            (confidence . ,(or (plist-get plist :confidence) 1.0))
            (importance . ,(or (plist-get plist :importance) 0.5))
            (observedAt . ,(or (plist-get plist :observed-at) (mara--now)))
            (supports . ,(or (plist-get plist :supports) '()))
            (supersedes . ,(or (plist-get plist :supersedes) '()))
            (tags . ,(or (plist-get plist :tags) '())))))
    (mara-memory-validate record)
    (let ((records (mara-memory-records)))
      (setf (alist-get 'memories mara-memory-current)
            (vconcat (append records (list record)))))
    (mara-memory-save)
    id))

(defun mara-memory-add-relationship-signal (subject predicate object
                                                    &optional summary)
  "Add a relationship signal for SUBJECT PREDICATE OBJECT.
The newest record supersedes the previous active value for the same subject and
predicate while preserving the old record for provenance."
  (let* ((previous (mara-memory-find-latest subject predicate))
         (previous-id (and previous (mara--alist-get 'id previous))))
    (mara-memory-add
     :kind "event"
     :subject subject
     :predicate predicate
     :object object
     :summary (or summary (format "%s %s = %s" subject predicate object))
     :confidence 1.0
     :importance 0.9
     :supersedes (if previous-id (list previous-id) '())
     :tags '("relationship"))))

(provide 'mara-memory)
;;; mara-memory.el ends here
