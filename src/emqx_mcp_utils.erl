-module(emqx_mcp_utils).

-export([
    json_encode/1,
    json_decode/1
]).

json_encode(Data) ->
    json:encode(Data).

json_decode(Data) ->
    json:decode(Data).
