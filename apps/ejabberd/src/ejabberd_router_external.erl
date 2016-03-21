%%%-------------------------------------------------------------------
%%% @author bartek
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 21. Mar 2016 12:30
%%%-------------------------------------------------------------------
-module(ejabberd_router_external).
-author("bartek").

-behaviour(xmpp_router).

-include("ejabberd.hrl").
-include("jlib.hrl").

%% xmpp_router callback
-export([filter/3, route/3]).

filter(OrigFrom, OrigTo, OrigPacket) ->
    {OrigFrom, OrigTo, OrigPacket}.

route(From, To, Packet) ->
    LDstDomain = To#jid.lserver,
    case mnesia:dirty_read(external_component, LDstDomain) of
        [] ->
            {From, To, Packet};
        [#external_component{handler = Handler}] ->
            ejabberd_local_delivery:do_local_route(From, To, Packet,
                LDstDomain, Handler),
            done
    end.
