-module(mod_group_sender).

-author('KGermanovKS@mail.ru').

-behaviour(gen_server).

%%-behaviour(gen_mod).

%% API
-export([start_link/2, start/2, stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3]).

-include("ejabberd.hrl").

-include("jlib.hrl").

-record(state, {
                host = <<"">> :: binary(),
                table
               }).

-define(PROCNAME, ejabberd_mod_group_sender).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE,
                            [Host, Opts], []).

start(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec = {Proc, {?MODULE, start_link, [Host, Opts]},
                       temporary, 1000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, stop),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc),
    ok.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Host, _Opts]) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    State = #state{host = Host, table = ets:new(Proc, [])},
    initMapGroups(State),
    ejabberd_router:register_route( atom_to_list(?MODULE) ), %% NOTE: register to Domain
    {ok, State}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
%%handle_call({filter, {From, To, Packet} }, _FromProc, State) ->
%%    ?DEBUG("Handle: from:~p to:~p msg:~p", [From, To, Packet]),
%%    Group = To#jid.server,
%%    ?DEBUG("Handle: to:~p group:~p", [To, Group]),
%%    {reply, Packet, State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Req, _From, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) -> {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({route, From, To, Packet}, State) ->
    Group = To#jid.user,
    ?DEBUG("Handle: to:~p group:~p", [To, Group]),
    case ets:lookup(State#state.table, Group) of
       [{Group, ListMembers}] ->
            lists:foreach( fun( {User, Domain} ) -> ejabberd_router:route( From, 
                                                                           To#jid{user = User, server = Domain, luser = User, lserver = Domain},
                                                                           Packet)
                           end, 
                           ListMembers);
       Error ->
            ?ERROR_MSG("No find for ~p records. error:~p", [To, Error])
    end,
    {noreply, State};
handle_info(_Info, State) -> {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
    ListAll = ets:tab2list(State#state.table),
    lists:foreach( fun( {Route, _Members} ) -> 
                        ejabberd_router:unregister_route(Route) 
                   end,
                   ListAll),
    ets:delete( State#state.table ),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%--------------------------------------------------------------------
%%                    Internal functions
%%--------------------------------------------------------------------
initMapGroups(#state{} = State) ->
    Host = State#state.host,
    ListGroups = mod_shared_roster:list_groups(Host),
    ?INFO_MSG("Groups:~p", [ListGroups]),
    lists:foreach( fun(G) -> addGroup(State, G, mod_shared_roster:get_group_users(Host, G) ) end, ListGroups),
    addGroup(State, "all", getAllUsers(Host) ).

getAllUsers(Host)->
    lists:map( fun(User) -> {User, Host} end, ejabberd_admin:registered_users(Host) ).

addGroup(#state{} = State, Group, ListMembers)->
    ?INFO_MSG("Try add to group:~p members:~p", [Group, ListMembers]),
    ets:insert(State#state.table, {Group, ListMembers}).