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
    start_link/0,
    create_tables/0
]).

-export([
    add_rbac_permission/4,
    get_rbac_permission/3,
    delete_rbac_permission/1,
    delete_rbac_permission/3,
    add_raw_rbac_permissions/3,
    parse_rbac_permission/1
]).

-export([
    match_server_name_rules/1,
    add_server_name_rule/1,
    get_server_name_rules/0,
    put_server_name_rules/1,
    delete_server_name_rule/1
]).

-export([
    match_server_name_filter_rules/1,
    add_server_name_filter_rules/1,
    get_server_name_filter_rules/0,
    put_server_name_filter_rules/1,
    delete_server_name_filter_rule/1
]).

-export([
    match_mcp_client_rbac_rules/1,
    add_mcp_client_rbac_rule/1,
    get_mcp_client_rbac_rules/0,
    put_mcp_client_rbac_rules/1,
    delete_mcp_client_rbac_rule/1
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
-define(TAB_RBAC_PERM, mcp_rbac_permission).
-define(TAB_SERVER_NAME, {?MODULE, mcp_server_name}).
-define(TAB_SERVER_NAME_FILTER, {?MODULE, mcp_server_name_filter}).
-define(TAB_MCP_CLIENT_RBAC, {?MODULE, mcp_client_rbac}).

-type rbac_permission() :: #{
    allowed_methods := [binary()] | all,
    allowed_tools := [binary()] | all,
    allowed_resources := [binary()] | all
}.

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

-type mcp_server_name_filter_rule() :: #{
    id := integer(),
    condition := binary(),
    selector := sql_selector(),
    server_name_filters := [binary()],
    server_name_filters_tmpl := [binary()]
}.

-type mcp_client_rbac_rule() :: #{
    id := integer(),
    condition := binary(),
    selector := sql_selector(),
    rbac := [
        #{
            server_name := binary(),
            server_name_tmpl := binary(),
            role_name := binary()
        }
    ]
}.

-type mcp_client_rbac_info() :: #{
    server_name := binary(),
    role_name := binary()
}.

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

create_tables() ->
    case ets:info(?TAB_RBAC_PERM) of
        undefined -> ets:new(?TAB_RBAC_PERM, [named_table, public, set]);
        _ -> ok
    end.

%%--------------------------------------------------------------------
%% RBAC Permissions
%%--------------------------------------------------------------------
-spec add_rbac_permission(binary(), binary(), binary(), rbac_permission()) -> ok.
add_rbac_permission(ServerId, ServerName, RoleName, Perm) ->
    gen_server:call(?SERVER, {add_rbac_permission, self(), ServerId, ServerName, RoleName, Perm}).

get_rbac_permission(ServerId, ServerName, RoleName) ->
    case ets:lookup(?TAB_RBAC_PERM, {ServerId, ServerName, RoleName}) of
        [] -> {error, not_found};
        [{_, Perm, _}] -> {ok, Perm}
    end.

delete_rbac_permission(ServerId) ->
    %% Delete all permissions for the given ServerId
    ets:match_delete(?TAB_RBAC_PERM, {{ServerId, '_', '_'}, '_'}),
    ok.

delete_rbac_permission(ServerId, ServerName, RoleName) ->
    ets:delete(?TAB_RBAC_PERM, {ServerId, ServerName, RoleName}),
    ok.

-spec add_raw_rbac_permissions(binary(), binary(), [map()]) -> ok.
add_raw_rbac_permissions(ServerId, ServerName, RbacPerms) ->
    lists:foreach(fun(#{<<"name">> := RoleName} = RbacPerm) ->
            Perm = parse_rbac_permission(RbacPerm),
            add_rbac_permission(ServerId, ServerName, RoleName, Perm)
        end, RbacPerms).

-spec parse_rbac_permission(map()) -> rbac_permission().
parse_rbac_permission(#{
    <<"allowed_methods">> := AllowedMethods,
    <<"allowed_tools">> := AllowedTools,
    <<"allowed_resources">> := AllowedResources
}) ->
    #{
        allowed_methods => parse_perm(AllowedMethods),
        allowed_tools => parse_perm(AllowedTools),
        allowed_resources => parse_perm(AllowedResources)
    }.

parse_perm(Perm) when is_list(Perm) ->
    Perm;
parse_perm(<<"all">>) ->
    all.

%%--------------------------------------------------------------------
%% Server Name Rules
%%--------------------------------------------------------------------
-spec match_server_name_rules(map()) -> {ok, binary()} | {error, term()}.
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

-spec put_server_name_rules([mcp_server_name_rule()]) -> ok.
put_server_name_rules(Rules) ->
    persistent_term:put(?TAB_SERVER_NAME, Rules).

delete_server_name_rule(Id) ->
    Rules = get_server_name_rules(),
    persistent_term:put(?TAB_SERVER_NAME, [R || #{id := Id0} = R <- Rules, Id0 =/= Id]).

%%--------------------------------------------------------------------
%% Server Name Filter Rules
%%--------------------------------------------------------------------
-spec match_server_name_filter_rules(map()) -> {ok, [binary()]} | {error, term()}.
match_server_name_filter_rules(ConnEvent) ->
    case get_server_name_filter_rules() of
        [] ->
            {error, not_found};
        ServerNameFilterRules ->
            match_server_name_filter_rules(ServerNameFilterRules, ConnEvent)
    end.

get_server_name_filter_rules() ->
    persistent_term:get(?TAB_SERVER_NAME_FILTER, []).

-spec put_server_name_filter_rules([mcp_server_name_filter_rule()]) -> ok.
put_server_name_filter_rules(Rules) ->
    persistent_term:put(?TAB_SERVER_NAME_FILTER, Rules).

delete_server_name_filter_rule(Id) ->
    Rules = get_server_name_filter_rules(),
    persistent_term:put(?TAB_SERVER_NAME_FILTER, [R || #{id := Id0} = R <- Rules, Id0 =/= Id]).

-spec add_server_name_filter_rules(mcp_server_name_filter_rule()) -> ok.
add_server_name_filter_rules(Rule) ->
    put_server_name_filter_rules([Rule | get_server_name_filter_rules()]).

%%--------------------------------------------------------------------
%% MCP client RBAC
%%--------------------------------------------------------------------
-spec match_mcp_client_rbac_rules(map()) -> {ok, [mcp_client_rbac_info()]} | {error, term()}.
match_mcp_client_rbac_rules(ConnEvent) ->
    case get_mcp_client_rbac_rules() of
        [] -> {error, not_found};
        ClientRbacRules -> match_mcp_client_rbac_rules(ClientRbacRules, ConnEvent)
    end.

get_mcp_client_rbac_rules() ->
    persistent_term:get(?TAB_MCP_CLIENT_RBAC, []).

-spec put_mcp_client_rbac_rules([mcp_client_rbac_rule()]) -> ok.
put_mcp_client_rbac_rules(Rules) ->
    persistent_term:put(?TAB_MCP_CLIENT_RBAC, Rules).

delete_mcp_client_rbac_rule(Id) ->
    Rules = get_mcp_client_rbac_rules(),
    persistent_term:put(?TAB_MCP_CLIENT_RBAC, [R || #{id := Id0} = R <- Rules, Id0 =/= Id]).

-spec add_mcp_client_rbac_rule(mcp_client_rbac_rule()) -> ok.
add_mcp_client_rbac_rule(Rule) ->
    put_mcp_client_rbac_rules([Rule | get_mcp_client_rbac_rules()]).

%%--------------------------------------------------------------------
%% Gen Server Callbacks
%%--------------------------------------------------------------------
init([]) ->
    {ok, #{mcp_servers => #{}}, {continue, init_tasks}}.

handle_continue(init_tasks, State) ->
    maybe
        ok ?= load_server_names(),
        ok ?= load_server_name_filters(),
        ok ?= load_mcp_client_rbac(),
        ?SLOG(info, #{msg => load_server_names_succeeded})
    else
        {error, Reason} ->
            ?SLOG(error, #{msg => load_server_name_files_failed, reason => Reason})
    end,
    {noreply, monitor_mc_servers(State)}.

monitor_mc_servers(#{mcp_servers := Servers} = State) ->
    NewServers = ets:foldl(
        fun({{ServerId, _, _}, _, Pid}, ServersAcc) ->
            erlang:monitor(process, Pid),
            ServersAcc#{Pid => ServerId}
        end,
        Servers,
        ?TAB_RBAC_PERM
    ),
    State#{mcp_servers => NewServers}.

handle_call({add_rbac_permission, Pid, ServerId, ServerName, RoleName, Perm}, _From, #{mcp_servers := Servers} = State) ->
    erlang:monitor(process, Pid),
    ets:insert(?TAB_RBAC_PERM, {{ServerId, ServerName, RoleName}, Perm, Pid}),
    {reply, ok, State#{mcp_servers => Servers#{Pid => ServerId}}};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, #{mcp_servers := Servers} = State) ->
    %% Clean up the monitor for the process
    case maps:find(Pid, Servers) of
        {ok, {ServerId, _}} ->
            delete_rbac_permission(ServerId);
        error ->
            ok
    end,
    {noreply, State};
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
            load_json_file(File, fun parse_server_name_rule/2, fun put_server_name_rules/1);
        _ ->
            ok
    end.

load_server_name_filters() ->
    case
        maps:get(<<"broker_suggested_server_name_filters">>, emqx_mcp_gateway:get_config(), #{
            <<"enable">> => true
        })
    of
        #{<<"enable">> := false} ->
            ok;
        #{<<"enable">> := true, <<"load_file">> := File} when is_binary(File) ->
            load_json_file(
                File, fun parse_server_name_filter_rule/2, fun put_server_name_filter_rules/1
            );
        _ ->
            ok
    end.

load_mcp_client_rbac() ->
    case
        maps:get(<<"mcp_client_rbac">>, emqx_mcp_gateway:get_config(), #{
            <<"enable">> => true
        })
    of
        #{<<"enable">> := false} ->
            ok;
        #{<<"enable">> := true, <<"load_file">> := File} when is_binary(File) ->
            load_json_file(File, fun parse_mcp_client_rbac_rule/2, fun put_mcp_client_rbac_rules/1);
        _ ->
            ok
    end.

load_json_file(File, ParseFun, StoreFun) ->
    maybe
        true ?= (core =:= mria_rlog:role()),
        {ok, ServerNamesBin} ?= file:read_file(File),
        JsonL = emqx_mcp_utils:json_decode(ServerNamesBin),
        ok ?= load_from_json(JsonL, ParseFun, StoreFun),
        ?SLOG(info, #{
            msg => "load_server_name_file_succeeded",
            file => File
        })
    else
        false -> ok;
        {error, _} = Error -> Error
    end.

load_from_json(JsonL, ParseFun, StoreFun) when is_list(JsonL) ->
    try
        RulesWithIds = lists:zip(lists:seq(1, length(JsonL)), JsonL),
        ServerNameRecords = [ParseFun(Id, Rule) || {Id, Rule} <- RulesWithIds],
        StoreFun(ServerNameRecords)
    catch
        error:Reason ->
            {error, Reason}
    end.

-spec parse_server_name_rule(integer(), map()) -> mcp_server_name_rule().
parse_server_name_rule(Id, #{<<"condition">> := SQL, <<"server_name">> := ServerName}) ->
    #{
        id => Id,
        condition => SQL,
        selector => parse_sql(SQL),
        server_name => ServerName,
        server_name_tmpl => bbmustache:parse_binary(ServerName)
    };
parse_server_name_rule(_, Rule) ->
    throw(#{reason => invalid_rule_format, rule => Rule}).

-spec parse_server_name_filter_rule(integer(), map()) -> mcp_server_name_filter_rule().
parse_server_name_filter_rule(Id, #{
    <<"condition">> := SQL, <<"server_name_filters">> := ServerNameFilters
}) ->
    %% assert that ServerNameFilters is an array
    true = is_list(ServerNameFilters),
    #{
        id => Id,
        condition => SQL,
        selector => parse_sql(SQL),
        server_name_filters => ServerNameFilters,
        server_name_filters_tmpl => [bbmustache:parse_binary(F) || F <- ServerNameFilters]
    };
parse_server_name_filter_rule(_, Rule) ->
    throw(#{reason => invalid_rule_format, rule => Rule}).

-spec parse_mcp_client_rbac_rule(integer(), map()) -> mcp_client_rbac_rule().
parse_mcp_client_rbac_rule(Id, #{<<"condition">> := SQL, <<"rbac">> := Rbac}) ->
    %% assert that 'rbac' is an array
    true = is_list(Rbac),
    #{
        id => Id,
        condition => SQL,
        selector => parse_sql(SQL),
        rbac => [
            #{
                server_name => ServerName,
                server_name_tmpl => bbmustache:parse_binary(ServerName),
                role_name => RoleName
            }
         || #{<<"server_name">> := ServerName, <<"role_name">> := RoleName} <- Rbac
        ]
    };
parse_mcp_client_rbac_rule(_, Rule) ->
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

match_server_name_rules(Rules, ConnEvent) ->
    RenderFun = fun(Rule, SelectedData) ->
        Tmpl = maps:get(server_name_tmpl, Rule),
        bbmustache:compile(Tmpl, SelectedData)
    end,
    match_server_name_rules(Rules, ConnEvent, RenderFun).

match_server_name_filter_rules(Rules, ConnEvent) ->
    RenderFun = fun(Rule, SelectedData) ->
        [
            bbmustache:compile(Tmpl, SelectedData)
         || Tmpl <- maps:get(server_name_filters_tmpl, Rule)
        ]
    end,
    match_server_name_rules(Rules, ConnEvent, RenderFun).

match_mcp_client_rbac_rules(Rules, ConnEvent) ->
    RenderFun = fun(Rule, SelectedData) ->
        Rbac = maps:get(rbac, Rule),
        [
            #{server_name => bbmustache:compile(Tmpl, SelectedData), role_name => Role}
         || #{server_name_tmpl := Tmpl, role_name := Role} <- Rbac
        ]
    end,
    match_server_name_rules(Rules, ConnEvent, RenderFun).

match_server_name_rules([], _ConnEvent, _) ->
    {error, not_found};
match_server_name_rules([Rule | Rest], ConnEvent, TmpKey) ->
    case do_match_server_name_rule(Rule, ConnEvent, TmpKey) of
        {ok, ServerName} ->
            {ok, ServerName};
        {error, _} ->
            match_server_name_rules(Rest, ConnEvent, TmpKey)
    end.

do_match_server_name_rule(#{id := Id, selector := Selector} = Rule, ConnEvent, RenderFun) ->
    Fields = maps:get(fields, Selector),
    Where = maps:get(where, Selector, []),
    try emqx_rule_runtime:evaluate_select(Fields, ConnEvent, Where) of
        {ok, SelectedData} ->
            Rendered = RenderFun(Rule, to_key_map(SelectedData)),
            {ok, Rendered};
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
