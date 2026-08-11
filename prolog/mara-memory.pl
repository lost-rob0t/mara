:- module(mara_memory,
          [ clear_memory/0,
            load_memory_file/1,
            ingest_memory_dict/1,
            active_memory/1,
            current_fact/4,
            contradicts/2,
            relevant_memory/4,
            relationship_snapshot/1
          ]).

:- use_module(library(apply)).
:- use_module(library(http/json)).
:- use_module(library(lists)).

:- dynamic memory/5.
:- dynamic source/3.
:- dynamic confidence/2.
:- dynamic importance/2.
:- dynamic observed_at/2.
:- dynamic valid_during/3.
:- dynamic supports/2.
:- dynamic supersedes/2.
:- dynamic tag/2.
:- dynamic summary/2.

clear_memory :-
    retractall(memory(_, _, _, _, _)),
    retractall(source(_, _, _)),
    retractall(confidence(_, _)),
    retractall(importance(_, _)),
    retractall(observed_at(_, _)),
    retractall(valid_during(_, _, _)),
    retractall(supports(_, _)),
    retractall(supersedes(_, _)),
    retractall(tag(_, _)),
    retractall(summary(_, _)).

load_memory_file(Path) :-
    clear_memory,
    setup_call_cleanup(
        open(Path, read, Stream, [encoding(utf8)]),
        json_read_dict(Stream, Root),
        close(Stream)),
    (   get_dict(memories, Root, Memories),
        is_list(Memories)
    ->  maplist(ingest_memory_dict, Memories)
    ;   true
    ).

ingest_memory_dict(Dict) :-
    required(Dict, id, Id),
    required(Dict, kind, Kind),
    required(Dict, subject, Subject),
    required(Dict, predicate, Predicate),
    required(Dict, object, Object),
    dict_value(Dict, summary, "", Summary),
    dict_value(Dict, confidence, 0.5, Confidence),
    dict_value(Dict, importance, 0.5, Importance),
    dict_value(Dict, observedAt, "", ObservedAt),
    dict_value(Dict, validFrom, "", ValidFrom),
    dict_value(Dict, validTo, "", ValidTo),
    dict_value(Dict, sourceSession, "", SourceSession),
    dict_value(Dict, sourceMessage, "", SourceMessage),
    dict_value(Dict, supports, [], Supports),
    dict_value(Dict, supersedes, [], Supersedes),
    dict_value(Dict, tags, [], Tags),
    assertz(memory(Id, Kind, Subject, Predicate, Object)),
    assertz(summary(Id, Summary)),
    assertz(confidence(Id, Confidence)),
    assertz(importance(Id, Importance)),
    assertz(observed_at(Id, ObservedAt)),
    assertz(valid_during(Id, ValidFrom, ValidTo)),
    assertz(source(Id, SourceSession, SourceMessage)),
    maplist(assert_support(Id), Supports),
    maplist(assert_supersedes(Id), Supersedes),
    maplist(assert_tag(Id), Tags).

required(Dict, Key, Value) :-
    get_dict(Key, Dict, Value),
    Value \== null,
    !.
required(_, Key, _) :-
    throw(error(existence_error(memory_field, Key), _)).

dict_value(Dict, Key, Default, Value) :-
    (   get_dict(Key, Dict, Candidate),
        Candidate \== null
    ->  Value = Candidate
    ;   Value = Default
    ).

assert_support(Id, Evidence) :- assertz(supports(Id, Evidence)).
assert_supersedes(Id, Old) :- assertz(supersedes(Id, Old)).
assert_tag(Id, Tag) :- assertz(tag(Id, Tag)).

active_memory(Id) :-
    memory(Id, _, _, _, _),
    \+ (supersedes(NewId, Id), memory(NewId, _, _, _, _)).

current_fact(Subject, Predicate, Object, Id) :-
    findall(ObservedAt-CandidateId-CandidateObject,
            ( active_memory(CandidateId),
              memory(CandidateId, _, Subject, Predicate, CandidateObject),
              observed_at(CandidateId, ObservedAt)
            ),
            Candidates),
    Candidates \= [],
    keysort(Candidates, Sorted),
    last(Sorted, _-Id-Object).

contradicts(A, B) :-
    A \== B,
    active_memory(A),
    active_memory(B),
    memory(A, _, Subject, Predicate, ObjectA),
    memory(B, _, Subject, Predicate, ObjectB),
    ObjectA \== ObjectB.

relevant_memory(Query, Id, Score, Reasons) :-
    active_memory(Id),
    memory(Id, _, Subject, Predicate, Object),
    summary(Id, Summary),
    relevance_match_count(Query, [Subject, Predicate, Object, Summary], Matches),
    Matches > 0,
    confidence(Id, Confidence),
    importance(Id, Importance),
    Raw is 0.45 + min(0.30, Matches * 0.10) +
          (Confidence * 0.15) + (Importance * 0.10),
    clamp(Raw, Score),
    Reasons = ["symbolic-text-match", "active-memory", "confidence", "importance"].

relevance_match_count(Query0, Fields, Count) :-
    value_text(Query0, QueryText),
    string_lower(QueryText, Query),
    split_string(Query, " \t\n", ".,!?;:()[]{}\"'", RawTerms),
    include(nontrivial_term, RawTerms, Terms),
    findall(1,
            ( member(Term, Terms),
              member(Field, Fields),
              value_text(Field, FieldText0),
              string_lower(FieldText0, FieldText),
              sub_string(FieldText, _, _, _, Term)
            ),
            Hits),
    length(Hits, Count).

nontrivial_term(Term) :- string_length(Term, Length), Length >= 2.

value_text(Value, Text) :-
    (   string(Value)
    ->  Text = Value
    ;   atom(Value)
    ->  atom_string(Value, Text)
    ;   term_string(Value, Text)
    ).

clamp(Value, Clamped) :-
    Clamped is max(0.0, min(1.0, Value)).

current_interest(Party, Value, Id) :-
    (   current_fact(Party, "relationship_interest", Value0, Id0)
    ->  Value = Value0,
        Id = Id0
    ;   Value = "unknown",
        Id = null
    ).

mutual_interest(true, Evidence) :-
    current_interest("user", "affirmative", UserId),
    current_interest("mara", "affirmative", MaraId),
    Evidence = [UserId, MaraId],
    !.
mutual_interest(false, Evidence) :-
    current_interest("user", _, UserId),
    current_interest("mara", _, MaraId),
    exclude(==(null), [UserId, MaraId], Evidence).

current_relationship_status(Status, Id) :-
    current_fact("dyad", "relationship_status", Status, Id).

session_count(Count) :-
    findall(Session,
            ( active_memory(Id),
              memory(Id, "event", _, _, _),
              source(Id, Session, _),
              Session \== ""
            ),
            Sessions0),
    sort(Sessions0, Sessions),
    length(Sessions, Count).

familiarity_score(Score) :-
    session_count(Count),
    Raw is Count / 8.0,
    clamp(Raw, Score).

affinity_delta("warm", 0.12).
affinity_delta("affectionate", 0.16).
affinity_delta("supportive", 0.10).
affinity_delta("playful", 0.08).
affinity_delta("neutral", 0.00).
affinity_delta("tense", -0.10).
affinity_delta("negative", -0.16).

trust_delta("positive", 0.12).
trust_delta("respected", 0.15).
trust_delta("repaired", 0.10).
trust_delta("neutral", 0.00).
trust_delta("strained", -0.12).
trust_delta("violated", -0.25).

weighted_signal(Predicate, DeltaPredicate, Id, Weighted) :-
    active_memory(Id),
    memory(Id, _, "dyad", Predicate, Value),
    call(DeltaPredicate, Value, Delta),
    confidence(Id, Confidence),
    importance(Id, Importance),
    Weighted is Delta * Confidence * Importance.

signal_score(Predicate, DeltaPredicate, Score) :-
    findall(Weighted,
            weighted_signal(Predicate, DeltaPredicate, _, Weighted),
            Weights),
    sum_list(Weights, Sum),
    Raw is 0.5 + Sum,
    clamp(Raw, Score).

affinity_score(Score) :- signal_score("interaction_quality", affinity_delta, Score).

trust_score(Score) :-
    findall(Weighted,
            ( weighted_signal("trust_signal", trust_delta, _, Weighted)
            ; weighted_signal("boundary_signal", trust_delta, _, Weighted)
            ),
            Weights),
    sum_list(Weights, Sum),
    Raw is 0.5 + Sum,
    clamp(Raw, Score).

relationship_phase("established-relationship", Reasons) :-
    mutual_interest(true, MutualEvidence),
    current_relationship_status("established-relationship", StatusId),
    append(MutualEvidence, [StatusId], Reasons),
    !.
relationship_phase("dating", Reasons) :-
    mutual_interest(true, MutualEvidence),
    current_relationship_status("dating", StatusId),
    append(MutualEvidence, [StatusId], Reasons),
    !.
relationship_phase("close", Reasons) :-
    familiarity_score(Familiarity),
    affinity_score(Affinity),
    trust_score(Trust),
    Familiarity >= 0.50,
    Affinity >= 0.65,
    Trust >= 0.50,
    current_interest("user", UserInterest, UserId),
    UserInterest \== "declined",
    current_interest("mara", MaraInterest, MaraId),
    MaraInterest \== "declined",
    exclude(==(null), [UserId, MaraId], Reasons),
    !.
relationship_phase("familiar", []) :-
    familiarity_score(Familiarity),
    Familiarity >= 0.25,
    !.
relationship_phase("acquaintance", []).

relationship_evidence(Evidence) :-
    findall(Id,
            ( active_memory(Id),
              memory(Id, _, Subject, Predicate, _),
              ( Subject == "dyad"
              ; Predicate == "relationship_interest"
              ; Predicate == "relationship_status"
              )
            ),
            Ids0),
    sort(Ids0, Evidence).

relationship_snapshot(Dict) :-
    current_interest("user", UserInterest, _),
    current_interest("mara", MaraInterest, _),
    mutual_interest(MutualInterest, _),
    familiarity_score(Familiarity),
    affinity_score(Affinity),
    trust_score(Trust),
    relationship_phase(Phase, PhaseReasons),
    relationship_evidence(Evidence),
    Dict = _{ phase: Phase,
              userInterest: UserInterest,
              maraInterest: MaraInterest,
              mutualInterest: MutualInterest,
              familiarityScore: Familiarity,
              affinityScore: Affinity,
              trustScore: Trust,
              phaseEvidence: PhaseReasons,
              evidence: Evidence
            }.

:- initialization(main, main).

main :-
    current_prolog_flag(argv, Args),
    catch(dispatch_args(Args), Error, cli_error(Error)).

dispatch_args([Command0, Path0 | Rest]) :-
    value_text(Command0, Command),
    value_text(Path0, Path),
    load_memory_file(Path),
    dispatch(Command, Rest),
    !.
dispatch_args(_) :-
    throw(error(domain_error(cli_arguments, "expected COMMAND MEMORY_PATH [ARGS...]"), _)).

dispatch("relationship", _) :-
    relationship_snapshot(Dict),
    json_write_dict(current_output, Dict),
    nl.
dispatch("relevant", [Query0 | _]) :-
    value_text(Query0, Query),
    findall(_{id: Id, score: Score, reasons: Reasons},
            relevant_memory(Query, Id, Score, Reasons),
            Rows0),
    sort(2, @>=, Rows0, Rows),
    json_write_dict(current_output, _{memories: Rows}),
    nl.
dispatch(Command, _) :-
    throw(error(domain_error(cli_command, Command), _)).

cli_error(Error) :-
    message_to_string(Error, Message),
    json_write_dict(current_output, _{error: Message}),
    nl,
    halt(1).
