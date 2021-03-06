-module(ws).
%% Dialyzer complains about not knowing these behaviors, so comment out.
%%-behaviour(cowboy_http_handler).
%%-behaviour(cowboy_websocket_handler).

%% Upstream interface.
-export([init/3, handle/2, terminate/3]).
-export([websocket_init/3, websocket_handle/3,
         websocket_info/3, websocket_terminate/3]).

%% Socket interaction and tools
-export([call/4, call_broadcast/4,
         call_sequence/2,
         call_sequence_bert/2,
         call_wait/4,
         call_exml/4,
         call_wait_exml/4,
         sync/2,

         info/3, info_ehtml/2, info_ehtml/3, info_ehtml/1,

         console/2,
         
         command/3, command/2,
         showhide_select/3,
         eval/2,

         %% Tools
         encode_id/1,
         timestamp/1,
         reload/1,
         reload_all/0,
         pids/0,
         find/1,

         %% HMAC for encoding binary terms in JavaScript strings.
         hmac_key/0, hmac/2,
         hmac_encode/2, hmac_decode/2,
         hmac_encode/1, hmac_decode/1,

         %% Generate JavaScript callbacks
         js_start/1,
         js_send_input/1,
         js_send_input_form/2,
         js_send_event/1,

         js_start_nolib/1,

         %% Delegate to supervisor's child
         to_child/3,
         widgets/1,

         %% Query values as produced by ws.js
         form_list/2

         
]).


%% For Single Page Applications (SPA), a websocket connection is used.
%% Messages sent over this socket are JSON- or BERT-encoded.

%% SPAs are structured like this:
%% - initial web page contains SPA layout template and a call to ws_start
%% - ws_start initiates the Erlang side of the application once the websocket is up


%% Cowboy API
init({tcp, http}, _Req, _Opts) ->
    {upgrade, protocol, cowboy_websocket}.
handle(Req, State) ->
    log:info("ws: not expected: ~p~n", [Req]),
    %% FIXME: xref complained about missing function.  I don't think this path is taken much.
    %% {ok, Req2} = cowboy_http_req:reply(404, [{'Content-Type', <<"text/html">>}]),
    ErrorBody = <<"Error">>,
    {ok, Req2} = cowboy_req:reply(404, [{<<"Content-Type">>, <<"text/html">>}], ErrorBody, Req),
    {ok, Req2, State}.
terminate(_Reason, _Req, _State) ->
    log:info("ws: terminate: ~p~n",[{_Reason, _Req, _State}]),
    ok.


%% Websocket API

websocket_init(_TransportName, Req, _Opts) ->
    {Agent,_} = cowboy_req:header(<<"user-agent">>,Req),
    {Peer, _} = cowboy_req:peer(Req),

    %% Register the connection centrally.
    ws_bc() ! {subscribe, self()},

    %% It's also useful to have these registered as a global name, but
    %% this should only be used for debugging.
    %% log:set_info_name({ws,self()}),
    tools:register_suffix(ws, self()),
    log:info("ws: init ~p~n",[{Agent,Peer}]),

    {ok, Req,
     #{agent => Agent,
       peer => Peer}}.

websocket_handle({text, Json}, Req, State) ->
    case json:decode(Json) of
        %% Interpret all incoming messages as JSON.
        {ok, EJson} ->
            NextState = handle_ejson_(EJson, State),  %% Async only
            {ok, Req, NextState}
        %%Error ->
        %%    log:info("not json: ~p~n", [{Json,Error}]),
        %%    {ok, Req, State}
    end;

websocket_handle({binary, Bin}, Req, State) -> 
    %% Binary messages (Uint8Array) are interpreted as binary erlang
    %% terms containing EJson messages.  The main reason for this is
    %% to avoid a JSON parser.
    EJson = erlang:binary_to_term(Bin),
    %% log:info("via bert: ~p~n",[EJson]),
    NextState = handle_ejson_(EJson, State),  %% Async only
    {ok, Req, NextState};
websocket_handle({ping,_}, Req, State) -> 
    {ok, Req, State};
websocket_handle({pong,_}, Req, State) -> 
    {ok, Req, State};
websocket_handle(Msg, Req, State) ->
    log:info("ws:websocket_handle ignore: ~p~n",[Msg]),
    {ok, Req, State}.

    


%% Messages sent to the websocket process.
%% supports obj.erl RPC protocol
websocket_info({Pid,_}=Msg, Req, State) when is_pid(Pid) ->
    {ok, Req, obj:handle(Msg, State)};

%% Raw data.
websocket_info({text, _}=Raw, Req, State)   -> {reply, Raw, Req, State};
websocket_info({binary, _}=Raw, Req, State) -> {reply, Raw, Req, State};
websocket_info({bert, Term}, Req, State)    -> {reply, {binary, term_to_binary(Term)}, Req, State};
 
%% Maps are interpreted as encoded JSON messages to be sent to the
%% websocket.  FIXME: change protocol to wrap this?
%% websocket.  The idea is to present the JavaScript code with
%% something that would come out of a JSON parser, i.e. a native
%% JavaScript object.  Whether we actually use JSON depends on whether
%% the environment supports a JSON encoder.  If not, use BERT.
websocket_info(Map, Req, State) when is_map(Map)-> 
    case apply(json,encode,[Map]) of
        {ok, JSON} ->
            {reply, {text, JSON}, Req, State};
        {error, json_not_supported} ->
            websocket_info({bert, Map}, Req, State)
    end;

%% Support the epid protocol.  Note that the Method tag is bundled
%% with the ID and the type to form the Epid sink address.
websocket_info({epid_send, {ID, Method, Type}, Val}, Req, State) ->
    Bin = type:encode({Type,Val}),
    websocket_info(call_fmt(ID, Method, Bin), Req, State);

%% Anything else gets sent to the delegate handler.
websocket_info(Msg, Req, #{handle := Handle}=State) -> 
    {ok, Req, Handle({info, Msg}, State)};

%% Or ignored
websocket_info(Msg, Req, State) -> 
    log:info("ws:websocket_info: ignore: ~p~n",[Msg]),
    {ok, Req, State}.

websocket_terminate(_Reason, _Req, State) ->
    log:info("terminate~n"),
    case maps:find(terminate, State) of
        {ok, Terminate} ->
            log:info("- running 'terminate' method~n"),
            Terminate(State), ok;
        _ ->
            log:info("- no 'terminate' method~n"),
            ok
    end,
    case maps:find(supervisor, State) of
        {ok, Pid} ->
            log:info("- shutdown supervisor ~p~n", [Pid]),
            %% exit(Pid, shutdown), ok;
            exit(Pid, kill), ok;
        _ ->
            log:info("- no supervisor~n"),
            ok
    end.



%% Tap point
handle_ejson_(Msg, State) ->
    %% log:info("handle_ejson: ~p~n", [Msg]),
    handle_ejson(Msg, State).

%% Generic websocket start routine.
%%
%% This uses a multi-step bootstrap:
%% - HTML with initial page layout calls into ws_start handler here, parameterized by code.
%% - We instantiate that code here, parameterized by the websocket connection
%% See also footnote 2.
handle_ejson(#{type := <<"ws_start">>,
               args := StartHmac},
             State) ->
    %% log:info("ws_start: ~p~n", [StartHmac]),
    {ok, Start} = hmac_decode(StartHmac),
    {ok, InitState} = Start(),
    maps:merge(State, InitState);


%% All ws.js browser applications support the ws_action message, which
%% supports HMAC-authenticated Erlang callbacks (closures).  See
%% web:button/1, web:checkbutton/1, ...  and ws_input in ws.js
%% See also footnote 1.
%% These are produced by "send*" methods in ws.js
handle_ejson(#{type := <<"ws_action">>, action := Action} = Msg, State) ->

    %% log:info("ws_action: ~p~n", [Msg]),
    %% Already dispatched, so these keys are no longer needed.
    M1 = maps:remove(action, Msg),
    M2 = maps:remove(type, M1),
    case Action of

        <<"">> ->
            %% Not a closure, but a message that is to be delivered to
            %% the default handler, which is either..
            case maps:find(handle, State) of
                {ok, Handle} ->
                    %% .. explicitly specified, or..
                    Handle({ws, M2}, State);
                _ ->
                    %% .. one of the children of the supervisor
                    %% associated to this websocket.
                    case State of
                        #{ supervisor  := Sup,
                           type_module := Types } ->
                            try 
                                FL = form_list(Types, M2),
                                to_children(Sup, FL)
                            catch
                                %% Decode error.
                                {bad_value, {Child,_}, _} = E ->
                                    to_child(Sup, Child, E)
                            end,
                            State;
                        _ ->
                            log:info("No handler for: ~p~n;", [M2]),
                            State
                    end
            end;
                    
        CallbackHMac ->
            %% Closure is authenticated.
            {ok, Fun} = hmac_decode(CallbackHMac),
            %% log:info("ws_action: ~p ~p~n",[Fun,M2]),
            Fun(M2, State)
    end;

%% Date and time from browser.
handle_ejson(#{type := <<"ws_datetime">>, 
               args := [Year,Month,Day,Hour,Minute,Second]}, State) ->
    DateTime = {{Year,Month,Day},{Hour,Minute,Second}},
    log:info("datetime: ~p~n", [DateTime]),

    %% Don't change the machine's time base, but record current
    %% timestamp in machine clock and browser time to reconstruct
    %% timestamps.
    maps:put(datetime,
             {machine_now(),
              DateTime},
             State);

%% All other messages are forwarded to the registered handler, if any.
handle_ejson(Msg, #{handle := Handle} = State) ->
    Handle({ws, Msg}, State);

handle_ejson(Msg, State) ->
    log:info("ws:handle_ejson: ignore: ~p~n",[Msg]), State.



%% call

%% Basic call format - see ws.js and method_call.js
%% Indirections:
%% ID -> DOM element data-behavior attribute -> behavior object -> method function
call_fmt(ID,Method,Arg) ->
    #{ type   => call,
       id     => encode_id(ID),
       method => Method,
       arg    => Arg}.

call_fmt_broadcast(ID,Method,Arg) ->
    #{ type   => call,
       name     => encode_id(ID),
       method => Method,
       arg    => Arg}.
    
%% Some Arg types are sent using Binary ERlang Term format for more
%% efficient encoding.
%% call_msg(ID,Method,{s16_le,_}=Arg) -> {bert, call_fmt(ID,Method,Arg)};
%% Default is JSON.
call_msg(ID,Method,Arg) -> call_fmt(ID,Method,Arg).

call_msg_broadcast(ID,Method,Arg) -> call_fmt_broadcast(ID,Method,Arg).


%% FIXME: check code and make sure no binary IDs are sent, then remove
%% case and use exml:encode_key
encode_id(ID) when is_binary(ID) -> ID;
encode_id(ID) -> type_base:encode({pterm,ID}).




%% A-synchronous messages send -- do not wait for reply.  See call.js
%% Some types are sent using Binary ERlang Term format.
call(Ws, ID, Method, Arg) -> Ws ! call_msg(ID,Method,Arg), ok.

call_broadcast(Ws, ID, Method, Arg) -> Ws ! call_msg_broadcast(ID,Method,Arg), ok.

%% Pass continuation to implement synchronous call.  Other side will
%% use cont as a ws_action.
call_wait(Ws, ID, Method, Arg) ->
    Ws ! maps:put(
           cont, cont_reply(self()),
           call_msg(ID,Method,Arg)),
    wait_reply().
cont_reply(Pid) ->
    hmac_encode(
      fun(Msg, State) -> Pid ! {cont_value, Msg}, State end).
wait_reply() -> 
    receive {cont_value, Msg} -> Msg end.

%% Queue-flush synchronization
sync(Ws, Thunk) ->
    Ws ! #{
      %% Piggy-back on ping type.
      type => ping,
      %% Reply message is ignored.  All information is contained in
      %% the closure.
      cont =>  ws:hmac_encode(fun(_Msg, WsState) -> Thunk(), WsState end)
     }.
    

    
    

%% E.g to avoid repaints when sending gui updates.
call_sequence(Ws, Messages) ->
    Ws ! fmt_sequence(Messages), ok.

fmt_sequence(Messages) ->
    #{ type => bundle,
       messages =>
           [call_msg(ID,Method,Arg)
            || {ID,Method,Arg} <- 
                   lists:flatten(Messages)] }.

call_sequence_bert(Ws, Messages) ->
    Ws ! {bert, fmt_sequence(Messages)}, ok.


%% Convenient shorthand for routines that expect innerHTML, which
%% needs to be encoded as binary.
call_exml(Ws, ID, Method, Els) ->
    call(Ws,ID,Method,exml:to_binary(Els)).
call_wait_exml(Ws, ID, Method, Els) ->
    call_wait(Ws,ID,Method,exml:to_binary(Els)).
    
              


%% Format message and send it over websocket to browser.  See ws.js
info_text(Ws, Text, Opts) ->      
    Bin = iolist_to_binary(Text),
    List = binary_to_list(Bin),
    UTF8 = unicode:characters_to_binary(List,latin1,utf8),
    call(Ws, live_log, append_text, [UTF8, Opts]).

info(Ws, Fmt, Args) ->
    info(Ws, Fmt, Args, #{}).
info(Ws, Fmt, Args, Opts) ->
    %% io:format("~p~n",[{Ws,Fmt,Args}]),
    info_text(Ws, io_lib:format(Fmt, Args), Opts).

%% Same, but for ehtml.
info_ehtml(Ws, Ehtml) ->
    info_ehtml(Ws, Ehtml, #{}).
info_ehtml(Ws, Ehtml, Opts) ->
    Bin = exml:to_binary([Ehtml]), %% FIXME: this can fail
    call(Ws, live_log, append_html, [Bin, Opts]).

%% Curried
info_ehtml(Ws) ->
    fun(Ehtml) -> info_ehtml(Ws, Ehtml) end.


%% Wrap text, ehtml as an io process.
console(Ws, Opts) ->
    log:info("console: ~p~n",[Opts]),
    log:format_to_io(
      fun() -> log:set_info_name({tools:annotate_pid(Ws), console}) end,
      fun(_, Fmt, Args) ->
              case log:format_record_ehtml([none, Fmt, Args]) of
                  {ehtml, Ehtml} -> info_ehtml(Ws, Ehtml, Opts);
                  {text, Text}   -> info_text(Ws, Text, Opts)
              end
      end).

%% Evaluate javascript code.
eval(Ws, Js) when is_binary(Js) ->
    Ws ! #{
      type => eval,
      code => Js,
      cont => cont_reply(self())
     },
    wait_reply();
eval(Ws, Js) -> eval(Ws, iolist_to_binary(Js)).


%% Run shell commands, streaming output to websocket log.
port_handle(Ws, Port) ->
    receive
        {Port, {data,{eol,Line}}} ->
            info(Ws,"~s~n",[Line]),
            port_handle(Ws, Port);
        Other ->
            log:info("port: ~p~n", [Other])
    end.
command(Ws, Fmt, Args) ->
    command(Ws, tools:format(Fmt,Args)).
command(Ws, Command) ->
    port_handle(
      Ws,
      open_port({spawn, Command},
                [{line, 1024}, binary, use_stdio, exit_status])).
    

%% datetime format.
machine_now() ->
    calendar:now_to_datetime(erlang:timestamp()).
    
%% Timestamp relative to browser time.
timestamp(Ws) ->
    {Machine0, Browser0} = obj:get(Ws, datetime),
    Machine1 = machine_now(),
    D2G = fun calendar:datetime_to_gregorian_seconds/1,
    calendar:gregorian_seconds_to_datetime(
      D2G(Browser0) + D2G(Machine1) - D2G(Machine0)).

%% See widget.js showhide
showhide_select(Ws,ID,Name) ->                            
    call(Ws,ID,select,type:encode({pterm,Name})).



%% Input and form data.


    


%% User data is represented as a triplet: key, type, value.  These can
%% be represented in decoded or encoded form, based on the
%% functionality exposed by a type module (an extension of type_base).
%% In the browser, the encoded triplet form is used represented as an
%% array of 3 strings, in Erlang, the decoded ktv() form is used.  For
%% the counterpart, see ws.js

%% In practice these are printable terms, using 'pterm' type from type_base.erl
-type key() :: _.
-type type() :: _.

%% Abbreviations: 
%% KTV : key, type, value
%% KTB : key, type, binary

-type ktb() :: {key(),{type(), binary()}}.
-type ktv() :: {key(),{type(), any()}}.



%% Unpack, but don't parse data yet.
%% Input format is generated by form_field() in ws.js
-spec ktb(atom(), [binary()]) -> ktb().
ktb(Types, [BinKey,BinType,BinVal]) ->
    {Types:decode({pterm,BinKey}),
     {Types:decode({pterm,BinType}),
      BinVal}}.

-spec form_list(atom(), _) -> [ktv()].
form_list(Types, EJson) ->

    %% Convert in two steps.  First step which reconstructs variable
    %% and type forms should not fail -- no user input is involved.
    KTBs = [ktb(Types, Binding) || Binding <- maps:get(form, EJson)],

    %% The values are typed in by the user, so convert them one by
    %% one. This way it is known which variable fails parsing.
    KTVs = 
        [try {Key, {Tag, Types:decode(TB)}}
         catch {type, Err} -> throw({bad_value, Key, Err}) end
         || {Key,{Tag,_}=TB} <- KTBs],
    KTVs.


%% FIXME: move spa_edit.erl input parser code here.

    
ws_bc() ->
    %% Start if not started, but make sure it is not linked.
    BC = serv:up(ws_bc, {spawner, fun serv:bc_start/0}),
    unlink(BC),
    BC.

%% Note that this is only a snapshot.  Pids can be invalid, and new
%% connections might have appeared by the time the Pids are used.  In
%% general it i safer to use uni-directional messages using the
%% broadcaster combined with some ad-hoc continuation passing.
pids() ->
    #{ pids := Pids } = obj:dump(ws_bc()),
    maps:keys(Pids).

%% For debugging:
%% Append &id=... when opening the page.

%% The identifier passed in can then be used in this function to find
%% the corresponding Erlang websocket process.

%%  This function assumes:
%% - The websocket processes understands the obj.erl protocol
%% - The 'query' field contains a map with query values
%% - The query values contain an 'id' field
%%
%% Note that it is possible that there are multiple clients.  Caller
%% should take care of that, so we just return the list here.

find(ID) when is_atom(ID) ->
    find(atom_to_binary(ID,utf8));
find(ID) when is_binary(ID) ->
    lists:flatten(
      lists:map(
        fun(Pid) ->
                try
                    {ok, Qv} = obj:find(Pid, query),
                    {ok, ID} = maps:find(id, Qv),
                    [Pid]
                catch
                    _:_ -> []
                end
        end,
        pids())).
    
    
                 
     

%% Ask all websockets to reload
reload_all() ->
    _ = ws_bc() ! {broadcast, #{ type => reload }}, ok.
reload(Ws) ->
    Ws !  #{ type => reload }, ok.

%% Encode/decode for tunneling through JSON, cookies, embedded JS,
%% URLs, ...  Use base64 encoding.
hmac_encode(GetKey,Obj) ->
    Bin = term_to_binary(Obj),
    Hmac = hmac(GetKey,Bin),
    base64:encode(term_to_binary({Bin,Hmac})).
hmac_decode(GetKey,Base64) ->
    {Bin,Hmac} = erlang:binary_to_term(base64:decode(Base64),[safe]),
    case hmac(GetKey,Bin) of
        Hmac  -> {ok, erlang:binary_to_term(Bin)};
        Hmac1 -> {error, {hmac_fail, Hmac, Hmac1}}
    end.
hmac(GetKey,Bin) when is_binary(Bin) -> 
    crypto:hmac(sha256,GetKey(),Bin).


%% By default, use a key that's generated once per session.  Failed
%% keys will cause websocket processes to die, disconnecting socket
%% which causes client to reconnect.  To change key, kill the process.
gen_hmac_key() ->
    crypto:strong_rand_bytes(32).

hmac_key() ->
    Pid = serv:up(
            hmac_key,
            {handler,
             fun() -> #{ key => gen_hmac_key() } end,
             fun obj:handle/2}),
    unlink(Pid),
    obj:get(Pid, key).
hmac_encode(X) -> hmac_encode(fun hmac_key/0, X).
hmac_decode(X) -> hmac_decode(fun hmac_key/0, X).



%% Encode calls to ws.js code.  Likely you want to export this
%% somewhere, e.g. in an app.js module, and prefix the calls with
%% "app.".
js_start(CB) ->
    tools:format_binary("start('~s')", [cb_encode(CB)]).
js_send_input(CB) ->
    tools:format_binary("send_input('~s', this)", [cb_encode(CB)]).
js_send_input_form(CB, Name) ->
    tools:format_binary("send_input('~s', document.forms['~s'])", [cb_encode(CB), Name]).
js_send_event(CB) ->
    tools:format_binary("send_event('~s', event)",[cb_encode(CB)]).

%% The above relies on ws.js
%% The below creates raw js code that can be inlined without use of ws.js


%% Create a websocket connection without relying on ws.js
js_start_nolib(Init) when is_map(Init)  ->
    js_start_nolib(ws:hmac_encode(fun() -> {ok, Init} end));
js_start_nolib(StartArgs) when is_binary(StartArgs) ->
[<<"
ws = new WebSocket('ws://' + location.host + '/ws');
ws.onopen = function() {
    var msg = { type: 'ws_start', args: '">>,StartArgs,<<"' };
    ws.send(JSON.stringify(msg));
}
ws.onmessage = function(msg) {
    var cmd = JSON.parse(msg.data);
    console.log(cmd);
    if (cmd.type == 'reload') {
        window.location.reload(true);
    }                             
}
">>].



%% See ws_action handler above.
cb_encode(handle) -> <<>>;
cb_encode(CB)-> hmac_encode(CB).


 
  
    



%% Forward message to supervisor's child by name.
to_child(Sup, Child, Msg) when is_atom(Child) ->
    lists:foreach(
      fun({C,Pid,_,_}) -> 
              if C == Child -> Pid ! Msg;
                 true -> ok
              end
      end,
      supervisor:which_children(Sup)).
    

widgets(Ws) ->
    case obj:find(Ws, supervisor) of
        {ok, Sup} ->
            maps:from_list(
              [{Id,Pid} || {Id,Pid,_,_} <- supervisor:which_children(Sup)]);
        _ ->
            #{}
    end.
    
    
    
    
    

%% Sup:      supervisor Pid
%% FormList: already decoded using application's type serializer
to_children(Sup, FormList) ->
    Child = form_destination(FormList),
    to_child(Sup, Child, FormList).


%% Find out where this needs to go by inspecting the key of the first
%% element in the form.

   
%% Awkward due to legacy multi-entry "form" format.  We're likely
%% never going to run into the general case.  So just handle the
%% special case for now.
form_destination([{{Path, _SubKey}, _Val} | _Rest]) when is_atom(Path) -> Path.
    



%% The problem here is routing of events.  One approach that seems to
%% work is to prefix all relevant identifiers using a supervis



         

%% Footnotes

%% 1. This mini-framework was constructed from the idea that embedded
%%    closures are a good general purpose construct.  It appears so,
%%    but for some applications such closures are overkill.  Often it
%%    makes more sense to have a single, centralized event handler.
%%
%% 2. Some hoop jumping is necessary to allow an initial page to be
%%    rendered before the websocket process is up.  This can be
%%    avoided by not rendering anything at all, and building up the
%%    page using websocket calls entirely.
