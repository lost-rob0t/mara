;;; mara-prolog.el --- Persistent SWI-Prolog runtime for Emacs -*- lexical-binding: t; -*-

;;; Commentary:
;; Small repository-local Prolog process library.  It owns a long-lived SWI-Prolog
;; subprocess and exchanges newline-delimited JSON request/response frames with it.
;; Mara-specific predicates live outside this transport layer.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defgroup mara-prolog nil
  "Persistent Prolog runtime support for Mara."
  :group 'mara)

(defcustom mara-prolog-program "swipl"
  "SWI-Prolog executable used by the embedded Mara Prolog layer."
  :type 'string
  :group 'mara-prolog)

(defconst mara-prolog--library-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the repository-local Prolog Emacs library.")

(defcustom mara-prolog-server-file
  (expand-file-name "../prolog/mara-prolog-server.pl"
                    mara-prolog--library-directory)
  "Repository-local SWI-Prolog server entry point."
  :type 'file
  :group 'mara-prolog)

(defcustom mara-prolog-call-timeout 5.0
  "Seconds a synchronous Prolog request may wait for a response."
  :type 'number
  :group 'mara-prolog)

(cl-defstruct (mara-prolog-request
               (:constructor mara-prolog--make-request))
  id done result error callback)

(cl-defstruct (mara-prolog-runtime
               (:constructor mara-prolog--make-runtime))
  program server-file process pending receive-buffer next-id)

(defun mara-prolog-make-runtime (&optional program server-file)
  "Create a Prolog runtime using PROGRAM and SERVER-FILE.
The subprocess is started lazily by `mara-prolog-start' or the first call."
  (mara-prolog--make-runtime
   :program (or program mara-prolog-program)
   :server-file (or server-file mara-prolog-server-file)
   :process nil
   :pending (make-hash-table :test #'eql)
   :receive-buffer ""
   :next-id 0))

(defun mara-prolog-available-p (&optional runtime)
  "Return non-nil when RUNTIME can start SWI-Prolog."
  (let ((program (if runtime
                     (mara-prolog-runtime-program runtime)
                   mara-prolog-program))
        (server-file (if runtime
                         (mara-prolog-runtime-server-file runtime)
                       mara-prolog-server-file)))
    (and (executable-find program)
         (file-readable-p server-file))))

(defun mara-prolog-live-p (runtime)
  "Return non-nil when RUNTIME owns a live Prolog subprocess."
  (let ((process (mara-prolog-runtime-process runtime)))
    (and (processp process) (process-live-p process))))

(defun mara-prolog--fail-pending (runtime message)
  "Fail every pending RUNTIME request with MESSAGE."
  (maphash
   (lambda (_id request)
     (unless (mara-prolog-request-done request)
       (setf (mara-prolog-request-error request) message
             (mara-prolog-request-done request) t)
       (when-let ((callback (mara-prolog-request-callback request)))
         (condition-case err
             (funcall callback nil message)
           (error
            (display-warning
             'mara-prolog
             (format "Prolog callback failed while closing runtime: %s" err)))))))
   (mara-prolog-runtime-pending runtime))
  (clrhash (mara-prolog-runtime-pending runtime)))

(defun mara-prolog--sentinel (runtime process event)
  "Handle PROCESS lifecycle EVENT for RUNTIME."
  (unless (process-live-p process)
    (when (eq process (mara-prolog-runtime-process runtime))
      (setf (mara-prolog-runtime-process runtime) nil
            (mara-prolog-runtime-receive-buffer runtime) "")
      (mara-prolog--fail-pending
       runtime
       (format "Prolog runtime exited: %s" (string-trim event))))))

(defun mara-prolog--resolve-response (runtime response)
  "Resolve one parsed RESPONSE frame for RUNTIME."
  (let* ((id (alist-get 'id response))
         (request (and (integerp id)
                       (gethash id (mara-prolog-runtime-pending runtime)))))
    (when request
      (remhash id (mara-prolog-runtime-pending runtime))
      (if (eq t (alist-get 'ok response))
          (setf (mara-prolog-request-result request) (alist-get 'result response))
        (setf (mara-prolog-request-error request)
              (or (alist-get 'error response) "Unknown Prolog error")))
      (setf (mara-prolog-request-done request) t)
      (when-let ((callback (mara-prolog-request-callback request)))
        (condition-case err
            (funcall callback
                     (mara-prolog-request-result request)
                     (mara-prolog-request-error request))
          (error
           (display-warning 'mara-prolog
                            (format "Prolog callback failed: %s" err))))))))

(defun mara-prolog--consume-line (runtime line)
  "Parse and dispatch one response LINE for RUNTIME."
  (unless (string-empty-p line)
    (condition-case err
        (mara-prolog--resolve-response
         runtime
         (json-parse-string line
                            :object-type 'alist
                            :array-type 'list
                            :null-object nil
                            :false-object :json-false))
      (error
       (display-warning 'mara-prolog
                        (format "Invalid Prolog response %S: %s" line err))))))

(defun mara-prolog--filter (runtime _process output)
  "Consume subprocess OUTPUT for RUNTIME."
  (let* ((combined (concat (mara-prolog-runtime-receive-buffer runtime) output))
         (parts (split-string combined "\n"))
         (complete (butlast parts))
         (remainder (car (last parts))))
    (setf (mara-prolog-runtime-receive-buffer runtime) (or remainder ""))
    (dolist (line complete)
      (mara-prolog--consume-line runtime line))))

(defun mara-prolog-start (runtime)
  "Start RUNTIME if needed and return it."
  (unless (mara-prolog-live-p runtime)
    (unless (mara-prolog-available-p runtime)
      (error "Prolog runtime unavailable; need %s and %s"
             (mara-prolog-runtime-program runtime)
             (mara-prolog-runtime-server-file runtime)))
    (setf (mara-prolog-runtime-receive-buffer runtime) "")
    (clrhash (mara-prolog-runtime-pending runtime))
    (let* ((buffer (get-buffer-create " *mara-prolog*"))
           (stderr-buffer (get-buffer-create " *mara-prolog-stderr*"))
           (process
            (make-process
             :name "mara-prolog"
             :buffer buffer
             :stderr stderr-buffer
             :command (list (mara-prolog-runtime-program runtime)
                            "-q"
                            "-s" (mara-prolog-runtime-server-file runtime)
                            "--")
             :coding 'utf-8-unix
             :connection-type 'pipe
             :noquery t
             :filter (lambda (process output)
                       (mara-prolog--filter runtime process output))
             :sentinel (lambda (process event)
                         (mara-prolog--sentinel runtime process event)))))
      (set-process-query-on-exit-flag process nil)
      (setf (mara-prolog-runtime-process runtime) process)))
  runtime)

(defun mara-prolog-stop (runtime)
  "Stop RUNTIME and fail outstanding calls."
  (let ((process (mara-prolog-runtime-process runtime)))
    (when (processp process)
      (set-process-filter process nil)
      (set-process-sentinel process nil)
      (when (process-live-p process)
        (delete-process process)))
    (setf (mara-prolog-runtime-process runtime) nil
          (mara-prolog-runtime-receive-buffer runtime) "")
    (mara-prolog--fail-pending runtime "Prolog runtime stopped"))
  nil)

(defun mara-prolog-restart (runtime)
  "Restart RUNTIME and return it."
  (mara-prolog-stop runtime)
  (mara-prolog-start runtime))

(defun mara-prolog--submit (runtime method params callback)
  "Submit METHOD with PARAMS and CALLBACK to RUNTIME.
Return the internal request object."
  (mara-prolog-start runtime)
  (let* ((id (1+ (mara-prolog-runtime-next-id runtime)))
         (request (mara-prolog--make-request
                   :id id :done nil :result nil :error nil :callback callback))
         (frame `((id . ,id)
                  (method . ,method)
                  (params . ,params))))
    (setf (mara-prolog-runtime-next-id runtime) id)
    (puthash id request (mara-prolog-runtime-pending runtime))
    (condition-case err
        (process-send-string
         (mara-prolog-runtime-process runtime)
         (concat (json-serialize frame
                                 :null-object nil
                                 :false-object :json-false)
                 "\n"))
      (error
       (remhash id (mara-prolog-runtime-pending runtime))
       (setf (mara-prolog-request-error request) (error-message-string err)
             (mara-prolog-request-done request) t)))
    request))

(defun mara-prolog-call-async (runtime method params callback)
  "Call Prolog METHOD with PARAMS on RUNTIME and invoke CALLBACK.
CALLBACK receives two arguments: RESULT and ERROR.  Return the request ID."
  (mara-prolog-request-id
   (mara-prolog--submit runtime method params callback)))

(defun mara-prolog-call (runtime method &optional params timeout)
  "Synchronously call Prolog METHOD with PARAMS on RUNTIME.
TIMEOUT defaults to `mara-prolog-call-timeout'.  Return the decoded result."
  (let* ((request (mara-prolog--submit runtime method params nil))
         (deadline (+ (float-time) (or timeout mara-prolog-call-timeout))))
    (while (and (not (mara-prolog-request-done request))
                (< (float-time) deadline)
                (mara-prolog-live-p runtime))
      (accept-process-output (mara-prolog-runtime-process runtime) 0.05))
    (unless (mara-prolog-request-done request)
      (remhash (mara-prolog-request-id request)
               (mara-prolog-runtime-pending runtime))
      (error "Prolog request %s timed out after %.2fs"
             method (or timeout mara-prolog-call-timeout)))
    (when-let ((error-value (mara-prolog-request-error request)))
      (error "Prolog request %s failed: %s" method error-value))
    (mara-prolog-request-result request)))

(provide 'mara-prolog)
;;; mara-prolog.el ends here
