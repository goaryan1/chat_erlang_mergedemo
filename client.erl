-module(client).
-export([start/0, send_message/0, offline/0, online/0, loop/1, exit/0, change_topic/0, start_helper/1, get_chat_topic/0, send_private_message/0, show_clients/0, help/0, kick/0, make_admin/0, show_admins/0]).
-record(client_status, {name, serverSocket, startPid, spawnedPid, adminStatus = false, muteTime = os:timestamp(), muteDuration = 0}).

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
                {admin, NewAdminStatus} ->
                    ClientStatus1 = ClientStatus#client_status{adminStatus = NewAdminStatus},
                    case NewAdminStatus of
                        true ->
                            io:format("Admin rights received !!~n");
                        false ->
                            io:format("Admin rights revoked !!~n")
                    end,
                    loop(ClientStatus1);
                {mute, NewMuteStatus, Duration} ->
                    case NewMuteStatus of
                        true ->
                            ClientStatus1 = ClientStatus#client_status{muteTime = os:timestamp(), muteDuration = Duration},
                            io:format("Muted for ~p minutes~n", [Duration]);
                        false ->
                            ClientStatus1 = ClientStatus#client_status{muteTime = os:timestamp(), muteDuration = 0},
                            io:format("Unmuted !!~n")
                    end,
                    loop(ClientStatus1);
                _ ->
                    io:format("Undefined message received~n")
            end;
        {tcp_closed, Socket} when State =:= online->
            io:format("Connection closed~n"),
            ok;
        {StartPid, Data} ->
            case Data of
                {private_message, Message, Receiver} ->
                    BinaryData = term_to_binary({private_message, Message, Receiver}),
                    gen_tcp:send(Socket, BinaryData),
                    private_message_helper(ClientStatus);
                {message, Message} ->
                    {MuteCheck, Duration} = mute_check(ClientStatus),
                    case MuteCheck of
                        true ->
                            io:format("Muted for ~p more minutes. ~n", [Duration]);
                        false ->
                            BinaryData = term_to_binary({message, Message}),
                            gen_tcp:send(Socket, BinaryData)
                    end;
                {exit} ->
                    BinaryData = term_to_binary({exit}),
                    gen_tcp:send(Socket, BinaryData);
                {make_admin, ClientName} ->
                    make_admin_helper(ClientStatus, ClientName);
                {show_clients} ->
                    BinaryData = term_to_binary({show_clients}),
                    gen_tcp:send(Socket, BinaryData),
                    ClientList = get_client_list(ClientStatus),
                    FormattedClientList = lists:map(fun({client, _, Name, _}) ->
                        Name
                        end, ClientList),
                    print_list(FormattedClientList);
                {show_admins} ->
                    BinaryData = term_to_binary({show_clients}),
                    gen_tcp:send(Socket, BinaryData),
                    ClientList = get_client_list(ClientStatus),
                    FilteredClientList = lists:filter(fun({client, _, _, Status}) ->
                        Status == true end, ClientList),
                    FormattedAdminClientList = lists:map(fun({client, _, Name, _}) ->
                        Name
                        end, FilteredClientList),
                    print_list(FormattedAdminClientList);
                {offline} ->
                    BinaryData = term_to_binary({offline}),
                    gen_tcp:send(Socket, BinaryData),
                    io:format("You are Offline Now :') ~n"),
                    loop(ClientStatus, offline);
                {online}} ->
                    BinaryData = term_to_binary({online}),
                    gen_tcp:send(Socket, BinaryData),
                    io:format("You are Online Now :) ~n"),
                    recv_old_messages(ClientStatus),
                    loop(ClientStatus, online);
                {topic} when State =:= online ->
                    BinaryData = term_to_binary({topic}),
                    gen_tcp:send(Socket, BinaryData),
                    ChatTopic = get_topic(ClientStatus),
                    io:format("Topic of the ChatRoom is : ~p~n",[ChatTopic]);
                {change_topic, NewTopic} when State =:= online ->
                    BinaryData = term_to_binary({change_topic, NewTopic}),
                    gen_tcp:send(Socket, BinaryData),
                    Status = get_status(ClientStatus),
                    case Status of
                        {success} ->
                            io:format("Topic of the ChatRoom is updated to : ~p~n",[NewTopic]);
                        _ ->
                            io:format("Error while Changing the Topic")
                    end;
                {kick, ClientName} ->
                    kick_helper(ClientStatus, ClientName)
            end
    end,
    loop(ClientStatus, online).

make_admin_helper(ClientStatus, ClientName) ->
    Socket = ClientStatus#client_status.serverSocket,
    AdminStatus = ClientStatus#client_status.adminStatus,
    case AdminStatus of
        true ->
            BinaryData = term_to_binary({make_admin, ClientName}),
            gen_tcp:send(Socket, BinaryData),
            receive
                {tcp, Socket, BinaryDataRec} ->
                    Data = binary_to_term(BinaryDataRec),
                    case Data of
                        {success} ->
                            ok;
                        {error, Message} ->
                            io:format("error: ~p", [Message])
                    end
            end;
        false ->
            io:format("Admin rights not available~n")
    end.

mute_check(ClientStatus) ->
    {_, TimeNow, _} = os:timestamp(),
    MuteDuration = ClientStatus#client_status.muteDuration,
    {_, TimeOfMute, _} = ClientStatus#client_status.muteTime,
    TimeSinceMute = (TimeNow - TimeOfMute)/(60),
    TimeLeft = MuteDuration - TimeSinceMute,
    case (TimeLeft > 0) of
        true ->
            {true, TimeLeft};   % still mute
        false ->
            {false, 0}      % mute time ended
    end.

kick_helper(ClientStatus, ClientName) ->
    Socket = ClientStatus#client_status.serverSocket,
    AdminStatus = ClientStatus#client_status.adminStatus,
    case AdminStatus of
        true ->
            BinaryData = term_to_binary({kick, ClientName}),
            gen_tcp:send(Socket, BinaryData),
            receive
                {tcp, Socket, BinaryDataRec} ->
                    Data = binary_to_term(BinaryDataRec),
                    case Data of
                        {success} ->
                            ok;
                        {error, Message} ->
                            io:format("error while kicking ~p: ~p", [ClientName, Message])
                    end
            end;
        false ->
            io:format("Admin rights not available~n")
    end.

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

kick() ->
    ClientName = string:trim(io:get_line("Enter Client Name: ")),
    StartPid = get(startPid),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {kick, ClientName}}.

make_admin() ->
    ClientName = string:trim(io:get_line("Enter Client Name: ")),
    StartPid = get(startPid),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {make_admin, ClientName}}.

show_admins() ->
    StartPid = get(startPid),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {show_admins}}.





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
