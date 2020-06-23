-module(server).
-define(PSTAT_INTERVAL, 10000).
-define(DEFAULT_PORT, 8000).

-compile(export_all).

% TODO: register a subscription service.

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

unsubscribe(Socket, Subscriptions) -> [subscription ! {lea, Socket} || subscription <- Subscriptions].

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
            case lists:member("#", Username) of
                true -> Caller ! invalid_username;
                false ->
                    case lists:member(Username, maps:values(Users)) of
                        true -> Caller ! username_taken, userlist(Users);
                        false -> Caller ! ok, userlist(maps:put(Socket, Username, Users))
                    end
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
            Caller ! ok,
            gamelist(maps:put(GameId, GameProcessId, Games), Id + 1);
        {get_games, Caller} ->
            Caller ! globalize(maps:keys(Games)),
            gamelist(Games, Id);
        {accept_game, Socket, GameId, Caller} ->
            case maps:get(GameId, Games, invalid_game_id) of
                invalid_game_id -> Caller ! invalid_game_id;
                GameProcessId ->
                    GameProcessId ! {acc, Socket, self()},
                    receive
                        ok -> Caller ! ok;
                        game_full -> Caller ! game_full
                    end
            end,
            gamelist(Games, Id);
        {observe_game, Socket, GameId, Caller} ->
            case maps:get(GameId, Games, invalid_game_id) of
                invalid_game_id -> Caller ! invalid_game_id;
                GameProcessId -> GameProcessId ! {obs, Socket}, Caller ! ok
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
        {leave_game, Socket, GameId, Caller} ->
            case maps:get(GameId, Games, invalid_game_id) of
                invalid_game_id -> Caller ! invalid_game_id;
                GameProcessId -> GameProcessId ! {lea, Socket}
            end,
            gamelist(Games, Id)
    end,
    ok.

get_games(Node) ->
    {gamelist, Node} ! {get_games, self()},
    receive Games -> Games end.

game(Board, Players, Turn, Observers) ->
    receive
        {acc, Player2, Caller} ->
            case Players of
                [Player1] -> Caller ! ok, game(Board, [Player1, Player2], Turn, Observers);
                [_, _] -> Caller ! game_full, game(Board, Players, Turn, Observers)
            end;
        {obs, Observer} -> game(Board, Players, Turn, [Observer | Observers]);
        {pla, _, _, Caller} -> Caller ! ok, game(Board, Players, Turn, Observers); % TODO: fix
        {lea, Socket} -> game(Board, lists:delete(Socket, Players), Turn, lists:delete(Socket, Observers))
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

psocket(Socket) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            pbalance ! {get_best_node, self()},
            receive
                BestNode -> spawn(BestNode, ?MODULE, pcomando, [Data, Socket, node()])
            end,
            psocket(Socket);
        {error, closed} ->
            Subscriptions = [],
            unsubscribe(Socket, Subscriptions),
            userlist ! {remove_user, Socket};
        {error, Reason} -> io:format("WOOOW: not implemented ~s", [Reason])
    end,
    ok.

p_con(Socket, CallerNode, Username) ->
    {userlist, CallerNode} ! {put_user, Socket, Username, self()},
    receive
        ok -> gen_tcp:send(Socket, "OK");
        invalid_username -> gen_tcp:send(Socket, "ERROR invalid_username");
        username_taken -> gen_tcp:send(Socket, "ERROR username_taken")
    end,
    ok.

p_bye(Socket, CallerNode) ->
    {userlist, CallerNode} ! {remove_user, Socket},
    Subscriptions = [],
    unsubscribe(Socket, Subscriptions),
    ok.

p_lsg(Socket, CMDID) ->
    Games = lists:concat([get_games(Node) || Node <- [node() | nodes()]]),
    case Games of
        [] -> gen_tcp:send(Socket, format("OK ~s", [CMDID]));
        _ -> gen_tcp:send(Socket, format("OK ~s ~s", [CMDID, string:join(Games, " ")]))
    end,
    ok.

p_new(Socket, CallerNode, CMDID) ->
    {gamelist, CallerNode} ! {create_game, Socket, self()},
    receive ok -> gen_tcp:send(Socket, format("OK ~s", [CMDID])) end,
    ok.

p_acc(Socket, CMDID, GameId) ->
    case parse_game_id(GameId) of
        invalid_game_id -> gen_tcp:send(Socket, format("ERROR ~s invalid_game_id", [CMDID]));
        {Id, Node} ->
            {gamelist, Node} ! {accept_game, Socket, Id, self()},
            receive
                ok -> gen_tcp:send(Socket, format("OK ~s", [CMDID]));
                game_full -> gen_tcp:send(Socket, format("ERROR ~s game_full", [CMDID]));
                invalid_game_id -> gen_tcp:send(Socket, format("ERROR ~s invalid_game_id", [CMDID]))
            end
    end,
    ok.

p_pla(Socket, CMDID, GameId, Move) ->
    case parse_game_id(GameId) of
        invalid_game_id -> gen_tcp:send(Socket, format("ERROR ~s invalid_game_id", [CMDID]));
        {Id, Node} ->
            {gamelist, Node} ! {player_move, Socket, Id, Move, self()},
            receive
                ok -> gen_tcp:send(Socket, format("OK ~s", [CMDID]));
                invalid_move -> gen_tcp:send(Socket, format("ERROR ~s invalid_move", [CMDID]));
                invalid_game_id -> gen_tcp:send(Socket, format("ERROR ~s invalid_game_id", [CMDID]))
            end
    end,
    ok.

p_obs(Socket, CMDID, GameId) ->
    case parse_game_id(GameId) of
        invalid_game_id -> gen_tcp:send(Socket, format("ERROR ~s invalid_game_id", [CMDID]));
        {Id, Node} ->
            {gamelist, Node} ! {observe_game, Socket, Id, self()},
            receive
                ok -> gen_tcp:send(Socket, format("OK ~s", [CMDID]));
                invalid_game_id -> gen_tcp:send(Socket, format("ERROR ~s invalid_game_id", [CMDID]))
            end
    end,
    ok.

p_lea(Socket, CMDID, GameId) ->
    case parse_game_id(GameId) of
        invalid_game_id -> gen_tcp:send(Socket, format("ERROR ~s invalid_game_id", [CMDID]));
        {Id, Node} ->
            {gamelist, Node} ! {leave_game, Socket, Id, self()},
            receive
                ok -> gen_tcp:send(Socket, format("OK ~s", [CMDID]));
                invalid_game_id -> gen_tcp:send(Socket, format("ERROR ~s invalid_game_id", [CMDID]))
            end
    end,
    ok.

pcomando(Data, Socket, CallerNode) ->
    io:format(user, ">> Ejecutando pcomando de ~p para el nodo ~p.~n", [Socket, CallerNode]),
    Lexemes = string:lexemes(string:trim(Data), " "),
    case Lexemes of
        ["CON", Username] -> p_con(Socket, CallerNode, Username);
        ["BYE"] -> p_bye(Socket, CallerNode);
        [CMD, CMDID | Args] ->
            case {CMD, Args} of
                {"LSG", []} -> p_lsg(Socket, CMDID);
                {"NEW", []} -> p_new(Socket, CallerNode, CMDID);
                {"ACC", [GameId]} -> p_acc(Socket, CMDID, GameId);
                {"PLA", [GameId, Move]} -> p_pla(Socket, CMDID, GameId, Move);
                {"OBS", [GameId]} -> p_obs(Socket, CMDID, GameId);
                {"LEA", [GameId]} -> p_lea(Socket, CMDID, GameId);
                _ -> gen_tcp:send(Socket, format("ERROR ~s invalid_command", [CMDID]))
            end;
        _ -> gen_tcp:send(Socket, "ERROR invalid_command")
    end,
    ok.
