-module(server).
-export([start/0, spawn_services/1, pstat/0, pbalance/1, dispatcher/1, psocket/2, pcomando/2]).
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
    ok.

pstat() ->
    [{pbalance, Node} ! {update_node_loads, node(), length(erlang:ports())} || Node <- [node() | nodes()]],
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

dispatcher(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            io:format(">> Se ha conectado un nuevo cliente ~p~n", [Socket]),
            spawn(?MODULE, psocket, [Socket, Socket]),
            dispatcher(ListenSocket);
        {error, Reason} ->
            io:format(">> Error: ~p.~n", [Reason])
            % cerrar?
    end,
    ok.

psocket(Socket, Username) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            pbalance ! {find_best_node, self()},
            receive
                BestNode ->
                    spawn(BestNode, ?MODULE, pcomando, [Data, self()]),
                    receive
                        {con, Nombre} -> psocket(Socket, Nombre);
                        ok -> psocket(Socket, Username);
                        error ->
                            io:format(">> Error: no se pudo procesar el comando.~n"),
                            psocket(Socket, Username);
                        _ ->
                            io:format(">> JAJA SALU2. VA AGAIN"),
                            psocket(Socket, Username)
                    end
            end;
        {error, closed} -> io:format(">> Se ha desconectado el cliente ~p.~n", [Username]);
        {error, Reason} -> io:format(">> Error: ~p.~n", [Reason])
    end,
    ok.

pcomando(Data, PSocketId) ->
    Lexemes = string:lexemes(Data, " "),
    case Lexemes of
        ["CON", Nombre] -> PSocketId ! {con, Nombre};
        ["BYE"] -> PSocketId ! bye;
        [CMD, CMDID | Args] ->
            case {CMD, Args} of
                {"LSG", []} -> PSocketId ! {lsg, CMDID, lista_de_juegos};
                {"NEW", []} -> PSocketId ! {new, CMDID};
                {"ACC", [JuegoId]} -> PSocketId ! {acc, CMDID, JuegoId};
                {"PLA", [JuegoId, Jugada]} -> PSocketId ! {pla, CMDID, JuegoId, Jugada};
                {"OBS", [JuegoId]} -> PSocketId ! {obs, CMDID, JuegoId};
                {"LEA", [JuegoId]} -> PSocketId ! {lea, CMDID, JuegoId};
                _ -> PSocketId ! error
            end;
        _ -> PSocketId ! error
    end,
    ok.
