;;; mara-state.el --- JSON persistence for Mara -*- lexical-binding: t; -*-

;;; Code:

(require 'json)
(require 'mara-core)

(defun mara-state-path (name &optional profile)
  "Return the state path for NAME and optional PROFILE."
  (let ((root (if profile
                  (expand-file-name (format "profiles/%s/" profile)
                                    mara-data-directory)
                mara-data-directory)))
    (expand-file-name (concat name ".json") root)))

(defun mara-state-read (path fallback)
  "Read JSON from PATH, returning FALLBACK when PATH does not exist."
  (if (not (file-exists-p path))
      fallback
    (condition-case err
        (with-temp-buffer
          (insert-file-contents path)
          (json-parse-buffer :object-type 'alist
                             :array-type 'list
                             :null-object nil
                             :false-object :json-false))
      (error
       (display-warning 'mara
                        (format "Could not read %s: %s" path err))
       fallback))))

(defun mara-state-write (path value)
  "Atomically write VALUE as UTF-8 JSON to PATH."
  (make-directory (file-name-directory path) t)
  (let ((temporary (make-temp-file "mara-state-" nil ".json"))
        (coding-system-for-write 'utf-8-unix))
    (unwind-protect
        (progn
          (with-temp-buffer
            (set-buffer-file-coding-system 'utf-8-unix)
            (insert (json-serialize value
                                    :null-object nil
                                    :false-object :json-false))
            (write-region (point-min) (point-max) temporary nil 'silent))
          (rename-file temporary path t))
      (when (file-exists-p temporary)
        (delete-file temporary))))
  value)

(provide 'mara-state)
;;; mara-state.el ends here
