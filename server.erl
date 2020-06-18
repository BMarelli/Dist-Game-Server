-module(server).
-export([start/0, pstat/0, pbalance/1, dispatcher/1, psocket/1, pcomando/3]).
-define(PSTAT_INTERVAL, 10000).
-define(DEFAULT_PORT, 8000)

start() ->
    case gen_tcp:listen(?DEFAULT_PORT, [{active, false}]) of
        {ok, Socket} -> ListenSocket = Socket;
        {error, Reason} ->
            io:format(">> Error: no se pudo crear el socket en el puerto ~p (~p).~n", [?DEFAULT_PORT, Reason]),
            io:format(">> Reintentando en otro puerto..."),
            case gen_tcp:listen(0, [{active, false}]) of
                {ok, Socket} -> ListenSocket = Socket;
                {error, Reason2} ->
                    io:format(">> Error: no se pudo crear el socket (~p).~n", [Reason2]),
                    erlang:error(cant_start_server)
            end
    end
    io:format(">> Socket creado. Escuchando en puerto ~p.~n", [inet:port(ListenSocket)]),
    spawn(?MODULE, dispatcher, [ListenSocket]),
    spawn(?MODULE, fun() -> apply_interval(?PSTAT_INTERVAL, ?MODULE, pstat, []), []),
    register(pbalance, spawn(?MODULE, pbalance, [maps:new()])),
    ok.

pstat() -> [{pbalance, Node} ! {update_node_loads, node(), length(erlang:ports())} || Node <- [node() | nodes()]],

pbalance(NodeLoads) ->
    receive
        {find_best_node, PSocketId} ->
            {BestNode, _} = lists:nth(1, lists:keysort(2, maps:to_list(NodeLoads))),
            PSocketId ! BestNode,
            pbalance(NodeLoads);
        {update_node_loads, Node, Load} -> pbalance(maps:put(Node, Load, NodeLoads))
    end.

dispatcher(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            io:format(">> Se ha conectado un nuevo cliente ~p~n", [Socket]),
            spawn(?MODULE, psocket, [Socket]),
            dispatcher(ListenSocket);
        {error, Reason} ->
            io:format(">> Error: ~p.~n", [Reason])
            % cerrar?
    end.

psocket(Socket) ->
    {ok, CMD} = gen_tcp:recv(Socket, 0),
    pbalance ! {find_best_node, self()},
    receive
        BestNode ->
            spawn(BestNode, ?MODULE, pcomando, [CMD, Socket, self()]),
            receive
                ok -> psocket(Socket)
            end
    end.

pcomando(CMD, Socket, PSocketId) ->
    io:format(">> pcomando recibio ~s~n", [CMD]),
    gen_tcp:send(Socket, "pong"),
    PSocketId ! ok.
