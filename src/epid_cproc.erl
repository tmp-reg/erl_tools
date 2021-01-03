%% Instantiate an epid_app subgraph as a set of C macro invocations.
%% Generic code.  See exo_patch.erl for specific code.

%% Example of a manually coded C fragment that uses mod_cproc.c from
%% uc_tools
%%
%% uint32_t in = hw_gpio_read(IN);
%% PROC(in_edge,       /*=*/ proc_edge, in);
%% PROC(in_edge_count, /*=*/ proc_acc,  in_edge.out);
%% if (in_edge.out) {
%%     infof("count = %d\n", in_edge_count);
%% }

%% FIXME: I'm going to implement this in lab_board.erl first.

-module(epid_cproc).
-export([example/0, code/3, handle_epid_compile/2]).


example() ->
    LocalPid = local_pid,
    Env = #{
      13 => {input,#{in => {epid,'A',1}}},
      14 => {input,#{in => {epid,'B',2}}},
      15 => {count,#{in => {epid,LocalPid,14}}},
      16 => {count,#{in => {epid,LocalPid,13}}}
     },
    Reduced = epid_dag:internalize(LocalPid, Env),
    Code = code(Reduced, [16], #{}),
    log:info("Reduced:~n~p~nCode:~n~s", [Reduced, Code]),
    ok.


    
    
%% This generates let.h syntax for mod_cproc.c conventions.
%%
%% Note that inputs are named to stick with the assumption throughout
%% that epid_app inputs are named.  The PROC() macro uses an array
%% initializer to implement this.  We do what is convenient; constant
%% propagation is left to the C compiler.
%%
%% The counterpart to this is connect external epids to internal ones,
%% and then forward them over TAG_U32 to the C code.

i(I) -> integer_to_list(I).
a(A) -> atom_to_list(A).

ref(A) when is_atom(A) -> a(A); %% FIXME: perform some validation here
ref(I) when is_integer(I) -> i(I).
    

code(Reduced, Outputs, SubGraph) ->
    sink:gen_to_list(
      fun(Sink) ->
              W = fun(D) -> Sink({data, D}) end,
              code(W, Reduced, Outputs, SubGraph),
              Sink(eof)
      end).

code(W, _Reduced = #{ inputs := Inputs, procs := Procs }, Outputs, SubGraph) ->
    EInputs = tools:enumerate(Inputs),
    NbInputs = length(EInputs),
    InputIndex = maps:from_list([{N,I} || {I,{N,_}} <- EInputs]),
    %% Header
    W(["// generated by epid_cproc.erl\n",
       "#define CPROC_NB_INPUTS ", i(NbInputs), "\n",
       "#include \"mod_cproc_plugin.c\"\n"]),
    %% Config parameter definitions
    lists:foreach(
      fun({Node, {Proc, _InNodes}}) ->
              config_def(W, Node, Proc),
              params_def(W, Node, Proc)
      end,
      Procs),
    %% Function body: let clauses and output clauses.
    W(["void cproc_update(w *input, w g) {\n"]),
    lists:foreach(
      fun({OutNode, {Proc, InNodes}}) -> let_clause(W, OutNode, Proc, InNodes, InputIndex, SubGraph) end,
      Procs),
    lists:foreach(
      fun(Output) -> W([tab(),"cproc_output(",i(Output),", ","n",i(Output),".out",");\n"]) end,
      Outputs),
    W("}\n").

struct_def(W, Node, ProcName, ProcParams, StorageClass, PostFix) ->
    W([StorageClass, a(ProcName),PostFix," ",
       "n",i(Node),PostFix," = { "]),
    
    lists:foreach(
      fun({ParamName, ParamValue}) ->
              W([".", a(ParamName), " = ",
                 ref(ParamValue),", "])
      end,
      maps:to_list(ProcParams)),
    W(["};\n"]).

config_def(W, Node, _Proc = #{ name := ProcName, config := ProcParams }) ->
    struct_def(W, Node, ProcName, ProcParams, "static const ", "_config");
config_def(_,_,_) -> ok.

params_def(W, Node, _Proc = #{ name := ProcName, params := ProcParams }) ->
    struct_def(W, Node, ProcName, ProcParams, "", "_params");
params_def(_,_,_) -> ok.


tab() ->
    "    ".

cond_bitvec(List) ->
    lists:foldl(
      fun(Bit,Acc) -> Acc + 1 bsl Bit end,
      0, List).
%% b(N) -> io_lib:format("~32.2.0B",[N]).
b(N) -> io_lib:format("0b~.2.0B",[N]).

let_clause(W, OutNode, ProcMeta = #{name :=ProcName}, InNodes, InputIndex, SubGraph) ->
    W([tab(),
       %% FIXME: SubGraph should contain a sensitivity vector
       %% wrt. inputs, for each node, to generate the guards for
       %% PROC_COND.  Currently it still contains a dependency list.

       %% Arg1 subgraph mask
       case SubGraph of
           synchronous -> "PROC(";
           _ -> ["PROC_COND(g&", b(cond_bitvec(maps:get(OutNode, SubGraph))), ", "]
       end,
       %% Arg2 instance name
       "n", i(OutNode), ", ",
       %% Arg3 processor name
       a(ProcName),", ",
       %% Arg4 static configuration
       case maps:find(config, ProcMeta) of
           {ok, _} -> ["&n", i(OutNode), "_config"];
           error   -> "NULL"
       end,
       ", ",
       %% Arg5 dynamic parameter
       case maps:find(params, ProcMeta) of
           {ok, _} -> ["&n", i(OutNode), "_params"];
           error   -> "NULL"
       end
      ]),
    %% Arg 6+ dataflow inputs.
    lists:foreach(
      fun({InName, InNode}) ->
              W([", .", a(InName), " = ",
                 %% Dereference input nodes.
                 case maps:find(InNode, InputIndex) of
                     {ok, Index} -> ["input[", i(Index), "]"];
                     error       -> ["n", i(InNode), ".out"]
                 end])
      end,
      maps:to_list(InNodes)),
    W(");\n").



%% This is used in conjunction with handle_epid_app/2 and
%% handle_epid_kill/2 from epid_app.  

%% See example in lab_board.erl, it uses delegates like this:
%% handle(Msg={_, {epid_app, _, _}},  State) -> epid_app:handle_epid_app(Msg, State);
%% handle(Msg={_, {epid_kill, _}},    State) -> epid_app:handle_epid_kill(Msg, State);
%% handle(Msg={_, {epid_compile, _}}, State) -> update_plugin(epid_cproc:handle_epid_compile(Msg, State));

handle_epid_compile({Caller, {epid_compile, Cmd}}, State = #{ epid_env := Env }) ->
    obj:reply(Caller, ok),
    case Cmd of
        clear ->
            State;
        commit ->
            %% The dag representation can be reduced by splitting
            %% inputs and internal nodes.
            DAG = epid_dag:internalize(self(), Env),

            %% Compute the "evented" subgraphs, encoded as a map from
            %% node number to indexed input, to be used in clause
            %% gating.
            Subgraphs = epid_dag:subgraphs(DAG),

            %% The DAG representation gets mapped to two things: input
            %% buffer mapping and C code.
            #{ inputs := Inputs, procs := Procs } = DAG,

            %% C code knows the input index mapping, so we can use
            %% just that to make the connections.
            epid_dag:connect_inputs(Inputs),
            
            Outputs = epid_dag:outputs(Procs, State),

            Code = code(DAG, Outputs, Subgraphs),
            %% log:info("DAG:~n~p~nCode:~n~s", [DAG, Code]),

            %% FIXME: It's not necessary to keep these intermedates.
            %% Just pass them as values.
            maps:merge(
              State,
              #{ code => Code,
                 dag  => DAG })
    end.
