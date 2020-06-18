-module(server).
-export([start/0, pstat/0, pbalance/1, dispatcher/1, psocket/1, pcomando/4, userlist/1, gamelist/1]).
-define(PSTAT_INTERVAL, 10000).
-define(DEFAULT_PORT, 8000).

spawn_services(ListenSocket) ->
    {_, Port} = inet:port(ListenSocket),
    io:format(">> Socket creado. Escuchando en puerto ~p.~n", [Port]),
    spawn(?MODULE, dispatcher, [ListenSocket]),
    spawn(?MODULE, pstat, []),
    register(pbalance, spawn(?MODULE, pbalance, [maps:new()])),
    register(userlist, spawn(?MODULE, userlist, [maps:new()])),
    register(gamelist, spawn(?MODULE, gamelist, [maps:new()])),
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

% TODO: cambiar estadistica
load() -> length(erlang:ports()).

pstat() ->
    [{pbalance, Node} ! {update_node_loads, node(), load()} || Node <- [node() | nodes()]],
    timer:sleep(?PSTAT_INTERVAL),
    pstat().

pbalance(NodeLoads) ->
    receive
        {find_best_node, PSocketId} ->
            {BestNode, _} = lists:nth(1, lists:keysort(2, maps:to_list(NodeLoads))),
            PSocketId ! BestNode,
            pbalance(NodeLoads);
        {update_node_loads, Node, Load} -> pbalance(maps:put(Node, Load, NodeLoads))
    end,
    ok.

userlist(Users) ->
    io:format(">> Users: ~p.~n", [Users]),
    receive
        {put_user, Socket, Username, Caller} ->
            case lists:member(Username, maps:values(Users)) of
                true -> Caller ! error, userlist(Users);
                false -> Caller ! ok, userlist(maps:put(Socket, Username, Users))
            end;
        {remove_user, Socket} -> userlist(maps:remove(Socket, Users));
        {get_users, Caller} -> Caller ! Users, userlist(Users)
    end,
    ok.

gamelist(Games) ->
    io:format(">> Games: ~p.~n", [Games]),
    receive
        {add_game, GameId, GameProcessId} -> gamelist(maps:put(GameId, GameProcessId, Games));
        {create_game, _} ->
            GameId = game_id, % TODO: generar bien
            GameProcessId = game_process_id,
            % GameProcessId = spawn(?MODULE, game, [[Player1, null], 1, []]),
            [{gamelist, Node} ! {add_game, GameId, GameProcessId} || Node <- nodes()],
            gamelist(maps:put(GameId, GameProcessId, Games));
        {get_games, Caller} -> Caller ! Games, gamelist(Games)
    end,
    ok.

dispatcher(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            io:format(">> Se ha conectado un nuevo cliente ~p~n", [Socket]),
            spawn(?MODULE, psocket, [Socket]),
            dispatcher(ListenSocket);
        {error, Reason} ->
            io:format(">> Error: ~p.~n", [Reason])
            % cerrar el resto de las cosas?
    end,
    ok.

psocket(Socket) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            pbalance ! {find_best_node, self()},
            receive
                BestNode ->
                    spawn(BestNode, ?MODULE, pcomando, [Data, self(), Socket, node()]),
                    receive
                        {con, _} -> % {con, Username}
                            gen_tcp:send(Socket, "OK"),
                            psocket(Socket);
                        bye ->
                            io:format(">> Se ha desconectado el cliente ~p.~n", [Socket]),
                            gen_tcp:send(Socket, "OK"),
                            gen_tcp:close(Socket);
                        {lsg, CMDID, Games} ->
                            % io:format(">> Enviando lista de juegos a ~p.~n", [Username]),
                            gen_tcp:send(Socket, "OK " ++ CMDID ++ " " ++ string:join(" ", Games)),
                            psocket(Socket);
                        {create_game, CMDID} ->
                            % io:format(">> Creando nuevo juego para ~p.~n", [Username]),
                            gen_tcp:send("OK " ++ CMDID),
                            psocket(Socket);
                        % {acc, CMDID, JuegoId} ->
                        %     io:format(">> TODO"),
                        %     gen_tcp:send("OK " ++ CMDID)
                        %     psocket(Socket, Username);
                        % {pla, CMDID, JuegoId, Jugada} ->
                        %     io:format(">> TODO"),
                        %     gen_tcp:send("OK " ++ CMDID)
                        %     psocket(Socket, Username);
                        % {obs, CMDID, JuegoId} ->
                        %     io:format(">> TODO"),
                        %     gen_tcp:send("OK " ++ CMDID)
                        %     psocket(Socket, Username);
                        % {lea, CMDID, JuegoId} ->
                        %     io:format(">> TODO"),
                        %     gen_tcp:send("OK " ++ CMDID)
                        %     psocket(Socket, Username);
                        {error} ->
                            % abstraer correctamente errores. cada comando erroneo deberia recibir correctamente su mensaje ERROR op1 op2...
                            io:format(">> Error: no se pudo procesar el comando.~n"),
                            psocket(Socket);
                        _ -> io:format(">> NOT IMPLEMENTED~n"), psocket(Socket)
                    end
            end;
        {error, closed} ->
            io:format(">> Se ha desconectado el cliente ~p.~n", [Socket]),
            userlist ! {remove_user, Socket};
        {error, Reason} -> io:format(">> Error: ~p.~n", [Reason])
    end,
    ok.

pcomando(Data, PSocketId, Socket, CallerNode) ->
    % io:format(user, ">> Ejecutando pcomando de ~p para ~p.~n", [ Caller]),
    Lexemes = string:lexemes(Data, " "),
    case Lexemes of
        ["CON", Username] ->
            {userlist, CallerNode} ! {put_user, Socket, Username, self()},
            receive
                ok -> PSocketId ! {con, Username};
                error -> PSocketId ! {error}
            end;
        ["BYE"] ->
            % dessubscribir de eventos
            {userlist, CallerNode} ! {remove_user, Socket},
            PSocketId ! bye;
        [CMD, CMDID | Args] ->
            case {CMD, Args} of
                {"LSG", []} -> gamelist ! {get_games, self()}, receive Games -> PSocketId ! {lsg, CMDID, Games} end;
                {"NEW", []} -> gamelist ! {create_game, Socket}, PSocketId ! {create_game, CMDID};
                {"ACC", [JuegoId]} -> PSocketId ! {acc, CMDID, JuegoId};
                {"PLA", [JuegoId, Jugada]} -> PSocketId ! {pla, CMDID, JuegoId, Jugada};
                {"OBS", [JuegoId]} -> PSocketId ! {obs, CMDID, JuegoId};
                {"LEA", [JuegoId]} -> PSocketId ! {lea, CMDID, JuegoId};
                _ -> PSocketId ! error
            end;
        _ -> PSocketId ! error
    end,
    ok.

% game([Player1, null], Turn, Observers) ->
%     receive
%         {acc, Player2} -> game([Player1, Player2], Turn, Observers)
%     end;
% game([Players], Turn, Observers) -> ok.