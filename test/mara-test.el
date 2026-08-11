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
           (when (and (boundp 'mara-brain--runtime)
                      (fboundp 'mara-brain-stop))
             (mara-brain-stop)
             (setq mara-brain--runtime nil))
           (setq mara-profile-current nil
                 mara-identity-current nil
                 mara-relationship-current nil
                 mara-memory-current nil
                 mara-memory-revision 0
                 mara-session-current nil
                 mara-visual-current nil)
           ,@body)
       (when (and (boundp 'mara-brain--runtime)
                  (fboundp 'mara-brain-stop))
         (mara-brain-stop)
         (setq mara-brain--runtime nil))
       (delete-directory mara-data-directory t))))

(ert-deftest mara-state-round-trip ()
  (mara-test-with-state
    (let ((path (mara-state-path "round-trip"))
          (value '((name . "Mara") (enabled . t))))
      (mara-state-write path value)
      (should (equal "Mara" (mara--alist-get 'name (mara-state-read path nil))))
      (should (eq t (mara--alist-get 'enabled (mara-state-read path nil)))))))

(ert-deftest mara-memory-round-trip ()
  (mara-test-with-state
    (mara-memory-load)
    (let ((id (mara-memory-add
               :kind "profile"
               :subject "user"
               :predicate "favorite_editor"
               :object "emacs"
               :summary "User prefers Emacs"
               :confidence 1.0
               :importance 0.8)))
      (setq mara-memory-current nil)
      (mara-memory-load)
      (let ((record (mara-memory-find-latest "user" "favorite_editor")))
        (should (equal id (mara--alist-get 'id record)))
        (should (equal "emacs" (mara--alist-get 'object record)))))))

(ert-deftest mara-prolog-runtime-persists-across-calls ()
  (let ((runtime (mara-prolog-make-runtime)))
    (unwind-protect
        (progn
          (skip-unless (mara-prolog-available-p runtime))
          (let ((first (mara-prolog-call runtime "ping")))
            (should (equal "pong" (mara--alist-get 'status first))))
          (let ((process (mara-prolog-runtime-process runtime)))
            (should (process-live-p process))
            (let ((second (mara-prolog-call runtime "ping")))
              (should (equal "pong" (mara--alist-get 'status second))))
            (should (eq process (mara-prolog-runtime-process runtime)))))
      (mara-prolog-stop runtime))))

(ert-deftest mara-brain-reloads-memory-without-process-restart ()
  (mara-test-with-state
    (skip-unless (mara-brain-available-p))
    (mara-memory-load)
    (mara-memory-add-relationship-signal
     "user" "relationship_interest" "affirmative")
    (let* ((first (mara-brain-relationship-snapshot))
           (process (mara-prolog-runtime-process mara-brain--runtime)))
      (should (equal "affirmative" (mara--alist-get 'userInterest first)))
      (mara-memory-add-relationship-signal
       "user" "relationship_interest" "declined")
      (let ((second (mara-brain-relationship-snapshot)))
        (should (equal "declined" (mara--alist-get 'userInterest second))))
      (should (eq process
                  (mara-prolog-runtime-process mara-brain--runtime))))))

(ert-deftest mara-relationship-interest-memory-supersedes-old-value ()
  (mara-test-with-state
    (mara-profile-load)
    (mara-relationship-load)
    (mara-relationship-set-interest 'userInterest "affirmative")
    (mara-relationship-set-interest 'userInterest "declined")
    (let* ((latest (mara-memory-find-latest "user" "relationship_interest"))
           (supersedes (mara--alist-get 'supersedes latest)))
      (should (equal "declined" (mara--alist-get 'object latest)))
      (should (= 1 (length supersedes))))))

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

(ert-deftest update-mara-targets-stable-branch ()
  (let (calls)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_program) "/usr/bin/git"))
              ((symbol-function 'mara--checkout-root)
               (lambda () "/tmp/mara/"))
              ((symbol-function 'mara--checkout-dirty-p)
               (lambda (_root) nil))
              ((symbol-function 'mara--git-output)
               (lambda (_root &rest args)
                 (if (equal args '("branch" "--show-current"))
                     "agent/prolog-memory-core"
                   "")))
              ((symbol-function 'mara--git-local-branch-p)
               (lambda (_root branch) (equal branch "main")))
              ((symbol-function 'mara--git-run)
               (lambda (_root _buffer &rest args)
                 (push args calls)
                 0)))
      (let ((mara-update-branch "main"))
        (update-mara))
      (should
       (equal '(("fetch" "origin" "main")
                ("switch" "main")
                ("merge" "--ff-only" "origin/main"))
              (nreverse calls))))))

(ert-deftest update-mara-refuses-dirty-checkout ()
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_program) "/usr/bin/git"))
            ((symbol-function 'mara--checkout-root)
             (lambda () "/tmp/mara/"))
            ((symbol-function 'mara--checkout-dirty-p)
             (lambda (_root) t)))
    (should-error (update-mara) :type 'user-error)))

(provide 'mara-test)
;;; mara-test.el ends here
