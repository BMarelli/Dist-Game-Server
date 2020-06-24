-module(server).
-define(PSTAT_INTERVAL, 10000).
-define(DEFAULT_PORT, 8000).

-compile(export_all).

% TODO: enforce consistency across send receive pattern

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

% -------------------- SERVICES --------------------

spawn_services(ListenSocket) ->
    {_, Port} = inet:port(ListenSocket),
    io:format(">> Socket creado. Escuchando en puerto ~p.~n", [Port]),
    spawn(?MODULE, dispatcher, [ListenSocket]),
    spawn(?MODULE, pstat, []),
    register(pbalance, spawn(?MODULE, pbalance, [maps:new()])),
    register(userlist, spawn(?MODULE, userlist, [maps:new()])),
    register(gamelist, spawn(?MODULE, gamelist, [maps:new(), 1])),
    ok.

dispatcher(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            io:format(">> Se ha conectado un nuevo cliente ~p~n", [Socket]),
            Pid = spawn(?MODULE, psocket, [Socket]),
            gen_tcp:controlling_process(Socket, Pid),
            dispatcher(ListenSocket);
        {error, Reason} -> io:format(">> Error: ~p.~n", [Reason])
    end.

pstat() ->
    Load = erlang:statistics(run_queue),
    [{pbalance, Node} ! {update_node_loads, node(), Load} || Node <- [node() | nodes()]],
    timer:sleep(?PSTAT_INTERVAL),
    pstat().

pbalance(NodeLoads) ->
    receive
        {get_best_node, PSocketId} ->
            {BestNode, _} = lists:nth(1, lists:keysort(2, maps:to_list(NodeLoads))),
            PSocketId ! {best_node, BestNode},
            pbalance(NodeLoads);
        {update_node_loads, Node, Load} -> pbalance(maps:put(Node, Load, NodeLoads))
    end.

userlist(Users) ->
    io:format("(debug)>> Userlist: ~p~n", [Users]),
    receive
        {put_user, Username, PSocketId} ->
            case lists:member($|, Username) of
                true -> PSocketId ! invalid_username, userlist(Users);
                false ->
                    case lists:member(Username, maps:keys(Users)) of
                        true -> PSocketId ! username_taken, userlist(Users);
                        false -> PSocketId ! ok, userlist(maps:put(Username, PSocketId, Users))
                    end
            end;
        {get_user, Username, Caller} ->
            case maps:get(Username, Users, invalid_username) of
                invalid_username -> Caller ! invalid_username;
                PSocketId -> Caller ! {user, PSocketId}
            end,
            userlist(Users);
        {remove_user, Username} -> userlist(maps:remove(Username, Users))
    end.

gamelist(Games, Id) ->
    io:format("(debug)>> Gamelist: ~p~n", [Games]),
    receive
        {create_game, Username, Caller} ->
            GameId = integer_to_list(Id),
            GameProcessId = spawn(?MODULE, lobby, [Username, [], globalise(GameId)]),
            Caller ! {ok, globalise(GameId)},
            gamelist(maps:put(GameId, GameProcessId, Games), Id + 1);
        {get_globalised_games, Caller} ->
            Caller ! [globalise(Game) || Game <- maps:keys(Games)],
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
                        invalid_move -> Caller ! invalid_move;
                        not_your_turn -> Caller ! not_your_turn;
                        game_not_started -> Caller ! game_not_started;
                        {board, Update} -> Caller ! {board, Update}
                    end
            end,
            gamelist(Games, Id);
        {leave_game, Username, GameId, Caller} ->
            case maps:get(GameId, Games, invalid_game_id) of
                invalid_game_id -> Caller ! invalid_game_id, gamelist(Games, Id);
                GameProcessId -> GameProcessId ! {lea, Username}, Caller ! ok, gamelist(maps:remove(GameId, Games), Id)
            end
    end.

psocket(Socket) ->
    inet:setopts(Socket, [{active, once}]),
    receive
        {tcp, Socket, Data} ->
            io:format("<< ~p: ~s~n", [Socket, string:trim(Data)]),
            Lexemes = string:lexemes(string:trim(Data), " "),
            case Lexemes of
                ["CON", Username] ->
                    userlist ! {put_user, Username, self()},
                    receive
                        ok -> gen_tcp:send(Socket, "OK"), psocket(Socket, Username, []);
                        invalid_username -> gen_tcp:send(Socket, "ERROR invalid_username"), psocket(Socket);
                        username_taken -> gen_tcp:send(Socket, "ERROR username_taken"), psocket(Socket)
                    end;
                _ -> gen_tcp:send(Socket, "ERROR not_registered"), psocket(Socket)
            end;
        {tcp_closed, Socket} ->
            io:format(">> Se ha desconectado el cliente ~p~n", [Socket]),
            ok
    end.
psocket(Socket, Username, Subscriptions) ->
    inet:setopts(Socket, [{active, once}]),
    receive
        {tcp, Socket, Data} ->
            io:format("<< ~p: ~s~n", [Socket, string:trim(Data)]),
            pbalance ! {get_best_node, self()},
            receive {best_node, BestNode} -> spawn(BestNode, ?MODULE, pcomando, [Data, globalise(Username), self()]) end,
            psocket(Socket, Username, Subscriptions);
        {tcp_closed, Socket} ->
            io:format(">> Se ha desconectado el cliente ~s~n", [Username]),
            userlist ! {remove_user, Username},
            unsubscribe(Username, Subscriptions);
        bye ->
            io:format(">> Se ha desconectado el cliente ~s~n", [Username]),
            userlist ! {remove_user, Username},
            unsubscribe(Username, Subscriptions),
            gen_tcp:close(Socket);
        {lsg, CMDID, Games} ->
            case Games of
                [] -> gen_tcp:send(Socket, format("OK ~s", [CMDID]));
                _ -> gen_tcp:send(Socket, format("OK ~s ~s", [CMDID, string:join(Games, " ")]))
            end,
            psocket(Socket, Username, Subscriptions);
        {new, CMDID, GameId} ->
            gen_tcp:send(Socket, format("OK ~s ~s", [CMDID, GameId])),
            psocket(Socket, Username, [GameId | Subscriptions]);
        {acc, CMDID, GameId} ->
            gen_tcp:send(Socket, format("OK ~s", [CMDID])),
            psocket(Socket, Username, [GameId | Subscriptions]);
        {pla, CMDID, _, _} ->
            gen_tcp:send(Socket, format("OK ~s", [CMDID])),
            psocket(Socket, Username, Subscriptions);
        {obs, CMDID, GameId} ->
            gen_tcp:send(Socket, format("OK ~s", [CMDID])),
            psocket(Socket, Username, [GameId | Subscriptions]);
        {lea, CMDID, GameId} ->
            gen_tcp:send(Socket, format("OK ~s", [CMDID])),
            psocket(Socket, Username, lists:delete(GameId, Subscriptions));
        {upd, CMDID, GameId, Update} ->
            gen_tcp:send(Socket, format("UPD ~s ~s ~s", [CMDID, GameId, Update])),
            psocket(Socket, Username, Subscriptions);
        {error, Args} ->
            gen_tcp:send(Socket, format("ERROR ~s", [string:join(Args, " ")])),
            psocket(Socket, Username, Subscriptions)
    end.

pcomando(Data, Username, Caller) ->
    Lexemes = string:lexemes(string:trim(Data), " "),
    case Lexemes of
        ["CON", _] -> Caller ! {error, ["already_registered"]};
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
                    case parse_globalised_id(GameId) of
                        invalid_id -> Caller ! {error, [CMDID, "invalid_game_id"]};
                        {Id, Node} ->
                            {gamelist, Node} ! {accept_game, Username, Id, self()},
                            receive
                                ok -> Caller ! {acc, CMDID, GameId};
                                game_full -> Caller ! {error, [CMDID, "game_full"]};
                                invalid_game_id -> Caller ! {error, [CMDID, "invalid_game_id"]}
                            end
                    end;
                {"PLA", [GameId, Move]} ->
                    case parse_globalised_id(GameId) of
                        invalid_id -> Caller ! {error, [CMDID, "invalid_game_id"]};
                        {Id, Node} ->
                            {gamelist, Node} ! {player_move, Username, Id, Move, self()},
                            receive
                                {board, Update} -> Caller ! {pla, CMDID, board, Update};
                                invalid_move -> Caller ! {error, [CMDID, "invalid_move"]};
                                invalid_game_id -> Caller ! {error, [CMDID, "invalid_game_id"]};
                                not_your_turn -> Caller ! {error, [CMDID, "not_your_turn"]};
                                game_not_started -> Caller ! {error, [CMDID, "game_not_started"]}
                            end
                    end;
                {"OBS", [GameId]} ->
                    case parse_globalised_id(GameId) of
                        invalid_id -> Caller ! {error, [CMDID, "invalid_game_id"]};
                        {Id, Node} ->
                            {gamelist, Node} ! {observe_game, Username, Id, self()},
                            receive
                                ok -> Caller ! {obs, CMDID, GameId};
                                invalid_game_id -> Caller ! {error, [CMDID, "invalid_game_id"]}
                            end
                    end;
                {"LEA", [GameId]} ->
                    case parse_globalised_id(GameId) of
                        invalid_id -> Caller ! {error, [CMDID, "invalid_game_id"]};
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

lobby(Player1, Observers, GameId) ->
    io:format("(debug)>> Game ~s: ~p ++ ~p~n", [GameId, Player1, Observers]),
    receive
        {acc, Player1, Caller} -> Caller ! ok, lobby(Player1, Observers, GameId);
        {acc, Player2, Caller} ->
            Caller ! ok,
            game([0, 0, 0, 0, 0, 0, 0, 0, 0], [Player1, Player2], 1, lists:delete(Player2, Observers), GameId);
        {obs, Player1} -> lobby(Player1, Observers, GameId);
        {obs, Observer} ->
            case lists:member(Observer, Observers) of
                true -> lobby(Player1, Observers, GameId);
                false -> lobby(Player1, [Observer | Observers], GameId)
            end;
        {lea, _} -> ok;
        {pla, _, _, Caller} -> Caller ! game_not_started
    end.

game(Board, Players, Turn, Observers, GameId) ->
    io:format("(debug)>> Game ~s: ~p ++ ~p~n", [GameId, Players, Observers]),
    receive
        {acc, _, Caller} -> Caller ! game_full, game(Board, Players, Turn, Observers, GameId);
        {obs, Observer} ->
            case lists:member(Observer, Observers ++ Players) of
                true -> game(Board, Players, Turn, Observers, GameId);
                false -> game(Board, Players, Turn, [Observer | Observers], GameId)
            end;
        {pla, Player, Move, Caller} ->
             case lists:nth(case Turn of 1 -> 1; -1 -> 2 end, Players) == Player of
                true ->
                    case edit_board(Board, Turn, Move) of
                        invalid_move ->
                            Caller ! invalid_move,
                            game(Board, Players, Turn, Observers, GameId);
                        {game_ended, Winner} ->
                            Caller ! {game_ended, Winner},
                            update_subscribers({game_ended, Winner}, Players -- [Player] ++ Observers, GameId);
                        NewBoard ->
                            Caller ! {board, string:join(NewBoard, ",")},
                            update_subscribers({board, string:join(NewBoard, ",")}, Players -- [Player] ++ Observers, GameId),
                            game(NewBoard, Players, (-1) * Turn, Observers, GameId)
                    end;
                false -> Caller ! not_your_turn
            end;
        {lea, Username} ->
            case lists:member(Username, Players) of
                true -> update_subscribers({game_ended, lists:nth(1, Players -- [Username])}, Players -- [Username] ++ Observers, GameId);
                false -> game(Board, Players, Turn, lists:delete(Username, Observers), GameId)
            end
    end.

edit_board(Board, Turn, MoveStr) ->
    try list_to_integer(MoveStr) of
        Move ->
            case Move < 1 orelse Move > 9 orelse lists:nth(Move, Board) =/= 0 of
            true -> invalid_move;
            false ->
                NewBoard = lists:sublist(Board, Move) ++ [Turn] ++ lists:nthtail(Board, Move + 1),
                case check_winner(Board, Turn) of
                    false -> NewBoard;
                    Winner -> {game_ended, Winner}
                end
            end
    catch _:_ -> invalid_move
    end.

check_winner([A11, A12, A13, A21, A22, A23, A31, A32, A33] = Board, Turn) ->
    M = lists:max([A11+A12+A13, A21+A22+A23, A31+A32+A33, A11+A21+A31, A12+A22+A32, A13+A23+A33, A11+A22+A33, A13+A22+A31]),
    Condition = 3 * Turn,
    case {lists:member(0, Board), M} of
        {_, Condition} -> Turn;
        {false, _} -> "DRAW";
        _ -> false
    end.

% TODO: puede pasar que sea invalido? checkear
update_subscribers(_, [], _) -> ok;
update_subscribers({CMDID, Update}, [Subscriber | Subscribers], GameId) ->
    case parse_globalised_id(Subscriber) of
        {Id, Node} ->
            {userlist, Node} ! {get_user, Id, self()},
            receive
                {user, PSocketId} -> PSocketId ! {upd, CMDID, GameId, Update}
            end,
            update_subscribers({CMDID, Update}, Subscribers, GameId)
    end.

get_games(Node) ->
    {gamelist, Node} ! {get_globalised_games, self()},
    receive Games -> Games end.

format(String, Data) -> lists:flatten(io_lib:format(String, Data)).

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

unsubscribe(_, []) -> ok;
unsubscribe(Username, [Subscription | Subscriptions]) ->
    case parse_globalised_id(Subscription) of
        invalid_id -> unsubscribe(Username, Subscriptions);
        {Id, Node} ->
            {gamelist, Node} ! {leave_game, Username, Id, self()},
            receive _ -> unsubscribe(Username, Subscriptions) end
    end.
