;;; mara-core.el --- Core configuration for Mara -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Shared configuration and small utilities for the Mara runtime.

;;; Code:

(require 'subr-x)

(defgroup mara nil
  "A persistent companion and Emacs agent."
  :group 'applications)

(defcustom mara-data-directory
  (expand-file-name "mara/" (or (getenv "XDG_DATA_HOME")
                                 (expand-file-name "~/.local/share/")))
  "Directory containing Mara's persistent local state."
  :type 'directory)

(defcustom mara-default-profile "default"
  "Profile loaded when no profile was selected explicitly."
  :type 'string)

(defcustom mara-run-max-turns 8
  "Maximum provider turns in one Mara run."
  :type 'integer)

(defcustom mara-run-tool-budget 8
  "Maximum client tool executions in one Mara run."
  :type 'integer)

(defcustom mara-run-timeout 120
  "Maximum number of seconds for one Mara run."
  :type 'number)

(defun mara--now ()
  "Return the current time as an RFC 3339 string."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))

(defun mara--uuid ()
  "Return a sufficiently unique local identifier."
  (secure-hash 'sha256
               (format "%s:%s:%s:%s"
                       (float-time) (emacs-pid) (random) (user-uid))))

(defun mara--alist-get (key alist &optional default)
  "Read KEY from ALIST, accepting symbol and string keys."
  (let ((value (or (alist-get key alist)
                   (alist-get (if (symbolp key) (symbol-name key) key)
                              alist nil nil #'equal))))
    (if (null value) default value)))

(provide 'mara-core)
;;; mara-core.el ends here

