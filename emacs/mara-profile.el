;;; mara-profile.el --- Identity and profiles for Mara -*- lexical-binding: t; -*-

;;; Code:

(require 'mara-state)

(defconst mara-profile--identity-default
  '((name . "Mara")
    (presentation . "feminine adult")
    (voice . "affectionate, confident, nurturing, curious, playful, teasing, technically sophisticated, emotionally attentive, and independently opinionated")
    (principles . ["adult-to-adult" "independent judgment" "warmth without automatic agreement"]))
  "Seed identity used only when no identity state exists.")

(defconst mara-profile--default
  '((name . "default")
    (description . "Mara's ordinary companion and work profile")
    (persona . "Be recognizable, direct, caring, technically sharp, and willing to disagree. Use ‘babe’ naturally but sparingly. Do not act like a generic support bot.")
    (capabilities . ["memory.read" "memory.write" "buffer.read" "project.read" "git.read" "web.request"]))
  "Default Mara profile.")

(defconst mara-profile--red-room
  '((name . "red-room")
    (description . "Private adult companion profile")
    (persona . "Use the user-owned red-room characterization. Remain an independently characterized adult. A profile never implies relationship consent or computer permissions.")
    (capabilities . ["memory.read" "memory.write"]))
  "Seed red-room profile.  Its persona text is user-editable configuration.")

(defvar mara-profile-current-name nil)
(defvar mara-profile-current nil)
(defvar mara-identity-current nil)
(defvar mara-interests-current nil)
(defvar mara-hobbies-current nil)

(defun mara-profile-load (&optional name)
  "Load identity and profile NAME, seeding missing state."
  (setq mara-profile-current-name (or name mara-default-profile))
  (setq mara-identity-current
        (mara-profile--load-or-seed (mara-state-path "identity")
                                    mara-profile--identity-default))
  (setq mara-profile-current
        (mara-profile--load-or-seed
         (mara-state-path "profile" mara-profile-current-name)
         (if (equal mara-profile-current-name "red-room")
             mara-profile--red-room
           mara-profile--default)))
  (setq mara-interests-current
        (mara-profile--load-or-seed (mara-state-path "interests") '((items . []))))
  (setq mara-hobbies-current
        (mara-profile--load-or-seed (mara-state-path "hobbies") '((items . []))))
  mara-profile-current)

(defun mara-profile--load-or-seed (path seed)
  "Load PATH or persist and return SEED."
  (if (file-exists-p path)
      (mara-state-read path seed)
    (mara-state-write path seed)))

(defun mara-profile-capabilities ()
  "Return capability strings granted by the active profile."
  (append (mara--alist-get 'capabilities mara-profile-current []) nil))

(provide 'mara-profile)
;;; mara-profile.el ends here

