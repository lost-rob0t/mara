;;; mara-daily-test.el --- Tests for Mara daily chat rollover -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'mara)

(ert-deftest mara-daily-session-reuses-current-day ()
  (mara-test-with-state
    (mara-profile-load)
    (cl-letf (((symbol-function 'mara-session--today)
               (lambda () "2026-08-11")))
      (mara-session-load-current)
      (let ((id (mara-session-id mara-session-current)))
        (should (equal "2026-08-11--default" id))
        (mara-session-add-message "user" "hello today")
        (setq mara-session-current nil)
        (mara-session-load-current)
        (should (equal id (mara-session-id mara-session-current)))
        (should
         (equal "hello today"
                (mara--alist-get
                 'content
                 (car (mara-session-messages mara-session-current)))))))))

(ert-deftest mara-daily-session-rolls-over-on-local-date-change ()
  (mara-test-with-state
    (mara-profile-load)
    (let ((today "2026-08-11"))
      (cl-letf (((symbol-function 'mara-session--today)
                 (lambda () today)))
        (mara-session-load-current)
        (let ((first-id (mara-session-id mara-session-current)))
          (setq today "2026-08-12"
                mara-session-current nil)
          (mara-session-load-current)
          (should-not (equal first-id (mara-session-id mara-session-current)))
          (should (equal "2026-08-12--default"
                         (mara-session-id mara-session-current))))))))

(ert-deftest mara-daily-context-reviews-previous-day ()
  (mara-test-with-state
    (mara-profile-load)
    (mara-relationship-load)
    (let ((today "2026-08-10")
          (yesterday "2026-08-09"))
      (cl-letf (((symbol-function 'mara-session--today)
                 (lambda () today))
                ((symbol-function 'mara-session--yesterday)
                 (lambda () yesterday)))
        (mara-session-load-current)
        (mara-session-add-message "user" "we worked on Mara memory")
        (mara-session-add-message "assistant" "I remember the tool work")
        (setq today "2026-08-11"
              yesterday "2026-08-10"
              mara-session-current nil)
        (mara-session-load-current)
        (let ((review (mara-session-previous-day-context))
              (context (mara-context-system-prompt)))
          (should (string-match-p "Previous-day conversation review (2026-08-10)" review))
          (should (string-match-p "we worked on Mara memory" review))
          (should (string-match-p "I remember the tool work" review))
          (should (string-match-p "Previous-day conversation review (2026-08-10)" context)))))))

(ert-deftest mara-daily-context-budget-keeps-newest-history ()
  (mara-test-with-state
    (let ((mara-session-previous-day-context-limit 40))
      (should
       (string-match-p
        "newest"
        (mara-session--bounded-transcript
         '(((role . "user") (content . "oldest message that should be omitted"))
           ((role . "assistant") (content . "newest")))
         mara-session-previous-day-context-limit))))))

(provide 'mara-daily-test)
;;; mara-daily-test.el ends here
