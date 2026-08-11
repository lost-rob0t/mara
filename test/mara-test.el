;;; mara-test.el --- Tests for Mara -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'mara)

(defmacro mara-test-with-state (&rest body)
  "Execute BODY with isolated Mara state."
  (declare (indent 0))
  `(let ((mara-data-directory (make-temp-file "mara-test-" t)))
     (unwind-protect
         (progn
           (setq mara-profile-current nil
                 mara-identity-current nil
                 mara-relationship-current nil
                 mara-session-current nil
                 mara-visual-current nil)
           ,@body)
       (delete-directory mara-data-directory t))))

(ert-deftest mara-state-round-trip ()
  (mara-test-with-state
    (let ((path (mara-state-path "round-trip"))
          (value '((name . "Mara") (enabled . t))))
      (mara-state-write path value)
      (should (equal "Mara" (mara--alist-get 'name (mara-state-read path nil))))
      (should (eq t (mara--alist-get 'enabled (mara-state-read path nil)))))))

(ert-deftest mara-override-preserves-organic-state ()
  (mara-test-with-state
    (mara-profile-load "red-room")
    (mara-relationship-load)
    (let ((organic (copy-tree (mara-relationship-organic))))
      (mara-relationship-set-override "dating" "practice mode" "red-room")
      (should (equal "dating" (mara-relationship-effective-phase)))
      (should (equal organic (mara-relationship-organic)))
      (mara-relationship-disable-override)
      (should (equal "acquaintance" (mara-relationship-effective-phase)))
      (should (equal organic (mara-relationship-organic))))))

(ert-deftest mara-mutual-interest-requires-both-parties ()
  (mara-test-with-state
    (mara-profile-load)
    (mara-relationship-load)
    (mara-relationship-set-interest 'userInterest "affirmative")
    (should-not (eq t (mara--alist-get 'mutualInterest
                                       (mara-relationship-organic))))
    (mara-relationship-set-interest 'maraInterest "affirmative")
    (should (eq t (mara--alist-get 'mutualInterest
                                   (mara-relationship-organic))))))

(ert-deftest mara-context-marks-override ()
  (mara-test-with-state
    (mara-profile-load "red-room")
    (mara-relationship-load)
    (mara-relationship-set-override "dating" "practice mode" "red-room")
    (let ((context (mara-context-system-prompt)))
      (should (string-match-p "explicit, not organic" context))
      (should (string-match-p "Never describe an override-selected phase as organically reached" context)))))

(ert-deftest mara-override-does-not-leak-across-profiles ()
  (mara-test-with-state
    (mara-profile-load "red-room")
    (mara-relationship-load)
    (mara-relationship-set-override "dating" "practice mode" "red-room")
    (should (equal "dating" (mara-relationship-effective-phase)))
    (mara-profile-load "default")
    (should (equal "acquaintance" (mara-relationship-effective-phase)))
    (should (mara-relationship-override))))

(ert-deftest mara-session-survives-reload ()
  (mara-test-with-state
    (mara-profile-load)
    (mara-session-new)
    (let ((id (mara-session-id mara-session-current)))
      (mara-session-add-message "user" "hello")
      (setq mara-session-current nil)
      (mara-session-load-current)
      (should (equal id (mara-session-id mara-session-current)))
      (should (equal "hello"
                     (mara--alist-get 'content
                                      (car (mara-session-messages mara-session-current))))))))

(ert-deftest mara-gptel-conversation-preserves-explicit-roles ()
  (should
   (equal '((prompt . "hello")
            (response . "hi")
            (prompt . "continue"))
          (mara-gptel--conversation
           '(((role . "user") (content . "hello"))
             ((role . "assistant") (content . "hi"))
             ((role . "user") (content . "continue")))))))

(ert-deftest mara-gptel-conversation-preserves-consecutive-user-turns ()
  (should
   (equal '((prompt . "first")
            (prompt . "retry"))
          (mara-gptel--conversation
           '(((role . "user") (content . "first"))
             ((role . "user") (content . "retry")))))))

(ert-deftest mara-gptel-callback-streams-and-assembles-final-text ()
  (let ((state (list :chunks nil))
        chunks final reported)
    (mara-gptel--dispatch-callback
     "Hel" '(:stream t :status "HTTP/2 200") nil state
     (lambda (chunk) (push chunk chunks))
     (lambda (response) (setq final response))
     (lambda (error-value) (setq reported error-value)))
    (mara-gptel--dispatch-callback
     "lo" '(:stream t :status "HTTP/2 200") nil state
     (lambda (chunk) (push chunk chunks))
     (lambda (response) (setq final response))
     (lambda (error-value) (setq reported error-value)))
    (should-not final)
    (should-not reported)
    (should (equal '("Hel" "lo") (nreverse chunks)))
    (mara-gptel--dispatch-callback
     t '(:stream t :status "HTTP/2 200") nil state
     #'ignore
     (lambda (response) (setq final response))
     (lambda (error-value) (setq reported error-value)))
    (should-not reported)
    (should (eq t (plist-get final :streamed)))
    (should (equal "Hello" (plist-get final :text)))))

(ert-deftest mara-gptel-callback-surfaces-handler-errors ()
  (let ((state (list :chunks nil)) reported)
    (mara-gptel--dispatch-callback
     "hello" '(:status "HTTP 200") nil state
     #'ignore
     (lambda (_response) (error "boom"))
     (lambda (error-value) (setq reported error-value)))
    (should (string-match-p "Mara gptel callback failed: boom" reported))))

(ert-deftest mara-gptel-callback-rejects-empty-final-response ()
  (let ((state (list :chunks nil)) reported succeeded)
    (mara-gptel--dispatch-callback
     "   \n" '(:status "HTTP 200") nil state
     #'ignore
     (lambda (_response) (setq succeeded t))
     (lambda (error-value) (setq reported error-value)))
    (should-not succeeded)
    (should (string-match-p "gptel returned an empty response" reported))))

(ert-deftest mara-run-stream-holds-only-visual-metadata-suffix ()
  (let (parts)
    (let ((run (make-mara-run
                :cancelled nil
                :stream-text ""
                :stream-emitted 0
                :on-text (lambda (chunk) (push chunk parts)))))
      (mara-run--stream-chunk run "Hello")
      (should (equal "Hello" (apply #'concat (nreverse (copy-sequence parts)))))
      (mara-run--stream-chunk run "\n[")
      (mara-run--stream-chunk run "[mara-expression:amused]]")
      (should (= 5 (mara-run--stream-safe-end run)))
      (should (equal "Hello" (apply #'concat (nreverse (copy-sequence parts)))))
      (mara-run--flush-stream run "Hello")
      (should (equal "Hello" (apply #'concat (nreverse parts)))))))

(ert-deftest mara-visual-response-marker-is-hidden ()
  (pcase-let ((`(,text . ,expression)
               (mara-visual--parse-response
                "Yeah, that tracks.\n[[mara-expression:amused]]")))
    (should (equal "Yeah, that tracks." text))
    (should (equal "amused" expression))))

(ert-deftest mara-visual-unknown-response-marker-is-still-hidden ()
  (pcase-let ((`(,text . ,expression)
               (mara-visual--parse-response
                "Nope.\n[[mara-expression:laser-eyes]]")))
    (should (equal "Nope." text))
    (should-not expression)))

(ert-deftest mara-context-includes-visual-reaction-protocol ()
  (mara-test-with-state
    (mara-profile-load)
    (mara-relationship-load)
    (should
     (string-match-p
      "mara-expression:NAME"
      (mara-context-system-prompt)))))

(ert-deftest mara-send-ignores-empty-text ()
  (should-not (mara-send ""))
  (should-not (mara-send "   \n\t")))

(ert-deftest mara-send-ignores-submit-without-prompt ()
  (with-temp-buffer
    (mara-mode)
    (should-not (mara-send))))

(ert-deftest mara-checkout-root-follows-loaded-library ()
  (let* ((repo (make-temp-file "mara-checkout-" t))
         (emacs-directory (expand-file-name "emacs" repo))
         (library (expand-file-name "mara.el" emacs-directory)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" repo))
          (make-directory emacs-directory)
          (write-region "" nil library nil 'silent)
          (cl-letf (((symbol-function 'locate-library)
                     (lambda (_library) library)))
            (should
             (equal (file-name-as-directory (file-truename repo))
                    (mara--checkout-root)))))
      (delete-directory repo t))))

(ert-deftest update-mara-runs-git-at-checkout-root ()
  (let (invocation)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_program) "/usr/bin/git"))
              ((symbol-function 'mara--checkout-root)
               (lambda () "/tmp/mara/"))
              ((symbol-function 'process-file)
               (lambda (program _infile _destination _display &rest args)
                 (setq invocation (cons program args))
                 0)))
      (update-mara)
      (should
       (equal '("git" "-C" "/tmp/mara/" "pull" "--ff-only")
              invocation)))))

(provide 'mara-test)
;;; mara-test.el ends here
