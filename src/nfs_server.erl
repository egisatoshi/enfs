%%%----------------------------------------------------------------------
%%% File    : nfs_server.erl
%%% Author  : Luke Gorrie <luke@bluetail.com>
%%% Purpose : Extensible NFS v2 (RFC 1094) server core
%%% Created : 22 Jun 2001 by Luke Gorrie <luke@bluetail.com>
%%%----------------------------------------------------------------------

-module(nfs_server).
-author('luke@bluetail.com').

-behaviour(gen_server).

-include("nfs.hrl").

%% External exports
-export([add_mountpoint/3]).
-export([debug/1]).

-export([start/0]).
-export([start_link/0,start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, 
	 terminate/2, code_change/3]).

-export([behaviour_info/1]).

-define(dbg(F,A),
	case get(debug) of
	    true -> io:format("~s:~w "++(F)++"\n",[?MODULE,?LINE|(A)]);
	    _ -> ok
	end).
%% -define(dbg(F,A), ok).

-define(NFS_PORT,    22049).	  %% normal port + 20000
-define(MOUNTD_PORT, 22050).	  %% arbitrary
-define(KLM_PORT,    22045).      %% normal + 20000

%% NFS identifies files by a "file handle", which is a fixed-length
%% opaque binary. This program's file handles look like this:
%%
%%   <<FileID:32, FilesystemID:32, _Junk/binary>>
%%
%% We have bi-directional mappings to identify which erlang module
%% implements each file system, and which term represents each file
%% id.

%% These tables are mappings. fh_id_tab maps file handles onto
%% identifying terms, etc.
-define(fh_id_tab,    nfs_fh_id).         %% FileID   => FH
-define(id_fh_tab,    nfs_id_fh).         %% FH       => FileID
-define(lock_fh_tab,  nfs_lock_fh).       %% FH       => Lock
-define(fsid_mod_tab, nfs_fsid_mod).      %% FSID     => Module
-define(misc_tab,     nfs_misc).          %% counters

%% fattr modes
-define(MODE_DIR,     8#0040000).
-define(MODE_CHAR,    8#0020000).
-define(MODE_BLOCK,   8#0060000).
-define(MODE_REGULAR, 8#0100000).
-define(MODE_SYMLINK, 8#0120000).
-define(MODE_SOCKET,  8#0140000).
-define(MODE_SETUID,  8#0004000).
-define(MODE_SETGID,  8#0002000).
-define(MODE_SV_SWAP, 8#0001000).	% "Save swapped text even after use."
-define(MODE_UR,      8#0000400).
-define(MODE_UW,      8#0000200).
-define(MODE_UX,      8#0000100).
-define(MODE_GR,      8#0000040).
-define(MODE_GW,      8#0000020).
-define(MODE_GX,      8#0000010).
-define(MODE_OR,      8#0000004).
-define(MODE_OW,      8#0000002).
-define(MODE_OX,      8#0000001).

-record(mount_ent,
	{
	  path,   %% mount path
	  mod,    %% backend mod
	  opts,   %% backend options
	  root,   %% root file handle
	  fsid    %% current fsid
	}).

-record(state, {
	  fh_suffix,        %% filehandle suffix in use
	  mountpoints = [] :: [#mount_ent{}],
	  locals :: dict()  %% dict: fsid -> localstate()
	 }).

-record(lock, {
	  exclusive = false :: boolean(),
	  rs = [] :: [{Owner::integer(),Offset::integer(),Len::integer()}]
	 }).

-spec behaviour_info(Arg::callbacks) -> 
			    list({FunctionName::atom(), Arity::integer()}).
behaviour_info(callbacks) ->
    [{init, 1},        %% {rootid,state0}
     {terminate,1},    %% void
     {getattr, 2},     %% fhandle
     {setattr, 3},     %% sattrargs
     {lookup,  3},     %% diropargs
     {readlink, 2},    %% fhandle
     {read,    5},     %% readargs
     {write,   6},     %% write
     {create,4},       %% createargs
     {remove,3},       %% diropargs
     {rename,5},       %% renameargs
     {link,4},         %% linkargs
     {symlink,5},      %% symlinkargs
     {mkdir,4},        %% createargs
     {rmdir,3},        %% diropargs
     {readdir, 3},     %% readdirargs
     {statfs, 2}       %% fhandle
    ];
behaviour_info(_) ->
    undefined.

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

start() ->
    application:start(nfs_server).

start_link() ->
    start_link([]).

start_link(Args) ->
    gen_server:start_link({local, nfs_server}, nfs_server, Args, []).

debug(On) when is_boolean(On) ->
    gen_server:call(?MODULE, {debug, On}).

add_mountpoint(Path, Module, Opts) ->
    gen_server:call(?MODULE, {add_mountpoint, Path, Module, Opts}).

%% @private
start_mountd() ->
    {ok, _Pid} = rpc_server:start_link({local, nfs_mountd},
				       [{udp, any, ?MOUNTD_PORT, false, []}],
				       ?MOUNTPROG,
				       mountprog,
				       ?MOUNTVERS,
				       ?MOUNTVERS,
				       nfs_svc,
				       do_init).

%% @private
start_nfsd() ->
    {ok, _Pid} = rpc_server:start_link({local, nfs_rpc_nfsd},
				       [{udp, any, ?NFS_PORT, false, []}],
				       ?NFS_PROGRAM,
				       nfs_program,
				       ?NFS_VERSION,
				       ?NFS_VERSION,
				       nfs_svc,
				       []).

%% @private
start_klm() ->
    {ok, _Pid} = rpc_server:start_link({local, nfs_klm},
 				       [{udp, any, ?KLM_PORT, false, []}],
 				       ?KLM_PROG,
 				       klmprog,
 				       ?KLM_VERS,
 				       ?KLM_VERS,
 				       nfs_svc,
 				       []).

%%%----------------------------------------------------------------------
%%% Callback functions from gen_server
%%%----------------------------------------------------------------------

init(Args0) ->
    Args = Args0 ++ application:get_all_env(enfs),
    put(debug, proplists:get_bool(debug, Args)),
    ?dbg("starting args=~w", [Args]),
    start_mountd(),
    start_nfsd(),
    %% start_klm(),  NOT YET
    ets:new(?fh_id_tab,    [named_table, public, set]),
    ets:new(?id_fh_tab,    [named_table, public, set]),
    ets:new(?lock_fh_tab,  [named_table, public, set]),
    ets:new(?fsid_mod_tab, [named_table, public, set]),
    ets:new(?misc_tab,     [named_table, public, set]),
    ets:insert(?misc_tab,  {next_fsid, 0}),
    ?dbg("init done", []),
    {ok, #state{ fh_suffix = make_suffix(),
		 mountpoints=[],
		 locals=dict:new() }}.

handle_call(Req, From, State) ->
    ?dbg("call: ~p", [Req]),
    Res = handle_call_(Req, From, State),
    case Res of
	{reply,_Value,_State1} ->
	    ?dbg("call_result: ~p\n", [_Value]);
	_Other ->
	    ?dbg("call_result: other=~p\n", [_Other])
    end,
    Res.

%% ----------------------------------------------------------------------
%% MOUNTPROC
%% ----------------------------------------------------------------------

handle_call_({mountproc_null_2, _Client}, _From, State) ->
    {reply, void, State};

handle_call_({mountproc_mnt_1, PathBin, _Client}, _From, State) ->
    Path = binary_to_list(PathBin),
    Es0 = State#state.mountpoints,
    case lists:keytake(Path, #mount_ent.path, Es0) of
	false ->
	    {reply, {1, void}, State};
	{value,Ent = #mount_ent { opts=Opts, mod=Mod, root=undefined },Es1} ->
	    case callback(Mod, init, [Opts]) of
		{error,_} ->
		    {reply, {1, void}, State};
		{Root,Loc} ->
		    FSID = new_fsid(Mod),
		    {ok, RootFH} = id2fh(Root, FSID, State),
		    Ent1 = Ent#mount_ent { root=RootFH, fsid=FSID },
		    Locals1 = dict:store(FSID,Loc,State#state.locals),
		    State1 = State#state { mountpoints = [Ent1 | Es1],
					   locals = Locals1 },
		    {reply, {0, RootFH}, State1}
	    end;
	{value,#mount_ent { root=Fh },_} ->
	    {reply, {0, Fh}, State}
    end;

handle_call_({mountproc_umnt_1, PathBin, _Client}, _From, State) ->
    ?dbg("unmount directory ~p", [PathBin]),
    Path = binary_to_list(PathBin),
    Es0 = State#state.mountpoints,
    case lists:keytake(Path, #mount_ent.path, Es0) of
	false ->
	    {reply, void, State};
	{value,Ent = #mount_ent { mod=Mod,root=RootFh,fsid=FSID }, Es1} ->
	    if RootFh =/= undefined ->
		    MState = dict:fetch(FSID, State#state.locals),
		    callback(Mod, terminate, [MState]),
		    Ent1 = Ent#mount_ent { root=undefined, fsid=undefined },
		    Locals1 = dict:erase(FSID, State#state.locals),
		    State1 = State#state { mountpoints = [Ent1 | Es1],
					   locals = Locals1 },
		    {reply, void, State1};
	       true ->
		    {reply, void, State}
	    end
    end;

handle_call_({mountproc_umntall_1, _Client}, _From, State) ->
    S1 = 
	lists:foldl(
	  fun(E, Si) ->
		  FSID = E#mount_ent.fsid,
		  if FSID =/= undefined ->
			  MState = dict:fetch(FSID, State#state.locals),
			  Mod = E#mount_ent.mod,
			  callback(Mod, terminate, [MState]),
			  Locals1 = dict:erase(FSID, Si#state.locals),
			  Si#state { locals = Locals1 };
		     true ->
			  Si
		  end
	  end, State, State#state.mountpoints),
    Ms = lists:map(
	   fun(E) ->
		   E#mount_ent { root=undefined, fsid=undefined }
	   end, State#state.mountpoints),
    {reply, void, S1#state { mountpoints = Ms }};

handle_call_({mountproc_export_1, _Client}, _From, State) ->
    ?dbg("export/all", []),
    Ent = export_entries(State#state.mountpoints),
    {reply, Ent, State};

%% ----------------------------------------------------------------------
%% NFSPROC
%% ----------------------------------------------------------------------

handle_call_({nfsproc_null_2, _Client}, _From, State) ->
    {reply, {nfs_stat(ok), void}, State};

handle_call_({nfsproc_getattr_2, FH, _Client}, _From, State) ->
    R = nfsproc_getattr(fh_arg(FH,State), State),
    {reply, R, State};

handle_call_({nfsproc_setattr_2, {FH, Attrs}, _Client}, _From, State) ->
    R = nfsproc_setattr(fh_arg(FH,State), Attrs, State),
    {reply, R, State};    

%% Obsolte (rfc1094)
handle_call_({nfsproc_root_2, _Client}, _From, State) ->
    {reply, void, State};

handle_call_({nfsproc_lookup_2, {DirFH, NameBin}, _C}, _From, State) ->
    R = nfsproc_lookup(fh_arg(DirFH,State), string_arg(NameBin), State),
    {reply, R, State};

handle_call_({nfsproc_readlink_2, FH,_C},
	     _From,State) ->
    R = nfsproc_readlink(fh_arg(FH,State), State),
    {reply, R, State};

handle_call_({nfsproc_read_2, {FH, Offset, Count, TotalCount},_C},
	     _From,State) ->
    R = nfsproc_read(fh_arg(FH,State),Offset,Count,TotalCount,State),
    {reply, R, State};

%% just decribed to be implemented in the future ?
handle_call_({nfsproc_writecache_2, _Client}, _From, State) ->
    {reply, void, State};

handle_call_({nfsproc_write_2, {FH, BeginOffset, Offset, TotalCount, Data},_C},
	     _From,State) ->
    R = nfsproc_write(fh_arg(FH,State), BeginOffset, Offset, 
		      TotalCount, Data, State),    
    {reply, R, State};

handle_call_({nfsproc_create_2, {{DirFH, NameBin},Attr}, _Client},
	     _From, State) ->
    R = nfsproc_create(fh_arg(DirFH,State),string_arg(NameBin),Attr,State),
    {reply, R, State};

handle_call_({nfsproc_remove_2, {DirFH, NameBin}, _Client},_From, State) ->
    R = nfsproc_remove(fh_arg(DirFH,State),string_arg(NameBin), State),
    {reply, R, State};

handle_call_({nfsproc_rename_2,{{DirFromFH,FromBin},{DirToFH,ToBin}},_Client},
	     _From, State) ->
    R = nfsproc_rename(fh_arg(DirFromFH,State),string_arg(FromBin),
		       fh_arg(DirToFH,State),string_arg(ToBin),State),
    {reply, R, State};

handle_call_({nfsproc_link_2,{FromFH,ToFH,ToNameBin},_Client},
	     _From, State) ->
    R = nfsproc_link(fh_arg(FromFH,State),
		     fh_arg(ToFH,State),string_arg(ToNameBin),State),
    {reply, R, State};

handle_call_({nfsproc_symlink_2,{FromFH,FromNameBin,ToPathBin,SAttr},_Client},
	     _From, State) ->
    R = nfsproc_symlink(fh_arg(FromFH,State),
			string_arg(FromNameBin),
			string_arg(ToPathBin),SAttr,State),
    {reply, R, State};

handle_call_({nfsproc_mkdir_2, {{DirFH, NameBin},Attr}, _Client},
	     _From, State) ->
    R = nfsproc_mkdir(fh_arg(DirFH,State),
		      string_arg(NameBin), Attr, State),
    {reply, R, State};

handle_call_({nfsproc_rmdir_2, {DirFH, NameBin}, _Client},_From, State) ->
    R = nfsproc_rmdir(fh_arg(DirFH,State),
		      string_arg(NameBin), State),
    {reply, R, State};

handle_call_({nfsproc_readdir_2, {FH, Cookie, Count}, _Client},
	    _From,
	    State) ->
    R = nfsproc_readdir(fh_arg(FH,State), Cookie, Count, State),
    {reply, R, State};

handle_call_({nfsproc_statfs_2, FH, _C}, _From, State) ->
    R = nfsproc_statfs(fh_arg(FH,State), State),
    {reply, R, State};

%% 
%%  klm_testrply	KLM_TEST (klm_testargs)
%%
handle_call_({klm_test_1,TestArgs,_Client}, _From, State) ->
    {_Exclusive,Lock} = TestArgs,
    {_ServerName,FH,Pid,L_Offset,L_Len} = Lock,
    Range = {Pid,L_Offset,L_Len},
    R = case ets:lookup(?lock_fh_tab, FH) of
	    [] ->
		{reply, void, State};
	    [L] ->
		%% FIXME: check more cases 
		case find_lock(Range,L#lock.rs) of
		    false ->
			{reply, void, State};
		    {Pid,_Offset,_Len} -> %% Pid is owner
			{reply, void, State};
		    {_Pid1,Offset,Len} ->
			Holder = {L#lock.exclusive,Pid,Offset,Len},
			{denied,Holder}
		end
	end,
    {reply, R, State};

%%
%%  klm_stat KLM_LOCK (klm_lockargs)
%%
handle_call_({klm_lock_1,LockArgs,_Client}, _From, State) ->
    {_Block,Exclusive,Lock} = LockArgs,
    {_ServerName,FH,Pid,L_Offset,L_Len} = Lock,
    Range = {Pid,L_Offset,L_Len},
    R = case ets:lookup(?lock_fh_tab, FH) of
	    [] ->
		L = #lock { exclusive=Exclusive, rs = [Range]},
		ets:insert(?lock_fh_tab, {FH,L}),
		{reply, 'klm_granted', State};
	    [L] when L#lock.rs =:= [] ->
		L = #lock { exclusive=Exclusive, rs = [Range]},
		ets:insert(?lock_fh_tab, {FH,L}),
		{reply, 'klm_granted', State};
	    [L] when L#lock.exclusive ->		
		case L#lock.rs of
		    [{Pid,_,_}|_] ->
			L1 = L#lock { rs = [Range | L#lock.rs] },
			ets:insert(?lock_fh_tab, {FH,L1}),
			{reply, 'klm_granted', State};
		    [_|_] ->
			{reply, 'klm_denied', State}
		end;
	    [L] -> %% shared
		case find_lock(Range,L#lock.rs) of
		    false ->
			L1 = L#lock { rs = [Range | L#lock.rs] },
			ets:insert(?lock_fh_tab, {FH,L1}),
			{reply, 'klm_granted', State};
		    {Pid,_Offs,_Len} -> %% allow overlap from same owner
			L1 = L#lock { rs = [Range | L#lock.rs] },
			ets:insert(?lock_fh_tab, {FH,L1}),
			{reply, 'klm_granted', State};
		    {_Pid1,_Offs1,_Len1} ->
			{reply, 'klm_denied', State}
		end
	end,
    {reply, R, State};

%%
%%  klm_stat KLM_CANCEL (klm_lockargs)
%%
handle_call_({klm_cancel_1,_KlmLockArgs,_Client}, _From, State) ->
    %% FIXME
    {reply, 'klm_granted', State};

%%
%%  klm_stat KLM_UNLOCK (klm_unlockargs)
%%
handle_call_({klm_unlock_1,KlmUnLockArgs,_Client}, _From, State) ->
    {_ServerName,FH,Pid,L_Offset,L_Len} = KlmUnLockArgs,
    Range = {Pid,L_Offset,L_Len},
    R = case ets:lookup(?lock_fh_tab, FH) of
	    [] -> {reply, 'klm_denied_nolock', State};
	    [L] ->
		case remove_matching_locks(Range, L#lock.rs) of
		    {0,_Rs} -> %% nothing removed
			{reply, 'klm_denied_nolock', State};
		    {_N,Rs1} ->
			L1 = L#lock { rs = Rs1},
			ets:insert(?lock_fh_tab, {FH,L1}),
			{reply, 'klm_granted', State}
		end
	end,
    {reply, R, State};

%% Local calls
handle_call_({add_mountpoint, Path, Mod, Opts}, _From, State) ->
    ?dbg("adding mount point=~p,mod=~p,opts=~p", [Path,Mod,Opts]),
    Ent = #mount_ent { path=Path, mod=Mod, opts=Opts },
    Ms = [Ent|State#state.mountpoints],
    {reply, ok, State#state{ mountpoints=Ms }};

handle_call_({debug, On}, _From, State) ->
    put(debug, On),
    {reply, ok, State};

handle_call_(Request, _From, State) ->
    io:format("Undefined callback: ~p~n", [Request]),
    Reply = {error, nocallback},
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    ?dbg("handle_cast got ~p\n", [_Msg]),
    {noreply, State}.

%% we may get {tcp_new,Sock} and {tcp_close,Sock} here ?
handle_info(_Info, State) ->
    ?dbg("handle_info got ~p\n", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

%%
%%    attrstat NFSPROC_GETATTR(fhandle)
%%
nfsproc_getattr({FH,ID,Mod,Loc}, _State) ->
    case callback(Mod, getattr, [ID,Loc]) of
	{ok, As} -> 
	    {nfs_stat(ok),make_fattr(FH,As)};
	{error,Error} ->
	    {nfs_stat(Error), void}
    end;
nfsproc_getattr(error, _State) ->
    {nfs_stat(estale), void}.

%%
%% attrstat NFSPROC_SETATTR(sattrargs)
%%
nfsproc_setattr({FH,ID,Mod,Loc}, Attrs, _State) ->
    case callback(Mod, setattr, [ID,Attrs,Loc]) of
	ok ->
	    case callback(Mod, getattr, [ID,Loc]) of
		{ok, As} -> 
		    {nfs_stat(ok),make_fattr(FH,As)};
		{error,Error} ->
		    {nfs_stat(Error), void}
	    end;
	{error, Error} ->
	    {nfs_stat(Error), void}
    end;
nfsproc_setattr(error, _Attrs, _State) ->
    {nfs_stat(estale), void}.
%%
%%  diropres NFSPROC_LOOKUP(diropargs)
%%
nfsproc_lookup({DirFH,DirID,Mod,Loc}, Name, State) ->
    case callback(Mod, lookup, [DirID,Name,Loc]) of
	{error, Error} ->
	    {nfs_stat(Error), void};
	{ok, ChildID} ->
	    {ok, ChildFH} = id2fh(ChildID,fh2fsid(DirFH),State),
	    case callback(Mod, getattr, [ChildID,Loc]) of
		{ok, As} -> 
		    {nfs_stat(ok),{ChildFH,make_fattr(ChildFH,As)}};
		{error, Error} ->
		    {nfs_stat(Error), void}
	    end
    end;
nfsproc_lookup(error, _NameBin, _State) ->
    {nfs_stat(estale), void}.
%%
%% readlinkres NFSPROC_READLINK(fhandle)
%%
nfsproc_readlink({_FH,ID,Mod,Loc}, _State) ->
    case callback(Mod, readlink, [ID,Loc]) of
	{ok, Path} ->
	    {nfs_stat(ok),erlang:iolist_to_binary(Path)};
	{error, Reason} ->
	    {nfs_stat(Reason), void}
    end;
nfsproc_readlink(error, _State) ->
    {nfs_stat(estale), void}.
%%
%% readres NFSPROC_READ(readargs)          = 6;
%%
nfsproc_read({FH,ID,Mod,Loc},Offset,Count,TotalCount,_State) ->
    case callback(Mod, read, [ID,Offset,Count,TotalCount,Loc]) of
	{ok, IOList} ->
	    case callback(Mod, getattr, [ID,Loc]) of
		{ok, As} ->
		    Data = erlang:iolist_to_binary(IOList),
		    {nfs_stat(ok), {make_fattr(FH,As),Data}};
		{error, Error} ->
		    {nfs_stat(Error), void}
	    end;
	{error, Reason} ->
	    {nfs_stat(Reason), void}
    end;
nfsproc_read(error,_Offset,_Count,_TotalCount,_State) ->
    {nfs_stat(estale), void}.
%%
%% attrstat NFSPROC_WRITE(writeargs);
%%
nfsproc_write({FH,ID,Mod,Loc}, BeginOffset, Offset, 
	      TotalCount, Data, _State) ->
    case callback(Mod, write, [ID,BeginOffset,Offset,TotalCount,
			       Data,Loc]) of
	ok ->
	    case callback(Mod, getattr, [ID,Loc]) of
		{ok, As} ->
		    {nfs_stat(ok), make_fattr(FH,As)};
		{error, Error} ->
		    {nfs_stat(Error), void}
	    end;
	{error, Reason} ->
	    {nfs_stat(Reason), void}
    end;
nfsproc_write(error, _BeginOffset, _Offset, _TotalCount, _Data, _State) ->
    {nfs_stat(estale), void}.

%%
%%   diropres NFSPROC_CREATE(createargs)
%%

nfsproc_create({DirFH,DirID,Mod,Loc},Name,Attr,State) ->
    case callback(Mod, create, [DirID, Name, Attr, Loc]) of
	{ok, ChildID} ->
	    {ok, ChildFH} = id2fh(ChildID,fh2fsid(DirFH),State),
	    case callback(Mod, getattr, [ChildID,Loc]) of
		{ok, As} ->
		    {nfs_stat(ok), {ChildFH, make_fattr(ChildFH,As)}};
		{error, Error} ->
		    {nfs_stat(Error), void}
	    end;
	{error, Error} ->
	    {nfs_stat(Error), void}
    end;
nfsproc_create(error,_Name,_Attr,_State) ->
    {nfs_stat(estale), void}.
%%
%%  stat NFSPROC_REMOVE(diropargs)
%%

nfsproc_remove({_DirFH,DirID,Mod,Loc}, Name, _State) ->
    case callback(Mod, remove, [DirID, Name, Loc]) of
	{error, Error} ->
	    nfs_stat(Error);
	ok ->
	    nfs_stat(ok)
    end;
nfsproc_remove(error, _Name, _State) ->
    nfs_stat(estale).

%%
%% stat NFSPROC_RENAME(renameargs)
%%
nfsproc_rename({_DirFromFH,DirFromID,Mod,Loc},From,
	       {_DirToFH,DirToID,Mod,Loc},To,_State) ->
    case callback(Mod, rename, [DirFromID,From,DirToID,To,Loc]) of
	{error, Error} ->
	    nfs_stat(Error);
	ok ->
	    nfs_stat(ok)
    end;
nfsproc_rename(error,_,_TArg,_To,_State) ->
    nfs_stat(estale);
nfsproc_rename(_FArg,_From, error,_To,_State) ->
    nfs_stat(estale);
nfsproc_rename(_FArg,_From,_TArg,_To, _State) ->
    %% probably a mod mismatch, different filesystems
    nfs_stat(enodev).
%%
%%   stat NFSPROC_LINK(linkargs)
%%
nfsproc_link({_FromFH,FromID,Mod,Loc},
	     {_ToFH,ToID,Mod,Loc},ToName,_State) ->
    case callback(Mod, link, [FromID,ToID,ToName,Loc]) of
	{error, Error} ->
	    nfs_stat(Error);
	ok ->
	    nfs_stat(ok)
    end;
nfsproc_link(error,_TArg,_To,_State) ->
    nfs_stat(estale);
nfsproc_link(_FArge,error,_To,_State) ->
    nfs_stat(estale);
nfsproc_link(_, _, _To, _State) ->
    %% probably a mod mismatch, different filesystems
    nfs_stat(enodev).
%%
%% stat NFSPROC_SYMLINK(symlinkargs)
%%
nfsproc_symlink({_FromFH,FromID,Mod,Loc},FromName,ToPath,SAttr,_State) ->
    case callback(Mod, symlink, [FromID,FromName,ToPath,SAttr,Loc]) of
	{error, Error} ->
	    nfs_stat(Error);
	ok ->
	    nfs_stat(ok)
    end;
nfsproc_symlink(error,_,_,_SAttr,_State) ->
    nfs_stat(estale).
%%
%% diropres NFSPROC_MKDIR(createargs)
%%
nfsproc_mkdir({DirFH,DirID,Mod,Loc}, Name, Attr, State) ->
    case callback(Mod, mkdir, [DirID, Name, Attr, Loc]) of
	{error, Error} ->
	    {nfs_stat(Error), void};
	{ok, ChildID} ->
	    {ok, ChildFH} = id2fh(ChildID,fh2fsid(DirFH),State),
	    case callback(Mod, getattr, [ChildID,Loc]) of
		{ok, As} ->
		    {nfs_stat(ok), {ChildFH, make_fattr(ChildFH,As)}};
		{error, Error} ->
		    {nfs_stat(Error), void}
	    end
    end;
nfsproc_mkdir(error,_Name,_Attr,_State) ->
    {nfs_stat(estale), void}.
%%
%% stat NFSPROC_RMDIR(diropargs)
%%
nfsproc_rmdir({_DirFH,DirID,Mod,Loc}, Name, _State) ->
    case callback(Mod, rmdir, [DirID,Name,Loc]) of
	{error, Error} ->
	    nfs_stat(Error);
	ok ->
	    nfs_stat(ok)
    end;
nfsproc_rmdir(error, _Name, _State) ->
    nfs_stat(estale).
%%
%% readdirres NFSPROC_READDIR(readdirargs)
%%

nfsproc_readdir({FH,ID,Mod,Loc}, <<Cookie:32/integer>>, Count, State) ->
    %% FIXME: handle big count + continuation
    case callback(Mod, readdir, [ID,Count,Loc]) of
	{error, ErrCode} ->
	    {nfs_stat(ErrCode), void};
	{ok, Names} ->
	    Entries = entries(Mod,fh2fsid(FH),ID,Names,
			      Loc,State,Cookie),
	    {nfs_stat(ok), {Entries, true}}
    end;
nfsproc_readdir(error, _CookieBin,_Count,_State) ->
    {nfs_stat(estale), void}.

%%
%% statfsres NFSPROC_STATFS(fhandle)
%%
nfsproc_statfs({_FH,ID,Mod,Loc}, _State) ->
    case callback(Mod, statfs, [ID,Loc]) of
	{ok, Res = {_Tsize, _Bsize, _Blocks, _Bfree, _Bavail}} ->
	    {nfs_stat(ok), Res};
	{error, Reason} ->
	    {nfs_stat(Reason), void}
    end;
nfsproc_statfs(error,_State) ->
    {nfs_stat(estale), void}.

%% fh -> id,mod,state
fh_arg(FH, State) ->
    case fh2id(FH) of
	{ok, ID} ->
	    Mod = fh2mod(FH),
	    Loc  = fh2local(FH,State),
	    {FH,ID,Mod,Loc};
	error ->
	    error
    end.

string_arg(Bin) when is_binary(Bin) ->
    binary_to_list(Bin).

	
callback(Mod, Func, Args) ->
    ?dbg("callback ~s:~s ~p\n", [Mod,Func,Args]),
    Res = (catch apply(Mod,Func,Args)),
    case Res of
	{'EXIT',Rsn} ->
	    io:format("Error in ~s: ~p~n", [Func,Rsn]),
	    {error, eio};
	_ ->
	    ?dbg("result = ~p\n", [Res]),
	    Res
    end.


entries(_Mod,_FSID,_DirID,[],_MState,_State,_N) ->
    void;
entries(Mod,FSID,DirID,[H|T],MState,State,N) ->
    Next = N+1,
    case callback(Mod,lookup,[DirID,H,MState]) of
	{ok, ID} ->
	    {id2fileid(ID,FSID,State),	% fileid
	     H,				% name
	     <<Next:32/integer>>,		% cookie
	     entries(Mod,FSID,DirID,T,MState,State,Next)	% nextentry
	    };
	{error, _Error} ->
	    %% just skip this one
	    entries(Mod,FSID,DirID,T,MState,State,Next)
    end.

export_entries([]) ->
    void;
export_entries([#mount_ent{path=Path}|Es]) ->
    Groups = void,  %% fixme
    {erlang:iolist_to_binary(Path),
     Groups,
     export_entries(Es)}.


make_suffix() ->
    SufBits = (32 - 8) * 8,
    {A,B,C} = now(),
    S0 = A,
    S1 = (S0 * 1000000) + B,
    S2 = (S1 * 1000000) + C,
    <<S2:SufBits/integer>>.


id2fileid(ID,FSID,State) ->
    {ok, FH} = id2fh(ID,FSID,State),
    fh2fileid(FH).

id2fh(ID,FSID,State) ->
    case ets:lookup(?id_fh_tab, ID) of
	[{_, FH}] -> {ok, FH};
	[] -> {ok, new_fh(ID,FSID,State)}
    end.

new_fh(ID,FSID,State) ->
    Suf  = State#state.fh_suffix,
    N    = ets:update_counter(?misc_tab,{next_fileid,FSID},1),
    FH = <<N:32/integer, FSID:32/integer, Suf/binary>>,
    ets:insert(?id_fh_tab, {ID, FH}),
    ets:insert(?fh_id_tab, {FH, ID}),
    FH.

%% fetch local backend state
fh2local(<<_FileID:32/integer, FSID:32/integer, _Pad/binary>>,State) ->
    dict:fetch(FSID, State#state.locals).

fh2mod(<<_FileID:32/integer, FSID:32/integer, _Pad/binary>>) ->
    ets:lookup_element(?fsid_mod_tab, FSID, 2).

fh2fileid(<<FileID:32/integer, _FSID:32/integer, _Pad/binary>>) ->
    FileID.

fh2fsid(<<_:32/integer, FSID:32/integer, _/binary>>) ->
    FSID.

fh2id(FH) ->
    case ets:lookup(?fh_id_tab, FH) of
	[{_, ID}] ->
	    {ok, ID};
	[] ->
	    error
    end.

new_fsid(Mod) when is_atom(Mod) ->
    FSID = ets:update_counter(?misc_tab, next_fsid, 1),
    ets:insert(?misc_tab,     {{next_fileid,FSID}, 0}),
    ets:insert(?fsid_mod_tab, {FSID, Mod}),
    FSID.


%% ----------------------------------------------------------------------
%% File attributes
%% ----------------------------------------------------------------------

%% List of file attributes, some which have defaults.
-record(fattr,{
	  type  = 'NFNON',
	  mode  = 0,
	  nlink = 1,
	  uid   = 0,
	  gid   = 0,
	  size  = 0,
	  blocksize = 1024,
	  rdev = 0,
	  blocks = 1,
	  fsid,
	  fileid,
	  atime = {0,0},
	  mtime = {0,0}, 
	  ctime = {0,0}
	 }).

%% Make an fattr (file attributes) struct. Opts is a dictionary of
%% values we're interested in setting (see fattr_spec/0 below for
%% available options).
make_fattr(FH,Opts) ->
    F0 = #fattr { fsid = fh2fsid(FH), fileid = fh2fileid(FH) },
    F = make_fattr_list(Opts,F0),
    list_to_tuple(tl(tuple_to_list(F))).

make_fattr_list([], F) -> F;
make_fattr_list([{Opt,Value}|Opts], F) ->
    F1 = set_fattr(Opt,Value,F),
    make_fattr_list(Opts, F1).

set_fattr(type,Value,F) ->
    F#fattr { type = fattr_type(Value),
	      mode = fattr_mode(Value) bor F#fattr.mode
	    };
set_fattr(mode,Value,F) ->
    F#fattr { mode = fattr_mode(Value) bor F#fattr.mode };
set_fattr(nlink,Value,F) -> F#fattr { nlink = Value };
set_fattr(uid,Value,F)   -> F#fattr { uid = Value };
set_fattr(gid,Value,F)   -> F#fattr { gid = Value };
set_fattr(size,Value,F)  -> F#fattr { size = Value };
set_fattr(blocksize,Value,F) -> F#fattr { blocksize = Value };
set_fattr(rdev,Value,F)   -> F#fattr { rdev = Value };
set_fattr(blocks,Value,F) -> F#fattr { blocks = Value };
set_fattr(fsid,Value,F)   -> F#fattr { fsid = Value };
set_fattr(fileid,Value,F) -> F#fattr { fileid = Value };
set_fattr(atime,Value,F)  -> F#fattr { atime = Value };
set_fattr(mtime,Value,F)  -> F#fattr { mtime = Value }; 
set_fattr(ctime,Value,F)  -> F#fattr { ctime = Value }.



fattr_type(none)      -> 'NFNON';
fattr_type(regular)   -> 'NFREG';
fattr_type(directory) -> 'NFDIR';
fattr_type(device)    -> 'NFCHR';
fattr_type(block)     -> 'NFBLK';
fattr_type(symlink)   -> 'NFLNK';
fattr_type(socket)    -> 'NFSOCK';
fattr_type(fifo)      -> 'NFFIFO';
fattr_type(_)         -> 'NFBAD'.


fattr_mode(regular)   -> ?MODE_REGULAR;
fattr_mode(directory) -> ?MODE_DIR;
fattr_mode(device)    -> ?MODE_CHAR;
fattr_mode(block)     -> ?MODE_BLOCK;
fattr_mode(symlink)   -> ?MODE_SYMLINK;
fattr_mode(socket)    -> ?MODE_SOCKET;
fattr_mode(setuid)    -> ?MODE_SETUID;  %% FIX
fattr_mode(setgid)    -> ?MODE_SETGID;  %% FIX
fattr_mode({U,G,O})   ->
    ((access(U) bsl 6) bor (access(G) bsl 3) bor access(O));
fattr_mode(Mode) when is_integer(Mode) ->
    Mode.

access([x|A]) -> ?MODE_OX bor access(A);
access([w|A]) -> ?MODE_OW bor access(A);
access([r|A]) -> ?MODE_OR bor access(A);
access([]) -> 0.

find_lock({Pid,Offset,Length},Rs) ->
    find_lock_(Pid,Offset,Offset+Length-1,Rs).

find_lock_(Pid,P1,P2,[R1={_Pid1,P3,L3}|Rs]) ->
    X1 = max(P1,P3),
    X2 = min(P2,P3+L3-1),
    if X1 > X2 -> find_lock_(Pid,P1,P2,Rs);
       true -> R1
    end;
find_lock_(_Pid,_P1,_P2,[]) ->
    false.

remove_matching_locks({Pid,Offset,Length}, Rs) ->
    remove_matching_locks_(Pid,Offset,Offset+Length-1,Rs,0,[]).

remove_matching_locks_(Pid,P1,P2,[R1={Pid1,P3,L3}|Rs],N,Acc) ->
    X1 = max(P1,P3),
    X2 = min(P2,P3+L3-1),
    if X1 > X2 ->
	    remove_matching_locks_(Pid,P1,P2,Rs,N,[R1|Acc]);
       Pid =:= Pid1 ->
	    remove_matching_locks_(Pid,P1,P2,Rs,N+1,Acc);
       true ->
	    remove_matching_locks_(Pid,P1,P2,Rs,N,[R1|Acc])
    end;
remove_matching_locks_(_Pid,_P1,_P2,[],N,Acc) ->
    {N,Acc}.



nfs_stat(ok)   -> 'NFS_OK';	                %% no error
nfs_stat(eperm) -> 'NFSERR_PERM';		%% Not owner
nfs_stat(enoent) -> 'NFSERR_NOENT';		%% No such file or directory
nfs_stat(eio) -> 'NFSERR_IO';		        %% I/O error
nfs_stat(enxio) -> 'NFSERR_NXIO';		%% No such device or address
nfs_stat(eacces) -> 'NFSERR_ACCES';             %% Permission denied
nfs_stat(eexist) -> 'NFSERR_EXIST';	        %% File exists
nfs_stat(enodev) -> 'NFSERR_NODEV';	        %% No such device
nfs_stat(enotdir) -> 'NFSERR_NOTDIR';	        %% Not a directory
nfs_stat(eisdir) -> 'NFSERR_ISDIR';	        %% Is a directory
nfs_stat(efbig)	-> 'NFSERR_FBIG';		%% File too large
nfs_stat(enospc) -> 'NFSERR_NOSPC';	        %% No space left on device
nfs_stat(erofs)	-> 'NFSERR_ROFS';		%% Read-only file system
nfs_stat(enametoolong)-> 'NFSERR_NAMETOOLONG';	%% File name too long
nfs_stat(enotempty) -> 'NFSERR_NOTEMPTY';	%% Directory not empty
nfs_stat(edquot) -> 'NFSERR_DQUOT';	        %% Disc quota exceeded
nfs_stat(estale) -> 'NFSERR_STALE';	        %% Stale NFS file handle
nfs_stat(wflush) -> 'NFSERR_WFLUSH';	        %% write cache flushed
nfs_stat(timeout) -> 'NFSERR_IO';	        %% timeout as I/O error

%% ssh_xfer errors 
nfs_stat(no_such_file)           -> nfs_stat(enoent);
nfs_stat(permission_denied)	 -> nfs_stat(eperm);
nfs_stat(failure)                -> nfs_stat(eio);
nfs_stat(bad_message)            -> nfs_stat(eio);
nfs_stat(no_connection)          -> nfs_stat(eio);
nfs_stat(connection_lost)        -> nfs_stat(eio);
nfs_stat(op_unsupported)         -> nfs_stat(enxio);
nfs_stat(invalid_handle)         -> nfs_stat(estae);
nfs_stat(no_such_path)           -> nfs_stat(enoent);
nfs_stat(file_already_exists)    -> nfs_stat(eexist);
nfs_stat(write_protect)          -> nfs_stat(eacces);
nfs_stat(no_media)               -> nfs_stat(enxio);
nfs_stat(no_space_on_filesystem) -> nfs_stat(enospc);
nfs_stat(quota_exceeded)         -> nfs_stat(edquot);
nfs_stat(unknown_principle)      -> nfs_stat(eio);
nfs_stat(lock_conflict)          -> nfs_stat(eio);
nfs_stat(not_a_directory)        -> nfs_stat(enotdir);
nfs_stat(file_is_a_directory)    -> nfs_stat(eisdir);
nfs_stat(cannot_delete)          -> nfs_stat(eacces);
nfs_stat(eof)                    -> nfs_stat(eio);
nfs_stat(_)                      -> nfs_stat(eio).

