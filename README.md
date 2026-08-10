# Mara

Mara is a private, persistent companion and Emacs agent. In v0.1, Emacs is
the runtime: identity, profiles, relationship state, sessions, provider calls,
and the capability-controlled tool loop all live in Emacs Lisp.

## Quick start

```elisp
(add-to-list 'load-path "/path/to/mara/emacs")
(require 'gptel)
;; Configure gptel-backend and gptel-model normally in your Emacs config.
(require 'mara)
```

Then run `M-x mara`. Mara stores state beneath `mara-data-directory`, which
defaults to `~/.local/share/mara/`.

Mara uses the active `gptel-backend` and `gptel-model`.  Anthropic, OpenAI,
OpenRouter, Ollama and other gptel backends can be switched without migrating
Mara's identity, relationship or session state.  Authentication remains in
the user's existing gptel configuration and is never written to Mara state.

## Current vertical slice

- modular Emacs Lisp runtime with JSON persistence
- separate identity, profile, relationship, interest, hobby, and session state
- explicit, visible, reversible relationship overrides alongside organic state
- asynchronous gptel provider with inherited backend/model selection
- provider-neutral multi-turn tool loop with turn/tool budgets, timeout,
  cancellation, and repeated-call detection
- capability broker and one controlled `mara_status` tool
- native `mara-mode` conversation buffer
- ERT coverage for persistence, relationship overrides, context, and sessions

Run tests with:

```sh
emacs -Q --batch -L emacs -L test -l test/mara-test.el -f ert-run-tests-batch-and-exit
```

## Security model

Model text is data, not authorization. Every local tool declares a capability,
and the broker checks that capability against the active profile before the
tool runs. Relationship overrides affect conversational context only; they do
not grant computer capabilities or replace organic relationship history.
