;;; mara-test.el --- Tests for Mara -*- lexical-binding: t; -*-

;;; Code:

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
                 mara-session-current nil)
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

(ert-deftest mara-gptel-conversation-uses-persistent-history ()
  (should
   (equal '("hello" "hi" "continue")
          (mara-gptel--conversation
           '(((role . "user") (content . "hello"))
             ((role . "assistant") (content . "hi"))
             ((role . "user") (content . "continue")))))))

(ert-deftest mara-send-ignores-empty-text ()
  (should-not (mara-send ""))
  (should-not (mara-send "   \n\t")))

(ert-deftest mara-send-ignores-submit-without-prompt ()
  (with-temp-buffer
    (mara-mode)
    (should-not (mara-send))))

(provide 'mara-test)
;;; mara-test.el ends here
