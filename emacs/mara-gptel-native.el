;;; mara-gptel-native.el --- Native gptel tools for Mara -*- lexical-binding: t; -*-

;;; Commentary:
;; Adapter from Mara's capability-controlled tool registry to native gptel
;; asynchronous tools.  gptel owns tool-call continuation while Mara remains
;; the authority for whether and how a tool may execute.

;;; Code:

(require 'cl-lib)
(require 'gptel-request)
(require 'mara-provider-gptel)
(require 'mara-tools)

(defun mara-gptel-native--argument-names (schema)
  "Return ordered argument names from JSON input SCHEMA."
  (mapcar
   (lambda (property)
     (if (symbolp (car property))
         (symbol-name (car property))
       (car property)))
   (mara--alist-get 'properties schema)))

(defun mara-gptel-native--function (tool)
  "Return an async gptel function that executes Mara TOOL via the broker."
  (let ((name (mara-tool-name tool))
        (argument-names
         (mara-gptel-native--argument-names
          (mara-tool-input-schema tool))))
    (lambda (callback &rest values)
      (mara-tools-execute
       name
       (cl-mapcar #'cons argument-names values)
       (lambda (result errorp)
         (funcall callback
                  (if errorp
                      (format "Mara capability/tool error: %s" result)
                    result)))))))

(defun mara-gptel-native-tools ()
  "Build native async gptel tools from Mara's authorized registry.

Every invocation still passes through `mara-tools-execute', so profile
capability checks remain authoritative even after the model has produced
a tool call."
  (let (tools)
    (maphash
     (lambda (_name tool)
       (when (mara-tools-authorized-p (mara-tool-capability tool))
         (push
          (gptel-make-tool
           :name (mara-tool-name tool)
           :description (mara-tool-description tool)
           :args (mara-gptel--tool-args (mara-tool-input-schema tool))
           :function (mara-gptel-native--function tool)
           :async t
           :category "mara"
           :confirm t
           :include t)
          tools)))
     mara-tools-registry)
    (nreverse tools)))

(provide 'mara-gptel-native)
;;; mara-gptel-native.el ends here
