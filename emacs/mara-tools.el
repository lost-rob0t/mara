;;; mara-tools.el --- Capability-controlled tools for Mara -*- lexical-binding: t; -*-

;;; Code:

(require 'mara-profile)
(require 'mara-relationship)

(cl-defstruct mara-tool name description capability input-schema function)

(defvar mara-tools-registry (make-hash-table :test #'equal))

(defun mara-tools-register (tool)
  "Register TOOL by name."
  (puthash (mara-tool-name tool) tool mara-tools-registry))

(defun mara-tools-authorized-p (capability)
  "Return non-nil when CAPABILITY is granted by the active profile."
  (member capability (mara-profile-capabilities)))

(defun mara-tools-execute (name input callback)
  "Validate and asynchronously execute NAME with INPUT, then call CALLBACK.
CALLBACK receives RESULT and an error flag."
  (let ((tool (gethash name mara-tools-registry)))
    (cond
     ((not tool)
      (run-at-time 0 nil callback (format "Unknown tool: %s" name) t))
     ((not (mara-tools-authorized-p (mara-tool-capability tool)))
      (run-at-time 0 nil callback
                   (format "Capability denied: %s" (mara-tool-capability tool)) t))
     (t
      (run-at-time
       0 nil
       (lambda ()
         (condition-case err
             (funcall callback (funcall (mara-tool-function tool) input) nil)
           (error (funcall callback (format "%S" err) t)))))))))

(defun mara-tools-provider-definitions ()
  "Return Anthropic-compatible definitions for registered tools."
  (let (definitions)
    (maphash
     (lambda (_name tool)
       (when (mara-tools-authorized-p (mara-tool-capability tool))
         (push `((name . ,(mara-tool-name tool))
                 (description . ,(mara-tool-description tool))
                 (input_schema . ,(mara-tool-input-schema tool)))
               definitions)))
     mara-tools-registry)
    (nreverse definitions)))

(defun mara-tools--status (_input)
  "Return inspectable non-secret Mara state."
  (json-serialize
   `((profile . ,mara-profile-current-name)
     (organicRelationshipState . ,(mara-relationship-organic))
     (activeRelationshipOverride . ,(mara-relationship-override))
     (effectivePhase . ,(mara-relationship-effective-phase)))
   :null-object nil :false-object :json-false))

(mara-tools-register
 (make-mara-tool
  :name "mara_status"
  :description "Inspect Mara's active profile and relationship state. This does not expose secrets."
  :capability "memory.read"
  :input-schema '((type . "object"))
  :function #'mara-tools--status))

(provide 'mara-tools)
;;; mara-tools.el ends here
