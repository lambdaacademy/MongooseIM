-module(run_common_test).
-export([ct/0, ct_cover/0]).

-define(CT_DIR, filename:join([".", "tests"])).
-define(CT_REPORT, filename:join([".", "ct_report"])).
-define(CT_CONFIG, "test.config").
-define(EJABBERD_NODE, 'ejabberd@localhost').

ct() ->
    ct:run_test([
        {config, [?CT_CONFIG]},
        {dir, ?CT_DIR},
        {logdir, ?CT_REPORT}
    ]),
    init:stop(0).

ct_cover() ->
    cover_call(start),
    cover_call(compile_beam_directory,["lib/ejabberd-2.1.8/ebin"]),
    %% io:format("Compiled modules ~p~n", [Compiled]),
    ct:run_test([
        {config, [?CT_CONFIG]},
        {dir, ?CT_DIR},
        {logdir, ?CT_REPORT},
        {suite, login_SUITE}
    ]),
    Modules = cover_call(modules),
    rpc:call(?EJABBERD_NODE, file, make_dir, ["coverage"]),
    Fun = fun(Module) ->
                  Stats = cover_call(analyse, [Module, module]),
                  FileName = lists:flatten(io_lib:format("~s.COVER.html",[Module])),
                  FilePath = filename:join(["coverage", FileName]),
                  cover_call(analyse_to_file, [Module, FilePath, [html]]),
                  io:format("~p ~p~n", [Module, Stats])
          end,
    lists:foreach(Fun, Modules),
    %% io:format("modules ~p~n", Modules),
    init:stop(0).

cover_call(Function) ->
    cover_call(Function, []).
cover_call(Function, Args) ->
    rpc:call(?EJABBERD_NODE, cover, Function, Args).
