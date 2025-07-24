-module(emqx_mcp_utils).

-export([
    json_encode/1,
    json_decode/1,
    can_topic_match_oneof/2
]).

json_encode(Data) ->
    json:encode(Data).

json_decode(Data) ->
    json:decode(Data).

can_topic_match_oneof(Topic, [Fltr | Filters]) ->
    match(Topic, Fltr) orelse can_topic_match_oneof(Topic, Filters);
can_topic_match_oneof(_, []) ->
    false.

match(Name, Name) ->
    true;
match(Name, Filter) when is_binary(Name), is_binary(Filter) ->
    match_words(words(Name), words(Filter));
match(Name, Filter) when is_binary(Name) ->
    match_words(words(Name), Filter);
match(Name, Filter) when is_binary(Filter) ->
    match_words(Name, words(Filter));
match(Name, Filter) ->
    match_words(Name, Filter).

match_words(Name, Filter) ->
    match_tokens(Name, Filter).

match_tokens([], []) ->
    true;
match_tokens([H | T1], [H | T2]) ->
    match_tokens(T1, T2);
match_tokens([_H | T1], ['+' | T2]) ->
    match_tokens(T1, T2);
match_tokens([<<>> | T1], ['' | T2]) ->
    match_tokens(T1, T2);
match_tokens(_, ['#']) ->
    true;
match_tokens(_, _) ->
    false.

words(Topic) when is_binary(Topic) ->
    [word(W) || W <- tokens(Topic)].

word(<<>>) -> '';
word(<<"+">>) -> '+';
word(<<"#">>) -> '#';
word(Bin) -> Bin.

tokens(Topic) ->
    binary:split(Topic, <<"/">>, [global]).
