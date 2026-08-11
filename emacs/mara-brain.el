;;; mara-brain.el --- Prolog-backed symbolic brain for Mara -*- lexical-binding: t; -*-

;;; Code:

(require 'mara-core)
(require 'mara-memory)
(require 'mara-prolog)

(defcustom mara-brain-swipl-program mara-prolog-program
  "SWI-Prolog executable used by Mara's symbolic brain."
  :type 'string)

(defconst mara-brain--emacs-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing `mara-brain.el'.")

(defcustom mara-brain-prolog-file
  (expand-file-name "../prolog/mara-memory.pl" mara-brain--emacs-directory)
  "Path to Mara's Prolog memory module."
  :type 'file)

(defcustom mara-brain-prolog-server-file
  (expand-file-name "../prolog/mara-prolog-server.pl" mara-brain--emacs-directory)
  "Path to Mara's repository-local Prolog server."
  :type 'file)

(defvar mara-brain--runtime nil
  "Persistent Prolog runtime used by Mara's brain.")

(defvar mara-brain--loaded-memory-stamp nil
  "Stamp of the memory file currently loaded into Prolog.")

(defun mara-brain--runtime ()
  "Return Mara's lazily created persistent Prolog runtime."
  (unless mara-brain--runtime
    (setq mara-brain--runtime
          (mara-prolog-make-runtime
           mara-brain-swipl-program
           mara-brain-prolog-server-file)))
  mara-brain--runtime)

(defun mara-brain-available-p ()
  "Return non-nil when Mara's persistent Prolog brain can run."
  (and (file-readable-p mara-brain-prolog-file)
       (file-readable-p mara-brain-prolog-server-file)
       (mara-prolog-available-p (mara-brain--runtime))))

(defun mara-brain--ensure-runtime ()
  "Ensure Mara's Prolog subprocess is running and return it."
  (unless (mara-brain-available-p)
    (error "Mara Prolog brain unavailable; need %s, %s, and %s"
           mara-brain-swipl-program
           mara-brain-prolog-file
           mara-brain-prolog-server-file))
  (let ((runtime (mara-brain--runtime)))
    (unless (mara-prolog-live-p runtime)
      ;; A fresh Prolog process has no in-memory facts, even when memory.json
      ;; itself has not changed since the previous process died.
      (setq mara-brain--loaded-memory-stamp nil))
    (mara-prolog-start runtime)))

(defun mara-brain--memory-stamp ()
  "Return an identity stamp for the current durable memory state."
  (let* ((path (mara-memory-path))
         (attributes (and (file-exists-p path)
                          (file-attributes path 'string))))
    (when attributes
      (list path
            mara-memory-revision
            (file-attribute-size attributes)
            (file-attribute-modification-time attributes)))))

(defun mara-brain-sync-memory (&optional force)
  "Load durable memory into persistent Prolog when it changed.
With FORCE non-nil, reload even when the memory stamp is unchanged."
  (unless mara-memory-current
    (mara-memory-load))
  (let* ((runtime (mara-brain--ensure-runtime))
         (path (mara-memory-path))
         (stamp (mara-brain--memory-stamp)))
    (when (or force
              (null mara-brain--loaded-memory-stamp)
              (not (equal stamp mara-brain--loaded-memory-stamp)))
      (mara-prolog-call runtime "load_memory" `((path . ,path)))
      (setq mara-brain--loaded-memory-stamp stamp)))
  mara-brain--loaded-memory-stamp)

(defun mara-brain-start ()
  "Start Mara's persistent Prolog brain and synchronize memory."
  (interactive)
  (mara-brain--ensure-runtime)
  (mara-brain-sync-memory t)
  (when (called-interactively-p 'interactive)
    (message "Mara Prolog brain started"))
  mara-brain--runtime)

(defun mara-brain-stop ()
  "Stop Mara's persistent Prolog brain."
  (interactive)
  (when mara-brain--runtime
    (mara-prolog-stop mara-brain--runtime))
  (setq mara-brain--loaded-memory-stamp nil)
  (when (called-interactively-p 'interactive)
    (message "Mara Prolog brain stopped"))
  nil)

(defun mara-brain-restart ()
  "Restart Mara's persistent Prolog brain and reload durable memory."
  (interactive)
  (if mara-brain--runtime
      (mara-prolog-restart mara-brain--runtime)
    (mara-brain--ensure-runtime))
  (setq mara-brain--loaded-memory-stamp nil)
  (mara-brain-sync-memory t)
  (when (called-interactively-p 'interactive)
    (message "Mara Prolog brain restarted"))
  mara-brain--runtime)

(defun mara-brain--call (method &optional params)
  "Call Prolog METHOD with PARAMS after synchronizing durable memory."
  (mara-brain-sync-memory)
  (mara-prolog-call (mara-brain--runtime) method params))

(defun mara-brain-relationship-snapshot ()
  "Return Prolog-derived organic relationship state."
  (mara-brain--call "relationship"))

(defun mara-brain-relevant-memories (query)
  "Return Prolog-ranked active memories relevant to QUERY."
  (mara--alist-get
   'memories
   (mara-brain--call "relevant" `((query . ,query)))))

(provide 'mara-brain)
;;; mara-brain.el ends here
