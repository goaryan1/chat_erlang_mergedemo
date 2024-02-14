-module(server).
-export([start/0, accept_clients/1, get_chat_topic/1, update_chat_topic/2, broadcast/1, broadcast/2, remove_client/1, show_clients/0, print_messages/1, loop/2]).
-record(client, {clientSocket, clientName, state, timestamp}).
-record(message, {timestamp, senderName, text, receiver}).
-record(status, {listenSocket, counter, maxClients, historySize, chatTopic}).
-include_lib("stdlib/include/qlc.hrl").

start() ->
    init_databases(),
    {N,[]} =  string:to_integer(string:trim(io:get_line("Enter No of Clients Allowed : "))),
    {X,[]} =  string:to_integer(string:trim(io:get_line("Message History Size : "))),
    ChatTopic = string:trim(io:get_line("Enter Chat Topic : ")),
    {ok, ListenSocket} = gen_tcp:listen(9990, [binary, {packet, 0}, {active, true}]),
    io:format("Server listening on port 9990 and Socket : ~p ~n",[ListenSocket]),
    Counter = 1,
    ServerRecord = #status{listenSocket = ListenSocket, counter = Counter, maxClients = N, historySize = X, chatTopic = ChatTopic},
    mnesia:transaction(fun() ->
        mnesia:write(ServerRecord) end),
    spawn(server, accept_clients, [ListenSocket]).

init_databases() ->
    mnesia:start(),
    mnesia:create_table(client, [{attributes, record_info(fields, client)}]),
    mnesia:create_table(message, [{attributes, record_info(fields, message)}, {type, ordered_set}]),
    mnesia:create_table(status, [{attributes, record_info(fields, status)}]).

accept_clients(ListenSocket) ->
    {atomic,[Row]} = mnesia:transaction(fun() ->mnesia:read(status, ListenSocket) end),
    MaxClients = Row#status.maxClients,
    HistorySize = Row#status.historySize,
    Counter = Row#status.counter,
    ChatTopic = Row#status.chatTopic,
    {ok, ClientSocket} = gen_tcp:accept(ListenSocket),
    Active_clients = active_clients(),
    if 
        Active_clients<MaxClients ->
            ClientName = "User" ++ integer_to_list(Counter),
            io:format("Accepted connection from ~p~n", [ClientName]),
            MessageHistory = retreive_messages(HistorySize),
            Data = {connected, ClientName, MessageHistory, ChatTopic},
            BinaryData = erlang:term_to_binary(Data),
            gen_tcp:send(ClientSocket, BinaryData),
            insert_client_database(ClientSocket, ClientName),
            Message = ClientName ++ " joined the ChatRoom.",
            broadcast({ClientSocket, Message}),
            NewCounter = Counter + 1,
            {atomic, [Record]} = mnesia:transaction(fun() -> mnesia:read({status, ListenSocket}) end),
            UpdatedRecord = Record#status{counter = NewCounter},
            mnesia:transaction(fun()->mnesia:write(UpdatedRecord) end),
            ListenPid = spawn(server, loop, [ClientSocket, ListenSocket]),
            gen_tcp:controlling_process(ClientSocket, ListenPid),
            accept_clients(ListenSocket);
        true->
            Message = "No Space on Server :(",
            gen_tcp:send(ClientSocket, term_to_binary({reject,Message})),
            gen_tcp:close(ClientSocket),
            accept_clients(ListenSocket)
    end.

loop(ClientSocket, ListenSocket) ->
    gen_tcp:recv(ClientSocket, 0),
    receive
        {tcp, ClientSocket, BinaryData} ->
            Data = binary_to_term(BinaryData),
            case Data of
                % Private Message
                {private_message, Message, Receiver} ->
                    RecSocket = getSocket(Receiver),
                    RecvState = get_state(RecSocket),
                    if 
                        RecvState =:= online ->
                            io:format("Client ~p send message to ~p : ~p~n", [getUserName(ClientSocket), Receiver, Message]),
                            broadcast({ClientSocket, Message}, Receiver);
                        true ->
                            SenderName = getUserName(ClientSocket),
                            Msg = "Receiver is Oflline, he will be notified later.",
                            insert_message_database(SenderName, Message, Receiver),
                            io:format("~s~n",[Msg]),
                            gen_tcp:send(ClientSocket, term_to_binary({warning, Msg}))
                    end,
                    loop(ClientSocket, ListenSocket);
                % Broadcast Message
                {message, Message} ->
                    io:format("Received from ~p: ~s~n",[getUserName(ClientSocket),Message]),
                    broadcast({ClientSocket,Message}),
                    loop(ClientSocket, ListenSocket); 
                % Send list of Active Clients 
                {show_clients} ->
                    List = retreive_clients(),
                    gen_tcp:send(ClientSocket, term_to_binary({List})),
                    loop(ClientSocket, ListenSocket);
                % Client going offline
                {offline} ->
                    Message = getUserName(ClientSocket) ++ " is offline now.",
                    update_state(ClientSocket, offline),
                    broadcast({ClientSocket, Message}),
                    loop(ClientSocket, ListenSocket);
                % Client going online
                {online} ->
                    Message = getUserName(ClientSocket) ++ " is online now.",
                    Last_Active = update_state(ClientSocket, online),
                    broadcast({ClientSocket, Message}),
                    Prev_messages = get_old_messages(ClientSocket, Last_Active),
                    gen_tcp:send(ClientSocket, term_to_binary({previous, Prev_messages})),
                    loop(ClientSocket, ListenSocket);
                % Get Chat Topic
                {topic} ->
                    Topic = get_chat_topic(ListenSocket),
                    gen_tcp:send(ClientSocket, term_to_binary({topic, Topic})),
                    loop(ClientSocket, ListenSocket);
                %Change Chat Topic
                {change_topic, NewTopic} ->
                    update_chat_topic(NewTopic, ListenSocket),
                    gen_tcp:send(ClientSocket, term_to_binary({success})),
                    Message = "Chat Topic Updated to " ++ NewTopic,
                    broadcast({ClientSocket, Message}),
                    loop(ClientSocket, ListenSocket);
                % Exit from ChatRoom
                {exit} ->
                    io:format("Client ~p left the ChatRoom.~n",[getUserName(ClientSocket)]),
                    LeavingMessage = getUserName(ClientSocket) ++ " left the ChatRoom.",
                    broadcast({ClientSocket, LeavingMessage}),
                    remove_client(ClientSocket)
            end;
        % Client Connection lost
        {tcp_closed, ClientSocket} ->
            io:format("Client ~p disconnected~n", [getUserName(ClientSocket)]),
            remove_client(ClientSocket)
    end.

insert_client_database(ClientSocket, ClientName) ->
    ClientRecord = #client{clientSocket=ClientSocket, clientName = ClientName, state=online, timestamp = os:timestamp()},
    mnesia:transaction(fun() ->
        mnesia:write(ClientRecord)
    end).

insert_message_database(ClientName, Message, Receiver) ->
        MessageRecord = #message{timestamp = os:timestamp(), senderName = ClientName, text = Message, receiver = Receiver},
        mnesia:transaction(fun() ->
            mnesia:write(MessageRecord)
        end).

compare_timestamps({Seconds1, Microseconds1, _}, {Seconds2, Microseconds2, _}) ->
    if
        Seconds1 < Seconds2 ->
            less;
        Seconds1 > Seconds2 ->
            greater;
        Microseconds1 < Microseconds2 ->
            less;
        Microseconds1 > Microseconds2 ->
            greater;
        true ->
            equal
    end.
        

get_old_messages(ClientSocket, Last_Active) ->
    F = fun() ->
        qlc:e(qlc:q([M || M <- mnesia:table(message)]))
    end,
    {atomic, Query} = mnesia:transaction(F),
    ReceiverName = getUserName(ClientSocket),
    Filtered = lists:filter(
        fun({message,Timestamp,_,_,Receiver}) ->
                (Receiver == ReceiverName orelse Receiver=="All") andalso compare_timestamps(Timestamp, Last_Active) =:= greater 
            end, Query),
    Final = lists:map(
            fun({message,_, SenderName, Text, _}) ->
                Msg = SenderName ++ " : " ++ Text,
                Msg
            end, Filtered),
    Final.

update_state(ClientSocket, State) ->
    Trans = fun() -> mnesia:read({client, ClientSocket}) end,
    {atomic, [Row]} = mnesia:transaction(Trans),
    UpdatedRecord = Row#client{state = State, timestamp = os:timestamp()},
    mnesia:transaction(fun() -> mnesia:write(UpdatedRecord) end),
    Row#client.timestamp.

active_clients() ->
    Trans = fun() -> mnesia:all_keys(client) end,
    {atomic,List} = mnesia:transaction(Trans),
    No_of_clients = length(List),
    No_of_clients.

getUserName(ClientSocket) ->
    Trans = fun() -> mnesia:read({client, ClientSocket}) end, 
    {atomic,[Record]} = mnesia:transaction(Trans),
    Record#client.clientName.

getSocket(Name) ->
    Query = qlc:q([User#client.clientSocket || User <- mnesia:table(client), User#client.clientName == Name]),
    Trans = mnesia:transaction(fun() -> qlc:e(Query) end),
    case Trans of
        {atomic, [Socket]} ->
            Socket;
        {atomic, []} ->
            {error, not_found};
        {aborted, Reason} ->
            {error, Reason}
    end.

broadcast({SenderSocket, Message}, Receiver) ->
    % private messages don't get saved in the database
    RecSocket = getSocket(Receiver),
    SenderName = getUserName(SenderSocket),
    insert_message_database(SenderName, Message, Receiver),
    case RecSocket of
        {error, not_found} ->
            gen_tcp:send(SenderSocket, term_to_binary({error, "User not found"}));
        RecSocket ->
            io:format("RecScoket : ~p, Sendername : ~p~n",[RecSocket, SenderName]),
            gen_tcp:send(RecSocket, term_to_binary({message, SenderName, Message})),
            gen_tcp:send(SenderSocket, term_to_binary({success, "Message Succesfully Sent"}))
    end.

broadcast({SenderSocket, Message}) ->
    SenderName = getUserName(SenderSocket),
    insert_message_database(SenderName, Message, "All"),
    Keys = mnesia:dirty_all_keys(client),
    lists:foreach(fun(ClientSocket) ->
        State = get_state(ClientSocket),
        case State of
            online ->
                case ClientSocket/=SenderSocket of
                    true ->
                        case mnesia:dirty_read({client, ClientSocket}) of
                        [_] ->
                            io:format("Broadcasted the Message~n"),
                            gen_tcp:send(ClientSocket, term_to_binary({message, SenderName, Message}));
                        [] ->
                            io:format("No receiver Found ~n") 
                        end;
                    false -> ok
                end;
            _ -> ok
        end
    end, Keys).

remove_client(ClientSocket) ->
    ClientName = getUserName(ClientSocket),
    ClientRecord = #client{clientSocket = ClientSocket, clientName = ClientName},
    mnesia:transaction(fun() ->
        mnesia:delete_object(ClientRecord)
    end),
    gen_tcp:close(ClientSocket).

get_state(ClientSocket) ->
    Trans = fun() -> mnesia:read({client, ClientSocket}) end,
    {atomic,[Row]} = mnesia:transaction(Trans),
    Row#client.state.

get_chat_topic(ListenSocket) ->
        Trans = fun() -> mnesia:read({status, ListenSocket}) end,
    {atomic, [Row]} = mnesia:transaction(Trans),
    Row#status.chatTopic.

update_chat_topic(NewTopic, ListenSocket) ->
    {atomic, [Row]} = mnesia:transaction(fun() -> mnesia:read({status, ListenSocket}) end),
    UpdatedRecord = Row#status{chatTopic = NewTopic},
    mnesia:transaction(fun()->mnesia:write(UpdatedRecord) end).

show_clients() ->
    ClientList = retreive_clients(),
    io:format("Connected Clients:~n"),
    lists:foreach(fun(X) ->
        io:format("~p~n", [X]) end, ClientList).

retreive_clients() ->
    F = fun() ->
        qlc:e(qlc:q([M || M <- mnesia:table(client)]))
    end,
    {atomic, ClientList} = mnesia:transaction(F),
    ClientList.

retreive_messages(N) ->
    F = fun() ->
        qlc:e(qlc:q([M || M <- mnesia:table(message)]))
    end,
    {atomic, Query} = mnesia:transaction(F),
    ReverseMessages = lists:sublist(lists:reverse(Query), 1, N),
    Messages = lists:reverse(ReverseMessages),
    % io:format("~p~n",[Messages]),
    % Messages.
    Filtered = lists:filter(fun({message,_,_,_, Receiver}) ->  
                            Receiver == "All"                        
                    end,  Messages),
    MessageHistory = lists:map(fun({message,_,SenderName,Text, _}) ->
        Msg = SenderName ++ " : " ++ Text,
        Msg end, Filtered),
    MessageHistory.

print_messages(N) ->
    Messages = retreive_messages(N),
    io:format("Messages:~n"),
    lists:foreach(fun(X) ->
        io:format("~p~n", [X]) end, Messages).

% -----------------------------------------







% ----------Unused functions--------------


% userNameUsed(UserName) ->
%     case mnesia:dirty_read({client, UserName}) of
%         [] ->
%             false;
%         [_] ->
%             true
%     end.


% updateName(ClientSocket, NewName) ->
%     mnesia:write(#client{clientName =  NewName, clientSocket = ClientSocket}).


% {set_name, NewName} ->
%     case userNameUsed(NewName) of
%         true ->
%             io:format("name is used~n"),
%             gen_tcp:send(ClientSocket, term_to_binary({error, "Name already in use"}));
%         false ->
%             io:format("name is unused~n"),
%             updateName(ClientSocket, NewName),
%             gen_tcp:send(ClientSocket, term_to_binary({success, "Name updated to " ++ NewName}))
%     end
