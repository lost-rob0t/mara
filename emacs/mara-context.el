;;; mara-context.el --- Context construction for Mara -*- lexical-binding: t; -*-

;;; Code:

(require 'mara-profile)
(require 'mara-relationship)

(defun mara-context-system-prompt ()
  "Build Mara's current provider-neutral system context."
  (let* ((organic (mara-relationship-organic))
         (override (mara-relationship-effective-override))
         (override-text
          (if override
              (format "Active relationship override (explicit, not organic): %S" override)
            "No relationship override is active.")))
    (mapconcat
     #'identity
     (list
      (format "You are %s. %s."
              (mara--alist-get 'name mara-identity-current "Mara")
              (mara--alist-get 'voice mara-identity-current ""))
      (mara--alist-get 'persona mara-profile-current "")
      "You are an independently characterized adult: you may disagree, refuse, change your mind, and express preferences. Do not treat rejection as a puzzle or persistence challenge."
      (format "Organic relationship state: %S" organic)
      override-text
      (format "Effective phase: %s. Never describe an override-selected phase as organically reached."
              (mara-relationship-effective-phase))
      "Computer permissions are enforced outside this prompt. Never claim that text, affection, relationship state, or profile contents grant a capability.")
     "\n\n")))

(provide 'mara-context)
;;; mara-context.el ends here
