-module(util).

-export([format/2, globalise/1, parse_globalised_id/1]).

globalise(Id) -> format("~s|~s", [Id, node()]).

parse_globalised_id(GlobalId) ->
    case string:lexemes(GlobalId, "|") of
        [Id, Node] ->
            NodeAtom = list_to_atom(Node),
            case lists:member(NodeAtom, [node() | nodes()]) of
                true -> {Id, NodeAtom};
                false -> invalid_id
            end;
        _ -> invalid_id
    end.

format(String, Data) -> lists:flatten(io_lib:format(String, Data)).