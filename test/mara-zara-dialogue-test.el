;;; mara-zara-dialogue-test.el --- Tests for typed Zara dialogue -*- lexical-binding: t; -*-

(require 'ert)
(require 'json)
(require 'mara-zara-dialogue)

(ert-deftest mara-zara-dialogue-normalizes-prolog-input-event ()
  (let* ((document
          '((sequence . 9)
            (occurredAt . 1.5)
            (type . "user.input_required")
            (data . ((turn_id . "turn-1")
                     (conversation_id . "conversation-1")
                     (kind . "prolog_question")
                     (prompt . "Which theme?")
                     (question_id . "theme")
                     (choices . ["outrun" "oled"])))))
         (request (mara-zara-dialogue--input-request document)))
    (should request)
    (should (equal "conversation-1" (plist-get request :conversation-id)))
    (should (equal "theme" (plist-get request :question-id)))
    (should (equal '("outrun" "oled") (plist-get request :choices)))))

(ert-deftest mara-zara-dialogue-ignores-normal-conversation-events ()
  (should-not
   (mara-zara-dialogue--input-request
    '((type . "assistant.complete")
      (data . ((text . "normal chat")))))))

(ert-deftest mara-zara-dialogue-choice-answer-keeps-conversation-correlation ()
  (let* ((request '(:conversation-id "conversation-1"
                    :turn-id "turn-1"
                    :kind "prolog_question"
                    :question-id "theme"
                    :prompt "Which theme?"
                    :choices ("outrun" "oled")))
         (payload (mara-zara-dialogue--answer-payload request "oled")))
    (should (equal "oled" (alist-get 'text payload)))
    (should (equal "conversation-1" (alist-get 'conversationId payload)))
    (should (= 2 (length payload)))))

(ert-deftest mara-zara-dialogue-rejects-unbounded-or-malformed-choice-state ()
  (should-not
   (mara-zara-dialogue--input-request
    '((type . "user.input_required")
      (data . ((kind . "prolog_question")
               (prompt . "")
               (choices . [])))))))

(provide 'mara-zara-dialogue-test)
;;; mara-zara-dialogue-test.el ends here
