;;; mara-gptel.el --- Native gptel integration for Mara -*- lexical-binding: t; -*-

;;; Commentary:
;; gptel owns Mara's conversation transport, streaming, tool continuation and
;; model/backend selection.  This file only carries Mara-specific gptel
;; configuration and adapts capability-controlled Mara tools to gptel tools.

;;; Code:

(require 'cl-lib)
(require 'gptel-request)
(require 'mara-tools)

(defcustom mara-gptel-backend nil
  "gptel backend used by Mara.
When nil, inherit the user's current `gptel-backend'."
  :type '(choice (const :tag "Inherit gptel backend" nil) sexp)
  :group 'mara)

(defcustom mara-gptel-model nil
  "gptel model used by Mara.
When nil, inherit the user's current `gptel-model'."
  :type '(choice (const :tag "Inherit gptel model" nil) symbol)
  :group 'mara)

(defun mara-gptel--tool-args (schema)
  "Convert JSON input SCHEMA to gptel argument specifications."
  (let ((properties (mara--alist-get 'properties schema))
        (required (append (mara--alist-get 'required schema []) nil))
        arguments)
    (dolist (property properties (nreverse arguments))
      (let* ((name (if (symbolp (car property))
                       (symbol-name (car property))
                     (car property)))
             (spec (cdr property))
             (type-name (mara--alist-get 'type spec "string")))
        (push (append
               (list :name name
                     :type (intern type-name)
                     :description (mara--alist-get 'description spec name))
               (unless (member name required) (list :optional t))
               (when-let ((values (mara--alist-get 'enum spec)))
                 (list :enum (vconcat values)))
               (when-let ((items (mara--alist-get 'items spec)))
                 (list :items items)))
              arguments)))))

(defun mara-gptel--argument-names (schema)
  "Return ordered argument names from JSON input SCHEMA."
  (mapcar
   (lambda (property)
     (if (symbolp (car property))
         (symbol-name (car property))
       (car property)))
   (mara--alist-get 'properties schema)))

(defun mara-gptel--tool-function (tool)
  "Return an async gptel function that executes Mara TOOL via the broker."
  (let ((name (mara-tool-name tool))
        (argument-names
         (mara-gptel--argument-names (mara-tool-input-schema tool))))
    (lambda (callback &rest values)
      (mara-tools-execute
       name
       (cl-mapcar #'cons argument-names values)
       (lambda (result errorp)
         (funcall callback
                  (if errorp
                      (format "Mara capability/tool error: %s" result)
                    result)))))))

(defun mara-gptel-tools ()
  "Build native async gptel tools from Mara's authorized registry.

Every invocation passes through `mara-tools-execute', so profile capability
checks remain authoritative after the model produces a tool call."
  (let (tools)
    (maphash
     (lambda (_name tool)
       (when (mara-tools-authorized-p (mara-tool-capability tool))
         (push
          (gptel-make-tool
           :name (mara-tool-name tool)
           :description (mara-tool-description tool)
           :args (mara-gptel--tool-args (mara-tool-input-schema tool))
           :function (mara-gptel--tool-function tool)
           :async t
           :category "mara"
           :confirm t
           :include t)
          tools)))
     mara-tools-registry)
    (nreverse tools)))

(provide 'mara-gptel)
;;; mara-gptel.el ends here
