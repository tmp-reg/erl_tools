-module(gdbstub_hub).
-export([start_link/0, start_link/1,
         send/1, call/1,
         dev/1, devs/0,
         %% Some high level calls
         info/1,
         find_uid/1, uids/0,

         %% Debug
         devpath_usb_port/1,

         %% Internal, for reloads
         ignore/2, print/2, print_etf/2,
         dev_start/1, dev_handle/2,
         hub_handle/2
]).

%% This module is a hub for uc_tools gdbstub-based devices.  See also
%% gdbstub.erl

%% Singal flow:
%% - gdbstub_hub board gets enumerated on some host
%% - hosts's udev config connects to exo_notify
%% - gdbstub_hub hub gets an 'add' message
%% - a process is started for the particular device
%% - this process starts a GDB server process for GDBRSP over TCP
%% - the server supports multiple connections

%% See /etc/net/udev/notify-tty.sh which currently delegates to
%% zoe:/etc/net/udev/tty/zoe_usb_9-2.sh

%% The script sends a line to the exo_notify daemon:
%% bluepoll add zoe /dev/ttyACM1 /devices/pci0000:00/0000:00:16.0/usb9/9-2/9-2.4/9-2.4:1.0/tty/ttyACM1

%% The host name + devpath is enough to uniquely identify the location
%% of the device.

start_link() ->
    start_link(fun gdbstub_hub:hub_handle/2).
start_link(HubHandle) ->
    {ok,
     serv:start(
       {handler,
        fun() -> process_flag(trap_exit, true), #{ } end,
        HubHandle})}.

%% Udev events will eventuall propagate to here.

%% Add a TTY device, most likely USB.
%% DevPath is used to uniquely identify the device, based on the
%% physical USB port location.
hub_handle({add_tty,BHost,TTYDev,DevPath}=_Msg, State)
  when is_binary(BHost) and is_binary(TTYDev) ->
    Host = binary_to_atom(BHost, utf8),
    log:info("~p~n", [_Msg]),
    ID = case devpath_usb_port(DevPath) of
             {ok, UsbPort} -> {Host,UsbPort};
             _ -> {Host,{tty,TTYDev}}
         end,
    case maps:find(ID, State) of
        {ok, Pid} ->
            log:info("already have ~p~n", [{ID,Pid}]),
            State;
        _ ->
            %% Easier to decouple GDB communication if there is a
            %% dedicated process per device.

            %% FIXME: Use listen errors to determine next port.
            Hub = self(),
            <<Offset:14,_:2,_/binary>> = crypto:hash(sha, [BHost,DevPath]),
            TcpPort = 10000 + Offset,

            Pid = gdbstub_hub:dev_start(
                    #{ hub => Hub,
                       log => fun gdbstub_hub:ignore/2,
                       %% log => fun(Msg) -> log:info("~p~n",[Msg]) end,
                       host => Host,
                       tty => TTYDev,
                       devpath => DevPath,
                       tcp_port => TcpPort,
                       id => ID }),
            log:info("adding ~p~n", [{ID,Pid}]),
            maps:put(ID, Pid, State)
    end;

hub_handle({up, Pid}, State) when is_pid(Pid) ->
    %% Ignore here.  Useful for Handle override.
    State;

hub_handle({'EXIT',Pid,_Reason}=_Msg,State) ->
    log:info("~p~n", [_Msg]),
    IState = tools:maps_inverse(State),
    case maps:find(Pid, IState) of
        {ok, ID} ->
            maps:remove(ID, State);
        _ ->
            log:info("Warning: ~p not registered~n", [Pid]),
            State
    end;

hub_handle({Pid, {dev_pid, ID}}, State) ->
    obj:reply(Pid, maps:find(ID, State)),
    State;
                          
hub_handle(Msg, State) ->
    obj:handle(Msg, State).


%% The main purpose of this process is to provide mutually exclusive
%% access to the GDB port.  Two cases are supported.

dev_start(#{ tty := Dev, id := {Host, _}, hub := Hub } = Init) ->      
    serv:start(
      {handler,
       fun() ->
               log:info("connecting ~p~n", [{Host,Dev}]),
               %% FIXME:
               Port = exo:open_ssh_port(Host, "gdbstub_connect", Dev, []),
               log:info("connected ~p~n",[Port]),
               Gdb = gdb_start(maps:merge(Init, #{ pid => self() })),
               Pid = self(),
               spawn(
                 fun() ->
                         %% Identify the board and notify.
                         obj:call(Pid, {set_meta, 
                                        gdbstub:uid(Pid),
                                        gdbstub:protocol(Pid),
                                        gdbstub:protocol2(Pid)}),
                         Hub ! {up, Pid}
                 end),

               maps:merge(
                 Init,
                 #{ gdb => Gdb,
                    port => Port })
       end,
       fun gdbstub_hub:dev_handle/2}).

dev_handle(Msg,State) ->
    %% Tap point
    log:info("~p~",[{Msg,State}]),
    dev_handle_(Msg,State).
dev_handle_(Msg={_,dump},State) ->
    obj:handle(Msg, State);
dev_handle_({Pid,{set_meta, UID, Proto, Proto2_}}, State) ->
    obj:reply(Pid, ok),
    Proto2 = case Proto2_ of "unknown" -> Proto; P2 -> P2 end,
    %% Pick a decoder for Proto2
    maps:merge(
      State,
      #{ uid => UID,
         decode => decoder(Proto2),
         proto => Proto,
         proto2 => Proto2 });
dev_handle_({Pid, {rsp_call, Request}}, 
            #{ port := Port } = State) ->
    true = port_command(Port, Request),
    obj:reply(
      Pid,
      case Request of
          "+" -> "";
          _   -> rsp:recv_port(Port, 3000)
      end),
    State;


%% Initially, ports speak GDB RSP.  Once we send something else, the
%% gdbstub connects the application.
dev_handle_({send, RawData},
            #{ port := Port } = State) ->
    true = port_command(Port, RawData),
    State;
dev_handle_({send_term, Term},
            #{ port := Port } = State) ->
    %% sm_etf uses {packet,4} wrapping
    Bin = term_to_binary(Term),
    Size = size(Bin),
    true = port_command(Port, [<<Size:32>>,Bin]),
    State;

%% For GDB RSP, all {data,_} messages should arrive in the
%% {rsp_call,_} handler.

%% If the application sends something back, it is assumed to be a
%% protocol understood by erlang:decode_packet.
dev_handle_({Port, Msg}, #{ port := Port} = State) ->
    %% log:info("Msg=~p~n", [Msg]),
    case Msg of
        {data, Bin} ->
            decode(Bin, State);
        _ ->
            log:info("ERROR: ~p~n",[Msg]),
            exit(Msg)
    end.

ignore(_Msg, State) ->
    State.

%% Because port is in raw mode, we don't have proper segmentation.  Do
%% that here.  DecodePacket use the API of erlang:decode_packet/3.
decode(NewBin, State = #{ decode := {DecodePacket, Type} }) ->
    PrevBin = maps:get(rest, State, <<>>),
    Bin = iolist_to_binary([PrevBin, NewBin]),
    case DecodePacket(Type,Bin,[]) of
        {more, _} ->
            maps:put(rest, Bin, State);
        {ok, Msg, RestBin} ->
            forward_msg(Msg, State),
            decode(<<>>, maps:put(rest, RestBin, State));
        {error,_}=E ->
            log:info("~p~n",[{E,Bin}]),
            maps:put(rest, <<>>, State)
    end.

forward_msg(Msg, State) ->
    print_etf(Msg, State).

print(Msg, State) -> 
    log:info("~p~n", [Msg]),
    State.
print_etf(Msg, State) -> 
    try
        Term = binary_to_term(Msg),
        %% Assume this is from uc_lib/gdb/sm_etf.c
        case Term of
            [{123,LogData}] ->
                log:info("~s", [LogData]);
            _ ->
                log:info("~p~n", [Term])
        end
    catch _C:_E -> 
            %% log:info("~p~n",[{_C,_E}]),
            print(Msg, State)
    end,
    State.

    


%% GDB RSP server.

gdb_start(#{ tcp_port := TCPPort } = Init) ->
    serv:start(
      {handler,
       fun() ->
               log:info("GDB remote access on TCP port ~p~n",[TCPPort]),
               serv_tcp:init(
                 [TCPPort], 
                 %% loop/2 uses blocking code (rsp:recv/1)
                 {body, 
                  fun(Sock, _) -> 
                          log:info("new connection~n"),
                          gdb_loop(maps:put(sock, Sock, Init))
                  end})
       end,
       fun serv_tcp:handle/2}).

%% GDB session is coupled to name, not to device instance.  This allows
%% device restarts while keeping gdb conn open.
gdb_loop(State = #{ sock := Sock, log := Log }) ->
    Request = rsp:recv(Sock),
    _ = Log({request,Request}, State),
    case gdb_dispatch(State, Request) of
        "" -> ignore;
        Reply ->
            _ = Log({reply, Reply}, State),
            ok = rsp:send(Sock, Reply)
    end,
    gdb_loop(State).

gdb_dispatch(#{ pid := Pid}, Request) ->
    obj:call(Pid, {rsp_call, Request}).

%%devpath_usb_port(test) ->
%%    devpath_usb_port(
%%      <<"/devices/pci0000:00/0000:00:16.0/usb9/9-2/9-2.4/9-2.4:1.0/tty/ttyACM1\n">>);
devpath_usb_port(Bin) ->
    case lists:reverse(re:split(Bin,"/")) of
        [_ttyACMx,<<"tty">>,_,UsbPort|_] ->
            case re:split(UsbPort,"-") of
                [Interface,Chain] ->
                    ChainList = re:split(Chain,"\\."),
                    {ok, [binary_to_integer(C) || C <- [Interface | ChainList]]};
                _ -> error
            end;
        _ -> error
    end.

%% It might be convenient. But maybe best not expose a naked Erlang
%% console on a TCP port without any form of authentication.

%% gdb_dispatch(#{ pid := Pid}, Request) ->
%%     %% By default, Send the the GDB command to the device.
%%     Forward = fun() -> obj:call(Pid, {rsp_call, Request}) end,

%%     %% Except when it is a monitor command...
%%     case rsp:qRcmd(Request) of
%%         false -> Forward();
%%         "" -> Forward();
%%         Cmd ->
%%             case lists:last(Cmd) of
%%                 46 ->
%%                     %% ... and it ends with a dot.  Then interpret it
%%                     %% as an erlang command where 'Dev' variable is bound.
%%                     Env = [{'Dev',Pid}],
%%                     Reply = tools:read_eval_print(Cmd, Env),
%%                     rsp:wrap(tools:hex(lists:flatten(Reply)));
%%                 _ ->
%%                     Forward()
%%             end
%%     end.


%% FIXME: Resolution isn't done very well.
send(Msg) -> gdbstub_hub ! Msg.
call(Msg) -> obj:call(gdbstub_hub, Msg).

dev(Pid) when is_pid(Pid) -> Pid;
dev(ID) -> {ok, Pid} = call({dev_pid, ID}), Pid.


info(ID) ->
    case call({dev_pid,ID}) of
        {ok, Pid} -> obj:dump(Pid);
        E -> E
    end.

find_uid(UID) ->
    maps:find(UID, uids()).
uids() ->
    uids(gdbstub_hub).
devs() ->
    maps:values(obj:dump(gdbstub_hub)).
    
uids(Hub) ->
    lists:foldl(
      fun({_ID,Pid},Map) ->
              case obj:dump(Pid) of
                  #{ uid := UID} ->
                      maps:put(UID,Pid,Map);
                  _ ->
                      Map
              end
      end,
      #{},
      maps:to_list(obj:dump(Hub))).



%% PROTOCOLS

%% The protocol that runs over the virtual serial port can be
%% anything.  What we need is a way for the board to specify how it
%% wants to be hooked up.  Note that input and output prococols can be
%% different.
%%
%% - raw
%% - {packet,N}
%% - {etf,N}         ETF wrapped in {packet,N}
%% - eterm           Printed Erlang terms
%% - sexp            s-expressions
%% - {ethernet,N}    {packet,N} encoded ethernet

decoder({packet,N}) -> {fun erlang:decode_packet/3, N};
decoder(raw)        -> {fun erlang:decode_packet/3, raw};

%% FIXME: Decoding should also do some routing in this case.  That
%% can't be expressed yet.
decoder({ethernet,N}) ->
    decoder({packet,N});

decoder(Str) when is_list(Str) ->
    try
        decoder(type:decode({pterm,list_to_binary(Str)}))
    catch C:E ->
            log:info("decoder: ~s unknown: ~p~n", [Str,{C,E}]),
            %% FIXME: use raw instead
            decoder(raw)
    end.
