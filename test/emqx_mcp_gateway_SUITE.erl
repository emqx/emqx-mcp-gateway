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

-module(emqx_mcp_gateway_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("emqx_plugin_helper/include/emqx.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("emqx_mcp_gateway/include/emqx_mcp_gateway.hrl").

-define(SERVER_NAME, <<"stdio/demo/calc">>).

all() ->
    [
        F
     || {F, _} <- ?MODULE:module_info(exports),
        is_test_function(F)
    ].

is_test_function(F) ->
    case atom_to_list(F) of
        "t_" ++ _ -> true;
        _ -> false
    end.

%%========================================================================
%% Init
%%========================================================================
init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

%%========================================================================
%% Test cases
%%========================================================================
t_mcp_normal_msg_flow(_) ->
    McpClientId = <<"myclient">>,
    {ok, C} = emqtt:start_link([
        {host, "localhost"},
        {clientid, McpClientId},
        {proto_ver, v5}
    ]),
    {ok, _} = emqtt:connect(C),

    {ok, _, [1]} = emqtt:subscribe(C, <<"$mcp-server/presence/#">>, qos1),
    ct:sleep(100),
    {ServerId, ServerName} =
        receive
            {publish, Msg} ->
                verify_server_presence_payload(maps:get(payload, Msg)),
                <<"$mcp-server/presence/", SidName/binary>> = maps:get(topic, Msg),
                split_id_and_server_name(SidName);
            Msg ->
                ct:fail({got_unexpected_message, Msg})
        after 100 ->
            ct:fail(no_message)
        end,
    ?assertEqual(?SERVER_NAME, ServerName),
    RpcTopic = <<"$mcp-rpc/", McpClientId/binary, "/", ServerName/binary>>,

    %% Subscribe to the RPC topic
    {ok, _, [1]} = emqtt:subscribe(C, #{}, [{RpcTopic, [{qos, qos1}, {nl, true}]}]),
    %% Initialize with the server
    InitRequest = emqx_mcp_message:initialize_request(
        #{
            <<"name">> => <<"testClient">>,
            <<"version">> => <<"1.0.0">>
        },
        #{
            sampling => #{}, roots => #{listChanged => true}
        }
    ),
    InitTopic = <<"$mcp-server/", ServerId/binary, "/", ServerName/binary>>,
    emqtt:publish(C, InitTopic, InitRequest, qos1),
    receive
        {publish, Msg1} ->
            ?assertEqual(RpcTopic, maps:get(topic, Msg1)),
            verify_initialize_response(maps:get(payload, Msg1));
        Msg1 ->
            ct:fail({got_unexpected_message, Msg1})
    after 100 ->
        ct:fail(no_message)
    end,

    %% Send the initialized notification
    InitNotif = emqx_mcp_message:initialized_notification(),
    emqtt:publish(C, RpcTopic, InitNotif, qos1),

    %% List tools
    ListToolsRequest = emqx_mcp_message:json_rpc_request(2, <<"tools/list">>, #{}),
    emqtt:publish(C, RpcTopic, ListToolsRequest, qos1),
    receive
        {publish, Msg2} ->
            ?assertEqual(RpcTopic, maps:get(topic, Msg2)),
            ?assertMatch(
                {ok, #{
                    id := 2,
                    type := json_rpc_response,
                    result := #{
                        <<"tools">> := [
                            #{
                                <<"name">> := <<"add">>,
                                <<"description">> := _,
                                <<"inputSchema">> := #{}
                            }
                        ]
                    }
                }},
                emqx_mcp_message:decode_rpc_msg(maps:get(payload, Msg2))
            );
        Msg2 ->
            ct:fail({got_unexpected_message, Msg2})
    after 100 ->
        ct:fail(no_message)
    end,

    emqtt:disconnect(C).

%%========================================================================
%% Helper functions
%%========================================================================
split_id_and_server_name(Str) ->
    %% Split the server ID and name from the topic
    case string:split(Str, <<"/">>) of
        [Id, ServerName] -> {Id, ServerName};
        _ -> throw({error, {invalid_id_and_server_name, Str}})
    end.

verify_server_presence_payload(Payload) ->
    Msg = emqx_mcp_message:decode_rpc_msg(Payload),
    ?assertMatch(
        {ok, #{type := json_rpc_notification, method := <<"notifications/server/online">>}}, Msg
    ).

verify_initialize_response(Payload) ->
    Msg = emqx_mcp_message:decode_rpc_msg(Payload),
    ?assertMatch(
        {ok, #{
            type := json_rpc_response,
            result := #{
                <<"capabilities">> := #{
                    <<"experimental">> := #{},
                    <<"prompts">> := #{<<"listChanged">> := _},
                    <<"resources">> :=
                        #{
                            <<"listChanged">> := _,
                            <<"subscribe">> := _
                        },
                    <<"tools">> := #{<<"listChanged">> := _}
                },
                <<"protocolVersion">> := <<"2024-11-05">>,
                <<"serverInfo">> := #{
                    <<"name">> := <<"Calculator">>,
                    <<"version">> := _
                }
            }
        }},
        Msg
    ).
