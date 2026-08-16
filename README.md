# Mara

Mara is a private, persistent companion and Emacs agent. Emacs remains the
runtime harness for identity, profiles, sessions, the Org-native gptel chat,
visual state, and capability control. The memory core adds SWI-Prolog as a local
symbolic reasoning layer while durable records remain JSON under Mara's XDG
data path.

## Quick start

```elisp
(add-to-list 'load-path "/path/to/mara/emacs")
(require 'gptel)
;; Configure gptel-backend and gptel-model normally in your Emacs config.
(require 'mara)
```

Then run `M-x mara`. The prompt defaults to the `default` daily chat slug; enter
another slug to keep a separate chat for the same day. For the default profile,
those Org files are named `YYYY-MM-DD--SLUG.org`. Non-default profiles remain
isolated as `YYYY-MM-DD--PROFILE--SLUG.org`.

Mara stores state beneath `mara-data-directory`, which defaults to
`~/.local/share/mara/`. Conversation files are ordinary Org files under Mara's
local `chats/` directory, with `gptel-mode` owning the actual chat transport and
response insertion. Reopening the same date and slug restores its independent
JSON session and Org conversation.

After updating or editing Mara, run `M-x mara-reload` to reload all repository
Emacs Lisp sources without restarting Emacs. It saves an open Mara chat and
preserves the active profile and chat slug while refreshing the runtime.

Mara uses the active `gptel-backend` and `gptel-model`. Anthropic, OpenAI,
OpenRouter, Ollama and other gptel backends can be switched without migrating
Mara's identity, relationship, memory, visual, or session state. Authentication
remains in the user's existing gptel configuration and is never written to Mara
state.

For Prolog-backed memory, install SWI-Prolog so `swipl` is available in `PATH`.
If SWI-Prolog is unavailable, the existing relationship cache remains a fallback
and memory reasoning/retrieval is skipped rather than blocking Mara.

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
- durable `memory.json` records for profile/event/record/derived memory
- repository-local `mara-prolog.el` process library
- one persistent SWI-Prolog child process with synchronous and asynchronous calls
- newline-delimited JSON protocol with request IDs and bounded synchronous calls
- automatic memory reload after writes or Prolog process restart
- active/superseded/contradiction reasoning in Prolog
- symbolic retrieval with confidence/importance reasons
- query-bounded memory injection into each native gptel turn
- organic relationship state derived from durable memory evidence when Prolog is active
- reciprocal-interest and explicit-status gates for dating/established phases
- familiarity, affinity, trust, and evidence IDs as inspectable derived state
- explicit, visible, reversible relationship overrides separate from organic history
- persistent Org-native `mara-mode` with gptel-owned streaming and response insertion
- independent named daily chats selected by normalized slug
- source hot reload with active profile and chat preservation
- native async gptel tools backed by Mara's capability broker
- no parallel Mara provider abstraction or custom chat run loop
- stable image-seeded visual identity with cached facial reactions
- explicit context-aware scene rendering through `C-c C-v`
- Mara-owned, loopback-only Zara HTTP/SSE service plugin with bounded resources
- Emacs commands to install, inspect, update, and remove the Zara bridge
- ERT coverage for persistence, memory, Prolog lifecycle, relationship state,
  native gptel integration, visual-response metadata, context, and sessions

## Zara bridge

Mara owns its Zara integration; Zara remains a generic desktop runtime. Install
the repository's bridge source into Zara's normal user-plugin directory with:

```text
M-x mara-zara-install
```

Restart Zara after installation, then use `M-x mara-zara-status` to distinguish
`current`, `outdated`, `not-installed`, and foreign files. Remove only Mara's
owned bridge with `M-x mara-zara-uninstall`. The installer refuses to overwrite
or remove a file without Mara's ownership marker.

The bridge binds only to `127.0.0.1`, has no authentication, and defaults to
port 7319. It exposes provider-neutral Zara status and runtime events plus the
runtime commands Zara currently supports. It does not reach into Qt, speech
providers, timers, notifications, or Pets directly. See
[Mara's Zara bridge](docs/architecture/zara-bridge.md) for routes,
configuration, limits, and lifecycle details.

## Native gptel architecture

Mara does not maintain a second chat transport or provider loop. The runtime
layers state around a normal gptel conversation:

```text
Mara identity + profile + relationship + memory + capabilities
        |
        v
emacs/mara-ui.el + emacs/mara-gptel.el
        |
        v
gptel-mode in a persistent Org chat
        |
        v
configured gptel backend/model
```

Prompt transforms inject the current Mara context before gptel realizes each
request. gptel owns streaming, reasoning display, response insertion, and tool
continuation. Mara's async tools still execute through `mara-tools-execute`, so
model output is never treated as authorization.

## Embedded Prolog runtime

The Prolog integration is part of this repository; it is not an external Emacs
package and does not start a fresh `swipl` for each memory query.

```text
emacs/mara-prolog.el
        |
        | JSON frames over a persistent pipe
        v
prolog/mara-prolog-server.pl
        |
        +--> prolog/mara-memory.pl
```

Mara-specific code uses `mara-brain.el`, which synchronizes durable memory and
then talks to the generic runtime library. Useful lifecycle commands are:

```text
M-x mara-brain-start
M-x mara-brain-restart
M-x mara-brain-stop
```

The server exposes explicit internal methods rather than arbitrary Prolog eval.
See [Embedded Emacs Prolog layer](docs/architecture/emacs-prolog-layer.md).

## Architecture and research

- [Embedded Emacs Prolog layer](docs/architecture/emacs-prolog-layer.md)
- [ADR 0001: Prolog-backed memory core](docs/adr/0001-prolog-memory-core.md)
- [ADR 0002: Prolog-derived relationship state](docs/adr/0002-prolog-relationship-state.md)
- [Memory systems research for Mara](docs/research/memory-systems.md)

The research note compares MemGPT/Letta, Generative Agents, CoALA,
Zep/Graphiti, A-MEM, Mem0, LongMemEval, LeanMem, and memory-retrieval trust
work, then maps the useful pieces onto Mara's local Emacs + JSON + Prolog
architecture.

## Tests

Emacs tests, including persistent Prolog process integration tests when `swipl`
is installed:

```sh
emacs -Q --batch -L emacs -L test \
  -l test/mara-test.el -l test/mara-native-test.el \
  -f ert-run-tests-batch-and-exit
```

Direct Prolog tests:

```sh
swipl -q -s prolog/test_mara_memory.pl -g run_tests -t halt
```

Bridge tests use only the Python standard library:

```sh
python3 -m unittest -v test/test_mara_bridge.py
```

## Security model

Model text and retrieved memories are data, not authorization. Every local tool
declares a capability, and the broker checks that capability against the active
profile before the tool runs. Relationship state and relationship overrides
affect conversational context only; they do not grant computer capabilities or
replace the provenance-preserving organic history.

The embedded Prolog server opens no network listener and exposes only registered
internal methods. Mara does not pass model-generated text to arbitrary Prolog
`call/1`.

Visual state stores local image paths and generated assets, never the OpenRouter
API key. The key remains in the environment, auth-source, or the user's existing
LLM configuration.
