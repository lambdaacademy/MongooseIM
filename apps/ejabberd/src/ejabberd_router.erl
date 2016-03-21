%%%----------------------------------------------------------------------
%%% File    : ejabberd_router.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Main router
%%% Created : 27 Nov 2002 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2011   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(ejabberd_router).
-author('alexey@process-one.net').

-behaviour(gen_server).
%% API
-export([route/3,
         route_error/4,
         register_route/1,
         register_route/2,
         register_routes/1,
         unregister_route/1,
         unregister_routes/1,
         dirty_get_all_routes/0,
         dirty_get_all_domains/0,
         register_components/1,
         register_component/1,
         unregister_component/1,
         unregister_components/1
        ]).

-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("ejabberd.hrl").
-include("jlib.hrl").

-record(state, {}).

-type handler() :: 'undefined'
| {'apply_fun',fun((_,_,_) -> any())}
| {'apply', M::atom(), F::atom()}.
-type domain() :: binary().

-type route() :: #route{domain :: domain(),
                         handler :: handler()}.
-type external_component() :: #external_component{domain :: domain(),
                         handler :: handler()}.


%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Description: Starts the server
%%--------------------------------------------------------------------


-spec start_link() -> 'ignore' | {'error',_} | {'ok',pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Route the error packet only if the originating packet is not an error itself.
%% RFC3920 9.3.1
-spec route_error(From   :: ejabberd:jid(),
                  To     :: ejabberd:jid(),
                  ErrPacket :: jlib:xmlel(),
                  OrigPacket :: jlib:xmlel()) -> ok.
route_error(From, To, ErrPacket, OrigPacket) ->
    #xmlel{attrs = Attrs} = OrigPacket,
    case <<"error">> == xml:get_attr_s(<<"type">>, Attrs) of
        false ->
            route(From, To, ErrPacket);
        true ->
            ok
    end.

-spec register_components([Domain :: domain()]) -> ok | {error, any()}.
register_components(Domains) ->
    LDomains = [{jlib:nameprep(Domain), Domain} || Domain <- Domains],
    Handler = make_handler(undefined),
    F = fun() ->
            [do_register_component(LDomain, Handler) || LDomain <- LDomains],
            ok
    end,
    case mnesia:transaction(F) of
        {atomic, ok}      -> ok;
        {aborted, Reason} -> {error, Reason}
    end.

-spec register_component(Domain :: domain()) -> ok | {error, any()}.
register_component(Domain) ->
    register_components([Domain]).

do_register_component({error, Domain}, _Handler) ->
    error({invalid_domain, Domain});
do_register_component({LDomain, _}, Handler) ->
    Component = #external_component{domain = LDomain, handler = Handler},
    case {mnesia:read(route, LDomain),
          mnesia:read(external_component, LDomain)} of
        {[], []} ->
            ok = mnesia:write(Component);
        _ ->
            mnesia:abort(route_already_exists)
    end.

-spec unregister_components([Domains :: domain()]) -> {atomic, ok}.
unregister_components(Domains) ->
    LDomains = [{jlib:nameprep(Domain), Domain} || Domain <- Domains],
    F = fun() ->
            [do_unregister_component(LDomain) || LDomain <- LDomains],
            ok
    end,
    {atomic, ok} = mnesia:transaction(F).

do_unregister_component({error, Domain}) ->
    error({invalid_domain, Domain});
do_unregister_component({LDomain, _}) ->
    ok = mnesia:delete({external_component, LDomain}).

-spec unregister_component(Domain :: domain()) -> {atomic, ok}.
unregister_component(Domain) ->
    unregister_components([Domain]).

-spec register_route(Domain :: domain()) -> any().
register_route(Domain) ->
    register_route(Domain, undefined).

-spec register_route(Domain :: domain(),
                     Handler :: handler()) -> any().
register_route(Domain, Handler) ->
    register_route_to_ldomain(jid:nameprep(Domain), Domain, Handler).

-spec register_routes([domain()]) -> 'ok'.
register_routes(Domains) ->
    lists:foreach(fun(Domain) ->
                      register_route(Domain)
                  end,
                  Domains).

-spec register_route_to_ldomain(binary(), domain(), handler()) -> any().
register_route_to_ldomain(error, Domain, _) ->
    erlang:error({invalid_domain, Domain});
register_route_to_ldomain(LDomain, _, HandlerOrUndef) ->
    Handler = make_handler(HandlerOrUndef),
    mnesia:dirty_write(#route{domain = LDomain, handler = Handler}).

-spec make_handler(handler()) -> handler().
make_handler(undefined) ->
    Pid = self(),
    {apply_fun, fun(From, To, Packet) ->
                    Pid ! {route, From, To, Packet}
                end};
make_handler({apply_fun, Fun} = Handler) when is_function(Fun, 3) ->
    Handler;
make_handler({apply, Module, Function} = Handler)
    when is_atom(Module),
         is_atom(Function) ->
    Handler.

unregister_route(Domain) ->
    case jid:nameprep(Domain) of
        error ->
            erlang:error({invalid_domain, Domain});
        LDomain ->
            mnesia:dirty_delete(route, LDomain)
    end.

unregister_routes(Domains) ->
    lists:foreach(fun(Domain) ->
                      unregister_route(Domain)
                  end,
                  Domains).


dirty_get_all_routes() ->
    lists:usort(all_routes()) -- ?MYHOSTS.

dirty_get_all_domains() ->
    lists:usort(all_routes()).

all_routes() ->
    mnesia:dirty_all_keys(route) ++ mnesia:dirty_all_keys(external_component).


%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([]) ->
    update_tables(),
    mnesia:create_table(route,
                        [{ram_copies, [node()]},
                         {type, set},
                         {attributes, record_info(fields, route)},
                         {local_content, true}]),
    mnesia:add_table_copy(route, node(), ram_copies),

    %% add distributed service_component routes
    mnesia:create_table(external_component,
                        [{ram_copies, [node()]},
                         {attributes, record_info(fields, external_component)},
                         {type, set}]),
    mnesia:add_table_copy(external_component, node(), ram_copies),
    compile_routing_module(),

    {ok, #state{}}.

%%--------------------------------------------------------------------
%% Function: handle_call(Request, From, State)
%%              -> {reply, Reply, State} |
%%                 {reply, Reply, State, Timeout} |
%%                 {noreply, State} |
%%                 {noreply, State, Timeout} |
%%                 {stop, Reason, Reply, State} |
%%                 {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({route, From, To, Packet}, State) ->
    route(From, To, Packet),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

routing_modules_list() ->
    %% this is going to be compiled on startup from settings
    mod_routing_machine:get_routing_module_list().

compile_routing_module() ->
    Mods = ejabberd_config:get_local_option(routing_modules),
    CodeStr = make_routing_module_source(Mods),
    {Mod, Code} = dynamic_compile:from_string(CodeStr),
    code:load_binary(Mod, "mod_routing_machine.erl", Code).

make_routing_module_source(undefined) ->
    ModList = [ejabberd_router_global,
               ejabberd_router_external,
               ejabberd_router_localdomain,
               ejabberd_s2s],
    make_routing_module_source(ModList);
make_routing_module_source(Mods) ->
    binary_to_list(iolist_to_binary(io_lib:format(
        "-module(mod_routing_machine).~n"
        "-compile(export_all).~n"
        "get_routing_module_list() -> ~p.~n",
        [Mods]))).

route(OrigFrom, OrigTo, OrigPacket) ->
    ?DEBUG("route~n\tfrom ~p~n\tto ~p~n\tpacket ~p~n",
           [OrigFrom, OrigTo, OrigPacket]),
    route(OrigFrom, OrigTo, OrigPacket, routing_modules_list()).

route(_, _, _, []) ->
    ok; %% shouldn't we raise error here?
route(OrigFrom, OrigTo, OrigPacket, [M|Tail]) ->
    ?DEBUG({using, M}),
    case (catch M:filter(OrigFrom, OrigTo, OrigPacket)) of
        {'EXIT', Reason} ->
            ?DEBUG({filtering, error}),
            ?ERROR_MSG("error when filtering from=~ts to=~ts in module=~p, reason=~p, packet=~ts, stack_trace=~p",
                [jid:to_binary(OrigFrom), jid:to_binary(OrigTo),
                    M, Reason, exml:to_binary(OrigPacket),
                    erlang:get_stacktrace()]),
            ok;
        drop ->
            ?DEBUG({filter, dropped}),
            ok;
        {OrigFrom, OrigTo, OrigPacket} ->
            ?DEBUG({filter, passed}),
            case catch(M:route(OrigFrom, OrigTo, OrigPacket)) of
                {'EXIT', Reason} ->
                    ?ERROR_MSG("error when routing from=~ts to=~ts in module=~p, reason=~p, packet=~ts, stack_trace=~p",
                        [jid:to_binary(OrigFrom), jid:to_binary(OrigTo),
                            M, Reason, exml:to_binary(OrigPacket),
                            erlang:get_stacktrace()]),
                    ?DEBUG({routing, error}),
                    ok;
                done ->
                    ?DEBUG({routing, done}),
                    ok;
                {From, To, Packet} ->
                    ?DEBUG({routing, skipped}),
                    route(From, To, Packet, Tail)
            end
    end.

update_tables() ->
    case catch mnesia:table_info(route, attributes) of
        [domain, node, pid] ->
            mnesia:delete_table(route);
        [domain, pid] ->
            mnesia:delete_table(route);
        [domain, pid, local_hint] ->
            mnesia:delete_table(route);
        [domain, handler] ->
            ok;
        {'EXIT', _} ->
            ok
    end,
    case lists:member(local_route, mnesia:system_info(tables)) of
        true ->
            mnesia:delete_table(local_route);
        false ->
            ok
    end.

