-module(server).
-define(PSTAT_INTERVAL, 10000).
-define(DEFAULT_PORT, 8000).

% -export([start/0, pstat/0, pbalance/1, dispatcher/1, psocket/1, pcomando/4, userlist/1, gamelist/1]).
-compile(export_all).

format(String, Data) -> lists:flatten(io_lib:format(String, Data)).

globalize(Ids) -> [format("~s|~s", [Id, node()]) || Id <- Ids].

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
        {put_user, Socket, Username, Caller} ->
            case lists:member(Username, maps:values(Users)) of
                true -> Caller ! username_taken, userlist(Users);
                false -> Caller ! ok, userlist(maps:put(Socket, Username, Users))
            end;
        {remove_user, Socket} -> userlist(maps:remove(Socket, Users))
    end,
    ok.

gamelist(Games, Id) ->
    io:format(">> Games: ~p.~n", [Games]),
    receive
        {create_game, Socket, Caller} ->
            GameId = integer_to_list(Id),
            GameProcessId = spawn(?MODULE, game, [[], [Socket], 1, []]),
            Caller ! {created_game, GameProcessId},
            gamelist(maps:put(GameId, GameProcessId, Games), Id + 1);
        {get_local_games, Caller} ->
            Caller ! globalize(maps:keys(Games)),
            gamelist(Games, Id);
        {accept_game, Socket, GameId, Caller} ->
            case maps:get(GameId, Games, invalid_game_id) of
                invalid_game_id -> Caller ! invalid_game_id;
                GameProcessId ->
                    GameProcessId ! {acc, Socket, self()},
                    receive
                        ok -> Caller ! {ok, GameProcessId};
                        game_full -> Caller ! game_full
                    end
            end,
            gamelist(Games, Id);
        {observe_game, Socket, GameId, Caller} ->
            case maps:get(GameId, Games, invalid_game_id) of
                invalid_game_id -> Caller ! invalid_game_id;
                GameProcessId -> GameProcessId ! {obs, Socket}, Caller ! {ok, GameProcessId}
            end,
            gamelist(Games, Id);
        {player_move, Socket, GameId, Move, Caller} ->
            case maps:get(GameId, Games, invalid_game_id) of
                invalid_game_id -> Caller ! invalid_game_id;
                GameProcessId ->
                    GameProcessId ! {pla, Socket, Move, self()},
                    receive
                        ok -> Caller ! ok;
                        invalid_move -> Caller ! invalid_move
                    end
            end,
            gamelist(Games, Id);
        {leave_obs, Socket, GameId, Caller} ->
            case maps:get(GameId, Games, invalid_game_id) of
                invalid_game_id -> Caller ! invalid_game_id;
                GameProcessId ->
                    GameProcessId ! {lea, Socket, self()},
                    receive
                        ok -> Caller ! {ok, GameProcessId};
                        not_an_observer -> Caller ! not_an_observer % No hace falta, no puede devolver un error
                    end
            end,
            gamelist(Games, Id)
    end,
    ok.

get_games(Node) ->
    {gamelist, Node} ! {get_local_games, self()},
    receive Games -> Games end.

game(Board, Players, Turn, Observers) ->
    receive
        {acc, Player2, Caller} ->
            case Players of
                [Player1] -> Caller ! ok, game(Board, [Player1, Player2], Turn, Observers);
                [_, _] -> Caller ! game_full, game(Board, Players, Turn, Observers)
            end;
        {obs, Observer} -> game(Board, Players, Turn, [Observer | Observers]);
        {pla, _, _, Caller} -> Caller ! ok, game(Board, Players, Turn, Observers);
        {lea, Socket, Caller} -> Caller ! ok, game(Board, Players, Turn, lists:delete(Socket, Observers));
        {unsubscribe_socket_ply, Socket} -> game(Board, lists:delete(Socket, Players), Turn, Observers); % TODO: MEJORAR
        {unsubscribe_socket, Socket} -> game(Board, Players, Turn, lists:delete(Socket, Observers))
    end.

dispatcher(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            io:format(">> Se ha conectado un nuevo cliente ~p~n", [Socket]),
            spawn(?MODULE, psocket, [Socket, []]),
            dispatcher(ListenSocket);
        {error, Reason} ->
            io:format(">> Error: ~p.~n", [Reason])
            % TODO: cerrar el resto de las cosas?
    end,
    ok.

psocket(Socket, GamesActive) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            pbalance ! {get_best_node, self()},
            receive
                {best_node, BestNode} ->
                    io:format(user, ">> Ejecutando pcomando de ~p en ~p.~n", [Socket, BestNode]),
                    spawn(BestNode, ?MODULE, pcomando, [Data, self(), Socket, node()]),
                    receive
                        {con, Username} ->
                            io:format(">> Se ha asociado el nombre ~p a ~p.~n", [Username, Socket]),
                            gen_tcp:send(Socket, "OK"),
                            psocket(Socket, GamesActive);
                        bye ->
                            io:format(">> Se ha desconectado ~p.~n", [Socket]),
                            unsubscribe(Socket, GamesActive),
                            gen_tcp:send(Socket, "OK"),
                            gen_tcp:close(Socket);
                        {lsg, CMDID, Games} ->
                            io:format(">> Enviando lista de juegos a ~p.~n", [Socket]),
                            case Games of
                                [] -> gen_tcp:send(Socket, format("OK ~s", [CMDID]));
                                _ -> gen_tcp:send(Socket, format("OK ~s ~s", [CMDID, string:join(Games, " ")]))
                            end,
                            psocket(Socket, GamesActive);
                        {new, CMDID, GameProcessId} ->
                            io:format(">> Se ha creado un nuevo juego para ~p.~n", [Socket]),
                            gen_tcp:send(Socket, format("OK ~s", [CMDID])),
                            psocket(Socket, [{player, GameProcessId}|GamesActive]);
                        {acc, CMDID, GameId, GameProcessId} ->
                            io:format(">> Se ha aceptado a ~p en el juego ~p.~n", [Socket, GameId]),
                            gen_tcp:send(Socket, format("OK ~s", [CMDID])),
                            psocket(Socket, [{player, GameProcessId}|GamesActive]);
                        {pla, CMDID, GameId, Move} ->
                            io:format(">> ~p realizó el movimiento ~p en el juego ~p.~n", [Socket, Move, GameId]),
                            gen_tcp:send(Socket, format("OK ~s", [CMDID])),
                            psocket(Socket, GamesActive);
                        {obs, CMDID, GameId, GameProcessId} ->
                            io:format(">> ~p está observando el juego ~p.~n", [Socket, GameId]),
                            gen_tcp:send(Socket, format("OK ~s", [CMDID])),
                            psocket(Socket, [{observer, GameProcessId}|GamesActive]);
                        {lea, CMDID, GameId, GameProcessId} ->
                            io:format(">> ~p dejo de observar el juego ~p.~n", [Socket, GameId]),
                            gen_tcp:send(Socket, format("OK ~s", [CMDID])),
                            psocket(Socket, lists:delete(GameProcessId, GamesActive));
                        {error, Reason} ->
                            gen_tcp:send(Socket, format("ERROR ~s", [Reason])),
                            io:format(">> Error: no se pudo procesar el comando.~n"), % TODO: cambiar esto
                            psocket(Socket, GamesActive);
                        _ -> io:format(">> NOT IMPLEMENTED~n"), psocket(Socket, GamesActive)
                    end
            end;
        {error, closed} ->
            io:format(">> Se ha desconectado el cliente ~p.~n", [Socket]),
            unsubscribe(Socket, GamesActive),
            userlist ! {remove_user, Socket};
        {error, Reason} -> io:format(">> Error: ~p.~n", [Reason])
    end,
    ok.

pcomando(Data, PSocketId, Socket, CallerNode) ->
    io:format(user, ">> Ejecutando pcomando de ~p para ~p.~n", [Socket, CallerNode]),
    Lexemes = string:lexemes(string:trim(Data), " "),
    case Lexemes of
        ["CON", Username] ->
            {userlist, CallerNode} ! {put_user, Socket, Username, self()},
            receive
                ok -> PSocketId ! {con, Username};
                username_taken -> PSocketId ! {error, format("~s username_taken", [Username])}
            end;
        ["BYE"] ->
            % TODO: dessubscribir de eventos
            {userlist, CallerNode} ! {remove_user, Socket},
            PSocketId ! bye;
        [CMD, CMDID | Args] ->
            case {CMD, Args} of
                {"LSG", []} ->
                    Games = [get_games(Node) || Node <- [node() | nodes()]],
                    PSocketId ! {lsg, CMDID, lists:concat(Games)};
                {"NEW", []} ->
                    gamelist ! {create_game, Socket, self()},
                    receive
                        {created_game, GameProcessId} -> PSocketId ! {new, CMDID, GameProcessId}
                    end;
                {"ACC", [GameId]} ->
                    case parse_game_id(GameId) of
                        invalid_game_id -> PSocketId ! {error, format("~s invalid_game_id", [CMDID])};
                        {Id, Node} ->
                            {gamelist, Node} ! {accept_game, Socket, Id, self()},
                            receive
                                {ok, GameProcessId} -> PSocketId ! {acc, CMDID, GameId, GameProcessId};
                                game_full -> PSocketId ! {error, format("~s game_full", [CMDID])};
                                invalid_game_id -> PSocketId ! {error, format("~s invalid_game_id", [CMDID])}
                            end
                    end;
                {"PLA", [GameId, Move]} ->
                    case parse_game_id(GameId) of
                        invalid_game_id -> PSocketId ! {error, format("~s invalid_game_id", [CMDID])};
                        {Id, Node} ->
                            {gamelist, Node} ! {player_move, Socket, Id, Move, self()},
                            receive
                                ok -> PSocketId ! {pla, CMDID, GameId, Move};
                                invalid_move -> PSocketId ! {error, format("~s invalid_move", [CMDID])}
                            end
                    end;
                {"OBS", [GameId]} ->
                    case parse_game_id(GameId) of
                        invalid_game_id -> PSocketId ! {error, format("~s invalid_game_id", [CMDID])};
                        {Id, Node} ->
                            {gamelist, Node} ! {observe_game, Socket, Id, self()},
                            receive
                                {ok, GameProcessId} -> PSocketId ! {obs, CMDID, GameId, GameProcessId};
                                invalid_game_id -> PSocketId ! {error, format("~s invalid_game_id", [CMDID])}
                            end
                    end;
                {"LEA", [GameId]} -> 
                    case parse_game_id(GameId) of
                        invalid_game_id -> PSocketId ! {error, format("~s invalid_game_id", [CMDID])};
                        {Id, Node} ->
                            {gamelist, Node} ! {leave_obs, Socket, Id, self()},
                            receive
                                {ok, GameProcessId} -> PSocketId ! {lea, CMDID, GameId, GameProcessId};
                                invalid_game_id -> PSocketId ! {error, format("~s invalid_game_id", [CMDID])}
                            end
                        end;
                _ -> PSocketId ! {error, format("~s invalid_command", [CMDID])}
            end;
        _ -> PSocketId ! {error, "invalid_command"}
    end,
    ok.

unsubscribe(_, []) -> ok;
unsubscribe(Socket, [{player, GameProcessId} | GamesActive]) ->
    GameProcessId ! {unsubscribe_socket_ply, Socket},
    unsubscribe(Socket, GamesActive);
unsubscribe(Socket, [{observer, GameProcessId}|GamesActive]) ->
    GameProcessId ! {unsubscribe_socket_obs, Socket},
    unsubscribe(Socket, GamesActive).
