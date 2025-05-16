#!/bin/bash

set -euo pipefail

erl -noshell -eval \
  '{ok, Conf} = file:consult("rebar.config"),
  {erl_opts, ErlOpts} = lists:keyfind(erl_opts, 1, Conf),
  {d, plugin_rel_vsn, Vsn1} = lists:keyfind(plugin_rel_vsn, 2, ErlOpts),
  {relx, RelxConf} = lists:keyfind(relx, 1, Conf),
  {release, {_, Vsn2}, _} = lists:keyfind(release, 1, RelxConf),
  case Vsn1 == Vsn2 of
    true ->
      halt(0);
    false ->
      io:format("version in erl_opts does not match release version, plugin_rel_vsn = ~s, but relx version = ~s\n", [Vsn1, Vsn2]),
      halt(1)
  end'
