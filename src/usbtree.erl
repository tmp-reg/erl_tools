-module(usbtree).
-export([kvstore/0,
         last_tty_devpath/1,
         save/2,
         map/0, keys/0, ttys/0,
         aliases/0,
         find_dev/1,
         find_tty_sh/1,
         test/0]).

%% This mechanism is generic enough to factor it out.  Originally part
%% of gdbstub / gdbstub_hub.  The basic problem solved here is to
%% manage the pysical location of USB nodes (most likely ttyACM) in an
%% IP network.  Such nodes are eventually exposed as Erlang processes,
%% but some bookkeeping is necessary to associate them to the host
%% they are connected to (which acts as IP or Erlang gateway), and the
%% usb tree address, i.e. host controller followed by a chain of hub
%% ports.  Additionally, last state is tracked to be able to manage
%% operations that reflect a node's usb upstream, such as power
%% control relays.


%% To be able to refer to a device when it is not yet represented as
%% an Erlang pid, we need to know where it is located.  To do this,
%% keep track of the last known location.

%% FIXME: DB reference is hardcoded. Make this configurable.
%% FIXME: It would be better as a flat SQL table maybe?
kvstore() ->
    exo:kvstore(bluepill).

last_tty_devpath(Name) ->    
    case kvstore:find(kvstore(), Name) of
        {ok, {pterm, Info}} ->  
            #{ host := Host, devpath := DevPath } = Info,
            Dev = devpath_to_dev(DevPath),
            {Host, Dev, DevPath};
        {error,{not_found, Name}} ->
            throw({usbtree_last_tty_not_found,Name})
    end.
    
devpath_to_dev(DevPath) ->
    [TTY|_] = lists:reverse(re:split(DevPath,"/")),
    tools:format_binary("/dev/~s", [TTY]).


save(Name, #{ host := Host, devpath := DevPath, uid := UID, usbport := Usbport }) ->
    Store = exo:kvstore(bluepill),
    Info0 = #{ host => Host,
               devpath => DevPath,
               usbport => Usbport,
               uid => UID},
    kvstore:put(Store, Name, {pterm, Info0}).





%% 
test() ->
    ok.

map() ->
    kvstore:to_map(kvstore()).
keys() ->
    maps:keys(map()).
ttys() ->
    [{tty,ID} || {tty,ID} <- keys()].

find_dev(Name) ->
    PhysDev =
        case maps:find(Name, aliases()) of
            {ok, Dev} -> Dev;
            error -> Name
        end,
    log:info("~p -> ~p~n", [Name, PhysDev]),
    case maps:find(PhysDev, map()) of
        {ok, {pterm, #{ devpath := DevPath, host := Host }=_Info}} ->
            log:info("~p -> ~p~n", [Name,_Info]),
            {ok, {Host, devpath_to_dev(DevPath)}};
        error ->
            {error, Name}
    end.

    
    
find_tty_sh(Name0) ->
    Name =
        case maps:find(Name0, aliases()) of
            {ok, N} -> N;
            _ -> Name0
        end,
    {ok, {Host, Dev}} = find_dev({tty,Name}),
    {ok, tools:format("~s\n~s\n", [Host,Dev])}.



%% High level name aliases.
%% FIXME: Put this config somewhere else.
aliases() -> 
    #{
       {tty, "bone0"} => {tty, "10c4-ea60-cp210x-1"}
     }.
    
