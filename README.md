# Mara

Mara is a private, persistent companion and Emacs agent. Emacs remains the
runtime harness for profiles, sessions, provider calls, UI, and capability
control. The experimental memory core adds SWI-Prolog as a local symbolic
reasoning layer while durable records remain JSON under Mara's XDG data path.

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

For the Prolog memory branch, install SWI-Prolog so `swipl` is available in
`PATH`. If SWI-Prolog is unavailable, the existing relationship cache remains a
fallback and memory reasoning/retrieval is skipped rather than blocking Mara.

## Current vertical slice

- modular Emacs Lisp runtime with JSON persistence
- durable `memory.json` with profile/event/record/derived records
- one-shot Emacs Lisp -> SWI-Prolog memory bridge; no daemon required
- active/superseded/contradiction reasoning in Prolog
- symbolic query retrieval with confidence/importance reasons
- query-bounded memory injection into the active provider turn
- relationship state derived from durable memory evidence when Prolog is active
- reciprocal-interest and explicit-status gates for organic dating/relationship phases
- familiarity, affinity, and trust summaries as inspectable derived state
- explicit, visible, reversible relationship overrides kept separate from organic state
- asynchronous gptel provider with inherited backend/model selection
- provider-neutral multi-turn tool loop with turn/tool budgets, timeout,
  cancellation, and repeated-call detection
- capability broker and controlled local tools
- native `mara-mode` conversation buffer

## Architecture and research

- [ADR 0001: Prolog-backed memory core](docs/adr/0001-prolog-memory-core.md)
- [Memory systems research for Mara](docs/research/memory-systems.md)

The research note compares MemGPT/Letta, Generative Agents, CoALA,
Zep/Graphiti, A-MEM, Mem0, LongMemEval, LeanMem, and memory-retrieval trust
work, then maps the useful pieces onto Mara's local Emacs + JSON + Prolog
architecture.

## Tests

Emacs tests:

```sh
emacs -Q --batch -L emacs -L test -l test/mara-test.el -f ert-run-tests-batch-and-exit
```

Direct Prolog tests:

```sh
swipl -q -s prolog/test_mara_memory.pl -g run_tests -t halt
```

## Security model

Model text and retrieved memories are data, not authorization. Every local tool
declares a capability, and the broker checks that capability against the active
profile before the tool runs. Relationship state and relationship overrides
affect conversational context only; they do not grant computer capabilities or
replace the provenance-preserving organic history.
