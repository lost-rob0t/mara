;;; mara-provider.el --- Provider abstraction for Mara -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)

(cl-defgeneric mara-provider-send (provider request on-success on-error)
  "Asynchronously send REQUEST through PROVIDER.")

(cl-defgeneric mara-provider-stream (provider request on-event on-success on-error)
  "Stream REQUEST through PROVIDER, invoking ON-EVENT for deltas.")

(cl-defgeneric mara-provider-cancel (provider handle)
  "Cancel HANDLE created by PROVIDER.")

(cl-defgeneric mara-provider-tool-call-p (_provider response)
  "Return non-nil when RESPONSE contains client tool requests."
  (not (null (plist-get response :tool-calls))))

(cl-defmethod mara-provider-stream ((provider t) request _on-event on-success on-error)
  "Fallback streaming implementation delegates to non-streaming send."
  (mara-provider-send provider request on-success on-error))

(provide 'mara-provider)
;;; mara-provider.el ends here

