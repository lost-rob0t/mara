# Memory systems research for Mara

Date: 2026-08-11
Status: Design input
Scope: Mara private runtime

This note records the memory-system research that informs Mara's Prolog memory core. It is intentionally about architecture rather than private conversation content.

## What the literature says

Long-term agent memory is not just "put old messages in a vector database." The strongest systems separate memory by purpose, preserve the history that produced a belief, and retrieve selectively.

### MemGPT / Letta: hierarchical context

MemGPT treats the model context window like a small fast memory tier and moves information between in-context and external memory. Current Letta keeps this idea through always-visible memory blocks, searchable files/archival memory, and external stores.

Useful lesson for Mara: keep a tiny amount of stable identity/relationship state always visible, but do not stuff the full history into every prompt.

References:

- https://arxiv.org/abs/2310.08560
- https://docs.letta.com/guides/core-concepts/memory/memory-blocks
- https://docs.letta.com/guides/core-concepts/memory/context-hierarchy

### Generative Agents: event stream, retrieval, reflection

Generative Agents stores an experience stream, retrieves memories using recency/relevance/importance, and periodically synthesizes higher-level reflections. The ablations matter: observation, planning, and reflection each contributed to believable long-running behavior.

Useful lesson for Mara: raw interactions and higher-level conclusions are different objects. A reflection or relationship conclusion must point back to evidence instead of replacing it.

Reference:

- https://arxiv.org/abs/2304.03442

### CoALA: memory types belong to different control loops

CoALA organizes language agents using working, episodic, semantic, and procedural memory together with internal actions that read and write those memories.

Useful lesson for Mara: conversational facts, events, relationship state, and learned procedures should not be one undifferentiated bag. Mara can begin with profile/event/record/derived memory and add procedural memory later.

Reference:

- https://arxiv.org/abs/2309.02427

### Zep / Graphiti: temporal relationship graphs

Zep's Graphiti models entities, relationships, and episodes with temporal validity and provenance. A fact can become invalid without deleting the historical episode that made it true at an earlier time.

Useful lesson for Mara: preferences and relationship state change. Store `observedAt`, `validFrom`, `validTo`, and explicit supersession rather than destructively editing history.

References:

- https://arxiv.org/abs/2501.13956
- https://github.com/getzep/graphiti

### A-MEM: memories should link and evolve

A-MEM creates structured notes with descriptions, keywords, tags, and links to related memories. New memories can change contextual representations of older memories instead of living as isolated chunks.

Useful lesson for Mara: graph edges do not require a graph database on day one. Prolog predicates can express links, support, contradiction, and supersession while JSON remains the durable evidence store.

Reference:

- https://arxiv.org/abs/2502.12110

### Mem0: extraction, consolidation, selective retrieval

Mem0 separates the act of extracting useful information from the act of retrieving it later. Its graph variant adds explicit relations between conversational facts.

Useful lesson for Mara: the LLM may propose candidate memories, but the persistence layer should validate, consolidate, and decide whether a candidate becomes durable state.

Reference:

- https://arxiv.org/abs/2504.19413

### LongMemEval: memory must survive updates and uncertainty

LongMemEval evaluates information extraction, multi-session reasoning, temporal reasoning, knowledge updates, and abstention. These are more useful requirements for Mara than simple nearest-neighbor recall.

Useful lesson for Mara: tests must include changed preferences, contradictory observations, "I don't know" cases, and questions requiring evidence from multiple sessions.

Reference:

- https://arxiv.org/abs/2410.10813

### LeanMem: do not process all history uniformly

LeanMem separates compact profile memory, temporal event memory, and source-grounded records, and allocates retrieval according to the evidence needs of the query. This is particularly close to the direction Mara already wants.

Useful lesson for Mara: stable profile facts should not be repeatedly summarized; mutable events should remain temporal; high-fidelity source records should remain available when verification matters.

Reference:

- https://arxiv.org/abs/2608.03463

### MemGate: retrieval is a trust boundary

Recent work on trustworthy memory search shows that semantic similarity can retrieve context that is relevant in topic but wrong for the current task, including memories that cause cross-domain leakage, sycophancy, tool drift, or prompt-injection-like effects.

Useful lesson for Mara: retrieved memory is untrusted context. Relevance is not admission. Tool permissions remain outside memory and relationship state.

Reference:

- https://arxiv.org/abs/2606.06054

## Mara's resulting memory model

Mara should use five logical layers even if the first implementation stores most of them in one JSON file:

```text
source episodes
    -> observations/events
    -> stable semantic/profile facts
    -> derived beliefs and relationship state
    -> selected working context
```

The layers have different rules:

| Layer | Mutable? | Typical content | Rule |
| --- | --- | --- | --- |
| source episode | no | original session/message reference | preserve provenance |
| event | append/supersede | something happened at a time | temporal ordering matters |
| profile | supersede | relatively stable preference/fact | conservative promotion |
| derived | recompute | conclusion supported by memories | always retain evidence |
| working context | ephemeral | memories selected for this turn | admission is query-specific |

This maps cleanly onto Prolog because the interesting operations are relational: "what supports this?", "what superseded this?", "what was true then?", "are these facts contradictory?", and "why was this retrieved?"

## Relationship memory is part of memory, not a side counter

Mara's relationship model should be derived from the same evidence graph.

The organic relationship state is a materialized view over memories such as:

```text
user --relationship_interest--> affirmative
mara --relationship_interest--> affirmative
dyad --interaction_quality--> warm
dyad --trust_signal--> positive
dyad --boundary_signal--> respected
dyad --relationship_status--> dating
```

Each edge is still a memory record with time, confidence, importance, source, and supersession metadata.

### What Prolog should infer

Prolog should own:

- current user interest from the latest non-superseded evidence
- current Mara interest from the latest non-superseded evidence
- whether interest is reciprocal
- familiarity from interaction history across sessions
- affinity/trust summaries from explicit signals
- the organic relationship phase
- the evidence IDs supporting every derived field

### What Prolog should not infer silently

A high interaction count must not automatically mean "dating." Dating and established-relationship phases require explicit current relationship-status evidence plus reciprocal interest. Familiarity and closeness may emerge from interaction history, but commitment is gated.

Explicit relationship overrides remain a separate visible UI/runtime mechanism. They change the effective conversational phase without rewriting organic history and never grant tool capabilities.

## Storage and execution choice

For the current Mara runtime:

- JSON remains the durable local record store under XDG data paths.
- SWI-Prolog is the symbolic reasoner, kept alive as a local child process by Emacs.
- Emacs Lisp remains the runtime harness and capability boundary.
- No Python service, graph database, vector database, or network daemon is required for the first vertical slice.
- Embeddings may later generate retrieval candidates, but symbolic/temporal admission decides what is usable.

## Evaluation targets

Before adding a vector store, Mara should pass deterministic tests for:

1. cross-session recall with provenance;
2. newer evidence superseding older evidence without deleting history;
3. contradictory evidence remaining unresolved when there is no justified winner;
4. relationship interest updating from newer evidence;
5. dating/established phases requiring explicit reciprocal evidence;
6. retrieval returning reasons/evidence IDs;
7. abstention when no active memory supports an answer;
8. memory never changing tool permissions.

The implementation plan lives in [ADR 0001](../adr/0001-prolog-memory-core.md).
