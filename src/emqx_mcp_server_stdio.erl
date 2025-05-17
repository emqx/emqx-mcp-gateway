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

-module(emqx_mcp_server_stdio).
-include_lib("emqx_plugin_helper/include/logger.hrl").

-behaviour(emqx_mcp_server).

-export([
    connect_server/1,
    unpack/2,
    send_msg/2,
    handle_close/1,
    handle_info/2
]).

-define(LINE_BYTES, 4096).

connect_server(#{<<"command">> := Cmd} = Conf) ->
    Args = maps:get(<<"args">>, Conf, []),
    Env0 = maps:get(<<"env">>, Conf, #{}),
    Env = [{emqx_utils_conv:str(K), emqx_utils_conv:str(V)} || {K, V} <- maps:to_list(Env0)],
    ?SLOG(debug, #{msg => connect_server, cmd => Cmd, args => Args, env => Env}),
    try
        Port = open_port(Cmd, Args, Env),
        {ok, #{port => Port}}
    catch
        error:Reason ->
            {error, Reason}
    end.

unpack({_Port, {data, Data}}, State) ->
    case Data of
        {eol, Data1} ->
            PartialData = maps:get(partial_data, State, <<>>),
            Data2 = <<PartialData/binary, Data1/binary>>,
            {ok, Data2, State#{partial_data => <<>>}};
        {noeol, Data1} ->
            PartialData = maps:get(partial_data, State, <<>>),
            Data2 = <<PartialData/binary, Data1/binary>>,
            {more, State#{partial_data => Data2}};
        _ ->
            {error, {invalid_port_data, Data}}
    end;
unpack({'EXIT', Port, Reason}, #{port := Port}) ->
    {stop, {port_exit, Reason}};
unpack(Data, _State) ->
    {error, {unexpected_stdio_data, Data}}.

send_msg(Msg, #{port := Port} = State) ->
    try
        true = erlang:port_command(Port, [Msg, io_lib:nl()]),
        {ok, State}
    catch
        error:badarg ->
            {error, badarg}
    end.

handle_info({Port, {data, {_, Data}}}, #{port := Port} = State) ->
    ?SLOG(error, #{msg => unexpected_port_data, data => Data}),
    {ok, State};
handle_info({'EXIT', Port, Reason}, #{port := Port}) ->
    {stop, {port_exit, Reason}}.

handle_close(#{port := Port}) ->
    case erlang:port_info(Port) of
        undefined -> ok;
        _ -> erlang:port_close(Port)
    end,
    ok;
handle_close(_) ->
    ok.

open_port(Cmd, Args, Env) ->
    PortSetting = [{args, Args}, {env, Env}, binary, {line, ?LINE_BYTES}, hide, stderr_to_stdout],
    erlang:open_port({spawn_executable, Cmd}, PortSetting).
