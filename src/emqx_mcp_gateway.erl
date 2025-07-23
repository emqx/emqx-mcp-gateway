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

-module(emqx_mcp_gateway).
-behaviour(gen_server).

%% for #message{} record
-include_lib("emqx_plugin_helper/include/emqx.hrl").
%% for hook priority constants
-include_lib("emqx_plugin_helper/include/emqx_hooks.hrl").
%% for logging
-include_lib("emqx_plugin_helper/include/logger.hrl").
-include("emqx_mcp_gateway.hrl").
-include("emqx_mcp_errors.hrl").

-export([
    enable/0,
    disable/0,
    get_config/0
]).

-export([
    on_config_changed/2,
    on_health_check/1
]).

-export([
    on_client_connected/2,
    on_client_connack/3,
    on_message_publish/1,
    on_session_subscribed/3
]).

-export([
    start_link/0,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(PROP_K_MCP_COMP_TYPE, <<"MCP-COMPONENT-TYPE">>).
-define(PROP_K_MCP_SERVER_NAME, <<"MCP-SERVER-NAME">>).
-define(PROP_K_MCP_SERVER_NAME_FILETERS, <<"MCP-SERVER-NAME-FILTERS">>).

%%==============================================================================
%% APIs
%%==============================================================================
enable() ->
    start_mcp_servers(),
    register_hook(),
    emqx_ctl:register_command(mcp, {emqx_mcp_gateway_cli, cmd}).

disable() ->
    unregister_hook(),
    emqx_ctl:unregister_command(mcp),
    stop_mcp_servers(),
    %% Restart the dispatcher to clean up the state
    emqx_mcp_server_dispatcher:restart().

%%==============================================================================
%% Config update
%%==============================================================================
get_config() ->
    emqx_plugin_helper:get_config(?PLUGIN_NAME_VSN).

on_config_changed(OldConfig, NewConfig) ->
    ok = gen_server:cast(?MODULE, {on_changed, OldConfig, NewConfig}).

on_health_check(_Options) ->
    case whereis(?MODULE) of
        undefined ->
            {error, <<"emqx_mcp_gateway is not running">>};
        _ ->
            ok
    end.

%%==============================================================================
%% gen_server callbacks
%%==============================================================================
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    erlang:process_flag(trap_exit, true),
    ?SLOG(debug, #{msg => "emqx_mcp_gateway_started"}),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({on_changed, _OldConfig, _NewConfig}, State) ->
    stop_mcp_servers(),
    start_mcp_servers(),
    {noreply, State};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Request, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%==============================================================================
%% Hooks
%%==============================================================================
on_client_connected(ClientInfo, ConnInfo) ->
    UserPropsConn = maps:get('User-Property', maps:get(conn_props, ConnInfo, #{}), []),
    ServerId = maps:get(clientid, ClientInfo),
    case proplists:get_value(?PROP_K_MCP_COMP_TYPE, UserPropsConn) of
        <<"mcp-server">> ->
            case get_broker_suggested_server_name(ClientInfo, ConnInfo) of
                {ok, SuggestedName} ->
                    Topic = <<"$mcp-server/presence/", ServerId/binary, "/", SuggestedName/binary>>,
                    erlang:put(mcp_server_presence_topic, Topic),
                    erlang:put(mcp_broker_suggested_server_name, SuggestedName),
                    ok;
                %% no server name configured
                {error, not_found} ->
                    ok
            end;
        <<"mcp-client">> ->
            case get_broker_suggested_server_name_filters(ClientInfo, ConnInfo) of
                {ok, ServerNameFilters} ->
                    erlang:put(mcp_broker_suggested_server_name_filters, ServerNameFilters),
                    ok;
                {error, not_found} ->
                    ok
            end;
        undefined ->
            ok
    end.

on_client_connack(ConnInfo, success, ConnAckProps) ->
    UserPropsConn = maps:get('User-Property', maps:get(conn_props, ConnInfo, #{}), []),
    case proplists:get_value(?PROP_K_MCP_COMP_TYPE, UserPropsConn) of
        <<"mcp-server">> ->
            case erlang:get(mcp_broker_suggested_server_name) of
                undefined ->
                    {ok, ConnAckProps};
                SuggestedName ->
                    {ok, add_broker_suggested_server_name(SuggestedName, ConnAckProps)}
            end;
        <<"mcp-client">> ->
            case erlang:get(mcp_broker_suggested_server_name_filters) of
                undefined ->
                    {ok, ConnAckProps};
                ServerNameFilters ->
                    {ok, add_broker_suggested_server_name_filters(ServerNameFilters, ConnAckProps)}
            end;
        undefined ->
            {ok, ConnAckProps}
    end;
on_client_connack(_ConnInfo, _Rc, ConnAckProps) ->
    {ok, ConnAckProps}.

on_message_publish(#message{topic = <<"$mcp-server/capability", _/binary>>} = Message) ->
    %% ignore capability notifications sent by mcp server
    {ok, Message};
on_message_publish(#message{topic = <<"$mcp-server/presence", _/binary>>} = Message) ->
    case erlang:get(mcp_server_presence_topic) of
        undefined ->
            {ok, Message};
        PresenceTopic ->
            {ok, Message#message{topic = PresenceTopic}}
    end;
on_message_publish(
    #message{
        from = McpClientId,
        topic = <<"$mcp-server/", ServerIdAndName/binary>>,
        headers = Headers,
        payload = RawInitReq
    } = Message
) ->
    {_, ServerName} = split_id_and_server_name(ServerIdAndName),
    case emqx_mcp_message:decode_rpc_msg(RawInitReq) of
        {ok, #{type := json_rpc_request, method := <<"initialize">>, id := Id}} ->
            Credentials = #{username => maps:get(username, Headers, undefined)},
            send_initialize_request(Id, ServerName, McpClientId, Credentials, RawInitReq);
        {ok, #{type := json_rpc_request, method := Method, id := Id}} ->
            ErrMsg = emqx_mcp_message:json_rpc_error(
                Id,
                ?ERR_C_UNEXPECTED_METHOD,
                ?ERR_UNEXPECTED_METHOD,
                #{expected => <<"initialize">>, received => Method}
            ),
            emqx_mcp_message:publish_mcp_server_message(
                ServerName, McpClientId, rpc, #{}, ErrMsg
            );
        {ok, Msg} ->
            ?SLOG(error, #{msg => unsupported_mcp_server_msg, rpc_msg => Msg});
        {error, #{reason := Reason} = Details} ->
            D = maps:remove(reason, Details),
            ErrCode =
                case Reason of
                    ?ERR_INVALID_JSON -> ?ERR_C_INVALID_JSON;
                    ?ERR_MALFORMED_JSON_RPC -> ?ERR_C_MALFORMED_JSON_RPC
                end,
            ErrMsg = emqx_mcp_message:json_rpc_error(0, ErrCode, Reason, D),
            emqx_mcp_message:publish_mcp_server_message(
                ServerName, McpClientId, rpc, #{}, ErrMsg
            )
    end,
    {ok, Message};
on_message_publish(
    #message{
        from = McpClientId,
        topic = <<"$mcp-client/presence/", McpClientId/binary>>,
        payload = PresenceMsg
    } = Message
) ->
    case emqx_mcp_message:decode_rpc_msg(PresenceMsg) of
        {ok, #{method := <<"notifications/disconnected">>}} ->
            ServerNamePids = get_mcp_server_name_pid_mapping(),
            ServerNames = maps:keys(ServerNamePids),
            lists:foreach(
                fun(ServerName) ->
                    _ = maybe_call_mcp_server(ServerName, client_disconnected)
                end,
                ServerNames
            ),
            ok;
        {ok, Msg} ->
            ?SLOG(error, #{msg => unsupported_client_presence_msg, rpc_msg => Msg});
        {error, Reason} ->
            ?SLOG(error, #{msg => decode_rpc_msg_failed, reason => Reason})
    end,
    {ok, Message};
on_message_publish(
    #message{
        from = McpClientId,
        topic = <<"$mcp-client/capability/", McpClientId/binary>>,
        payload = ListChangedNotify
    } = Message
) ->
    ServerNamePids = get_mcp_server_name_pid_mapping(),
    ServerNames = maps:keys(ServerNamePids),
    lists:foreach(
        fun(ServerName) ->
            _ = maybe_call_mcp_server(ServerName, {rpc, ListChangedNotify})
        end,
        ServerNames
    ),
    {ok, Message};
on_message_publish(
    #message{
        from = McpClientId,
        topic = <<"$mcp-rpc/", ClientIdAndServerName/binary>>,
        payload = RpcMsg
    } = Message
) ->
    {_, ServerName} = split_id_and_server_name(ClientIdAndServerName),
    case maybe_call_mcp_server(ServerName, {rpc, RpcMsg}) of
        {error, Reason} ->
            case emqx_mcp_message:decode_rpc_msg(RpcMsg) of
                {ok, #{type := json_rpc_request, id := Id}} ->
                    ErrMsg = error_to_rpc_msg(Id, Reason),
                    emqx_mcp_message:publish_mcp_server_message(
                        ServerName, McpClientId, rpc, #{}, ErrMsg
                    );
                {error, Reason} ->
                    ?SLOG(error, #{msg => decode_rpc_msg_failed, reason => Reason})
            end;
        _ ->
            ok
    end,
    {ok, Message};
on_message_publish(Message) ->
    %% Ignore other messages
    {ok, Message}.

on_session_subscribed(_, <<"$mcp-server/presence/", ServerIdAndName/binary>> = _Topic, _SubOpts) ->
    {_, ServerNameFilter} =
        case string:split(ServerIdAndName, <<"/">>) of
            [Id, ServerName] -> {Id, ServerName};
            [ServerName] -> {undefined, ServerName};
            _ -> throw({error, {invalid_server_name_filter, ServerIdAndName}})
        end,
    foreach_configured_mcp_server(
        fun(_, _Name, #{<<"server_name">> := ServerName} = ServerConf) ->
            case maps:get(<<"enable">>, ServerConf, true) of
                true ->
                    case emqx_topic:match(ServerName, ServerNameFilter) of
                        true ->
                            ServerDesc = maps:get(<<"server_desc">>, ServerConf, <<>>),
                            ServerMeta = server_meta(ServerName),
                            emqx_mcp_message:send_server_online_message(
                                ServerName, ServerDesc, ServerMeta
                            );
                        false ->
                            ok
                    end;
                false ->
                    ok
            end
        end
    ),
    ok;
on_session_subscribed(_, _Topic, _SubOpts) ->
    %% Ignore other topics
    ok.

add_broker_suggested_server_name(SuggestedName, ConnAckProps) ->
    UserPropsConnAck = maps:get('User-Property', ConnAckProps, []),
    UserPropsConnAck1 = [{?PROP_K_MCP_SERVER_NAME, SuggestedName} | UserPropsConnAck],
    ConnAckProps#{'User-Property' => UserPropsConnAck1}.

add_broker_suggested_server_name_filters(ServerNameFilters, ConnAckProps) ->
    ServerNameFilters1 = iolist_to_binary(emqx_mcp_utils:json_encode(ServerNameFilters)),
    UserPropsConnAck = maps:get('User-Property', ConnAckProps, []),
    UserPropsConnAck1 = [{?PROP_K_MCP_SERVER_NAME_FILETERS, ServerNameFilters1} | UserPropsConnAck],
    ConnAckProps#{'User-Property' => UserPropsConnAck1}.

split_id_and_server_name(Str) ->
    %% Split the server ID and name from the topic
    case string:split(Str, <<"/">>) of
        [Id, ServerName] -> {Id, ServerName};
        _ -> throw({error, {invalid_id_and_server_name, Str}})
    end.

get_broker_suggested_server_name(ClientInfo, ConnInfo) ->
    ConnEvent = eventmsg_connected(ClientInfo, ConnInfo),
    emqx_mcp_server_name_manager:match_server_name_rules(ConnEvent).

get_broker_suggested_server_name_filters(ClientInfo, ConnInfo) ->
    ConnEvent = eventmsg_connected(ClientInfo, ConnInfo),
    emqx_mcp_server_name_manager:match_server_name_filter_rules(ConnEvent).

register_hook() ->
    hook('client.connected', {?MODULE, on_client_connected, []}),
    hook('client.connack', {?MODULE, on_client_connack, []}),
    hook('message.publish', {?MODULE, on_message_publish, []}),
    hook('session.subscribed', {?MODULE, on_session_subscribed, []}),
    ok.

unregister_hook() ->
    unhook('client.connected', {?MODULE, on_client_connected}),
    unhook('client.connack', {?MODULE, on_client_connack}),
    unhook('message.publish', {?MODULE, on_message_publish}),
    unhook('session.subscribed', {?MODULE, on_session_subscribed}),
    ok.

hook(HookPoint, MFA) ->
    %% Higher priority than retainer, make it possible to handle mcp service discovery
    %% messages in this module rather than in emqx_retainer.
    Priority = ?HP_RETAINER + 1,
    ok = emqx_hooks:put(HookPoint, MFA, Priority).

unhook(HookPoint, MFA) ->
    ok = emqx_hooks:del(HookPoint, MFA).

%%==============================================================================
%% Internal functions
%%==============================================================================
foreach_configured_mcp_server(Fun) ->
    Config = get_config(),
    lists:foreach(
        fun(T) ->
            case maps:get(T, Config, undefined) of
                undefined ->
                    ok;
                ServerConfs ->
                    maps:foreach(
                        fun(Name, ServerConf) ->
                            Fun(T, Name, ServerConf)
                        end,
                        ServerConfs
                    )
            end
        end,
        [<<"stdio_servers">>, <<"http_servers">>, <<"internal_servers">>]
    ).

start_mcp_servers() ->
    foreach_configured_mcp_server(fun start_mcp_server/3).

start_mcp_server(ServerType, Name, #{<<"server_name">> := ServerName} = ServerConf) ->
    case maps:get(<<"enable">>, ServerConf, true) of
        true ->
            start_mcp_server(ServerType, Name, ServerName, ServerConf);
        false ->
            ok
    end.

start_mcp_server(ServerType, Name, ServerName, ServerConf) ->
    Conf = #{
        name => Name,
        server_name => ServerName,
        server_conf => maps:without([<<"enable">>], ServerConf),
        mod => mcp_server_callback_module(ServerType),
        opts => #{}
    },
    ok = emqx_mcp_server_dispatcher:stop_servers(ServerName),
    ok = emqx_mcp_server_dispatcher:start_listening_servers(Conf).

stop_mcp_servers() ->
    emqx_mcp_server:stop_supervised_all().

mcp_server_callback_module(<<"stdio_servers">>) ->
    emqx_mcp_server_stdio;
mcp_server_callback_module(<<"http_servers">>) ->
    emqx_mcp_server_http;
mcp_server_callback_module(<<"internal_servers">>) ->
    emqx_mcp_server_internal;
mcp_server_callback_module(SType) ->
    throw({error, {invalid_mcp_server_type, SType}}).

server_meta(ServerName) ->
    case emqx_mcp_authorization:get_roles(ServerName) of
        {ok, Roles} ->
            #{
                <<"authorization">> => #{
                    <<"roles">> => Roles
                }
            };
        _ ->
            #{}
    end.

send_initialize_request(Id, ServerName, McpClientId, Credentials, RawInitReq) ->
    case
        emqx_mcp_server_dispatcher:initialize(ServerName, McpClientId, Credentials, Id, RawInitReq)
    of
        {ok, #{raw_response := Resp, server_pid := ServerPid}} ->
            register_mcp_server_pid(ServerName, ServerPid),
            emqx_mcp_message:publish_mcp_server_message(ServerName, McpClientId, rpc, #{}, Resp);
        {json_rpc_error, ErrMsg} ->
            emqx_mcp_message:publish_mcp_server_message(ServerName, McpClientId, rpc, #{}, ErrMsg);
        {error, Reason} ->
            ErrMsg = error_to_rpc_msg(Id, Reason),
            emqx_mcp_message:publish_mcp_server_message(ServerName, McpClientId, rpc, #{}, ErrMsg)
    end.

error_to_rpc_msg(Id, Reason) when is_atom(Reason) ->
    emqx_mcp_message:json_rpc_error(Id, ?ERR_CODE(Reason), Reason, #{});
error_to_rpc_msg(Id, #{reason := Reason} = Details) when is_atom(Reason) ->
    emqx_mcp_message:json_rpc_error(Id, ?ERR_CODE(Reason), Reason, maps:remove(reason, Details)).

register_mcp_server_pid(ServerName, ServerPid) ->
    ServerNamePids = get_mcp_server_name_pid_mapping(),
    erlang:put(mcp_server_pid, ServerNamePids#{ServerName => ServerPid}).

get_mcp_server_pid(ServerName) ->
    ServerNamePids = get_mcp_server_name_pid_mapping(),
    maps:find(ServerName, ServerNamePids).

get_mcp_server_name_pid_mapping() ->
    case erlang:get(mcp_server_pid) of
        undefined -> #{};
        ServerNamePids -> ServerNamePids
    end.

maybe_call_mcp_server(ServerName, Request) ->
    case get_mcp_server_pid(ServerName) of
        {ok, ServerPid} ->
            emqx_mcp_server:safe_call(ServerPid, Request, infinity);
        _ ->
            %% ignore if no server running
            ok
    end.

%% same as emqx_rule_events:eventmsg_connected/2
eventmsg_connected(
    ClientInfo = #{
        clientid := ClientId,
        username := Username,
        is_bridge := IsBridge,
        mountpoint := Mountpoint
    },
    ConnInfo = #{
        peername := PeerName,
        sockname := SockName,
        clean_start := CleanStart,
        proto_name := ProtoName,
        proto_ver := ProtoVer,
        connected_at := ConnectedAt
    }
) ->
    Keepalive = maps:get(keepalive, ConnInfo, 0),
    ConnProps = maps:get(conn_props, ConnInfo, #{}),
    RcvMax = maps:get(receive_maximum, ConnInfo, 0),
    ExpiryInterval = maps:get(expiry_interval, ConnInfo, 0),
    #{
        event => 'client.connected',
        timestamp => erlang:system_time(millisecond),
        node => node(),
        clientid => ClientId,
        username => Username,
        mountpoint => Mountpoint,
        peername => ntoa(PeerName),
        sockname => ntoa(SockName),
        proto_name => ProtoName,
        proto_ver => ProtoVer,
        keepalive => Keepalive,
        clean_start => CleanStart,
        receive_maximum => RcvMax,
        expiry_interval => ExpiryInterval div 1000,
        is_bridge => IsBridge,
        conn_props => emqx_utils_maps:printable_props(ConnProps),
        connected_at => ConnectedAt,
        client_attrs => maps:get(client_attrs, ClientInfo, #{})
    }.

ntoa(undefined) ->
    undefined;
ntoa(IpOrIpPort) ->
    iolist_to_binary(emqx_utils:ntoa(IpOrIpPort)).
