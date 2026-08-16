;;; mara-zara-test.el --- Tests for Mara's Zara installer -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'mara-zara)

(defmacro mara-zara-test-with-layout (&rest body)
  "Run BODY with isolated bridge source and installation directories."
  (declare (indent 0))
  `(let* ((root (make-temp-file "mara-zara-test-" t))
          (emacs-directory (expand-file-name "emacs/" root))
          (source-directory (expand-file-name "zara-plugin/" root))
          (install-directory (expand-file-name "installed/" root))
          (mara-zara--emacs-directory emacs-directory)
          (mara-zara-plugin-directory install-directory))
     (unwind-protect
         (progn
           (make-directory emacs-directory)
           (make-directory source-directory)
           (with-temp-file (expand-file-name "mara_bridge.py" source-directory)
             (insert "MARA_ZARA_BRIDGE = True\nVERSION = 'test'\n"))
           ,@body)
       (delete-directory root t))))

(ert-deftest mara-zara-install-status-and-uninstall ()
  (mara-zara-test-with-layout
    (should (eq 'not-installed (plist-get (mara-zara-status) :state)))
    (let ((installed (mara-zara-install)))
      (should (file-regular-p installed))
      (should (= #o644 (file-modes installed)))
      (should (eq 'current (plist-get (mara-zara-status) :state)))
      (with-temp-file (mara-zara--source-file)
        (insert "MARA_ZARA_BRIDGE = True\nVERSION = 'new'\n"))
      (should (eq 'outdated (plist-get (mara-zara-status) :state)))
      (mara-zara-install)
      (should (eq 'current (plist-get (mara-zara-status) :state)))
      (mara-zara-uninstall)
      (should-not (file-exists-p installed)))))

(ert-deftest mara-zara-refuses-foreign-plugin-file ()
  (mara-zara-test-with-layout
    (make-directory mara-zara-plugin-directory)
    (with-temp-file (mara-zara--installed-file)
      (insert "# belongs to somebody else\n"))
    (should (eq 'foreign (plist-get (mara-zara-status) :state)))
    (should-error (mara-zara-install) :type 'user-error)
    (should-error (mara-zara-uninstall) :type 'user-error)
    (should (file-exists-p (mara-zara--installed-file)))))

(ert-deftest mara-zara-reports-missing-repository-source ()
  (mara-zara-test-with-layout
    (delete-file (mara-zara--source-file))
    (should (eq 'source-missing (plist-get (mara-zara-status) :state)))
    (should-error (mara-zara-install) :type 'user-error)))

(provide 'mara-zara-test)
;;; mara-zara-test.el ends here
