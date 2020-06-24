-module(client).
-compile(export_all).

% TODO: hacer lo de cmdid

% TODO: dont export_all

format(String, Data) -> lists:flatten(io_lib:format(String, Data)).

help() ->
    io:format("Sus opciones son: ~n"),
    io:format("[LSG] Listar los juegos disponibles. ~n"),
    io:format("[NEW] Crear un nuevo juego. ~n"),
    io:format("[ACC GameId] Aceptar un juego disponible. ~n"),
    io:format("[PLA GameId Move] Realizar una jugada en un juego en el que participes. ~n"),
    io:format("[PLA GameId quit] Abandonar un juego en el que participes. ~n"),
    io:format("[OBS GameId] Observar un juego. ~n"),
    io:format("[LEA GameId] Dejar de observar un juego. ~n"),
    io:format("[BYE] Terminar la conexión, abandonando todos los juegos en los que participes. ~n").

% TODO: usar X y O en vez de 1 y -1. vamos a tener que mantener conocimiento sobre si somos player1 o player2
show_board(GameId, Board) ->
    [A11, A12, A13, A21, A22, A23, A31, A32, A33] = string:lexemes(Board, ","),
    io:format(">> Board [~s]~n", [GameId]),
    io:format(" ~s | ~s | ~s ~n", [A11, A12, A13]),
    io:format("-----------~n"),
    io:format(" ~s | ~s | ~s ~n", [A21, A22, A23]),
    io:format("-----------~n"),
    io:format(" ~s | ~s | ~s ~n", [A31, A32, A33]).

start(Port) ->
    case gen_tcp:connect({127,0,0,1}, Port, [{active, false}]) of
        {ok, Socket} ->
            io:format("Conectado al servidor en 127.0.0.1:~p~n", [Port]),
            spawn(?MODULE, receiver, [Socket]),
            sender(Socket);
        {error, _} ->
            io:format("No se pudo conectar al servidor en 127.0.0.1:~p~n", [Port])
    end.

sender(Socket) ->
    Username = string:trim(io:get_line(">> Ingrese un nombre de usuario: ")),
    gen_tcp:send(Socket, format("CON ~s", [Username])),
        % ok -> io:format("WELCOME.~n"), sender(Socket, Line, 0)
    io:format("Para ver la lista de comandos disponibles, ingrese HELP~n"),
    sender(Socket, Username, 1).
sender(Socket, Username, CMDID) ->
    CMDString = string:trim(io:get_line(">> ")),
    Lexemes = string:lexemes(CMDString, " "),
    case Lexemes of
        ["HELP"] -> help(), sender(Socket, Username, CMDID);
        ["CON", _] -> gen_tcp:send(Socket, CMDString), sender(Socket, Username, CMDID);
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
                ["ERROR" | Args] -> io:format("ERROR ~s~n", [string:join(Args, " ")]);
                ["UPD", CMDID, GameId, "board", Board] -> show_board(GameId, Board);
                ["UPD", CMDID, GameId, "game_ended", Winner] ->
                    io:format("El juego ~s termino: [~s]~n", [GameId, Winner]);
                ["OK" | Args] ->
                    case Args of
                        [CMDID, GameId, "board", Board] -> show_board(GameId, Board);
                        [CMDID, "game_ended", GameId, Winner] ->
                            io:format("El juego ~s termino: [~s]~n", [GameId, Winner]);
                        _ -> io:format("~s~n", [Data])
                    end
            end,
            receiver(Socket);
        {error, closed} -> io:format("jeje~n")
    end.