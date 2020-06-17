-module(tp).

-export([start/0, pstat/0, pbalance/0, dispatcher/1, psocket/1, pcomando/3]).

start() ->
    spawn(?MODULE, dispatcher, [init]),
    spawn(?MODULE, pstat, []),
    register(pbalance, spawn(?MODULE, pbalance, [])),
    ok.

pstat() ->
    error.

pbalance() ->
    receive
        {Pid, find_node} -> Pid ! ok
    end,
    pbalance().

dispatcher(init) ->
    {ok, ListenSocket} = gen_tcp:listen(8000, [{active, false}]), % habria que procesar el atomo de retorno (handlear si no es ok)
    % Port = inet:port(ListenSocket),
    dispatcher(ListenSocket);
dispatcher(ListenSocket) ->
    {ok, Socket} = gen_tcp:accept(ListenSocket),
    io:format("> Se ha conectado un nuevo cliente ~p~n", [Socket]),
    spawn(?MODULE, psocket, [Socket]),
    dispatcher(ListenSocket).

psocket(Socket) ->
    {ok, CMD} = gen_tcp:recv(Socket, 0),
    pbalance ! {self(), find_node},
    receive
        ok ->
            % spawn(Node, ?MODULE, pcomando, [CMD, Socket, self()]),
            spawn(?MODULE, pcomando, [CMD, Socket, self()]),
            receive
                ok -> psocket(Socket)
            end
    end.

pcomando(CMD, Socket, PSocketId) ->
    io:format("> pcomando recibio ~s~n", [CMD]),
    PSocketId ! ok.