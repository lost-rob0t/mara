;;; mara-avatar-test.el --- Tests for Mara's avatar Emacs client -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(let ((parent (directory-file-name
               (file-name-directory
                (or load-file-name buffer-file-name)))))
  (add-to-list 'load-path (expand-file-name "../emacs" parent)))

(require 'mara-avatar)

(ert-deftest mara-avatar-status-returns-document ()
  (cl-letf* ((requests '())
             ((symbol-function 'mara-avatar--request)
              (lambda (method path payload)
                (push (list method path payload) requests)
                '((state . "running")
                  (avatar . ((presence . "idle")))))))
    (let ((document (mara-avatar-status)))
      (should (equal (alist-get 'state document) "running"))
      (should (equal (car requests) '("GET" "/v1/avatar/status" nil))))))

(ert-deftest mara-avatar-show-posts-empty-payload ()
  (cl-letf* ((calls '())
             ((symbol-function 'mara-avatar--post)
              (lambda (path payload) (push (list path payload) calls) t)))
    (mara-avatar-show)
    (mara-avatar-hide)
    (should (equal (reverse calls)
                   '(("/v1/avatar/show" nil) ("/v1/avatar/hide" nil))))))

(ert-deftest mara-avatar-emotion-posts-semantic-value ()
  (cl-letf* ((calls '())
             ((symbol-function 'mara-avatar--post)
              (lambda (path payload) (push (list path payload) calls) t)))
    (mara-avatar-emotion "happy")
    (should (equal (car calls)
                   '("/v1/avatar/emotion" (("emotion" . "happy")))))))

(ert-deftest mara-avatar-gesture-posts-semantic-value ()
  (cl-letf* ((calls '())
             ((symbol-function 'mara-avatar--post)
              (lambda (path payload) (push (list path payload) calls) t)))
    (mara-avatar-gesture "wave")
    (should (equal (car calls)
                   '("/v1/avatar/gesture" (("gesture" . "wave")))))))

(ert-deftest mara-avatar-install-state-reports-missing-source ()
  (cl-letf (((symbol-function 'file-exists-p) (lambda (_path) nil)))
    (should (eq (mara-avatar--state) 'source-missing))))

(ert-deftest mara-avatar-install-state-reports-foreign-plugin ()
  (cl-letf (((symbol-function 'file-exists-p) (lambda (_path) t))
            ((symbol-function 'mara-avatar--owned-file-p) (lambda (_path) nil)))
    (should (eq (mara-avatar--state) 'foreign))))

(ert-deftest mara-avatar-install-state-reports-current ()
  (cl-letf (((symbol-function 'file-exists-p) (lambda (_path) t))
            ((symbol-function 'mara-avatar--owned-file-p) (lambda (_path) t))
            ((symbol-function 'mara-avatar--file-digest)
             (lambda (_path) "same")))
    (should (eq (mara-avatar--state) 'current))))

;;; mara-avatar-test.el ends here
