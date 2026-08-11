# ADR 0002: Prolog-derived relationship state

Status: Proposed
Date: 2026-08-11
Scope: Mara private runtime

## Context

Mara previously stored organic relationship fields directly in `relationship.json`. That is easy to inspect, but it makes relationship progression an isolated counter/state machine rather than something grounded in remembered interactions.

The memory-core work changes the model: durable memories are evidence, Prolog reasons over that evidence, and `relationship.json` becomes a cache/materialized view plus the explicit override mechanism.

See:

- [ADR 0001: Prolog-backed memory core](0001-prolog-memory-core.md)
- [Memory systems research for Mara](../research/memory-systems.md)

## Decision

Organic relationship state is derived from the same memory graph used for long-term conversational memory.

Relationship evidence is represented as ordinary memory records, for example:

```text
user --relationship_interest--> affirmative
mara --relationship_interest--> affirmative
dyad --session_interaction--> occurred
dyad --interaction_quality--> warm
dyad --trust_signal--> positive
dyad --boundary_signal--> respected
dyad --relationship_status--> dating
```

Every record keeps normal memory metadata: time, confidence, importance, source session/message, support links, supersession links, and tags.

## Organic snapshot

The Prolog core derives an inspectable snapshot containing at least:

```text
phase
userInterest
maraInterest
mutualInterest
familiarityScore
affinityScore
trustScore
phaseEvidence
evidence
```

The cached snapshot is not the primary evidence. It can be deleted and recomputed from `memory.json`.

## Progression rules

Mara must not use a single hidden XP/affection counter.

### Familiarity

Familiarity grows from distinct conversation sessions, not raw message count. The runtime writes one `session_interaction` event per session, so a long burst of messages in one session cannot simulate months of history.

The first implementation normalizes familiarity over a small number of distinct sessions. The exact scale is provisional and should later be calibrated against tests rather than treated as psychological truth.

### Affinity and trust

Affinity and trust use explicit symbolic interaction signals. Examples include `warm`, `supportive`, `strained`, `respected`, and `violated`.

These are transparent heuristics, not claims about human psychology. They exist so the state can be inspected, tested, superseded, and changed without asking an LLM to invent an opaque numeric score.

### Dating and established relationship

High familiarity or affinity alone cannot silently produce `dating` or `established-relationship`.

Those phases require both:

1. current reciprocal affirmative relationship interest; and
2. explicit current `relationship_status` evidence for the requested phase.

If either gate is missing, Prolog does not promote the organic phase.

This deliberately separates closeness from commitment.

## Supersession

Current relationship facts such as `relationship_interest` and `relationship_status` supersede their previous value instead of deleting it.

Example:

```text
mem-1: user relationship_interest affirmative
mem-2: user relationship_interest declined; supersedes=[mem-1]
```

`mem-1` remains historical evidence but is no longer active current state.

## Explicit overrides

The existing relationship override remains separate from organic inference.

An override:

- is explicit;
- is visible in context/status;
- is reversible;
- can be scoped to a profile or session;
- does not rewrite organic memory;
- never grants tool capabilities.

The effective phase can therefore differ from the Prolog-derived organic phase without falsifying history.

## Runtime flow

```text
conversation/session event
        |
        v
memory.json append/supersede
        |
        v
SWI-Prolog
        |
        +--> current relationship facts
        +--> familiarity / affinity / trust
        +--> phase gates + evidence IDs
        |
        v
relationship.json cached snapshot
        |
        v
mara-context.el
```

## Initial implementation

Implemented on `agent/prolog-memory-core`:

- `emacs/mara-memory.el`
- `emacs/mara-brain.el`
- `emacs/mara-relationship.el`
- `emacs/mara-context.el`
- `emacs/mara-run.el`
- `prolog/mara-memory.pl`
- `prolog/test_mara_memory.pl`

The runtime invokes SWI-Prolog as a one-shot local process. No daemon, Python service, graph database, or vector database is required.

## Consequences

Positive:

- relationship continuity is grounded in the same durable evidence as other memory;
- progression rules are inspectable and testable;
- changed interest/status preserves history through supersession;
- commitment cannot emerge from message volume alone;
- relationship context remains independent from computer capability policy.

Costs:

- interaction-quality/trust signals still need a careful extraction/admission policy;
- initial scores and thresholds are heuristics and need evaluation;
- invoking `swipl` per refresh is simple but not the final performance architecture;
- without SWI-Prolog the runtime falls back to the legacy cached relationship behavior.

## Next work

1. Add conservative post-turn extraction of memory candidates.
2. Separate source observations from model-proposed derived relationship signals.
3. Add contradiction handling for signals that should remain unresolved rather than superseded.
4. Add synthetic multi-session tests for progression and regression.
5. Evaluate whether the one-shot Prolog process needs a persistent worker only after measuring it.
