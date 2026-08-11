;;; mara-brain.el --- SWI-Prolog bridge for Mara -*- lexical-binding: t; -*-

;;; Code:

(require 'json)
(require 'mara-core)
(require 'mara-memory)

(defcustom mara-brain-swipl-program "swipl"
  "SWI-Prolog executable used by Mara's symbolic memory brain."
  :type 'string)

(defconst mara-brain--emacs-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing `mara-brain.el'.")

(defcustom mara-brain-prolog-file
  (expand-file-name "../prolog/mara-memory.pl" mara-brain--emacs-directory)
  "Path to Mara's Prolog memory core."
  :type 'file)

(defun mara-brain-available-p ()
  "Return non-nil when the Prolog memory brain can run."
  (and (executable-find mara-brain-swipl-program)
       (file-readable-p mara-brain-prolog-file)))

(defun mara-brain--parse-json (text)
  "Parse one JSON object from TEXT."
  (json-parse-string text
                     :object-type 'alist
                     :array-type 'list
                     :null-object nil
                     :false-object :json-false))

(defun mara-brain--run (command &rest arguments)
  "Run Prolog COMMAND with memory state and ARGUMENTS, returning parsed JSON."
  (unless (mara-brain-available-p)
    (error "Mara Prolog brain unavailable; need %s and %s"
           mara-brain-swipl-program mara-brain-prolog-file))
  (unless mara-memory-current
    (mara-memory-load))
  (let ((buffer (generate-new-buffer " *mara-brain*")))
    (unwind-protect
        (let ((status
               (apply #'process-file
                      mara-brain-swipl-program
                      nil buffer nil
                      "-q" "-s" mara-brain-prolog-file "--"
                      command (mara-memory-path) arguments)))
          (with-current-buffer buffer
            (let ((output (string-trim (buffer-string))))
              (unless (zerop status)
                (error "Mara Prolog brain failed: %s" output))
              (mara-brain--parse-json output))))
      (kill-buffer buffer))))

(defun mara-brain-relationship-snapshot ()
  "Return Prolog-derived organic relationship state."
  (mara-brain--run "relationship"))

(defun mara-brain-relevant-memories (query)
  "Return Prolog-ranked active memories relevant to QUERY."
  (mara--alist-get 'memories (mara-brain--run "relevant" query)))

(provide 'mara-brain)
;;; mara-brain.el ends here
