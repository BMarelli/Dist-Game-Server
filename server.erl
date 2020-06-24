-module(server).
-import(util, [format/2, globalise/1, parse_globalised_id/1]).
-import(tictactoe, [lobby/3]).
-compile(export_all).

-define(PSTAT_INTERVAL, 10000).
-define(DEFAULT_PORT, 8000).

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
            GameProcessId = spawn(tictactoe, lobby, [Username, [], util:globalise(GameId)]),
            Caller ! {ok, util:globalise(GameId)},
            gamelist(maps:put(GameId, GameProcessId, Games), Id + 1);
        {get_globalised_games, Caller} ->
            Caller ! [util:globalise(Game) || Game <- maps:keys(Games)],
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
            receive {best_node, BestNode} -> spawn(BestNode, ?MODULE, pcomando, [Data, util:globalise(Username), self()]) end,
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
                [] -> gen_tcp:send(Socket, util:format("OK ~s", [CMDID]));
                _ -> gen_tcp:send(Socket, util:format("OK ~s ~s", [CMDID, string:join(Games, " ")]))
            end,
            psocket(Socket, Username, Subscriptions);
        {new, CMDID, GameId} ->
            gen_tcp:send(Socket, util:format("OK ~s ~s", [CMDID, GameId])),
            psocket(Socket, Username, [GameId | Subscriptions]);
        {acc, CMDID, GameId} ->
            gen_tcp:send(Socket, util:format("OK ~s", [CMDID])),
            psocket(Socket, Username, [GameId | Subscriptions]);
        {pla, CMDID, _, _} ->
            gen_tcp:send(Socket, util:format("OK ~s", [CMDID])),
            psocket(Socket, Username, Subscriptions);
        {obs, CMDID, GameId} ->
            gen_tcp:send(Socket, util:format("OK ~s", [CMDID])),
            psocket(Socket, Username, [GameId | Subscriptions]);
        {lea, CMDID, GameId} ->
            gen_tcp:send(Socket, util:format("OK ~s", [CMDID])),
            psocket(Socket, Username, lists:delete(GameId, Subscriptions));
        {upd, CMDID, GameId, Update} ->
            gen_tcp:send(Socket, util:format("UPD ~s ~s ~s", [CMDID, GameId, Update])),
            psocket(Socket, Username, Subscriptions);
        {error, Args} ->
            gen_tcp:send(Socket, util:format("ERROR ~s", [string:join(Args, " ")])),
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
                    case util:parse_globalised_id(GameId) of
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
                    case util:parse_globalised_id(GameId) of
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
                    case util:parse_globalised_id(GameId) of
                        invalid_id -> Caller ! {error, [CMDID, "invalid_game_id"]};
                        {Id, Node} ->
                            {gamelist, Node} ! {observe_game, Username, Id, self()},
                            receive
                                ok -> Caller ! {obs, CMDID, GameId};
                                invalid_game_id -> Caller ! {error, [CMDID, "invalid_game_id"]}
                            end
                    end;
                {"LEA", [GameId]} ->
                    case util:parse_globalised_id(GameId) of
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

get_games(Node) ->
    {gamelist, Node} ! {get_globalised_games, self()},
    receive Games -> Games end.

unsubscribe(_, []) -> ok;
unsubscribe(Username, [Subscription | Subscriptions]) ->
    case util:parse_globalised_id(Subscription) of
        invalid_id -> unsubscribe(Username, Subscriptions);
        {Id, Node} ->
            {gamelist, Node} ! {leave_game, Username, Id, self()},
            receive _ -> unsubscribe(Username, Subscriptions) end
    end.
