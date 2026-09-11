;;; mara-modern-test.el --- Tests for Mara modern UI and work tools -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'json)
(require 'mara-test)
(require 'mara-ui-modern)
(require 'mara-work-tools)

(defun mara-modern-test--parse (text)
  "Parse JSON TEXT into an alist."
  (json-parse-string text
                     :object-type 'alist
                     :array-type 'list
                     :null-object nil
                     :false-object nil))

(defun mara-modern-test--count (regexp)
  "Count matches for REGEXP in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((count 0))
      (while (re-search-forward regexp nil t)
        (setq count (1+ count)))
      count)))

(ert-deftest mara-default-profile-migrates-work-capabilities-once ()
  (mara-test-with-state
    (let ((path (mara-state-path "profile" "default")))
      (mara-state-write
       path
       '((name . "default")
         (capabilities . ["memory.read" "memory.write" "buffer.read"
                          "project.read" "git.read" "web.request"])))
      (mara-profile-load "default")
      (dolist (capability '("file.read" "file.write" "shell.exec" "emacs.eval"))
        (should (member capability (mara-profile-capabilities))))
      (should (= mara-profile--capability-schema-version
                 (mara--alist-get 'capabilitySchemaVersion
                                  mara-profile-current))))))

(ert-deftest mara-work-tools-are-registered-and-default-authorized ()
  (mara-test-with-state
    (mara-profile-load "default")
    (dolist (name '("mara_file_list"
                    "mara_file_read"
                    "mara_file_write"
                    "mara_git_status"
                    "mara_git_diff"
                    "mara_git_log"
                    "mara_emacs_buffers"
                    "mara_emacs_read_buffer"
                    "mara_emacs_eval"
                    "mara_bash"
                    "mara_brave_search"))
      (let ((tool (gethash name mara-tools-registry)))
        (should (mara-tool-p tool))
        (should (mara-tools-authorized-p (mara-tool-capability tool)))))))

(ert-deftest mara-file-tools-round-trip-text ()
  (let* ((directory (make-temp-file "mara-file-tools-" t))
         (path (expand-file-name "nested/example.txt" directory)))
    (unwind-protect
        (progn
          (mara-work-tools--file-write
           `(("path" . ,path) ("content" . "hello mara")))
          (let ((result
                 (mara-modern-test--parse
                  (mara-work-tools--file-read `(("path" . ,path))))))
            (should (equal "hello mara" (mara--alist-get 'content result)))
            (should-not (mara--alist-get 'truncated result))))
      (delete-directory directory t))))

(ert-deftest mara-bash-runs-in-selected-directory ()
  (let ((directory (make-temp-file "mara-bash-" t)))
    (unwind-protect
        (let ((result
               (mara-modern-test--parse
                (mara-work-tools--bash
                 `(("command" . "pwd")
                   ("directory" . ,directory))))))
          (should (= 0 (mara--alist-get 'exit result)))
          (should (string-match-p
                   (regexp-quote (file-truename directory))
                   (file-truename
                    (string-trim (mara--alist-get 'output result))))))
      (delete-directory directory t))))

(ert-deftest mara-ui-modern-deduplicates-gptel-and-mara-preamble ()
  (with-temp-buffer
    (insert
     ":PROPERTIES:\n"
     ":GPTEL_MODEL: openrouter/auto\n"
     ":GPTEL_SYSTEM: first prompt\n"
     ":END:\n"
     "#+title: Mara — default — default\n"
     "#+category: mara\n"
     "#+filetags: :mara:gptel:\n"
     "#+property: mara_session first\n\n"
     ":PROPERTIES:\n"
     ":GPTEL_MODEL: openrouter/auto\n"
     ":GPTEL_SYSTEM: duplicate prompt\n"
     ":END:\n"
     "#+title: Mara — default — default\n"
     "#+category: mara\n"
     "#+filetags: :mara:gptel:\n"
     "#+property: mara_session first\n\n"
     "* You\nhello\n")
    (mara-ui-modern--normalize-preamble)
    (should (= 1 (mara-modern-test--count "^:PROPERTIES:$")))
    (should (= 1 (mara-modern-test--count "^#\\+title:")))
    (should (= 1 (mara-modern-test--count "^#\\+category:")))
    (should (= 1 (mara-modern-test--count "^#\\+filetags:")))
    (should (= 1 (mara-modern-test--count
                  "^#\\+property:[ \t]+mara_session")))))

(ert-deftest mara-ui-modern-font-lock-compacts-system-and-tools ()
  (with-temp-buffer
    (mara-mode)
    (insert ":GPTEL_SYSTEM: a very long stored system prompt\n")
    (insert ":GPTEL_TOOLS: mara_status mara_memory_search mara_bash\n")
    (font-lock-ensure (point-min) (point-max))
    (goto-char (point-min))
    (re-search-forward "a very long stored system prompt")
    (should (string-match-p
             "system prompt"
             (format "%s" (get-text-property (match-beginning 0) 'display))))
    (forward-line 1)
    (re-search-forward "mara_status")
    (should (string-match-p
             "3 tools enabled"
             (format "%s" (get-text-property (match-beginning 0) 'display))))))

(provide 'mara-modern-test)
;;; mara-modern-test.el ends here
