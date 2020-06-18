-module(test).

-export([client/0, server/0, foo/1]).

client() ->
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, 1234, []),
    gen_tcp:send(Socket, "ping"),
    receive
        {tcp, Socket, Pong} -> io:format("recv: ~p~n", [Pong]);
        {tcp_closed, Reason} -> io:format("error: ~p~n", [Reason]);
    end,
    gen_tcp:close(Socket).

server() ->
    {ok, ListenSocket} = gen_tcp:listen(1234, [{active, false}]),
    {ok, ClientSocket} = gen_tcp:accept(ListenSocket),
    foo(ClientSocket).

foo(ClientSocket) ->
    case gen_tcp:recv(ClientSocket, 0) of
        {ok, Ping} -> io:format("recv: ~p~n", [Ping]),
                      gen_tcp:send(ClientSocket, "pong"),
                      foo(ClientSocket);
        {error, Reason} -> io:format("error: ~p~n", [Reason]), ok
    end.