-module(tictactoe).
-import(util, [parse_globalised_id/1]).
-compile(export_all).

lobby(Player1, Observers, GameId) ->
    io:format("(debug)>> Game ~s: ~p ++ ~p~n", [GameId, Player1, Observers]),
    receive
        {acc, Player1, Caller} -> Caller ! ok, lobby(Player1, Observers, GameId);
        {acc, Player2, Caller} ->
            Caller ! ok,
            game([0, 0, 0, 0, 0, 0, 0, 0, 0], [Player1, Player2], 1, lists:delete(Player2, Observers), GameId);
        {obs, Player1} -> lobby(Player1, Observers, GameId);
        {obs, Observer} ->
            case lists:member(Observer, Observers) of
                true -> lobby(Player1, Observers, GameId);
                false -> lobby(Player1, [Observer | Observers], GameId)
            end;
        {lea, _} -> ok;
        {pla, _, _, Caller} -> Caller ! game_not_started
    end.

game(Board, Players, Turn, Observers, GameId) ->
    io:format("(debug)>> Game ~s: ~p ++ ~p~n", [GameId, Players, Observers]),
    receive
        {acc, _, Caller} -> Caller ! game_full, game(Board, Players, Turn, Observers, GameId);
        {obs, Observer} ->
            case lists:member(Observer, Observers ++ Players) of
                true -> game(Board, Players, Turn, Observers, GameId);
                false -> game(Board, Players, Turn, [Observer | Observers], GameId)
            end;
        {pla, Player, Move, Caller} ->
             case lists:nth(case Turn of 1 -> 1; -1 -> 2 end, Players) == Player of
                true ->
                    case edit_board(Board, Turn, Move) of
                        invalid_move ->
                            Caller ! invalid_move,
                            game(Board, Players, Turn, Observers, GameId);
                        {game_ended, Winner} ->
                            Caller ! {game_ended, Winner},
                            update_subscribers({game_ended, Winner}, Players -- [Player] ++ Observers, GameId);
                        NewBoard ->
                            MSjBoard = string:join(lists:map(fun(X) -> integer_to_list(X) end, NewBoard), ","),
                            Caller ! {board, MSjBoard},
                            update_subscribers({board, MSjBoard}, Players -- [Player] ++ Observers, GameId),
                            game(NewBoard, Players, (-1) * Turn, Observers, GameId)
                    end;
                false -> Caller ! not_your_turn
            end;
        {lea, Username} ->
            case lists:member(Username, Players) of
                true -> update_subscribers({game_ended, lists:nth(1, Players -- [Username])}, Players -- [Username] ++ Observers, GameId);
                false -> game(Board, Players, Turn, lists:delete(Username, Observers), GameId)
            end
    end.

edit_board(Board, Turn, MoveStr) ->
    try list_to_integer(MoveStr) of
        Move ->
            case Move < 1 orelse Move > 9 orelse lists:nth(Move, Board) =/= 0 of
            true -> invalid_move;
            false ->
                NewBoard = lists:sublist(Board, Move) ++ [Turn] ++ lists:nthtail(Move + 1, Board),
                case check_winner(Board, Turn) of
                    false -> NewBoard;
                    Winner -> {game_ended, Winner}
                end
            end
    catch _:_ -> invalid_move
    end.

check_winner([A11, A12, A13, A21, A22, A23, A31, A32, A33] = Board, Turn) ->
    M = lists:max([A11+A12+A13, A21+A22+A23, A31+A32+A33, A11+A21+A31, A12+A22+A32, A13+A23+A33, A11+A22+A33, A13+A22+A31]),
    Condition = 3 * Turn,
    case {lists:member(0, Board), M} of
        {_, Condition} -> Turn;
        {false, _} -> "DRAW";
        _ -> false
    end.

% TODO: puede pasar que sea invalido? checkear
update_subscribers(_, [], _) -> ok;
update_subscribers({CMDID, Update}, [Subscriber | Subscribers], GameId) ->
    case util:parse_globalised_id(Subscriber) of
        {Id, Node} ->
            {userlist, Node} ! {get_user, Id, self()},
            receive
                {user, PSocketId} -> PSocketId ! {upd, CMDID, GameId, Update}
            end,
            update_subscribers({CMDID, Update}, Subscribers, GameId)
    end.
