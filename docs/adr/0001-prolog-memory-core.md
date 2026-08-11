# ADR 0001: Prolog-backed memory core

Status: Proposed
Date: 2026-08-10
Scope: Mara private runtime

## Context

Mara v0.1 keeps runtime orchestration, provider calls, relationship state, sessions, tools, and JSON persistence in Emacs Lisp. The next architectural step is persistent long-term memory that can support multi-session continuity without forcing the full transcript into every model call.

This ADR intentionally contains architecture and generic examples only. It must not contain private conversation excerpts, sensitive personal examples, or user-specific relationship details.

Current memory research strongly suggests that a useful long-term agent memory is not a single vector store. High-performing systems separate always-visible working/profile state from larger archival/event memory, preserve temporal and provenance information, consolidate repeated observations into more stable knowledge, and selectively retrieve evidence for the current query.

Relevant systems and findings:

- MemGPT/Letta uses hierarchical memory: small persistent in-context blocks plus larger archival memory and conversation search.
- A-MEM dynamically creates structured notes with contextual descriptions, keywords, tags, links, and evolving connections between memories.
- Zep/Graphiti represents conversational memory as a temporally aware knowledge graph so relationships can change without destroying history.
- Mem0 performs extraction, consolidation, and selective retrieval; its graph variant adds relational structure.
- LongMemEval shows that long-term memory requires more than fact recall: systems must handle multi-session reasoning, temporal reasoning, knowledge updates, and abstention.
- LongMemEval-V2 expands this toward experience memory: static state, dynamic state, workflows, recurring failure modes, and premise awareness.
- LeanMem argues against processing all dialogue uniformly. It separates compact profile memory, temporal event memory, and source-grounded records, and retrieves them according to evidence needs.
- Recent security work treats memory retrieval as a trust boundary: semantic similarity alone can retrieve contextually inappropriate or adversarial memories.

Primary references:

- MemGPT: https://arxiv.org/abs/2310.08560
- A-MEM: https://arxiv.org/abs/2502.12110
- Zep / Graphiti: https://arxiv.org/abs/2501.13956
- Mem0: https://arxiv.org/abs/2504.19413
- LongMemEval: https://arxiv.org/abs/2410.10813
- LongMemEval-V2: https://arxiv.org/abs/2605.12493
- LeanMem: https://arxiv.org/abs/2608.03463
- Trustworthy memory search / MemGate: https://arxiv.org/abs/2606.06054
- Letta memory blocks: https://docs.letta.com/guides/core-concepts/memory/memory-blocks
- Letta context hierarchy: https://docs.letta.com/guides/core-concepts/memory/context-hierarchy

## Decision

Mara will add a Prolog-backed reasoning layer for long-term memory while retaining Emacs Lisp as the runtime harness and JSON as the initial persistence format.

Prolog is not the transcript database and is not initially responsible for durable writes. It is the symbolic layer that classifies, derives, validates, ranks, and explains memory state.

The initial flow is:

```text
user message
    |
    v
session transcript (source evidence)
    |
    v
memory candidate extraction
    |
    v
validated memory records (JSON)
    |
    v
Prolog memory core
    |
    +--> consolidation / contradiction / temporal rules
    |
    +--> retrieval candidates + reasons
    |
    v
mara-context.el
    |
    v
LLM
```

### Memory classes

The first implementation will distinguish four classes.

1. `profile` — compact relatively stable facts or preferences that may deserve frequent context inclusion.
2. `event` — timestamped episodic observations and interactions whose temporal order matters.
3. `record` — source-grounded evidence that should remain immutable and traceable to its origin.
4. `derived` — conclusions inferred from one or more memories; these must retain provenance to supporting records.

Procedural/experience memory is deliberately deferred until the basic conversational memory pipeline is stable.

### Source of truth

Raw session messages remain source evidence. Memory records must reference their source session/message identifiers. Derived memories must never erase the evidence used to produce them.

Memory truth is therefore layered rather than overwritten:

```text
source record -> observation -> derived belief
```

A newer observation may supersede an older belief while the older observation remains historically available.

### Temporal model

Memory records should distinguish at least:

- `observedAt`: when Mara learned the information
- `validFrom`: when the information appears to have become true, when known
- `validTo`: when it stopped being true, when known

This allows facts to change without destructive replacement.

### Candidate memory schema

Initial persisted records should be close to:

```json
{
  "id": "mem-...",
  "kind": "profile|event|record|derived",
  "subject": "...",
  "predicate": "...",
  "object": "...",
  "summary": "...",
  "confidence": 0.0,
  "importance": 0.0,
  "observedAt": "...",
  "validFrom": null,
  "validTo": null,
  "sourceSession": "...",
  "sourceMessage": "...",
  "supports": [],
  "supersedes": [],
  "tags": []
}
```

The schema is intentionally explicit. We should resist storing arbitrary opaque prose as the only representation.

### Memory writes

The LLM may propose memories but must not directly declare durable truth.

The harness should treat extraction output as candidate data:

```text
LLM proposal -> structural validation -> dedupe/contradiction checks -> persistence
```

At first, automatic writes should be conservative. Low-confidence candidates can remain event/record memories without being promoted into stable profile facts.

### Prolog responsibilities

The initial Prolog core should support predicates conceptually equivalent to:

```prolog
memory(Id, Kind, Subject, Predicate, Object).
source(Id, SessionId, MessageId).
confidence(Id, Score).
importance(Id, Score).
observedAt(Id, Timestamp).
validDuring(Id, From, To).
supports(DerivedId, EvidenceId).
supersedes(NewId, OldId).

activeMemory(Id).
contradicts(A, B).
stableFact(Subject, Predicate, Object, Evidence).
relevantMemory(QueryContext, Id, Score, Reasons).
```

The key requirement is explainability: retrieval and consolidation should be able to return reasons/evidence rather than only a score.

### Retrieval

Do not use semantic similarity as the sole retrieval criterion.

Retrieval should eventually combine:

```text
semantic relevance
+ symbolic relation match
+ temporal validity
+ recency
+ importance
+ confidence
+ provenance quality
- contradiction penalty
- stale/superseded penalty
```

The first implementation does not need embeddings. Exact/entity/tag matching plus Prolog rules is sufficient to validate the architecture. Embeddings can be added later as one candidate-generation mechanism, not as the memory system itself.

### Context tiers

Mara should eventually expose memory to the model through three tiers:

1. always-visible compact state: identity and a very small set of high-value stable memories
2. retrieved memory: query-relevant profile/events/derived facts
3. source evidence: fetched only when verification or detail is needed

This mirrors the useful part of hierarchical memory systems without importing their entire runtime model.

### Relationship state

Relationship state should consume memory evidence rather than becoming an unrelated counter system. Relationship advancement rules can eventually query interaction history and derived state, but relationship logic is downstream of the generic memory model.

This ADR does not define specific relationship thresholds.

### Safety and trust boundary

Persistent memory is a durable control channel and must be treated as untrusted data until admitted for the current task.

At minimum:

- preserve provenance
- keep model-generated proposals distinguishable from source evidence
- prevent retrieved memory from granting tool capabilities
- allow memories to be superseded without destroying history
- support abstention when evidence is weak or contradictory
- avoid injecting irrelevant sensitive memories merely because they are semantically similar

## Initial implementation slice

Do not introduce Python, a Prolog daemon, actors, sockets, a vector database, or a graph database in the first slice.

Add:

```text
emacs/mara-memory.el
emacs/mara-brain.el
prolog/mara-memory.pl
```

And persist records initially at:

```text
~/.local/share/mara/memory.json
```

### Phase 1

- define JSON memory record schema
- append validated memory records from Emacs Lisp
- load a small working set into SWI-Prolog
- implement active/superseded/contradiction rules
- expose a `mara-brain-relevant-memories` call
- inject only selected memory summaries into `mara-context.el`
- add ERT tests plus direct SWI-Prolog tests

### Phase 2

- candidate extraction from completed turns
- deduplication and consolidation
- confidence/importance updates
- temporal replacement/supersession
- derived memories with evidence links

### Phase 3

- embedding-assisted candidate generation if exact/symbolic retrieval is insufficient
- richer graph traversal
- memory maintenance/forgetting policy
- procedural/experience memory
- evaluation harness using synthetic conversations

## Alternatives considered

### Vector store only

Rejected as the core architecture. Useful later for candidate retrieval, but weak at provenance, contradiction, temporal change, symbolic inference, and deterministic relationship/state rules.

### Put all memory in Prolog facts on disk

Rejected for the first version. Prolog should reason over memory, not become the sole evidence store. Keeping source records in JSON makes persistence and debugging simpler while the model evolves.

### Python memory service

Deferred. Mara v0.1 is already an Emacs runtime. Adding Python before the memory abstraction is proven adds another process boundary without solving a current requirement.

### Full knowledge graph database

Deferred. The memory schema and Prolog relations can express graph structure before a dedicated graph database is justified.

## Consequences

Positive:

- explicit and inspectable memory semantics
- provenance and temporal reasoning from the beginning
- relationship logic can later depend on real remembered evidence
- no mandatory vector database
- preserves the simple Emacs-first harness
- enables deterministic tests around memory behavior

Costs:

- requires a clean Emacs Lisp <-> SWI-Prolog bridge
- extraction still depends partly on probabilistic model output
- symbolic schemas can become brittle if expanded too quickly
- ranking will initially be less fuzzy than embedding-based systems

## Open questions

- Should `memory.json` be one append-only log plus materialized views instead of a mutable array?
- What is the minimum candidate extraction format that multiple gptel backends can reliably produce?
- How should confidence change when repeated independent observations agree?
- Which contradictions should automatically supersede old beliefs versus remain unresolved?
- How much memory should be always visible before retrieval is required?
- When should memory consolidation run: immediately after each turn, at session close, or both?
- What evaluation corpus should Mara use to test recall, updates, temporal reasoning, contradiction handling, and abstention?

## First experiment

Build the smallest vertical slice that proves this query works across sessions:

```prolog
relevantMemory(Context, Id, Score, Reasons).
```

The returned memory must have provenance, must not be superseded, and must be injectable into the next system context without loading the full prior transcript.
