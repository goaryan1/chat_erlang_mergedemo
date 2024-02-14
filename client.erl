-module(client).
-export([start/0, offline/0, online/0, send_message/0, change_topic/0, loop/2, exit/0, get_chat_topic/0, start_helper/1, send_private_message/0, show_clients/0, help/0]).
-record(client_status, {name, serverSocket, startPid, spawnedPid}).

start() ->
    ClientStatus = #client_status{startPid = self()},
    SpawnedPid = spawn(client, start_helper, [ClientStatus]),
    put(spawnedPid, SpawnedPid),
    put(startPid, self()).

start_helper(ClientStatus) ->
    {ok, Socket} = gen_tcp:connect('localhost', 9990, [binary, {active, true}]),
    gen_tcp:recv(Socket, 0),
    receive
        {tcp, Socket, BinaryData} ->
            Data = erlang:binary_to_term(BinaryData),
            case Data of
                {connected, Name, MessageHistory, ChatTopic} ->
                    io:format("connected to server, with username ~p~n", [Name]),
                    io:format("Topic of the ChatRoom is : ~p~n",[ChatTopic]),
                    io:format("Message History: ~n"),
                    print_list(MessageHistory),
                    ClientStatus1 = ClientStatus#client_status{serverSocket = Socket, name = Name},
                    loop(ClientStatus1, online);
                {reject, Message} ->
                    io:format("Error : ~s~n",[Message])
            end;
        {tcp_closed, Socket} ->
            io:format("Not connected to the server: ~n")
    end.

loop(ClientStatus, State) ->
    Socket = ClientStatus#client_status.serverSocket,
    StartPid = ClientStatus#client_status.startPid,
    gen_tcp:recv(Socket, 0),    % activate listening
    receive
        {tcp, Socket, BinaryData} when State =:= online ->
            Data = binary_to_term(BinaryData),
            case Data of
                {message, SenderName, Message} ->
                    io:format("Received: ~p from user ~p~n", [Message, SenderName]),
                    loop(ClientStatus, online);
                true ->
                    io:format("Undefined message received~n")
            end;
        {tcp_closed, Socket} when State =:= online->
            io:format("Connection closed~n"),
            ok;
        {StartPid, {private_message, Message, Receiver}} when State =:= online ->
            BinaryData = term_to_binary({private_message, Message, Receiver}),
            gen_tcp:send(Socket, BinaryData),
            private_message_helper(ClientStatus);
        {StartPid, {message, Message}} when State =:= online ->
            BinaryData = term_to_binary({message, Message}),
            gen_tcp:send(Socket, BinaryData);
        {StartPid, {exit}} when State =:= online ->
            BinaryData = term_to_binary({exit}),
            gen_tcp:send(Socket, BinaryData); 
        {StartPid, {show_clients}} when State =:= online ->
            BinaryData = term_to_binary({show_clients}),
            gen_tcp:send(Socket, BinaryData),
            ClientList = get_client_list(ClientStatus),
            FormattedClientList = lists:map(fun({client, _, Name}) ->
                Name
                end, ClientList),
            print_list(FormattedClientList);
        {StartPid, {offline}} ->
            BinaryData = term_to_binary({offline}),
            gen_tcp:send(Socket, BinaryData),
            io:format("You are Offline Now :') ~n"),
            loop(ClientStatus, offline);
        {StartPid, {online}} ->
            BinaryData = term_to_binary({online}),
            gen_tcp:send(Socket, BinaryData),
            io:format("You are Online Now :) ~n"),
            recv_old_messages(ClientStatus),
            loop(ClientStatus, online);
        {StartPid, {topic}} when State =:= online ->
            BinaryData = term_to_binary({topic}),
            gen_tcp:send(Socket, BinaryData),
            ChatTopic = get_topic(ClientStatus),
            io:format("Topic of the ChatRoom is : ~p~n",[ChatTopic]);
        {StartPid, {change_topic, NewTopic}} when State =:= online ->
            BinaryData = term_to_binary({change_topic, NewTopic}),
            gen_tcp:send(Socket, BinaryData),
            Status = get_status(ClientStatus),
            case Status of
                {success} ->
                    io:format("Topic of the ChatRoom is updated to : ~p~n",[NewTopic]);
                _ ->
                    io:format("Error while Changing the Topic")
            end
    end,
    loop(ClientStatus, online).

private_message_helper(#client_status{} = ClientStatus) ->
    Socket = ClientStatus#client_status.serverSocket,
    gen_tcp:recv(Socket, 0),
    receive
        {tcp, Socket, BinaryData} ->
            Data = binary_to_term(BinaryData),
            case Data of
                {success, _Message} ->
                    ok;
                {warning, Message} ->
                    io:format("~s~n",[Message]);
                {error, Message} ->
                    io:format("Error : ~s~n",[Message])
            end
    end.

recv_old_messages(ClientStatus) ->
    ServerSocket = ClientStatus#client_status.serverSocket,
    gen_tcp:recv(ServerSocket, 0),
    receive
        {tcp, ServerSocket, BinaryData} ->
            Data = binary_to_term(BinaryData),
            case Data of
                {previous, List} ->
                    io:format("Old Messages : ~n"),
                    print_list(List);
                _ ->
                    ok
            end
    end.

get_client_list(#client_status{} = ClientStatus) ->
    Socket = ClientStatus#client_status.serverSocket,
    gen_tcp:recv(Socket, 0),
    receive
        {tcp, Socket, BinaryData} ->
            Data = binary_to_term(BinaryData),
            {ClientList} = Data,
            ClientList
    end.

get_topic(ClientStatus) ->
    Socket = ClientStatus#client_status.serverSocket,
    gen_tcp:recv(Socket, 0),
    receive
        {tcp, Socket, BinaryData} ->
            Data = binary_to_term(BinaryData),
            {topic, ChatTopic} = Data,
            ChatTopic
    end.

get_status(ClientStatus) ->
    Socket = ClientStatus#client_status.serverSocket,
    gen_tcp:recv(Socket, 0),
    receive
        {tcp, Socket, BinaryData} ->
            Data = binary_to_term(BinaryData),
            Data
    end.

change_topic() ->
    Topic = string:trim(io:get_line("Enter New Topic : ")),
    StartPid = get(startPid),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {change_topic, Topic}}.

send_message() ->
    Message = string:trim(io:get_line("Enter message: ")),
    StartPid = get(startPid),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {message, Message}}.

send_private_message() ->
    Message = string:trim(io:get_line("Enter message: ")),
    Receiver = string:trim(io:get_line("Enter receiver name: ")),
    StartPid = get(startPid),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {private_message, Message, Receiver}}.

offline() ->
    StartPid = get(startPid),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {offline}}.

online() ->
    StartPid = get(startPid),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {online}}.

exit() ->
    StartPid = get(startPid),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {exit}}.

get_chat_topic() ->
    StartPid = get(startPid),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {topic}}.

show_clients() ->
    StartPid = get(startPid),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {show_clients}}.

help() ->
    % show available commands
    Commands = ["send_message/0", "send_private_message/0", "exit/0", "show_clients/0"],
    print_list(Commands).

print_list(List) ->
    lists:foreach(fun(X) ->
        io:format("~p~n", [X]) end, List).


% ----------------------------------









% ----------Unused functions-------------

% set_name() ->
%     NewName = string:trim(io:get_line("Enter desired username: ")),
%     StartPid = get(startPid),
%     SpawnedPid = get(spawnedPid),
%     SpawnedPid ! {StartPid, {set_name, NewName}}.



% set_name_handler(#client_status{} = ClientStatus, NewName) ->
%     io:format("70"),
%     Socket = ClientStatus#client_status.serverSocket,
%     gen_tcp:recv(Socket, 0),
%     receive
%         {tcp, Socket, BinaryData} ->
%             Data = binary_to_term(BinaryData),
%             io:format("Data received: ~p~n", Data),
%             case Data of
%                 {error, Message} ->
%                     io:format("error while updating username: ~p~n", [Message]),
%                     ClientStatus;
%                 {success, _Message} ->
%                     io:format("username updated to ~p~n", [NewName]),
%                     ClientStatus1 = ClientStatus#client_status{name = NewName},
%                     ClientStatus1
%             end
%     end.


% {StartPid, {set_name, NewName}} ->
%     BinaryData = term_to_binary({set_name, NewName}),
%     gen_tcp:send(Socket, BinaryData),
%     set_name_handler(ClientStatus, NewName)
