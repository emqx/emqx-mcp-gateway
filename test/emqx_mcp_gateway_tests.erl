-module(emqx_mcp_gateway_tests).

-include_lib("eunit/include/eunit.hrl").

check_mcp_pub_acl_test_() ->
    [
        ?_assertEqual(
            deny,
            emqx_mcp_gateway:check_mcp_pub_acl(
                undefined, <<"$mcp-server/capability/s1/sn1">>, <<"s1">>, <<"sn1">>
            )
        ),
        ?_assertEqual(
            allow,
            emqx_mcp_gateway:check_mcp_pub_acl(
                mcp_server, <<"$mcp-server/capability/s1/sn1">>, <<"s1">>, <<"sn1">>
            )
        ),
        ?_assertEqual(
            allow,
            emqx_mcp_gateway:check_mcp_pub_acl(
                mcp_server, <<"$mcp-server/capability/s1/sn1/sn2">>, <<"s1">>, <<"sn1/sn2">>
            )
        ),
        ?_assertEqual(
            deny,
            emqx_mcp_gateway:check_mcp_pub_acl(
                mcp_server, <<"$mcp-server/capability/s1/sn1/sn2/e">>, <<"s1">>, <<"sn1/sn2">>
            )
        ),
        ?_assertEqual(
            allow,
            emqx_mcp_gateway:check_mcp_pub_acl(
                mcp_server, <<"$mcp-server/presence/s1/sn1/sn2">>, <<"s1">>, <<"sn1/sn2">>
            )
        ),
        ?_assertEqual(
            deny,
            emqx_mcp_gateway:check_mcp_pub_acl(
                mcp_server, <<"$mcp-server/presence/s1/sn1/sn2/e">>, <<"s1">>, <<"sn1/sn2">>
            )
        ),
        ?_assertEqual(
            allow,
            emqx_mcp_gateway:check_mcp_pub_acl(
                mcp_server, <<"$mcp-rpc/c1/s1/sn1">>, <<"s1">>, <<"sn1">>
            )
        ),
        ?_assertEqual(
            deny,
            emqx_mcp_gateway:check_mcp_pub_acl(
                mcp_server, <<"$mcp-rpc/c1/s1/sn1/e">>, <<"s1">>, <<"sn1">>
            )
        ),

        ?_assertEqual(
            allow,
            emqx_mcp_gateway:check_mcp_pub_acl(
                mcp_client, <<"$mcp-server/xxx/sn1/sn2">>, <<"xxx">>, [<<"sn1/sn2">>]
            )
        ),
        ?_assertEqual(
            deny,
            emqx_mcp_gateway:check_mcp_pub_acl(
                mcp_client, <<"$mcp-server/xxx/sn1/sn2/sn3">>, <<"xxx">>, [<<"sn1/sn2">>]
            )
        ),
        ?_assertEqual(
            allow,
            emqx_mcp_gateway:check_mcp_pub_acl(
                mcp_client, <<"$mcp-client/presence/xxx">>, <<"xxx">>, [<<"sn1/sn2">>]
            )
        ),
        ?_assertEqual(
            deny,
            emqx_mcp_gateway:check_mcp_pub_acl(
                mcp_client, <<"$mcp-client/presence/xxx">>, <<"c1">>, [<<"sn1/sn2">>]
            )
        ),
        ?_assertEqual(
            allow,
            emqx_mcp_gateway:check_mcp_pub_acl(
                mcp_client, <<"$mcp-rpc/c1/s1/sn1/sn2/sn3/sn4">>, <<"c1">>, [
                    <<"sn1/sn2">>, <<"sn1/sn2/sn3/sn4">>
                ]
            )
        ),
        ?_assertEqual(
            allow,
            emqx_mcp_gateway:check_mcp_pub_acl(
                mcp_client, <<"$mcp-rpc/c1/s1/sn1/sn2/sn3/sn4">>, <<"c1">>, [<<"sn1/#">>]
            )
        ),
        ?_assertEqual(
            allow,
            emqx_mcp_gateway:check_mcp_pub_acl(
                mcp_client, <<"$mcp-rpc/c1/s1/sn1/sn2/sn3/sn4">>, <<"c1">>, [
                    <<"sn1/sn2">>, <<"sn1/sn2/+/sn4">>
                ]
            )
        )
    ].

check_mcp_sub_acl_test_() ->
    [
        ?_assertEqual(
            deny,
            emqx_mcp_gateway:check_mcp_sub_acl(
                undefined, <<"$mcp-server/s1/sn1/sn2">>, <<"s1">>, <<"sn1/sn2">>
            )
        ),
        ?_assertEqual(
            allow,
            emqx_mcp_gateway:check_mcp_sub_acl(
                mcp_server, <<"$mcp-server/s1/sn1/sn2">>, <<"s1">>, <<"sn1/sn2">>
            )
        ),
        ?_assertEqual(
            allow,
            emqx_mcp_gateway:check_mcp_sub_acl(
                mcp_server, <<"$mcp-client/capability/c1">>, <<"s1">>, <<"sn1/sn2">>
            )
        ),
        ?_assertEqual(
            allow,
            emqx_mcp_gateway:check_mcp_sub_acl(
                mcp_server, <<"$mcp-client/presence/c1">>, <<"s1">>, <<"sn1/sn2">>
            )
        ),
        ?_assertEqual(
            allow,
            emqx_mcp_gateway:check_mcp_sub_acl(
                mcp_server, <<"$mcp-rpc/c1/s1/sn1/sn2/sn3/sn4">>, <<"s1">>, <<"sn1/sn2/sn3/sn4">>
            )
        ),
        ?_assertEqual(
            allow,
            emqx_mcp_gateway:check_mcp_sub_acl(
                mcp_client, <<"$mcp-server/capability/s1/sn1/+">>, <<"c1">>, [
                    <<"sn1">>, <<"sn1/+">>
                ]
            )
        ),
        ?_assertEqual(
            allow,
            emqx_mcp_gateway:check_mcp_sub_acl(
                mcp_client, <<"$mcp-server/presence/s1/sn1/+">>, <<"c1">>, [<<"sn1">>, <<"sn1/+">>]
            )
        ),
        ?_assertEqual(
            allow,
            emqx_mcp_gateway:check_mcp_sub_acl(
                mcp_client, <<"$mcp-rpc/c1/s1/sn1/sn2/sn3/sn4">>, <<"c1">>, [
                    <<"sn1">>, <<"sn1/+">>, <<"sn1/#">>
                ]
            )
        ),
        ?_assertEqual(
            deny,
            emqx_mcp_gateway:check_mcp_sub_acl(
                mcp_client, <<"$mcp-rpc/c1/s1/sn1/sn2/sn3/sn4">>, <<"c1">>, [<<"sn1">>, <<"sn1/+">>]
            )
        )
    ].
