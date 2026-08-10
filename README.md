# Mara

Mara is a private, persistent companion and Emacs agent. In v0.1, Emacs is
the runtime: identity, profiles, relationship state, sessions, provider calls,
and the capability-controlled tool loop all live in Emacs Lisp.

## Quick start

```elisp
(add-to-list 'load-path "/path/to/mara/emacs")
(require 'mara)
(setq mara-anthropic-api-key-function
      (lambda () (auth-source-pick-first-password :host "api.anthropic.com")))
```

Then run `M-x mara`. Mara stores state beneath `mara-data-directory`, which
defaults to `~/.local/share/mara/`.

The first provider is Anthropic. Set `ANTHROPIC_API_KEY` or customize
`mara-anthropic-api-key-function`. The key is never written to Mara state.

## Current vertical slice

- modular Emacs Lisp runtime with JSON persistence
- separate identity, profile, relationship, interest, hobby, and session state
- explicit, visible, reversible relationship overrides alongside organic state
- asynchronous Anthropic Messages API adapter
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

