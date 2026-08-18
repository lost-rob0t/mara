;;; mara-tools.el --- Capability-controlled tools for Mara -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'mara-brain)
(require 'mara-memory)
(require 'mara-profile)
(require 'mara-relationship)
(require 'mara-session)

(cl-defstruct mara-tool name description capability input-schema function)

(defvar mara-tools-registry (make-hash-table :test #'equal))

(defcustom mara-tools-memory-search-limit 8
  "Maximum number of memories returned by one native memory search."
  :type 'integer
  :group 'mara)

(defcustom mara-tools-session-history-limit 12
  "Maximum number of current-session messages returned by the history tool."
  :type 'integer
  :group 'mara)

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

(defun mara-tools--ensure-state ()
  "Ensure the local state needed by native tools is loaded."
  (unless mara-profile-current
    (mara-profile-load))
  (unless mara-memory-current
    (mara-memory-load))
  (unless mara-relationship-current
    (mara-relationship-load))
  (unless mara-session-current
    (mara-session-load-current)))

(defun mara-tools--json (value)
  "Serialize VALUE as Unicode JSON text for a native tool response."
  (let ((json (json-serialize value
                              :null-object nil
                              :false-object :json-false)))
    (if (multibyte-string-p json)
        json
      (decode-coding-string json 'utf-8))))

(defun mara-tools--required-string (input key)
  "Return required non-empty string KEY from INPUT."
  (let ((value (mara--alist-get key input)))
    (unless (and (stringp value) (not (string-empty-p value)))
      (user-error "Tool argument %s must be a non-empty string" key))
    value))

(defun mara-tools--memory-record (id)
  "Return durable memory record ID, or nil."
  (cl-find-if
   (lambda (record)
     (equal id (mara--alist-get 'id record)))
   (mara-memory-records)))

(defun mara-tools--memory-active-p (record)
  "Return non-nil when RECORD has not been superseded."
  (let ((id (mara--alist-get 'id record)))
    (not
     (cl-some
      (lambda (candidate)
        (member id (append (mara--alist-get 'supersedes candidate '()) nil)))
      (mara-memory-records)))))

(defun mara-tools--query-terms (query)
  "Return normalized search terms extracted from QUERY."
  (seq-filter
   (lambda (term) (>= (length term) 2))
   (split-string (downcase query) "[^[:alnum:]_-]+" t)))

(defun mara-tools--memory-match-count (record terms)
  "Return the number of TERMS matched by RECORD text."
  (let ((text
         (downcase
          (mapconcat
           #'identity
           (mapcar
            (lambda (value) (if (stringp value) value (format "%s" value)))
            (list (mara--alist-get 'subject record "")
                  (mara--alist-get 'predicate record "")
                  (mara--alist-get 'object record "")
                  (mara--alist-get 'summary record "")))
           " "))))
    (cl-count-if
     (lambda (term)
       (string-match-p (regexp-quote term) text))
     terms)))

(defun mara-tools--memory-hit (record score reasons)
  "Build one compact memory hit from RECORD, SCORE, and REASONS."
  `((id . ,(mara--alist-get 'id record))
    (kind . ,(mara--alist-get 'kind record))
    (subject . ,(mara--alist-get 'subject record))
    (predicate . ,(mara--alist-get 'predicate record))
    (object . ,(mara--alist-get 'object record))
    (summary . ,(mara--alist-get 'summary record ""))
    (confidence . ,(mara--alist-get 'confidence record 0.5))
    (importance . ,(mara--alist-get 'importance record 0.5))
    (score . ,score)
    (reasons . ,(vconcat reasons))))

(defun mara-tools--fallback-memory-hits (query)
  "Return lexical active-memory hits for QUERY without requiring Prolog."
  (let ((terms (mara-tools--query-terms query))
        hits)
    (dolist (record (mara-memory-records))
      (let ((matches (mara-tools--memory-match-count record terms)))
        (when (and (mara-tools--memory-active-p record)
                   (> matches 0))
          (let* ((confidence (or (mara--alist-get 'confidence record) 0.5))
                 (importance (or (mara--alist-get 'importance record) 0.5))
                 (score
                  (min 1.0
                       (+ 0.35
                          (* matches 0.12)
                          (* confidence 0.15)
                          (* importance 0.10)))))
            (push
             (mara-tools--memory-hit
              record score '("fallback-text-match" "active-memory"
                             "confidence" "importance"))
             hits)))))
    (sort hits
          (lambda (a b)
            (> (mara--alist-get 'score a 0.0)
               (mara--alist-get 'score b 0.0))))))

(defun mara-tools--prolog-memory-hits (query)
  "Return Prolog-ranked memory hits for QUERY."
  (let (hits)
    (dolist (row (mara-brain-relevant-memories query))
      (when-let ((record (mara-tools--memory-record
                          (mara--alist-get 'id row))))
        (push
         (mara-tools--memory-hit
          record
          (mara--alist-get 'score row 0.0)
          (mara--alist-get 'reasons row '()))
         hits)))
    (sort hits
          (lambda (a b)
            (> (mara--alist-get 'score a 0.0)
               (mara--alist-get 'score b 0.0))))))

(defun mara-tools--memory-search (input)
  "Search durable memory using INPUT."
  (mara-tools--ensure-state)
  (let* ((query (mara-tools--required-string input "query"))
         (brain-available (mara-brain-available-p))
         (backend (if brain-available "prolog" "fallback"))
         (hits
          (if brain-available
              (condition-case _err
                  (mara-tools--prolog-memory-hits query)
                (error
                 (setq backend "fallback")
                 (mara-tools--fallback-memory-hits query)))
            (mara-tools--fallback-memory-hits query)))
         (selected (seq-take hits mara-tools-memory-search-limit)))
    (mara-tools--json
     `((query . ,query)
       (backend . ,backend)
       (count . ,(length selected))
       (memories . ,(vconcat selected))))))

(defun mara-tools--remember (input)
  "Persist one durable memory from INPUT."
  (mara-tools--ensure-state)
  (let* ((kind (or (mara--alist-get "kind" input) "record"))
         (subject (mara-tools--required-string input "subject"))
         (predicate (mara-tools--required-string input "predicate"))
         (object (mara-tools--required-string input "object"))
         (summary
          (or (mara--alist-get "summary" input)
              (format "%s %s %s" subject predicate object)))
         (id
          (mara-memory-add
           :kind kind
           :subject subject
           :predicate predicate
           :object object
           :summary summary
           :confidence 0.9
           :importance 0.7
           :source-session
           (when mara-session-current
             (mara-session-id mara-session-current))
           :tags '("assistant-memory" "durable"))))
    (mara-tools--json
     `((stored . t)
       (memoryId . ,id)
       (subject . ,subject)
       (predicate . ,predicate)
       (object . ,object)
       (summary . ,summary)))))

(defun mara-tools--supersede-memory (input)
  "Supersede one durable memory using INPUT."
  (mara-tools--ensure-state)
  (let* ((old-id (mara-tools--required-string input "memory_id"))
         (old (or (mara-tools--memory-record old-id)
                  (user-error "Unknown memory: %s" old-id)))
         (object (mara-tools--required-string input "object"))
         (summary
          (or (mara--alist-get "summary" input)
              (format "Updated %s: %s"
                      (mara--alist-get 'predicate old)
                      object)))
         (tags
          (delete-dups
           (append (append (mara--alist-get 'tags old '()) nil)
                   '("supersession"))))
         (id
          (mara-memory-add
           :kind (mara--alist-get 'kind old "record")
           :subject (mara--alist-get 'subject old)
           :predicate (mara--alist-get 'predicate old)
           :object object
           :summary summary
           :confidence (mara--alist-get 'confidence old 0.9)
           :importance (mara--alist-get 'importance old 0.7)
           :source-session
           (when mara-session-current
             (mara-session-id mara-session-current))
           :supersedes (list old-id)
           :tags tags)))
    (mara-tools--json
     `((stored . t)
       (supersededId . ,old-id)
       (memoryId . ,id)
       (subject . ,(mara--alist-get 'subject old))
       (predicate . ,(mara--alist-get 'predicate old))
       (object . ,object)
       (summary . ,summary)))))

(defun mara-tools--normalized-organic ()
  "Return a JSON-safe copy of the organic relationship state."
  (let ((organic (copy-tree (mara-relationship-organic) t)))
    (dolist (field '(phaseEvidence evidence) organic)
      (setf (alist-get field organic)
            (vconcat (or (mara--alist-get field organic) '()))))))

(defun mara-tools--relationship-status (_input)
  "Return inspectable relationship state."
  (mara-tools--ensure-state)
  (let ((brain-available (mara-brain-available-p)))
    (when brain-available
      (condition-case _err
          (mara-relationship-refresh-organic)
        (error nil)))
    (mara-tools--json
     `((brainAvailable . ,(if brain-available t :json-false))
       (organicRelationshipState . ,(mara-tools--normalized-organic))
       (activeRelationshipOverride . ,(mara-relationship-override))
       (effectivePhase . ,(mara-relationship-effective-phase))))))

(defun mara-tools--brain-query (input)
  "Inspect Prolog relevance reasoning using INPUT."
  (mara-tools--ensure-state)
  (let ((query (mara-tools--required-string input "query")))
    (if (not (mara-brain-available-p))
        (mara-tools--json
         `((available . :json-false)
           (query . ,query)
           (reason . "SWI-Prolog brain is unavailable")))
      (let ((rows (mara-brain-relevant-memories query)))
        (mara-tools--json
         `((available . t)
           (query . ,query)
           (memories
            . ,(vconcat
                (mapcar
                 (lambda (row)
                   `((id . ,(mara--alist-get 'id row))
                     (score . ,(mara--alist-get 'score row 0.0))
                     (reasons . ,(vconcat
                                  (mara--alist-get 'reasons row '())))))
                 rows)))))))))

(defun mara-tools--session-history (_input)
  "Return the most recent current-session messages."
  (mara-tools--ensure-state)
  (let* ((messages (mara-session-messages mara-session-current))
         (recent
          (if (> (length messages) mara-tools-session-history-limit)
              (last messages mara-tools-session-history-limit)
            messages)))
    (mara-tools--json
     `((sessionId . ,(mara-session-id mara-session-current))
       (profile . ,(mara-session-profile mara-session-current))
       (chatSlug . ,(mara-session-chat-slug mara-session-current))
       (count . ,(length recent))
       (messages . ,(vconcat recent))))))

(defun mara-tools--profile-get (_input)
  "Return the active profile and stable identity configuration."
  (mara-tools--ensure-state)
  (mara-tools--json
   `((profileName . ,mara-profile-current-name)
     (identityName . ,(mara--alist-get 'name mara-identity-current "Mara"))
     (voice . ,(mara--alist-get 'voice mara-identity-current ""))
     (persona . ,(mara--alist-get 'persona mara-profile-current ""))
     (capabilities . ,(vconcat (mara-profile-capabilities)))
     (interests . ,(vconcat (mara--alist-get 'items mara-interests-current '())))
     (hobbies . ,(vconcat (mara--alist-get 'items mara-hobbies-current '()))))))

(defun mara-tools--status (_input)
  "Return inspectable non-secret Mara state."
  (mara-tools--ensure-state)
  (mara-tools--json
   `((profile . ,mara-profile-current-name)
     (organicRelationshipState . ,(mara-tools--normalized-organic))
     (activeRelationshipOverride . ,(mara-relationship-override))
     (effectivePhase . ,(mara-relationship-effective-phase))
     (memoryCount . ,(length (mara-memory-records)))
     (brainAvailable . ,(if (mara-brain-available-p) t :json-false))
     (nativeToolCount . ,(hash-table-count mara-tools-registry)))))

(mara-tools-register
 (make-mara-tool
  :name "mara_status"
  :description "Inspect Mara's active profile, relationship state, memory count, Prolog availability, and native tool count."
  :capability "memory.read"
  :input-schema '((type . "object"))
  :function #'mara-tools--status))

(mara-tools-register
 (make-mara-tool
  :name "mara_memory_search"
  :description "Search Mara's durable local memory for prior user facts, preferences, project decisions, corrections, and relationship evidence. Uses Prolog ranking when available and a lexical fallback otherwise."
  :capability "memory.read"
  :input-schema
  '((type . "object")
    (properties
     . ((query . ((type . "string")
                  (description . "Natural-language memory query")))))
    (required . ["query"]))
  :function #'mara-tools--memory-search))

(mara-tools-register
 (make-mara-tool
  :name "mara_memory_remember"
  :description "Persist one explicit durable fact or preference that will likely matter in future conversations. Do not use for transient chatter or speculative inferences."
  :capability "memory.write"
  :input-schema
  '((type . "object")
    (properties
     . ((subject . ((type . "string")
                    (description . "Entity the memory is about, usually user, mara, dyad, or a project name")))
        (predicate . ((type . "string")
                      (description . "Stable relation name such as preferred_editor or project_goal")))
        (object . ((type . "string")
                   (description . "The durable value to remember")))
        (summary . ((type . "string")
                    (description . "Short human-readable summary")))
        (kind . ((type . "string")
                 (description . "Memory kind")
                 (enum . ["profile" "event" "record" "derived"])))))
    (required . ["subject" "predicate" "object"]))
  :function #'mara-tools--remember))

(mara-tools-register
 (make-mara-tool
  :name "mara_memory_supersede"
  :description "Correct or update an existing durable memory while preserving provenance by appending a replacement that supersedes the old memory."
  :capability "memory.write"
  :input-schema
  '((type . "object")
    (properties
     . ((memory_id . ((type . "string")
                      (description . "Existing memory ID to supersede")))
        (object . ((type . "string")
                   (description . "Replacement value")))
        (summary . ((type . "string")
                    (description . "Short explanation of the correction")))))
    (required . ["memory_id" "object"]))
  :function #'mara-tools--supersede-memory))

(mara-tools-register
 (make-mara-tool
  :name "mara_relationship_status"
  :description "Inspect Mara's organic relationship state, explicit override, effective phase, and whether the Prolog brain is available."
  :capability "memory.read"
  :input-schema '((type . "object"))
  :function #'mara-tools--relationship-status))

(mara-tools-register
 (make-mara-tool
  :name "mara_brain_query"
  :description "Inspect the Prolog brain's raw relevance ranking for a memory query, including memory IDs, scores, and reasoning tags."
  :capability "memory.read"
  :input-schema
  '((type . "object")
    (properties
     . ((query . ((type . "string")
                  (description . "Natural-language query to inspect")))))
    (required . ["query"]))
  :function #'mara-tools--brain-query))

(mara-tools-register
 (make-mara-tool
  :name "mara_session_history"
  :description "Inspect the recent messages persisted in Mara's current local conversation session."
  :capability "memory.read"
  :input-schema '((type . "object"))
  :function #'mara-tools--session-history))

(mara-tools-register
 (make-mara-tool
  :name "mara_profile_get"
  :description "Inspect Mara's active profile, stable identity voice, persona, capabilities, interests, and hobbies."
  :capability "memory.read"
  :input-schema '((type . "object"))
  :function #'mara-tools--profile-get))

(provide 'mara-tools)
;;; mara-tools.el ends here
