;;; mara-work-tools.el --- Local work tools for Mara -*- lexical-binding: t; -*-

;;; Commentary:
;; Capability-gated local work tools.  This module extends `mara-tools'
;; without changing the broker: every call is still authorized by the active
;; Mara profile before the implementation runs.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'mara-tools)

(defcustom mara-work-tools-output-limit 65536
  "Maximum number of characters returned by one local work tool."
  :type 'integer
  :group 'mara)

(defcustom mara-work-tools-directory-limit 200
  "Maximum number of directory entries returned by `mara_file_list'."
  :type 'integer
  :group 'mara)

(defcustom mara-work-tools-command-timeout 30
  "Maximum number of seconds allowed for one `mara_bash' invocation."
  :type 'integer
  :group 'mara)

(defcustom mara-work-tools-brave-count 8
  "Default number of Brave Search results returned by `mara_brave_search'."
  :type 'integer
  :group 'mara)

(defun mara-work-tools--optional-string (input key)
  "Return optional string KEY from INPUT, or nil."
  (let ((value (mara--alist-get key input)))
    (when (and (stringp value) (not (string-empty-p value)))
      value)))

(defun mara-work-tools--bounded-text (text)
  "Return TEXT bounded to `mara-work-tools-output-limit'."
  (if (<= (length text) mara-work-tools-output-limit)
      (cons text :json-false)
    (cons (concat (substring text 0 mara-work-tools-output-limit)
                  "\n… output truncated …")
          t)))

(defun mara-work-tools--directory (input)
  "Return an existing directory selected by INPUT."
  (let* ((raw (or (mara-work-tools--optional-string input "directory")
                  default-directory))
         (directory (file-name-as-directory (expand-file-name raw))))
    (unless (file-directory-p directory)
      (user-error "Directory does not exist: %s" directory))
    directory))

(defun mara-work-tools--path (input &optional key)
  "Return expanded path from INPUT KEY, defaulting KEY to \"path\"."
  (expand-file-name
   (mara-tools--required-string input (or key "path"))))

(defun mara-work-tools--process (program args &optional directory)
  "Run PROGRAM with ARGS in DIRECTORY and return (STATUS . OUTPUT)."
  (with-temp-buffer
    (let ((default-directory (or directory default-directory)))
      (let ((status (apply #'process-file program nil t nil args)))
        (cons status (buffer-string))))))

(defun mara-work-tools--file-list (input)
  "List directory entries selected by INPUT."
  (let* ((directory (mara-work-tools--directory input))
         (paths (seq-take
                 (directory-files directory t directory-files-no-dot-files-regexp)
                 mara-work-tools-directory-limit))
         entries)
    (dolist (path paths)
      (let* ((attrs (file-attributes path 'string))
             (kind (cond
                    ((file-directory-p path) "directory")
                    ((stringp (car attrs)) "symlink")
                    (t "file"))))
        (push `((name . ,(file-name-nondirectory path))
                (path . ,path)
                (type . ,kind)
                (size . ,(or (file-attribute-size attrs) 0))
                (modified . ,(format-time-string
                               "%Y-%m-%dT%H:%M:%S%z"
                               (file-attribute-modification-time attrs))))
              entries)))
    (mara-tools--json
     `((directory . ,directory)
       (count . ,(length entries))
       (entries . ,(vconcat (nreverse entries)))))))

(defun mara-work-tools--file-read (input)
  "Read a UTF-8 text file selected by INPUT."
  (let* ((path (mara-work-tools--path input))
         (attrs (file-attributes path))
         (size (and attrs (file-attribute-size attrs))))
    (unless (file-regular-p path)
      (user-error "Not a regular file: %s" path))
    (with-temp-buffer
      (insert-file-contents path nil 0 mara-work-tools-output-limit)
      (let* ((raw (buffer-string))
             (bounded (mara-work-tools--bounded-text raw)))
        (mara-tools--json
         `((path . ,path)
           (size . ,(or size 0))
           (truncated . ,(if (and size (> size mara-work-tools-output-limit))
                             t
                           (cdr bounded)))
           (content . ,(car bounded))))))))

(defun mara-work-tools--file-write (input)
  "Write UTF-8 text file selected by INPUT."
  (let* ((path (mara-work-tools--path input))
         (content (mara-tools--required-string input "content"))
         (parent (file-name-directory path)))
    (when parent
      (make-directory parent t))
    (with-temp-file path
      (insert content))
    (mara-tools--json
     `((path . ,path)
       (written . t)
       (characters . ,(length content))))))

(defun mara-work-tools--git-directory (input)
  "Return Git worktree directory selected by INPUT."
  (let* ((directory (mara-work-tools--directory input))
         (probe (mara-work-tools--process
                 "git" (list "-C" directory "rev-parse" "--show-toplevel"))))
    (unless (zerop (car probe))
      (user-error "Not a Git worktree: %s" directory))
    (file-name-as-directory (string-trim (cdr probe)))))

(defun mara-work-tools--git-status (input)
  "Return concise Git status for INPUT directory."
  (let* ((root (mara-work-tools--git-directory input))
         (result (mara-work-tools--process
                  "git" (list "-C" root "status" "--short" "--branch")))
         (bounded (mara-work-tools--bounded-text (cdr result))))
    (mara-tools--json
     `((root . ,root)
       (exit . ,(car result))
       (truncated . ,(cdr bounded))
       (output . ,(car bounded))))))

(defun mara-work-tools--git-diff (input)
  "Return Git diff for INPUT directory."
  (let* ((root (mara-work-tools--git-directory input))
         (staged (eq (mara--alist-get "staged" input) t))
         (args (append (list "-C" root "diff")
                       (when staged (list "--cached"))))
         (result (mara-work-tools--process "git" args))
         (bounded (mara-work-tools--bounded-text (cdr result))))
    (mara-tools--json
     `((root . ,root)
       (staged . ,(if staged t :json-false))
       (exit . ,(car result))
       (truncated . ,(cdr bounded))
       (output . ,(car bounded))))))

(defun mara-work-tools--git-log (input)
  "Return compact Git log for INPUT directory."
  (let* ((root (mara-work-tools--git-directory input))
         (raw-count (mara--alist-get "count" input))
         (count (if (integerp raw-count) (max 1 (min 50 raw-count)) 12))
         (result
          (mara-work-tools--process
           "git"
           (list "-C" root "log" "--decorate" "--oneline"
                 "-n" (number-to-string count))))
         (bounded (mara-work-tools--bounded-text (cdr result))))
    (mara-tools--json
     `((root . ,root)
       (count . ,count)
       (exit . ,(car result))
       (truncated . ,(cdr bounded))
       (output . ,(car bounded))))))

(defun mara-work-tools--emacs-buffers (_input)
  "Return a compact list of live Emacs buffers."
  (let (rows)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (push `((name . ,(buffer-name buffer))
                (mode . ,(symbol-name major-mode))
                (file . ,buffer-file-name)
                (modified . ,(if (buffer-modified-p) t :json-false)))
              rows)))
    (mara-tools--json
     `((count . ,(length rows))
       (buffers . ,(vconcat (nreverse rows)))))))

(defun mara-work-tools--emacs-read-buffer (input)
  "Read text from an Emacs buffer selected by INPUT."
  (let* ((name (mara-tools--required-string input "buffer"))
         (buffer (get-buffer name)))
    (unless (buffer-live-p buffer)
      (user-error "No live buffer named %s" name))
    (with-current-buffer buffer
      (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
             (bounded (mara-work-tools--bounded-text text)))
        (mara-tools--json
         `((buffer . ,name)
           (mode . ,(symbol-name major-mode))
           (file . ,buffer-file-name)
           (truncated . ,(cdr bounded))
           (content . ,(car bounded))))))))

(defun mara-work-tools--emacs-eval (input)
  "Evaluate one Emacs Lisp FORM from INPUT."
  (let* ((source (mara-tools--required-string input "form"))
         (form (car (read-from-string source)))
         (result (eval form)))
    (mara-tools--json
     `((form . ,source)
       (result . ,(prin1-to-string result))))))

(defun mara-work-tools--bash (input)
  "Execute one shell command from INPUT with a bounded timeout."
  (let* ((command (mara-tools--required-string input "command"))
         (directory (mara-work-tools--directory input))
         (timeout-bin (executable-find "timeout"))
         (program (or timeout-bin shell-file-name))
         (args (if timeout-bin
                   (list (format "%ds" mara-work-tools-command-timeout)
                         shell-file-name shell-command-switch command)
                 (list shell-command-switch command)))
         (result (mara-work-tools--process program args directory))
         (bounded (mara-work-tools--bounded-text (cdr result))))
    (mara-tools--json
     `((directory . ,directory)
       (command . ,command)
       (exit . ,(car result))
       (timedOut . ,(if (= (car result) 124) t :json-false))
       (truncated . ,(cdr bounded))
       (output . ,(car bounded))))))

(defun mara-work-tools--brave-key ()
  "Return Brave Search API key from the environment, or nil."
  (or (getenv "BRAVE_SEARCH_API_KEY")
      (getenv "BRAVE_API_KEY")))

(defun mara-work-tools--brave-search (input)
  "Search the web with Brave Search using INPUT."
  (let* ((query (mara-tools--required-string input "query"))
         (raw-count (mara--alist-get "count" input))
         (count (if (integerp raw-count)
                    (max 1 (min 20 raw-count))
                  mara-work-tools-brave-count))
         (key (mara-work-tools--brave-key)))
    (unless (and key (not (string-empty-p key)))
      (user-error
       "Brave Search key missing; set BRAVE_SEARCH_API_KEY or BRAVE_API_KEY"))
    (let* ((url-request-method "GET")
           (url-request-extra-headers
            `(("Accept" . "application/json")
              ("X-Subscription-Token" . ,key)))
           (url
            (format
             "https://api.search.brave.com/res/v1/web/search?q=%s&count=%d"
             (url-hexify-string query) count))
           (buffer (url-retrieve-synchronously url t t 15)))
      (unless (buffer-live-p buffer)
        (user-error "Brave Search request failed"))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (unless (re-search-forward "\r?\n\r?\n" nil t)
              (user-error "Malformed Brave Search response"))
            (let* ((payload
                    (json-parse-buffer
                     :object-type 'alist
                     :array-type 'list
                     :null-object nil
                     :false-object :json-false))
                   (web (mara--alist-get 'web payload))
                   (results (append (mara--alist-get 'results web []) nil))
                   rows)
              (dolist (result results)
                (push `((title . ,(mara--alist-get 'title result ""))
                        (url . ,(mara--alist-get 'url result ""))
                        (description . ,(mara--alist-get 'description result "")))
                      rows))
              (mara-tools--json
               `((query . ,query)
                 (count . ,(length rows))
                 (results . ,(vconcat (nreverse rows)))))))
        (kill-buffer buffer)))))

(mara-tools-register
 (make-mara-tool
  :name "mara_file_list"
  :description "List files and directories in a local directory."
  :capability "file.read"
  :input-schema
  '((type . "object")
    (properties
     . ((directory . ((type . "string")
                      (description . "Directory to list; defaults to the current Emacs directory"))))))
  :function #'mara-work-tools--file-list))

(mara-tools-register
 (make-mara-tool
  :name "mara_file_read"
  :description "Read a local UTF-8 text file with bounded output."
  :capability "file.read"
  :input-schema
  '((type . "object")
    (properties
     . ((path . ((type . "string")
                 (description . "File path to read")))))
    (required . ["path"]))
  :function #'mara-work-tools--file-read))

(mara-tools-register
 (make-mara-tool
  :name "mara_file_write"
  :description "Create or replace a local UTF-8 text file, creating parent directories as needed."
  :capability "file.write"
  :input-schema
  '((type . "object")
    (properties
     . ((path . ((type . "string")
                 (description . "File path to write")))
        (content . ((type . "string")
                    (description . "Complete file contents")))))
    (required . ["path" "content"]))
  :function #'mara-work-tools--file-write))

(mara-tools-register
 (make-mara-tool
  :name "mara_git_status"
  :description "Show concise Git branch and worktree status for a local repository."
  :capability "git.read"
  :input-schema
  '((type . "object")
    (properties
     . ((directory . ((type . "string")
                      (description . "Path inside the Git worktree"))))))
  :function #'mara-work-tools--git-status))

(mara-tools-register
 (make-mara-tool
  :name "mara_git_diff"
  :description "Show the working-tree or staged Git diff for a local repository."
  :capability "git.read"
  :input-schema
  '((type . "object")
    (properties
     . ((directory . ((type . "string")
                      (description . "Path inside the Git worktree")))
        (staged . ((type . "boolean")
                   (description . "When true, show the staged diff"))))))
  :function #'mara-work-tools--git-diff))

(mara-tools-register
 (make-mara-tool
  :name "mara_git_log"
  :description "Show a compact decorated Git commit log for a local repository."
  :capability "git.read"
  :input-schema
  '((type . "object")
    (properties
     . ((directory . ((type . "string")
                      (description . "Path inside the Git worktree")))
        (count . ((type . "integer")
                  (description . "Number of commits, from 1 to 50"))))))
  :function #'mara-work-tools--git-log))

(mara-tools-register
 (make-mara-tool
  :name "mara_emacs_buffers"
  :description "List live Emacs buffers with mode, file, and modified state."
  :capability "buffer.read"
  :input-schema '((type . "object"))
  :function #'mara-work-tools--emacs-buffers))

(mara-tools-register
 (make-mara-tool
  :name "mara_emacs_read_buffer"
  :description "Read the current text of a named Emacs buffer with bounded output."
  :capability "buffer.read"
  :input-schema
  '((type . "object")
    (properties
     . ((buffer . ((type . "string")
                   (description . "Exact Emacs buffer name")))))
    (required . ["buffer"]))
  :function #'mara-work-tools--emacs-read-buffer))

(mara-tools-register
 (make-mara-tool
  :name "mara_emacs_eval"
  :description "Evaluate one Emacs Lisp form in the running Emacs process."
  :capability "emacs.eval"
  :input-schema
  '((type . "object")
    (properties
     . ((form . ((type . "string")
                 (description . "Single Emacs Lisp form to evaluate")))))
    (required . ["form"]))
  :function #'mara-work-tools--emacs-eval))

(mara-tools-register
 (make-mara-tool
  :name "mara_bash"
  :description "Run one Bash-compatible shell command locally with a bounded timeout and output limit."
  :capability "shell.exec"
  :input-schema
  '((type . "object")
    (properties
     . ((command . ((type . "string")
                    (description . "Shell command to execute")))
        (directory . ((type . "string")
                      (description . "Working directory; defaults to the current Emacs directory")))))
    (required . ["command"]))
  :function #'mara-work-tools--bash))

(mara-tools-register
 (make-mara-tool
  :name "mara_brave_search"
  :description "Search the web with Brave Search. Requires BRAVE_SEARCH_API_KEY or BRAVE_API_KEY in Emacs' environment."
  :capability "web.request"
  :input-schema
  '((type . "object")
    (properties
     . ((query . ((type . "string")
                  (description . "Web search query")))
        (count . ((type . "integer")
                  (description . "Number of results, from 1 to 20")))))
    (required . ["query"]))
  :function #'mara-work-tools--brave-search))

(provide 'mara-work-tools)
;;; mara-work-tools.el ends here
