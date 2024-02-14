-module(server).
-export([start/0, accept_clients/1, broadcast/1, broadcast/2, remove_client/1, show_clients/0, print_messages/1, loop/1]).
-record(client, {clientSocket, clientName}).
-record(message, {timestamp, senderName, text}).
-record(server_status, {listenSocket, counter, maxClients, historySize}).
-include_lib("stdlib/include/qlc.hrl").

start() ->
    init_databases(),
    {N,[]} =  string:to_integer(string:trim(io:get_line("Enter No of Clients Allowed : "))),
    {X,[]} =  string:to_integer(string:trim(io:get_line("Message History Size : "))),
    {ok, ListenSocket} = gen_tcp:listen(9991, [binary, {packet, 0}, {active, true}]),
    io:format("Server listening on port 9991 and Socket : ~p ~n",[ListenSocket]),
    Counter = 1,
    ServerStatus = #server_status{listenSocket = ListenSocket, counter = Counter, maxClients = N, historySize = X},
    spawn(server, accept_clients, [ServerStatus]).

init_databases() ->
    mnesia:start(),
    mnesia:create_table(client, [{attributes, record_info(fields, client)}]),
    mnesia:create_table(message, [{attributes, record_info(fields, message)}, {type, ordered_set}]).

accept_clients(ServerStatus) ->
    ListenSocket = ServerStatus#server_status.listenSocket,
    MaxClients = ServerStatus#server_status.maxClients,
    HistorySize = ServerStatus#server_status.historySize,
    Counter = ServerStatus#server_status.counter,
    {ok, ClientSocket} = gen_tcp:accept(ListenSocket),
    Active_clients = active_clients(),
    if 
        Active_clients<MaxClients ->
            ClientName = "User" ++ integer_to_list(Counter),
            io:format("Accepted connection from ~p~n", [ClientName]),
            MessageHistory = retreive_messages(HistorySize),
            Data = {connected, ClientName, MessageHistory},
            BinaryData = erlang:term_to_binary(Data),
            gen_tcp:send(ClientSocket, BinaryData),
            insert_client_database(ClientSocket, ClientName),
            Message = ClientName ++ " joined the ChatRoom.",
            broadcast({ClientSocket, Message}),
            NewCounter = Counter + 1,
            ServerStatus1 = ServerStatus#server_status{counter = NewCounter},
            ListenPid = spawn(server, loop, [ClientSocket]),
            gen_tcp:controlling_process(ClientSocket, ListenPid),
            accept_clients(ServerStatus1);
        true->
            Message = "No Space on Server :(",
            gen_tcp:send(ClientSocket, term_to_binary({reject,Message})),
            gen_tcp:close(ClientSocket),
            accept_clients(ServerStatus)
    end.

loop(ClientSocket) ->
    gen_tcp:recv(ClientSocket, 0),
    receive
        {tcp, ClientSocket, BinaryData} ->
            Data = binary_to_term(BinaryData),
            case Data of
                % Private Message
                {private_message, Message, Receiver} ->
                    io:format("Client ~p send message to ~p : ~p~n", [getUserName(ClientSocket), Receiver, Message]),
                    broadcast({ClientSocket, Message}, Receiver),
                    loop(ClientSocket);
                % Broadcast Message
                {message, Message} ->
                    io:format("Received from ~p: ~s~n",[getUserName(ClientSocket),Message]),
                    broadcast({ClientSocket,Message}),
                    loop(ClientSocket); 
                % Send list of Active Clients 
                {show_clients} ->
                    List = retreive_clients(),
                    gen_tcp:send(ClientSocket, term_to_binary({List})),
                    loop(ClientSocket);
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
    ClientRecord = #client{clientSocket=ClientSocket, clientName = ClientName},
    mnesia:transaction(fun() ->
        mnesia:write(ClientRecord)
    end).

insert_message_database(ClientName, Message) ->
        MessageRecord = #message{timestamp = os:timestamp(), senderName = ClientName, text = Message},
        mnesia:transaction(fun() ->
            mnesia:write(MessageRecord)
        end).

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
    case RecSocket of
        {error, not_found} ->
            gen_tcp:send(SenderSocket, term_to_binary({error, "User not found"}));
        RecvSocket ->
            io:format("RecScoket : ~p, Sendername : ~p~n",[RecvSocket, SenderName]),
            gen_tcp:send(RecvSocket, term_to_binary({message, SenderName, Message})),
            gen_tcp:send(SenderSocket, {success, "Message Succesfully Sent"})
    end.

broadcast({SenderSocket, Message}) ->
    SenderName = getUserName(SenderSocket),
    insert_message_database(SenderName, Message),
    Keys = mnesia:dirty_all_keys(client),
    lists:foreach(fun(ClientSocket) ->
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
            end
        end, Keys).

remove_client(ClientSocket) ->
    ClientName = getUserName(ClientSocket),
    ClientRecord = #client{clientSocket = ClientSocket, clientName = ClientName},
    mnesia:transaction(fun() ->
        mnesia:delete_object(ClientRecord)
    end),
    gen_tcp:close(ClientSocket).

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
    MessageHistory = lists:map(fun(X) ->  
                        {message,_,SenderName,Text} = X,
                        MsgString = SenderName ++  " : " ++ Text,
                        MsgString
                    end,  Messages),
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
