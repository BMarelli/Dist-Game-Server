-module(server).
-define(PSTAT_INTERVAL, 10000).
-define(DEFAULT_PORT, 8000).

-compile(export_all).

% TODO: register a subscription service.

format(String, Data) -> lists:flatten(io_lib:format(String, Data)).

globalize(Id) -> format("~s|~s", [Id, node()]).

unsubscribe(_, []) -> ok;
unsubscribe(Username, [Subscription | Subscriptions]) ->
    case parse_game_id(Subscription) of
        invalid_game_id -> unsubscribe(Username, Subscriptions);
        {Id, Node} ->
            {gamelist, Node} ! {leave_game, Username, Id, self()},
            receive _ -> unsubscribe(Username, Subscriptions) end
    end.

get_games(Node) -> {gamelist, Node} ! {get_globalized_games, self()}, receive Games -> Games end.

parse_game_id(GameId) ->
    case string:lexemes(GameId, "|") of
        [Id, Node] ->
            NodeAtom = list_to_atom(Node),
            case lists:member(NodeAtom, [node() | nodes()]) of
                true -> {Id, NodeAtom};
                false -> invalid_game_id
            end;
        _ -> invalid_game_id
    end.

spawn_services(ListenSocket) ->
    {_, Port} = inet:port(ListenSocket),
    io:format(">> Socket creado. Escuchando en puerto ~p.~n", [Port]),
    spawn(?MODULE, dispatcher, [ListenSocket]),
    spawn(?MODULE, pstat, []),
    register(pbalance, spawn(?MODULE, pbalance, [maps:new()])),
    register(userlist, spawn(?MODULE, userlist, [maps:new()])),
    register(gamelist, spawn(?MODULE, gamelist, [maps:new(), 1])),
    ok.

start() ->
    case gen_tcp:listen(?DEFAULT_PORT, [{active, false}]) of
        {ok, Socket} -> spawn_services(Socket);
        {error, Reason} ->
            io:format(">> Error: no se pudo crear el socket en el puerto ~p (~p).~n", [?DEFAULT_PORT, Reason]),
            io:format(">> Reintentando en otro puerto...~n"),
            case gen_tcp:listen(0, [{active, false}]) of
                {ok, Socket} -> spawn_services(Socket);
                {error, Reason2} ->
                    io:format(">> Error: no se pudo crear el socket (~p).~n", [Reason2]),
                    erlang:error(cant_start_server)
            end
    end,
    ok.

load() -> erlang:statistics(run_queue).

pstat() ->
    [{pbalance, Node} ! {update_node_loads, node(), load()} || Node <- [node() | nodes()]],
    timer:sleep(?PSTAT_INTERVAL),
    pstat().

pbalance(NodeLoads) ->
    receive
        {get_best_node, PSocketId} ->
            {BestNode, _} = lists:nth(1, lists:keysort(2, maps:to_list(NodeLoads))),
            PSocketId ! {best_node, BestNode},
            pbalance(NodeLoads);
        {update_node_loads, Node, Load} -> pbalance(maps:put(Node, Load, NodeLoads))
    end,
    ok.

userlist(Users) ->
    io:format(">> Users: ~p.~n", [Users]),
    receive
        {put_user, Username, Socket, Caller} ->
            case lists:member("|", Username) of
                true -> Caller ! invalid_username;
                false ->
                    case lists:member(Username, maps:keys(Users)) of
                        true -> Caller ! username_taken, userlist(Users);
                        false -> Caller ! ok, userlist(maps:put(Username, Socket, Users))
                    end
            end;
        {remove_user, Username} -> userlist(maps:remove(Username, Users))
    end.

gamelist(Games, Id) ->
    io:format(">> Games: ~p.~n", [Games]),
    receive
        {create_game, Username, Caller} ->
            GameId = integer_to_list(Id),
            GameProcessId = spawn(?MODULE, game, [[], [Username], 1, []]),
            Caller ! {ok, globalize(GameId)},
            gamelist(maps:put(GameId, GameProcessId, Games), Id + 1);
        {get_globalized_games, Caller} ->
            Caller ! [globalize(game) || game <- maps:keys(Games)],
            gamelist(Games, Id);
        {accept_game, Username, GameId, Caller} ->
            case maps:get(GameId, Games, invalid_game_id) of
                invalid_game_id -> Caller ! invalid_game_id;
                GameProcessId ->
                    GameProcessId ! {acc, Username, self()},
                    receive
                        ok -> Caller ! ok;
                        game_full -> Caller ! game_full
                    end
            end,
            gamelist(Games, Id);
        {observe_game, Username, GameId, Caller} ->
            case maps:get(GameId, Games, invalid_game_id) of
                invalid_game_id -> Caller ! invalid_game_id;
                GameProcessId -> GameProcessId ! {obs, Username}, Caller ! ok
            end,
            gamelist(Games, Id);
        {player_move, Username, GameId, Move, Caller} ->
            case maps:get(GameId, Games, invalid_game_id) of
                invalid_game_id -> Caller ! invalid_game_id;
                GameProcessId ->
                    GameProcessId ! {pla, Username, Move, self()},
                    receive
                        ok -> Caller ! ok;
                        invalid_move -> Caller ! invalid_move
                    end
            end,
            gamelist(Games, Id);
        {leave_game, Username, GameId, Caller} ->
            case maps:get(GameId, Games, invalid_game_id) of
                invalid_game_id -> Caller ! invalid_game_id;
                GameProcessId -> GameProcessId ! {lea, Username}, Caller ! ok
            end,
            gamelist(Games, Id)
    end,
    ok.

game(Board, Players, Turn, Observers) ->
    receive
        {acc, Player2, Caller} ->
            case Players of
                [Player1] -> Caller ! ok, game(Board, [Player1, Player2], Turn, Observers);
                [_, _] -> Caller ! game_full, game(Board, Players, Turn, Observers)
            end;
        {obs, Observer} -> game(Board, Players, Turn, [Observer | Observers]);
        {pla, _, _, Caller} -> Caller ! ok, game(Board, Players, Turn, Observers); % TODO: fix
        {lea, Username} -> game(Board, lists:delete(Username, Players), Turn, lists:delete(Username, Observers))
    end.

dispatcher(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            io:format(">> Se ha conectado un nuevo cliente ~p~n", [Socket]),
            Pid = spawn(?MODULE, psocket, [Socket]),
            gen_tcp:controlling_process(Socket, Pid),
            dispatcher(ListenSocket);
        {error, Reason} ->
            io:format(">> Error: ~p.~n", [Reason])
            % TODO: cerrar el resto de las cosas?
    end,
    ok.

psocket(Socket) ->
    inet:setopts(Socket, [{active, once}]),
    receive
        {tcp, Socket, Data} ->
            Lexemes = string:lexemes(string:trim(Data), " "),
            case Lexemes of
                ["CON", Username] ->
                    userlist ! {put_user, Username, Socket, self()},
                    receive
                        ok -> gen_tcp:send(Socket, "OK"), psocket(Socket, Username, []);
                        invalid_username -> gen_tcp:send(Socket, "ERROR invalid_username"), psocket(Socket);
                        username_taken -> gen_tcp:send(Socket, "ERROR username_taken"), psocket(Socket)
                    end;
                _ -> gen_tcp:send(Socket, "ERROR not_registered"), psocket(Socket)
            end;
        {tcp_closed, Socket} -> ok
    end.

psocket(Socket, Username, Subscriptions) ->
    inet:setopts(Socket, [{active, once}]),
    receive
        {tcp, Socket, Data} ->
            pbalance ! {get_best_node, self()},
            receive {best_node, BestNode} -> spawn(BestNode, ?MODULE, pcomando, [Data, globalize(Username), self()]) end,
            psocket(Socket, Username, Subscriptions);
        {tcp_closed, Socket} -> userlist ! {remove_user, Username}, unsubscribe(Username, Subscriptions);
        bye -> userlist ! {remove_user, Username}, unsubscribe(Username, Subscriptions), gen_tcp:close(Socket);
        {lsg, CMDID, Games} ->
            case Games of
                [] -> gen_tcp:send(Socket, format("OK ~s", [CMDID]));
                _ -> gen_tcp:send(Socket, format("OK ~s ~s", [CMDID, string:join(Games, " ")]))
            end,
            psocket(Socket, Username, Subscriptions);
        {new, CMDID, GameId} ->
            gen_tcp:send(Socket, format("OK ~s", [CMDID])),
            psocket(Socket, Username, [GameId | Subscriptions]);
        {acc, CMDID, GameId} ->
            gen_tcp:send(Socket, format("OK ~s", [CMDID])),
            psocket(Socket, Username, [GameId | Subscriptions]);
        {pla, CMDID, _, _} -> gen_tcp:send(Socket, format("OK ~s", [CMDID]));
        {obs, CMDID, GameId} ->
            gen_tcp:send(Socket, format("OK ~s", [CMDID])),
            psocket(Socket, Username, [GameId | Subscriptions]);
        {lea, CMDID, GameId} ->
            gen_tcp:send(Socket, format("OK ~s", [CMDID])),
            psocket(Socket, Username, lists:delete(GameId, Subscriptions));
        {error, Args} ->
            gen_tcp:send(Socket, format("ERROR ~s", [string:join(Args, " ")])),
            psocket(Socket, Username, Subscriptions)
    end.

pcomando(Data, Username, Caller) ->
    Lexemes = string:lexemes(string:trim(Data), " "),
    case Lexemes of
        ["CON", _] -> Caller ! {error, "already_registered"};
        ["BYE"] -> Caller ! bye;
        [CMD, CMDID | Args] ->
            case {CMD, Args} of
                {"LSG", []} ->
                    Games = lists:concat([get_games(Node) || Node <- [node() | nodes()]]),
                    Caller ! {lsg, CMDID, Games};
                {"NEW", []} ->
                    gamelist ! {create_game, Username, self()},
                    receive {ok, GameId} -> Caller ! {new, CMDID, GameId} end;
                {"ACC", [GameId]} ->
                    case parse_game_id(GameId) of
                        invalid_game_id -> Caller ! {error, [CMDID, "invalid_game_id"]};
                        {Id, Node} ->
                            {gamelist, Node} ! {accept_game, Username, Id, self()},
                            receive
                                ok -> Caller ! {acc, CMDID, GameId};
                                game_full -> Caller ! {error, [CMDID, "game_full"]};
                                invalid_game_id -> Caller ! {error, [CMDID, "invalid_game_id"]}
                            end
                    end;
                {"PLA", [GameId, Move]} ->
                    case parse_game_id(GameId) of
                        invalid_game_id -> Caller ! {error, [CMDID, "invalid_game_id"]};
                        {Id, Node} ->
                            {gamelist, Node} ! {player_move, Username, Id, Move, self()},
                            receive
                                ok -> Caller ! {pla, CMDID, GameId, Move};
                                game_full -> Caller ! {error, [CMDID, "game_full"]};
                                invalid_game_id -> Caller ! {error, [CMDID, "invalid_game_id"]}
                            end
                    end;
                {"OBS", [GameId]} ->
                    case parse_game_id(GameId) of
                        invalid_game_id -> Caller ! {error, [CMDID, "invalid_game_id"]};
                        {Id, Node} ->
                            {gamelist, Node} ! {observe_game, Username, Id, self()},
                            receive
                                ok -> Caller ! {observe_game, CMDID, GameId};
                                invalid_game_id -> Caller ! {error, [CMDID, "invalid_game_id"]}
                            end
                    end;
                {"LEA", [GameId]} ->
                    case parse_game_id(GameId) of
                        invalid_game_id -> Caller ! {error, [CMDID, "invalid_game_id"]};
                        {Id, Node} ->
                            {gamelist, Node} ! {leave_game, Username, Id, self()},
                            receive
                                ok -> Caller ! {lea, CMDID, GameId};
                                invalid_game_id -> Caller ! {error, [CMDID, "invalid_game_id"]}
                            end
                    end;
                _ -> Caller ! {error, [CMDID, "invalid_command"]}
            end;
        _ -> Caller ! {error, ["invalid_command"]}
    end.
