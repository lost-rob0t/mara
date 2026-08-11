:- module(mara_prolog_server, [main/0]).

:- use_module(library(http/json)).
:- use_module(library(readutil)).
:- use_module('./mara-memory.pl').

main :-
    set_stream(user_input, encoding(utf8)),
    set_stream(user_output, encoding(utf8)),
    server_loop.

server_loop :-
    read_line_to_string(user_input, Line),
    (   Line == end_of_file
    ->  true
    ;   handle_line(Line),
        flush_output(user_output),
        server_loop
    ).

handle_line(Line) :-
    catch(handle_line_(Line, Id),
          Error,
          emit_error_for(Id, Error)).

handle_line_(Line, Id) :-
    atom_string(Atom, Line),
    atom_json_dict(Atom, Request, []),
    request_id(Request, Id),
    request_method(Request, Method),
    request_params(Request, Params),
    dispatch(Method, Params, Result),
    emit_success(Id, Result).

request_id(Request, Id) :-
    (   get_dict(id, Request, Id0),
        integer(Id0)
    ->  Id = Id0
    ;   throw(error(domain_error(request_id, Request), _))
    ).

request_method(Request, Method) :-
    (   get_dict(method, Request, Method0),
        string(Method0)
    ->  Method = Method0
    ;   throw(error(domain_error(request_method, Request), _))
    ).

request_params(Request, Params) :-
    (   get_dict(params, Request, Params0),
        is_dict(Params0)
    ->  Params = Params0
    ;   Params = _{}
    ).

dispatch("ping", _, _{status: "pong"}).

dispatch("load_memory", Params, _{loaded: true, path: Path}) :-
    required_string(Params, path, Path),
    load_memory_file(Path).

dispatch("relationship", _, Snapshot) :-
    relationship_snapshot(Snapshot).

dispatch("relevant", Params, _{memories: Rows}) :-
    required_string(Params, query, Query),
    findall(_{id: Id, score: Score, reasons: Reasons},
            relevant_memory(Query, Id, Score, Reasons),
            Rows0),
    predsort(compare_relevance_rows, Rows0, Rows).

dispatch(Method, _, _) :-
    throw(error(domain_error(prolog_method, Method), _)).

required_string(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Candidate),
        string(Candidate)
    ->  Value = Candidate
    ;   throw(error(existence_error(request_parameter, Key), _))
    ).

compare_relevance_rows(Order, A, B) :-
    get_dict(score, A, ScoreA),
    get_dict(score, B, ScoreB),
    compare(ScoreOrder, ScoreB, ScoreA),
    (   ScoreOrder == (=)
    ->  get_dict(id, A, IdA),
        get_dict(id, B, IdB),
        compare(Order, IdA, IdB)
    ;   Order = ScoreOrder
    ).

emit_success(Id, Result) :-
    json_write_dict(user_output,
                    _{id: Id, ok: true, result: Result},
                    [width(0)]),
    nl(user_output).

emit_error_for(Id0, Error) :-
    (var(Id0) -> Id = null ; Id = Id0),
    message_to_string(Error, Message),
    json_write_dict(user_output,
                    _{id: Id, ok: false, error: Message},
                    [width(0)]),
    nl(user_output).

:- initialization(main, main).
