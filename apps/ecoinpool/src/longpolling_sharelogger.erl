
%%
%% Copyright (C) 2011  Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
%%
%% This file is part of ecoinpool.
%%
%% ecoinpool is free software: you can redistribute it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% ecoinpool is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with ecoinpool.  If not, see <http://www.gnu.org/licenses/>.
%%

-module(longpolling_sharelogger).
-behaviour(gen_event).

-include("ecoinpool_misc_types.hrl").
-include("ecoinpool_db_records.hrl").

-export([
    new_polling_monitor/1,
    new_polling_monitor/2,
    new_polling_monitor/3,
    new_polling_monitor/4,
    poll_for_changes/2
]).

% Callbacks from gen_event
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3]).

-define(POLLING_MONITOR_TIMEOUT, 60 * 1000000).
-define(POLLING_MONITOR_TIMEOUT_CHECK, 10 * 1000).

-record(polling_monitor, {
    type :: subpool | user | worker,
    subpool_id :: binary(),
    is_aux = false :: boolean(),
    user_worker_id :: term(),
    last_return :: erlang:timestamp(),
    waiting :: {pid() | atom(), reference()} | undefined,
    has_changes = false :: boolean()
}).

-record(state, {
    pmon_tbl :: ets:tid(),
    pmons :: dict(),
    check_timer :: timer:tref()
}).

%% ===================================================================
%% API functions
%% ===================================================================

% Returns a token (hex binary)
new_polling_monitor(SubpoolId) ->
    new_polling_monitor(SubpoolId, false).

new_polling_monitor(SubpoolId, Aux) ->
    gen_event:call(ecoinpool_share_broker, ?MODULE, {new_polling_monitor, subpool, Aux, SubpoolId, undefined}).

new_polling_monitor(SubpoolId, Type, UserId) ->
    new_polling_monitor(SubpoolId, false, Type, UserId).
   
new_polling_monitor(SubpoolId, Aux, user, UserId) ->
    gen_event:call(ecoinpool_share_broker, ?MODULE, {new_polling_monitor, user, Aux, SubpoolId, UserId});
new_polling_monitor(SubpoolId, Aux, worker, WorkerId) ->
    gen_event:call(ecoinpool_share_broker, ?MODULE, {new_polling_monitor, worker, Aux, SubpoolId, WorkerId}).

% Will reply by sending {share_changes_result, Result} to the given process
% where Result can be {error, kicked | invalid_token} or {ok, Data} where Data
% is a tuple {Invalid, Valid, Candidate} for subpool and worker monitoring
% and a list [{WorkerId, Invalid, Valid, Candidate}] for user monitoring.
-spec poll_for_changes(To :: pid() | atom(), Token :: binary()) -> ok.
poll_for_changes(To, Token) ->
    gen_event:call(ecoinpool_share_broker, ?MODULE, {poll_for_changes, To, Token}).

%% ===================================================================
%% Gen_Event callbacks
%% ===================================================================

init([]) ->
    PMonTbl = ets:new(pmon_tbl, [set, protected]),
    {ok, CheckTimer} = timer:apply_interval(?POLLING_MONITOR_TIMEOUT_CHECK, gen_event, call, [ecoinpool_share_broker, ?MODULE, timeout_check]),
    {ok, #state{pmon_tbl=PMonTbl, pmons=dict:new(), check_timer=CheckTimer}}.

handle_event(#share{subpool_id=SubpoolId, is_aux=IsAux, worker_id=WorkerId, user_id=UserId, state=ShareState}, State=#state{pmon_tbl=PMonTbl, pmons=PMons}) ->
    Pos = case ShareState of invalid -> 2; valid -> 3; candidate -> 4 end,
    NewPMons = dict:map(
        fun
            (Token, PM=#polling_monitor{type=Type, subpool_id=ThisSubpoolId, is_aux=ThisAux, user_worker_id=UserOrWorkerId, waiting=Waiting, has_changes=HasChanges}) when ThisSubpoolId =:= SubpoolId, ThisAux =:= IsAux ->
                Key = case Type of
                    subpool ->
                        Token;
                    user when UserId =:= UserOrWorkerId ->
                        {Token, WorkerId};
                    worker when WorkerId =:= UserOrWorkerId ->
                        Token;
                    _ ->
                        undefined
                end,
                case Key of
                    undefined ->
                        PM;
                    _ ->
                        case ets:member(PMonTbl, Key) of
                            true ->
                                ets:update_counter(PMonTbl, Key, {Pos, 1});
                            _ ->
                                ets:insert(PMonTbl, setelement(Pos, {Key, 0,0,0}, 1))
                        end,
                        case Waiting of
                            undefined ->
                                if
                                    HasChanges ->
                                        PM;
                                    true ->
                                        PM#polling_monitor{has_changes=true}
                                end;
                            {To, MRef} ->
                                send_reply_and_flush(Token, Type, To, PMonTbl),
                                erlang:demonitor(MRef, [flush]),
                                PM#polling_monitor{last_return=erlang:now(), waiting=undefined}
                        end
                end;
            (_, PM) ->
                PM
        end,
        PMons
    ),
    {ok, State#state{pmons=NewPMons}};

handle_event(#subpool{}, State) ->
    {ok, State}.

handle_call({new_polling_monitor, Type, Aux, SubpoolId, UserOrWorkerId}, State=#state{pmons=PMons}) ->
    Token = ecoinpool_util:new_random_uuid(),
    PMon = #polling_monitor{
        type=Type,
        subpool_id=SubpoolId,
        is_aux=Aux,
        user_worker_id=UserOrWorkerId,
        last_return=erlang:now()
    },
    {ok, Token, State#state{pmons=dict:store(Token, PMon, PMons)}};

handle_call({poll_for_changes, To, Token}, State=#state{pmon_tbl=PMonTbl, pmons=PMons}) ->
    NewPMons = case dict:find(Token, PMons) of
        {ok, PM=#polling_monitor{type=Type, waiting=Waiting, has_changes=HasChanges}} ->
            if
                HasChanges ->
                    send_reply_and_flush(Token, Type, To, PMonTbl),
                    dict:store(Token, PM#polling_monitor{last_return=erlang:now(), has_changes=false}, PMons);
                true -> % Set to wait
                    case Waiting of
                        undefined ->
                            ok;
                        {OldTo, MRef} ->
                            OldTo ! {share_changes_result, {error, kicked}}, % Kick out already waiting
                            erlang:demonitor(MRef, [flush])
                    end,
                    dict:store(Token, PM#polling_monitor{waiting={To, erlang:monitor(process, To)}}, PMons)
            end;
        error ->
            To ! {share_changes_result, {error, invalid_token}}, % Reply invalid token
            PMons
    end,
    {ok, ok, State#state{pmons=NewPMons}};

handle_call(timeout_check, State=#state{pmons=PMons}) ->
    Now = erlang:now(),
    NewPMons = dict:filter(
        fun
            (_, #polling_monitor{last_return=LastReturn, waiting=undefined}) ->
                case timer:now_diff(Now, LastReturn) of
                    Diff when Diff > ?POLLING_MONITOR_TIMEOUT ->
                        false;
                    _ ->
                        true
                end;
            (_, _) ->
                true
        end,
        PMons
    ),
    {ok, ok, State#state{pmons=NewPMons}}.

handle_info({'DOWN', _, _, To, _}, State=#state{pmons=PMons}) ->
    NewPMons = dict:map(
        fun
            (_, PM=#polling_monitor{waiting={ThisTo, _}}) when ThisTo =:= To -> PM#polling_monitor{last_return=erlang:now(), waiting=undefined};
            (_, V) -> V
        end,
        PMons
    ),
    {ok, State#state{pmons=NewPMons}};

handle_info(_, State) ->
    {ok, State}.

terminate(_Reason, #state{check_timer=CheckTimer}) ->
    timer:cancel(CheckTimer),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

send_reply_and_flush(Token, user, To, PMonTbl) ->
    Data = [{WorkerId, Invalid, Valid, Candidate} || [WorkerId, Invalid, Valid, Candidate] <- ets:match(PMonTbl, {{Token, '$1'}, '$2', '$3', '$4'})],
    To ! {share_changes_result, {ok, Data}},
    do_flush(Token, user, PMonTbl);
send_reply_and_flush(Token, Type, To, PMonTbl) -> % Type can here be either subpool or worker
    Data = case ets:lookup(PMonTbl, Token) of
        [{_, Invalid, Valid, Candidate}] -> {Invalid, Valid, Candidate}
    end,
    To ! {share_changes_result, {ok, Data}},
    do_flush(Token, Type, PMonTbl).

do_flush(Token, user, PMonTbl) ->
    ets:match_delete(PMonTbl, {{Token, '_'}, '_', '_', '_'});
do_flush(Token, _, PMonTbl) -> % Type can here be either subpool or worker
    ets:delete(PMonTbl, Token).
