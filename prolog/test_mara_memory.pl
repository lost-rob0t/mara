:- begin_tests(mara_memory).

:- use_module('./mara-memory.pl').

memory_dict(Id, Subject, Predicate, Object, ObservedAt, Supersedes,
            _{ id: Id,
               kind: "event",
               subject: Subject,
               predicate: Predicate,
               object: Object,
               summary: "test memory",
               confidence: 1.0,
               importance: 1.0,
               observedAt: ObservedAt,
               validFrom: null,
               validTo: null,
               sourceSession: "session-1",
               sourceMessage: "message-1",
               supports: [],
               supersedes: Supersedes,
               tags: ["test"]
             }).

test(newer_interest_supersedes_older_interest) :-
    clear_memory,
    memory_dict("old", "user", "relationship_interest", "affirmative",
                "2026-08-10T00:00:00Z", [], Old),
    memory_dict("new", "user", "relationship_interest", "declined",
                "2026-08-11T00:00:00Z", ["old"], New),
    ingest_memory_dict(Old),
    ingest_memory_dict(New),
    relationship_snapshot(Snapshot),
    assertion(Snapshot.userInterest == "declined"),
    assertion(Snapshot.mutualInterest == false),
    assertion(\+ active_memory("old")),
    assertion(active_memory("new")).

test(dating_requires_reciprocal_interest) :-
    clear_memory,
    memory_dict("user-interest", "user", "relationship_interest", "affirmative",
                "2026-08-11T00:00:00Z", [], UserInterest),
    memory_dict("status", "dyad", "relationship_status", "dating",
                "2026-08-11T00:00:01Z", [], Status),
    ingest_memory_dict(UserInterest),
    ingest_memory_dict(Status),
    relationship_snapshot(Snapshot),
    assertion(Snapshot.phase == "acquaintance"),
    assertion(Snapshot.mutualInterest == false).

test(dating_with_reciprocal_interest_and_explicit_status) :-
    clear_memory,
    memory_dict("user-interest", "user", "relationship_interest", "affirmative",
                "2026-08-11T00:00:00Z", [], UserInterest),
    memory_dict("mara-interest", "mara", "relationship_interest", "affirmative",
                "2026-08-11T00:00:01Z", [], MaraInterest),
    memory_dict("status", "dyad", "relationship_status", "dating",
                "2026-08-11T00:00:02Z", [], Status),
    ingest_memory_dict(UserInterest),
    ingest_memory_dict(MaraInterest),
    ingest_memory_dict(Status),
    relationship_snapshot(Snapshot),
    assertion(Snapshot.phase == "dating"),
    assertion(Snapshot.mutualInterest == true),
    assertion(member("status", Snapshot.phaseEvidence)).

test(unresolved_conflict_is_visible) :-
    clear_memory,
    memory_dict("a", "user", "favorite_editor", "emacs",
                "2026-08-10T00:00:00Z", [], A),
    memory_dict("b", "user", "favorite_editor", "vim",
                "2026-08-11T00:00:00Z", [], B),
    ingest_memory_dict(A),
    ingest_memory_dict(B),
    assertion(contradicts("a", "b")).

test(symbolic_retrieval_returns_reasons) :-
    clear_memory,
    memory_dict("editor", "user", "favorite_editor", "emacs",
                "2026-08-11T00:00:00Z", [], Editor),
    ingest_memory_dict(Editor),
    once(relevant_memory("favorite editor", "editor", Score, Reasons)),
    assertion(Score > 0.0),
    assertion(member("symbolic-text-match", Reasons)).

:- end_tests(mara_memory).
