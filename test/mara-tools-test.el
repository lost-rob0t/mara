;;; mara-tools-test.el --- Tests for Mara native tools -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'mara-test)
(require 'mara-tools)

(defun mara-tools-test--parse (json)
  "Parse JSON tool response into an alist."
  (json-parse-string json
                     :object-type 'alist
                     :array-type 'list
                     :null-object nil
                     :false-object nil))

(ert-deftest mara-tools-registers-memory-and-brain-surface ()
  (dolist (name '("mara_status"
                  "mara_memory_search"
                  "mara_memory_remember"
                  "mara_memory_supersede"
                  "mara_relationship_status"
                  "mara_brain_query"
                  "mara_session_history"
                  "mara_profile_get"))
    (should (mara-tool-p (gethash name mara-tools-registry)))))

(ert-deftest mara-tools-json-returns-decoded-unicode ()
  (let* ((summary "tool result — unicode survives 😭")
         (json (mara-tools--json `((summary . ,summary))))
         (parsed (mara-tools-test--parse json)))
    (should (multibyte-string-p json))
    (should (equal summary (mara--alist-get 'summary parsed)))))

(ert-deftest mara-tools-memory-search-falls-back-without-prolog ()
  (mara-test-with-state
    (cl-letf (((symbol-function 'mara-brain-available-p)
               (lambda () nil)))
      (let* ((remember
              (mara-tools-test--parse
               (mara-tools--remember
                '(("subject" . "user")
                  ("predicate" . "preferred_editor")
                  ("object" . "emacs")
                  ("summary" . "User prefers Emacs")))))
             (id (mara--alist-get 'memoryId remember))
             (search
              (mara-tools-test--parse
               (mara-tools--memory-search
                '(("query" . "preferred editor emacs")))))
             (memories (mara--alist-get 'memories search)))
        (should (stringp id))
        (should (equal "fallback" (mara--alist-get 'backend search)))
        (should (= 1 (mara--alist-get 'count search)))
        (should (equal id (mara--alist-get 'id (car memories))))
        (should (equal "emacs"
                       (mara--alist-get 'object (car memories))))))))

(ert-deftest mara-tools-memory-supersede-hides-stale-fallback-record ()
  (mara-test-with-state
    (cl-letf (((symbol-function 'mara-brain-available-p)
               (lambda () nil)))
      (let* ((remember
              (mara-tools-test--parse
               (mara-tools--remember
                '(("subject" . "user")
                  ("predicate" . "preferred_editor")
                  ("object" . "emacs")))))
             (old-id (mara--alist-get 'memoryId remember))
             (replacement
              (mara-tools-test--parse
               (mara-tools--supersede-memory
                `(("memory_id" . ,old-id)
                  ("object" . "doom-emacs")
                  ("summary" . "User now prefers Doom Emacs")))))
             (new-id (mara--alist-get 'memoryId replacement))
             (search
              (mara-tools-test--parse
               (mara-tools--memory-search
                '(("query" . "preferred_editor")))))
             (memories (mara--alist-get 'memories search)))
        (should (not (equal old-id new-id)))
        (should (= 1 (mara--alist-get 'count search)))
        (should (equal new-id (mara--alist-get 'id (car memories))))
        (should (equal "doom-emacs"
                       (mara--alist-get 'object (car memories))))))))

(ert-deftest mara-tools-brain-query-reports-unavailable-runtime ()
  (mara-test-with-state
    (cl-letf (((symbol-function 'mara-brain-available-p)
               (lambda () nil)))
      (let ((result
             (mara-tools-test--parse
              (mara-tools--brain-query
               '(("query" . "editor"))))))
        (should-not (mara--alist-get 'available result))
        (should (string-match-p
                 "unavailable"
                 (mara--alist-get 'reason result)))))))

(ert-deftest mara-context-explains-native-memory-tool-policy ()
  (mara-test-with-state
    (cl-letf (((symbol-function 'mara-brain-available-p)
               (lambda () nil)))
      (mara-profile-load)
      (mara-relationship-load)
      (let ((context (mara-context-system-prompt "remember this")))
        (should (string-match-p "mara_memory_remember" context))
        (should (string-match-p "mara_memory_supersede" context))
        (should (string-match-p "transient chatter" context))))))

(provide 'mara-tools-test)
;;; mara-tools-test.el ends here
