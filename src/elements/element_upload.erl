-module(element_upload).
-behaviour(gen_server).
-include_lib("wf.hrl").
-include_lib("kernel/include/file.hrl").
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-compile(export_all).
-record(state, {ctl_id, name, mimetype, data= <<>>, root="", dir="", delegate, room, post_write, img_tool, width=200, height=200, target}).

init([Init]) ->
  case file:open(filename:join([Init#state.root, Init#state.dir, Init#state.name]), [raw, binary, write]) of
    {ok, D} -> file:close(D), {ok, Init}; {error, enoent} -> {ok, Init}; {error, enotdir} -> {ok, Init}; {error, R} -> {stop, R}
  end.
handle_call({deliver_slice, Data}, _F, S) ->
  OldData = S#state.data,
  NewData = <<OldData/binary, Data/binary>>,
  {reply, {upload, erlang:byte_size(NewData)}, S#state{data=NewData}}.
handle_cast(complete, S) ->
  File = filename:join([S#state.root,S#state.dir,S#state.name]),
  Data = S#state.data,
  case S#state.delegate of
    undefined ->
      filelib:ensure_dir(File),
      file:write_file(File, Data, [write, raw]),
      case S#state.post_write of
        undefined-> ok;
        Api ->
          error_logger:info_msg("post write defined! ~p", [Api]),
          case S#state.img_tool of
            undefined -> Thumb = "";
            M ->
              Dir = filename:dirname(File),
              Ext = filename:extension(File),
              Name = filename:basename(File, Ext),
              Thumb = filename:join([Dir, "thumbnail", Name++"_thumb"++Ext]),
              filelib:ensure_dir(Thumb),
              M:make_thumb(File, S#state.width, S#state.height, Thumb)
          end,
          wf:wire(wf:f("~s({preview: '~s', id:'~s', file:'~s', type:'~s', thumb:'~s'});", [Api, S#state.target, hash(File), File, S#state.mimetype, Thumb])), wf:flush(S#state.room)
      end;
    Module -> Module:control_event(S#state.ctl_id,
      {S#state.root, S#state.dir, S#state.name, S#state.mimetype, Data, S#state.room, S#state.post_write, S#state.img_tool, S#state.target})
  end,
  {stop, normal, #state{}}.
handle_info(_Info, S) -> {noreply, S}.
terminate(R, S) ->
  case R of
    normal -> ok; shutdown -> ok; {shutdown, _T} -> ok;
    _E -> wf:wire(wf:f("$(#~s).trigger('error', '~s')", [S#state.ctl_id, "Server error"])), wf:flush(S#state.room)
  end.
code_change(_, S, _) -> {ok, S}.

render_element(#upload{id=Id} = R) ->
  Uid = case Id of undefined -> wf:temp_id(); I -> I end,
  wire(R#upload{id=Uid}), render(R#upload{id=Uid}).

render(#upload{id=Id} = R) ->
  wf_tags:emit_tag(<<"input">>, [], [
    {<<"id">>, Id},
    {<<"type">>, <<"file">>},
    {<<"class">>, R#upload.class},
    {<<"style">>, <<"display:none">>},
    {<<"name">>, R#upload.name}
  ]).

wire(#upload{id=Id} = R) ->
  case R#upload.post_write of undefined-> ok;  Api -> wf:wire(#api{name=Api, tag=postwrite}) end,

  wf:wire( wf:f("$(function(){ $('#~s').upload({"
    "preview: '~s',"
    "beginUpload: function(msg){~s},"
    "deliverSlice: function(msg){~s},"
    "queryFile: function(msg){~s},"
    "complete: function(msg){~s} }); });", [Id, atom_to_list(R#upload.preview)]++ [wf_event:generate_postback_script(Tag, ignore, Id, element_upload, control_event, <<"{'msg': msg}">>)
      || Tag <- [{begin_upload, R#upload.root, R#upload.dir, R#upload.delegate, R#upload.post_write, R#upload.img_tool, R#upload.post_target}, deliver_slice, {query_file, R#upload.root, R#upload.dir, R#upload.delegate_query}, complete]])).

control_event(Cid, Tag) ->
  Msg = wf:q(msg),
  Room = upload,
  {Event, Param} = case Msg of
    {'query', Name, MimeType} ->
      wf:reg(Room),
      case Tag of
        {query_file, Root, Dir, undefined} -> {exist, case file:read_file_info(filename:join([Root,Dir,binary_to_list(Name)])) of {ok, FileInfo} -> FileInfo#file_info.size; {error, _} -> 0 end};
        {query_file, Root, Dir, M} -> M:control_event(Cid, {query_file, Root, Dir, Name, MimeType});
        _ -> {error, "Server error: Wrong postback!"}
      end;
    {begin_upload, Name, MimeType} ->
      {begin_upload, Root, Dir, Delegate, Post, Tool, Target} = Tag,
      case gen_server:start(?MODULE, [#state{ctl_id=Cid, root=Root, dir=Dir, name=binary_to_list(Name), mimetype=MimeType, delegate=Delegate, room=Room, post_write=Post, img_tool=Tool, target=Target}], []) of
        {ok, Pid} -> {begin_upload, pid_to_list(Pid)}; {error, R} when is_atom(R) -> {error, atom_to_list(R)}; {error, R}-> {error, R} end;
    {upload, Pid, Data} -> gen_server:call(list_to_pid(binary_to_list(Pid)), {deliver_slice, Data});
    {complete, Pid} -> gen_server:cast(list_to_pid(binary_to_list(Pid)), complete), {complete, "skip"};
    M -> {error, M}
  end,
  wf:wire(wf:f("$('#~s').trigger('~p', [~p]);", [Cid, Event, Param])).

hash(Filename) ->
  {ok, Content} = file:read_file(Filename),
  <<Hash:160/integer>> = crypto:sha(Content),
  lists:flatten(io_lib:format("~40.16.0b", [Hash])).
