;;; mara-gptel.el --- Native gptel integration for Mara -*- lexical-binding: t; -*-

;;; Commentary:
;; gptel owns Mara's conversation transport, streaming, tool continuation and
;; model/backend selection.  This file only carries Mara-specific gptel
;; configuration and adapts capability-controlled Mara tools to gptel tools.

;;; Code:

(require 'cl-lib)
(require 'gptel-request)
(require 'mara-tools)
(require 'subr-x)

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

(defun mara-gptel--raw-byte-char-p (char)
  "Return non-nil when CHAR is Emacs' multibyte raw-byte representation."
  (and (>= char #x3fff80)
       (<= char #x3fffff)))

(defun mara-gptel--unicode-string-p (text)
  "Return non-nil when TEXT contains no Emacs raw-byte characters.

Raw-byte characters are how Emacs preserves bytes 128..255 that were inserted
into a multibyte buffer without decoding.  Such a string can report itself as
multibyte while still being unsuitable for gptel's nested JSON request data."
  (and (stringp text)
       (cl-every
        (lambda (char)
          (not (mara-gptel--raw-byte-char-p char)))
        text)))

(defun mara-gptel--decode-raw-utf8-runs (text)
  "Decode raw UTF-8 byte runs embedded in multibyte TEXT.

Inserting a unibyte UTF-8 string into a multibyte Org buffer does not decode
UTF-8.  Emacs preserves bytes 128..255 as raw-byte characters instead.  Decode
contiguous raw-byte runs while leaving already-valid Unicode untouched."
  (with-temp-buffer
    (set-buffer-multibyte t)
    (let ((index 0)
          (text-length (length text)))
      (while (< index text-length)
        (let ((char (aref text index)))
          (if (mara-gptel--raw-byte-char-p char)
              (let (bytes)
                (while (and (< index text-length)
                            (mara-gptel--raw-byte-char-p
                             (aref text index)))
                  (push (- (aref text index) #x3fff00) bytes)
                  (setq index (1+ index)))
                (insert
                 (decode-coding-string
                  (apply #'unibyte-string (nreverse bytes))
                  'utf-8)))
            (insert-char char)
            (setq index (1+ index))))))
    (buffer-string)))

(defun mara-gptel--normalize-tool-result (result)
  "Return RESULT as Unicode text safe for gptel tool continuation.

`json-serialize' returns a unibyte UTF-8 string.  Mara normally decodes that
before gptel inserts the result into the Org chat.  A stale adapter or an
already-inserted result can additionally turn those bytes into Emacs raw-byte
characters inside a multibyte string.  `multibyte-string-p' alone therefore
does not prove that tool text is decoded Unicode.

Normalize both representations at the Mara/gptel boundary.  If decoding still
leaves raw bytes, return a small ASCII error result rather than poisoning the
next automatic gptel request."
  (let* ((text (if (stringp result) result (format "%s" result)))
         (normalized
          (cond
           ((not (multibyte-string-p text))
            (decode-coding-string text 'utf-8))
           ((mara-gptel--unicode-string-p text)
            text)
           (t
            (mara-gptel--decode-raw-utf8-runs text)))))
    (if (mara-gptel--unicode-string-p normalized)
        normalized
      (format
       "Mara capability/tool error: tool returned undecodable text (%d chars)"
       (length text)))))

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
                  (mara-gptel--normalize-tool-result
                   (if errorp
                       (format "Mara capability/tool error: %s" result)
                     result))))))))

(defun mara-gptel-tools ()
  "Build native async gptel tools from Mara's authorized registry.

Every invocation passes through `mara-tools-execute', so profile capability
checks remain authoritative after the model produces a tool call.  Mara's
registered tools do not require per-call confirmation; the capability broker
remains the authorization boundary."
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
           :confirm nil
           :include t)
          tools)))
     mara-tools-registry)
    (nreverse tools)))

(provide 'mara-gptel)
;;; mara-gptel.el ends here
