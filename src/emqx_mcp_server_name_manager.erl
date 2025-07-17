%%--------------------------------------------------------------------
%% Copyright (c) 2017-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_mcp_server_name_manager).

-feature(maybe_expr, enable).

-behaviour(gen_server).

-include_lib("emqx_plugin_helper/include/logger.hrl").

%% API
-export([
    start_link/0
]).

-export([
    load_json_file/1,
    match_server_name_rules/1,
    match_server_name_rules/2,
    add_server_name_rule/1,
    get_server_name_rules/0,
    put_server_name_rules/1,
    delete_server_name_rule/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_continue/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% Types
-define(SERVER, ?MODULE).
-define(TAB_SERVER_NAME, {?MODULE, mcp_server_name}).

-type sql_selector() :: #{
    fields := term(),
    where := tuple()
}.

-type mcp_server_name_rule() :: #{
    id := integer(),
    condition := binary(),
    selector := sql_selector(),
    server_name := binary(),
    server_name_tmpl := binary()
}.

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec load_json_file(binary()) -> {ok, binary()} | {error, term()}.
match_server_name_rules(ConnEvent) ->
    case get_server_name_rules() of
        [] ->
            {error, not_found};
        ServerNameRules ->
            match_server_name_rules(ServerNameRules, ConnEvent)
    end.

-spec add_server_name_rule(mcp_server_name_rule()) -> ok.
add_server_name_rule(Rule) ->
    put_server_name_rules([Rule | get_server_name_rules()]).

get_server_name_rules() ->
    persistent_term:get(?TAB_SERVER_NAME, []).

put_server_name_rules(Rules) ->
    persistent_term:put(?TAB_SERVER_NAME, Rules).

delete_server_name_rule(Id) ->
    Rules = get_server_name_rules(),
    persistent_term:put(?TAB_SERVER_NAME, [R || #{id := Id0} = R <- Rules, Id0 =/= Id]).

match_server_name_rules([], _ConnEvent) ->
    {error, not_found};
match_server_name_rules([Rule | Rest], ConnEvent) ->
    case match_server_name_rule(Rule, ConnEvent) of
        {ok, ServerName} ->
            {ok, ServerName};
        {error, _} ->
            match_server_name_rules(Rest, ConnEvent)
    end.

match_server_name_rule(#{id := Id, selector := Selector, server_name_tmpl := Tmpl}, ConnEvent) ->
    Fields = maps:get(fields, Selector),
    Where = maps:get(where, Selector, []),
    try emqx_rule_runtime:evaluate_select(Fields, ConnEvent, Where) of
        {ok, SelectedData} ->
            {ok, bbmustache:compile(Tmpl, to_key_map(SelectedData))};
        false ->
            {error, not_match}
    catch
        throw:Reason ->
            ?SLOG(error, #{
                msg => match_server_name_rule_failed,
                id => Id,
                reason => Reason
            }),
            {error, Reason};
        Class:Error:St ->
            ?SLOG(error, #{
                msg => match_server_name_rule_failed,
                id => Id,
                class => Class,
                error => Error,
                stacktrace => St
            }),
            {error, {Class, Error}}
    end.

init([]) ->
    {ok, #{}, {continue, load_server_names}}.

handle_continue(load_server_names, State) ->
    case load_server_names() of
        ok -> ok;
        {error, Reason} -> ?SLOG(error, #{msg => load_server_names_failed, reason => Reason})
    end,
    {noreply, State}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Import From CSV
%%--------------------------------------------------------------------
load_server_names() ->
    case
        maps:get(<<"broker_suggested_server_name">>, emqx_mcp_gateway:get_config(), #{
            <<"enable">> => true
        })
    of
        #{<<"enable">> := false} ->
            ok;
        #{<<"enable">> := true, <<"load_file">> := File} when is_binary(File) ->
            load_json_file(File);
        _ ->
            ok
    end.

load_json_file(File) ->
    maybe
        true ?= (core =:= mria_rlog:role()),
        {ok, ServerNamesBin} ?= file:read_file(File),
        JsonL = emqx_mcp_utils:json_decode(ServerNamesBin),
        ok ?= load_from_json(JsonL),
        ?SLOG(info, #{
            msg => "load_server_name_file_succeeded",
            file => File
        })
    else
        false -> ok;
        {error, _} = Error -> Error
    end.

load_from_json(JsonL) when is_list(JsonL) ->
    try
        RulesWithIds = lists:zip(lists:seq(1, length(JsonL)), JsonL),
        ServerNameRecords = [parse_rule(Id, Rule) || {Id, Rule} <- RulesWithIds],
        put_server_name_rules(ServerNameRecords)
    catch
        error:Reason ->
            {error, Reason}
    end.

parse_rule(Id, #{<<"condition">> := SQL, <<"server_name">> := ServerName}) ->
    #{
        id => Id,
        condition => SQL,
        selector => parse_sql(SQL),
        server_name => ServerName,
        server_name_tmpl => bbmustache:parse_binary(ServerName)
    };
parse_rule(_, Rule) ->
    throw(#{reason => invalid_rule_format, rule => Rule}).

parse_sql(SQL) ->
    case emqx_rule_sqlparser:parse(SQL, #{with_from => false}) of
        {ok, Select} ->
            case emqx_rule_sqlparser:select_is_foreach(Select) of
                true ->
                    throw(#{reason => foreach_not_allowed, sql => SQL});
                false ->
                    #{
                        fields => emqx_rule_sqlparser:select_fields(Select),
                        where => emqx_rule_sqlparser:select_where(Select)
                    }
            end;
        {error, Reason} ->
            throw(#{reason => invalid_sql, sql => SQL, details => Reason})
    end.

to_key_map(SelectedData) when is_map(SelectedData) ->
    maps:fold(
        fun(K, V, Acc) ->
            Acc#{ensure_list(K) => V}
        end,
        #{},
        SelectedData
    ).

ensure_list(Key) when is_atom(Key) ->
    atom_to_list(Key);
ensure_list(Key) when is_binary(Key) ->
    binary_to_list(Key);
ensure_list(Key) when is_list(Key) ->
    Key;
ensure_list(Key) ->
    throw(#{reason => invalid_key_type, key => Key}).
