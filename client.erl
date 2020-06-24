-module(client).
-export([start/1, receiver/1]).

format(String, Data) -> lists:flatten(io_lib:format(String, Data)).

help() ->
    io:format("[LSG] Listar los juegos disponibles~n"),
    io:format("[NEW] Crear un nuevo juego~n"),
    io:format("[ACC GameId] Aceptar un juego disponible~n"),
    io:format("[PLA GameId Move] Realizar una jugada en un juego en el que participes~n"),
    io:format("[PLA GameId quit] Abandonar un juego en el que participes~n"),
    io:format("[OBS GameId] Observar un juego~n"),
    io:format("[LEA GameId] Dejar de observar un juego~n"),
    io:format("[BYE] Terminar la conexión, abandonando todos los juegos en los que participes~n").

prettify(V) -> case V of "0" -> " "; "1" -> "O"; "-1" -> "X" end.

show_board(Board) ->
    [A11, A12, A13, A21, A22, A23, A31, A32, A33] = [prettify(V) || V <- string:lexemes(Board, ",")],
    io:format(" ~s | ~s | ~s~n", [A11, A12, A13]),
    io:format("-----------~n"),
    io:format(" ~s | ~s | ~s~n", [A21, A22, A23]),
    io:format("-----------~n"),
    io:format(" ~s | ~s | ~s~n", [A31, A32, A33]).

start(Port) ->
    case gen_tcp:connect({127,0,0,1}, Port, [{active, false}]) of
        {ok, Socket} ->
            io:format("Conectado al servidor en 127.0.0.1:~p~n", [Port]),
            register(Socket);
        {error, _} ->
            io:format("No se pudo conectar al servidor en 127.0.0.1:~p~n", [Port])
    end.

register(Socket) ->
    Username = string:trim(io:get_line(">> Ingrese un nombre de usuario: ")),
    gen_tcp:send(Socket, format("CON ~s", [Username])),
    case gen_tcp:recv(Socket, 0) of
        {ok, "OK"} ->
            io:format("Para ver la lista de comandos disponibles, ingrese HELP~n"),
            try
                spawn_link(?MODULE, receiver, [Socket]),
                sender(Socket, Username, 1)
            catch _:_ -> ok
            end;
        {ok, "ERROR" ++ Reason} ->
            io:format("ERROR: ~s~n", [Reason]),
            register(Socket);
        {error, _} ->
            io:format("Se ha perdido la conexión con el servidor~n")
    end.

sender(Socket, Username, CMDID) ->
    CMDString = string:trim(io:get_line(">> ")),
    Lexemes = string:lexemes(CMDString, " "),
    case Lexemes of
        [] -> sender(Socket, Username, CMDID);
        ["HELP"] -> help(), sender(Socket, Username, CMDID);
        ["BYE"] -> gen_tcp:send(Socket, CMDString);
        [CMD | []] ->
            gen_tcp:send(Socket, format("~s ~s", [CMD, integer_to_list(CMDID)])),
            sender(Socket, Username, CMDID + 1);
        [CMD | Args] ->
            gen_tcp:send(Socket, format("~s ~s ~s", [CMD, integer_to_list(CMDID), string:join(Args, " ")])),
            sender(Socket, Username, CMDID + 1)
    end.

receiver(Socket) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            Lexemes = string:lexemes(Data, " "),
            case Lexemes of
                ["UPD", CMDID, GameId, "board", Board] ->
                    gen_tcp:send(Socket, format("OK ~s", [CMDID])),
                    io:format("Actualización sobre el juego ~s:~n", [GameId]),
                    show_board(Board);
                ["UPD", CMDID, GameId, "game_ended", Winner] ->
                    gen_tcp:send(Socket, format("OK ~s", [CMDID])),
                    io:format("Actualización sobre el juego ~s:~n", [GameId]),
                    io:format("Juego terminado. Ganador: ~s~n", [Winner]);
                ["OK", _, GameId, "board", Board] ->
                    io:format("Actualización sobre el juego ~s:~n", [GameId]),
                    show_board(Board);
                ["OK", _, GameId, "game_ended", Winner] ->
                    io:format("Actualización sobre el juego ~s:~n", [GameId]),
                    io:format("Juego terminado. Ganador: ~s~n", [Winner]);
                _ -> io:format("~s~n", [Data])
            end,
            receiver(Socket);
        {error, _} ->
            io:format("Se ha perdido la conexión con el servidor~n"),
            exit(lost_connection)
    end.
