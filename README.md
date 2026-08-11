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

Mara uses the active `gptel-backend` and `gptel-model`. Anthropic, OpenAI,
OpenRouter, Ollama and other gptel backends can be switched without migrating
Mara's identity, relationship or session state. Authentication remains in the
user's existing gptel configuration and is never written to Mara state.

## Visual reactions

Mara can keep a stable visual identity instead of generating a new face every
turn. The visual runtime uses OpenRouter's image endpoint independently from
the text model. Its default image model is `bytedance-seed/seedream-4.5`, and
`OPENROUTER_IMAGE_MODEL` can select another OpenRouter image model.

Set `OPENROUTER_API_KEY` or store an `openrouter.ai` secret in Emacs
auth-source, then run:

```text
M-x mara-visual-bootstrap
```

Choose one canonical Mara image. The runtime copies that image into Mara's
local state and sequentially bootstraps a cached reaction bank: neutral, happy,
amused, affectionate, teasing, concerned, focused, annoyed, surprised, and
sleepy. Those cached images are reused; Mara's text response carries a hidden
machine-readable expression marker which is stripped before display and
persistence, then the side-window portrait changes to the selected reaction.

A full scene is deliberately opt-in because it costs an image generation call.
Inside `mara-mode`:

```text
C-c C-v        render a new scene from recent conversation context
C-u C-c C-v    render the scene with extra minibuffer direction
```

Scene generation uses the current reaction portrait as the image reference,
keeps Mara's identity stable, and stores generated scenes under Mara's local
visual state directory.

## Current vertical slice

- modular Emacs Lisp runtime with JSON persistence
- separate identity, profile, relationship, interest, hobby, and session state
- explicit, visible, reversible relationship overrides alongside organic state
- asynchronous gptel provider with inherited backend/model selection
- provider-neutral multi-turn tool loop with turn/tool budgets, timeout,
  cancellation, and repeated-call detection
- capability broker and one controlled `mara_status` tool
- native Evil-friendly `mara-mode` conversation buffer
- stable image-seeded visual identity with cached facial reactions
- explicit context-aware scene rendering through `C-c C-v`
- ERT coverage for persistence, relationship overrides, context, sessions, and
  visual-response metadata

Run tests with:

```sh
emacs -Q --batch -L emacs -L test -l test/mara-test.el -f ert-run-tests-batch-and-exit
```

## Security model

Model text is data, not authorization. Every local tool declares a capability,
and the broker checks that capability against the active profile before the
tool runs. Relationship overrides affect conversational context only; they do
not grant computer capabilities or replace organic relationship history.

Visual state stores local image paths and generated assets, never the OpenRouter
API key. The key remains in the environment, auth-source, or the user's existing
LLM configuration.
