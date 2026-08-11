;;; mara-visual.el --- Visual reactions for Mara -*- lexical-binding: t; -*-

;;; Commentary:
;; Mara keeps one canonical reference image, bootstraps a stable bank of facial
;; expressions from it, swaps those cached reactions as conversation context
;; changes, and generates a fresh scene only when the user explicitly asks.

;;; Code:

(require 'auth-source)
(require 'cl-lib)
(require 'json)
(require 'mara-core)
(require 'mara-session)
(require 'mara-state)
(require 'subr-x)
(require 'url)
(require 'url-http)

(defgroup mara/visual nil
  "Visual identity and reactions for Mara."
  :group 'mara
  :prefix "mara-visual-")

(defcustom mara-visual-image-endpoint "https://openrouter.ai/api/v1/images"
  "OpenRouter endpoint used for Mara image generation."
  :type 'string
  :group 'mara/visual)

(defcustom mara-visual-image-model
  (or (getenv "OPENROUTER_IMAGE_MODEL")
      "bytedance-seed/seedream-4.5")
  "OpenRouter image model used for Mara visuals."
  :type 'string
  :group 'mara/visual)

(defcustom mara-visual-image-size "1024x1024"
  "Default image size requested for Mara visuals."
  :type 'string
  :group 'mara/visual)

(defcustom mara-visual-image-quality "high"
  "Default image quality requested for Mara visuals."
  :type '(choice (const "low")
                 (const "medium")
                 (const "high")
                 (const "auto"))
  :group 'mara/visual)

(defcustom mara-visual-output-format "png"
  "Output image format requested for Mara visuals."
  :type '(choice (const "png") (const "jpeg") (const "webp"))
  :group 'mara/visual)

(defcustom mara-visual-buffer-name "*Mara Visual*"
  "Buffer used to display Mara's current visual state."
  :type 'string
  :group 'mara/visual)

(defcustom mara-visual-bootstrap-expressions
  '(("neutral" . "calm neutral resting expression")
    ("happy" . "warm genuine smile")
    ("amused" . "subtle amused smirk")
    ("affectionate" . "soft affectionate expression")
    ("teasing" . "playful teasing grin")
    ("concerned" . "concerned attentive expression")
    ("focused" . "serious focused analytical expression")
    ("annoyed" . "mildly annoyed skeptical expression")
    ("surprised" . "genuinely surprised expression")
    ("sleepy" . "sleepy relaxed late-night expression"))
  "Expression bank generated from Mara's canonical input image."
  :type '(repeat (cons string string))
  :group 'mara/visual)

(defvar mara-visual-current nil)
(defvar mara-visual--busy nil)

(define-derived-mode mara-visual-mode special-mode "Mara-Visual"
  "Major mode for Mara's current visual state."
  (setq-local truncate-lines nil))

(defun mara-visual--root ()
  "Return Mara's visual asset directory."
  (expand-file-name "visual/" mara-data-directory))

(defun mara-visual--expression-directory ()
  "Return the cached facial-expression directory."
  (expand-file-name "expressions/" (mara-visual--root)))

(defun mara-visual--scene-directory ()
  "Return the generated scene directory."
  (expand-file-name "scenes/" (mara-visual--root)))

(defun mara-visual--state-path ()
  "Return the persistent visual-state path."
  (mara-state-path "visual"))

(defun mara-visual-load ()
  "Load Mara's persisted visual state."
  (setq mara-visual-current
        (mara-state-read (mara-visual--state-path) nil)))

(defun mara-visual-save ()
  "Persist `mara-visual-current'."
  (when mara-visual-current
    (mara-state-write (mara-visual--state-path) mara-visual-current)))

(defun mara-visual--expression-entry (name)
  "Return cached expression entry named NAME."
  (cl-find-if
   (lambda (entry)
     (equal name (mara--alist-get 'name entry)))
   (append (mara--alist-get 'expressions mara-visual-current []) nil)))

(defun mara-visual-expression-file (name)
  "Return cached image file for expression NAME, or nil."
  (when-let ((entry (mara-visual--expression-entry name)))
    (mara--alist-get 'file entry)))

(defun mara-visual--known-expression-p (name)
  "Return non-nil when NAME is a configured reaction expression."
  (assoc-string name mara-visual-bootstrap-expressions t))

(defun mara-visual-ready-p ()
  "Return non-nil when the complete facial-expression bank is available."
  (unless mara-visual-current
    (mara-visual-load))
  (let ((seed (and mara-visual-current
                   (mara--alist-get 'seedImage mara-visual-current))))
    (and seed
         (file-readable-p seed)
         (cl-every
          (lambda (spec)
            (let ((file (mara-visual-expression-file (car spec))))
              (and file (file-readable-p file))))
          mara-visual-bootstrap-expressions))))

(defun mara-visual-current-expression ()
  "Return Mara's current expression label."
  (and mara-visual-current
       (mara--alist-get 'currentExpression mara-visual-current)))

(defun mara-visual--api-key ()
  "Return the OpenRouter API key without persisting it in Mara state."
  (or (and (fboundp 'ai/llm--require-api-key)
           (ignore-errors (ai/llm--require-api-key 'openrouter)))
      (getenv "OPENROUTER_API_KEY")
      (when-let* ((entry (car (auth-source-search
                               :host "openrouter.ai"
                               :require '(:secret)
                               :max 1)))
                  (secret (plist-get entry :secret)))
        (if (functionp secret) (funcall secret) secret))
      (user-error
       "Set OPENROUTER_API_KEY or add an auth-source secret for openrouter.ai")))

(defun mara-visual--mime-type (file)
  "Return a supported image MIME type for FILE."
  (pcase (downcase (or (file-name-extension file) ""))
    ("png" "image/png")
    ((or "jpg" "jpeg") "image/jpeg")
    ("webp" "image/webp")
    (_ (user-error "Unsupported Mara reference image: %s" file))))

(defun mara-visual--data-url (file)
  "Return FILE encoded as an image data URL."
  (unless (file-readable-p file)
    (user-error "Mara reference image is not readable: %s" file))
  (let ((mime (mara-visual--mime-type file)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (format "data:%s;base64,%s"
              mime
              (base64-encode-string (buffer-string) t)))))

(defun mara-visual--request-body (prompt reference-file)
  "Build an OpenRouter image request for PROMPT and REFERENCE-FILE."
  (append
   `((model . ,mara-visual-image-model)
     (prompt . ,prompt)
     (n . 1)
     (size . ,mara-visual-image-size)
     (quality . ,mara-visual-image-quality)
     (output_format . ,mara-visual-output-format)
     (background . "auto"))
   (when reference-file
     `((input_references
        . ,(vector
            `((type . "image_url")
              (image_url . ((url . ,(mara-visual--data-url reference-file)))))))))))

(defun mara-visual--read-json-response ()
  "Read JSON from the current URL response buffer."
  (goto-char (or (and (boundp 'url-http-end-of-headers)
                      url-http-end-of-headers)
                 (point-min)))
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'symbol)
        (json-false nil)
        (json-null nil))
    (json-read)))

(defun mara-visual--api-error (payload)
  "Return a useful OpenRouter API error string from PAYLOAD."
  (let ((error-object (alist-get 'error payload)))
    (cond
     ((and (listp error-object) (alist-get 'message error-object))
      (alist-get 'message error-object))
     (error-object (format "%S" error-object))
     (t "OpenRouter image request failed"))))

(defun mara-visual--write-image (encoded output-file)
  "Decode ENCODED image data and write OUTPUT-FILE."
  (make-directory (file-name-directory output-file) t)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert (base64-decode-string encoded))
    (let ((coding-system-for-write 'no-conversion))
      (write-region (point-min) (point-max) output-file nil 'silent)))
  output-file)

(defun mara-visual--response-callback
    (status output-file on-success on-error)
  "Handle OpenRouter STATUS and save the result to OUTPUT-FILE."
  (unwind-protect
      (condition-case err
          (let* ((http-status (and (boundp 'url-http-response-status)
                                   url-http-response-status))
                 (payload (mara-visual--read-json-response)))
            (when (or (plist-get status :error)
                      (and http-status (>= http-status 400)))
              (error "%s" (mara-visual--api-error payload)))
            (let* ((image (car (alist-get 'data payload)))
                   (encoded (and image (alist-get 'b64_json image))))
              (unless encoded
                (error "OpenRouter returned no image data"))
              (mara-visual--write-image encoded output-file)
              (funcall on-success output-file payload)))
        (error
         (funcall on-error (error-message-string err))))
    (kill-buffer (current-buffer))))

(defun mara-visual--generate
    (prompt output-file reference-file on-success on-error)
  "Generate OUTPUT-FILE from PROMPT and REFERENCE-FILE asynchronously."
  (let* ((key (mara-visual--api-key))
         (url-request-method "POST")
         (url-request-extra-headers
          `(("Authorization" . ,(concat "Bearer " key))
            ("Content-Type" . "application/json")
            ("X-Title" . "Mara Visual Runtime")))
         (url-request-data
          (encode-coding-string
           (json-encode
            (mara-visual--request-body prompt reference-file))
           'utf-8)))
    (url-retrieve
     mara-visual-image-endpoint
     #'mara-visual--response-callback
     (list output-file on-success on-error)
     t t)))

(defun mara-visual--bootstrap-prompt (name description)
  "Return an identity-preserving bootstrap prompt for NAME and DESCRIPTION."
  (format
   (concat
    "The reference image is the canonical visual identity of an adult character named Mara. "
    "Preserve the same person exactly: face shape, apparent age, hair, eyes, skin tone, "
    "distinctive accessories, clothing design, art style, camera framing, and overall identity. "
    "Create a clean reaction portrait with the facial expression '%s': %s. "
    "Change the expression and only the minimal head or eye direction needed to make it natural. "
    "Keep pose, outfit, lighting, and background as consistent with the reference as possible. "
    "No text, caption, watermark, extra people, or character redesign.")
   name description))

(defun mara-visual--store-expression (name file)
  "Store expression NAME at FILE in `mara-visual-current'."
  (let* ((entries (append (mara--alist-get 'expressions mara-visual-current []) nil))
         (filtered
          (cl-remove-if
           (lambda (entry)
             (equal name (mara--alist-get 'name entry)))
           entries)))
    (setf (alist-get 'expressions mara-visual-current)
          (vconcat
           (append filtered
                   (list `((name . ,name) (file . ,file)))))))
  (setf (alist-get 'updatedAt mara-visual-current) (mara--now))
  (mara-visual-save))

(defun mara-visual--bootstrap-next (seed remaining)
  "Generate REMAINING facial expressions from canonical SEED."
  (if (null remaining)
      (progn
        (setq mara-visual--busy nil)
        (mara-visual-set-expression "neutral")
        (message "Mara visual bootstrap complete: %d expressions cached"
                 (length mara-visual-bootstrap-expressions)))
    (pcase-let* ((`(,name . ,description) (car remaining))
                 (output
                  (expand-file-name
                   (format "%s.%s" name mara-visual-output-format)
                   (mara-visual--expression-directory))))
      (message "Mara visual bootstrap: generating %s..." name)
      (mara-visual--generate
       (mara-visual--bootstrap-prompt name description)
       output
       seed
       (lambda (file _payload)
         (mara-visual--store-expression name file)
         (mara-visual--bootstrap-next seed (cdr remaining)))
       (lambda (error-value)
         (setq mara-visual--busy nil)
         (display-warning
          'mara
          (format "Mara visual bootstrap failed at %s: %s"
                  name error-value)))))))

;;;###autoload
(defun mara-visual-bootstrap (seed-file)
  "Bootstrap Mara's facial reaction bank from canonical SEED-FILE."
  (interactive
   (list (read-file-name "Canonical Mara image: " nil nil t)))
  (when mara-visual--busy
    (user-error "Mara visual generation is already busy: %s" mara-visual--busy))
  (unless (file-readable-p seed-file)
    (user-error "Mara seed image is not readable: %s" seed-file))
  (mara-visual--mime-type seed-file)
  (let* ((extension (downcase (file-name-extension seed-file)))
         (canonical-seed
          (expand-file-name (concat "seed." extension)
                            (mara-visual--root))))
    (make-directory (mara-visual--root) t)
    (make-directory (mara-visual--expression-directory) t)
    (copy-file seed-file canonical-seed t)
    (setq mara-visual-current
          `((version . 1)
            (seedImage . ,canonical-seed)
            (model . ,mara-visual-image-model)
            (expressions . [])
            (currentExpression . nil)
            (currentImage . ,canonical-seed)
            (updatedAt . ,(mara--now))))
    (mara-visual-save)
    (setq mara-visual--busy "bootstrap")
    (mara-visual-display canonical-seed)
    (mara-visual--bootstrap-next
     canonical-seed
     (copy-tree mara-visual-bootstrap-expressions))))

(defun mara-visual-set-expression (name)
  "Switch Mara's displayed cached facial expression to NAME."
  (unless mara-visual-current
    (mara-visual-load))
  (let ((file (mara-visual-expression-file name)))
    (when (and file (file-readable-p file))
      (setf (alist-get 'currentExpression mara-visual-current) name
            (alist-get 'currentImage mara-visual-current) file
            (alist-get 'updatedAt mara-visual-current) (mara--now))
      (mara-visual-save)
      (mara-visual-display file)
      file)))

(defun mara-visual--parse-response (text)
  "Return cons of visible TEXT and a trailing Mara expression marker."
  (let ((case-fold-search t)
        (regexp
         "\\(?:\\n\\)?\\[\\[mara-expression:\\([[:alnum:]-]+\\)\\]\\][[:space:]]*\\'"))
    (if (and (stringp text) (string-match regexp text))
        (let ((name (downcase (match-string 1 text))))
          (cons
           (string-trim-right (substring text 0 (match-beginning 0)))
           (and (mara-visual--known-expression-p name) name)))
      (cons text nil))))

(defun mara-visual-consume-response (text)
  "Strip Mara visual metadata from TEXT and apply its facial reaction."
  (pcase-let ((`(,visible . ,expression)
               (mara-visual--parse-response text)))
    (when expression
      (mara-visual-set-expression expression))
    visible))

(defun mara-visual-context-instructions ()
  "Return machine-readable facial-reaction instructions for Mara's model."
  (format
   (concat
    "Visual reaction protocol: Mara has a cached facial-expression bank. "
    "At the very end of every normal assistant response, append exactly one metadata marker on its own line: "
    "[[mara-expression:NAME]]. NAME must be one of: %s. "
    "Choose the expression that best matches Mara's actual reaction to the current conversational context. "
    "Do not mention or explain this marker in prose; the runtime strips it before display and persistence.")
   (mapconcat #'car mara-visual-bootstrap-expressions ", ")))

(defun mara-visual-display (&optional file)
  "Display FILE, or Mara's current visual image, in a right-side buffer."
  (interactive)
  (unless mara-visual-current
    (mara-visual-load))
  (let ((image-file
         (or file
             (and mara-visual-current
                  (mara--alist-get 'currentImage mara-visual-current)))))
    (unless (and image-file (file-readable-p image-file))
      (user-error "Mara has no readable visual image yet; run M-x mara-visual-bootstrap"))
    (let ((buffer (get-buffer-create mara-visual-buffer-name)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (mara-visual-mode)
          (erase-buffer)
          (insert
           (format "Mara — %s\n\n"
                   (or (mara-visual-current-expression) "canonical")))
          (condition-case err
              (insert-image (create-image image-file))
            (error
             (insert (format "Image display failed: %s\n%s"
                             (error-message-string err)
                             image-file))))))
      (display-buffer-in-side-window
       buffer
       '((side . right)
         (slot . 1)
         (window-width . 0.34))))))

(defun mara-visual--recent-context (&optional limit)
  "Return the last LIMIT Mara session messages as compact scene context."
  (let* ((messages (and mara-session-current
                        (mara-session-messages mara-session-current)))
         (count (min (or limit 8) (length messages))))
    (mapconcat
     (lambda (message)
       (format "%s: %s"
               (upcase (mara--alist-get 'role message "unknown"))
               (mara--alist-get 'content message "")))
     (last messages count)
     "\n")))

(defun mara-visual--scene-prompt (&optional extra)
  "Build a context-aware Mara scene prompt with optional EXTRA direction."
  (let ((context (mara-visual--recent-context 8))
        (expression (or (mara-visual-current-expression) "neutral")))
    (concat
     "The reference image is Mara, an adult character, and defines her canonical visual identity. "
     "Preserve Mara's face, apparent age, hair, eyes, skin tone, distinctive accessories, outfit design, and art style. "
     "Generate one coherent scene snapshot that reflects the CURRENT conversation context below rather than a generic portrait. "
     "Mara's current facial reaction is " expression ". "
     "Infer setting, pose, activity, props, and atmosphere only from the supplied context; do not invent major events that are unsupported. "
     "If the context is primarily coding or chatting, a believable desktop or room scene is appropriate. "
     "Keep Mara clearly recognizable. No text, captions, UI labels, watermarks, or character redesign."
     (if (and extra (not (string-empty-p (string-trim extra))))
         (concat " Additional user direction: " (string-trim extra) ".")
       "")
     "\n\nCURRENT CONVERSATION:\n"
     context)))

(defun mara-visual--scene-success (file _payload)
  "Persist and display a successfully generated scene FILE."
  (setq mara-visual--busy nil)
  (setf (alist-get 'currentImage mara-visual-current) file
        (alist-get 'lastScene mara-visual-current) file
        (alist-get 'updatedAt mara-visual-current) (mara--now))
  (mara-visual-save)
  (mara-visual-display file)
  (message "Mara scene rendered: %s" file))

(defun mara-visual--scene-error (error-value)
  "Report failed scene generation ERROR-VALUE."
  (setq mara-visual--busy nil)
  (display-warning 'mara (format "Mara scene generation failed: %s" error-value)))

;;;###autoload
(defun mara-visual-render-scene (&optional prompt)
  "Generate a fresh scene from Mara's current context.
With prefix argument, interactively read extra PROMPT direction."
  (interactive
   (list (when current-prefix-arg
           (read-string "Extra scene direction: "))))
  (when mara-visual--busy
    (user-error "Mara visual generation is already busy: %s" mara-visual--busy))
  (unless mara-visual-current
    (mara-visual-load))
  (unless (mara-visual-ready-p)
    (user-error "Bootstrap Mara's visual identity first with M-x mara-visual-bootstrap"))
  (let* ((reference
          (or (mara-visual-expression-file
               (or (mara-visual-current-expression) "neutral"))
              (mara--alist-get 'seedImage mara-visual-current)))
         (output
          (expand-file-name
           (format "scene-%s.%s"
                   (format-time-string "%Y%m%d-%H%M%S")
                   mara-visual-output-format)
           (mara-visual--scene-directory))))
    (make-directory (mara-visual--scene-directory) t)
    (setq mara-visual--busy "scene")
    (message "Rendering Mara scene with %s..." mara-visual-image-model)
    (mara-visual--generate
     (mara-visual--scene-prompt prompt)
     output
     reference
     #'mara-visual--scene-success
     #'mara-visual--scene-error)))

(provide 'mara-visual)
;;; mara-visual.el ends here
