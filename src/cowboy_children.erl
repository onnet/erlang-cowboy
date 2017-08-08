%% Copyright (c) 2017, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(cowboy_children).

-export([init/0]).
-export([up/4]).
-export([down/2]).
-export([shutdown/2]).
-export([shutdown_timeout/3]).
-export([terminate/1]).
-export([which_children/2]).
-export([count_children/1]).

-record(child, {
	pid :: pid(),
	streamid :: cowboy_stream:streamid() | undefined,
	shutdown :: timeout(),
	timer = undefined :: undefined | reference()
}).

-type children() :: [#child{}].
-export_type([children/0]).

-spec init() -> [].
init() ->
	[].

-spec up(Children, pid(), cowboy_stream:streamid(), timeout())
	-> Children when Children::children().
up(Children, Pid, StreamID, Shutdown) ->
	[#child{
		pid=Pid,
		streamid=StreamID,
		shutdown=Shutdown
	}|Children].

-spec down(Children, pid())
	-> {ok, cowboy_stream:streamid() | undefined, Children} | error
	when Children::children().
down(Children0, Pid) ->
	case lists:keytake(Pid, #child.pid, Children0) of
		{value, #child{streamid=StreamID, timer=Ref}, Children} ->
			_ = case Ref of
				undefined -> ok;
				_ -> erlang:cancel_timer(Ref, [{async, true}, {info, false}])
			end,
			{ok, StreamID, Children};
		false ->
			error
	end.

%% We ask the processes to shutdown first. This gives
%% a chance to processes that are trapping exits to
%% shut down gracefully. Others will exit immediately.
%%
%% @todo We currently fire one timer per process being
%% shut down. This is probably not the most efficient.
%% A more efficient solution could be to maintain a
%% single timer and decrease the shutdown time of all
%% processes when it fires. This is however much more
%% complex, and there aren't that many processes that
%% will need to be shutdown through this function, so
%% this is left for later.
-spec shutdown(Children, cowboy_stream:streamid())
	-> Children when Children::children().
shutdown(Children0, StreamID) ->
	[
		case Child of
			#child{pid=Pid, streamid=StreamID, shutdown=Shutdown} ->
				exit(Pid, shutdown),
				Ref = erlang:start_timer(Shutdown, self(), {shutdown, Pid}),
				Child#child{streamid=undefined, timer=Ref};
			_ ->
				Child
		end
	|| Child <- Children0].

-spec shutdown_timeout(children(), reference(), pid()) -> ok.
shutdown_timeout(Children, Ref, Pid) ->
	case lists:keyfind(Pid, #child.pid, Children) of
		#child{timer=Ref} ->
			exit(Pid, kill),
			ok;
		_ ->
			ok
	end.

-spec terminate(children()) -> ok.
terminate(Children) ->
	%% Ask all children to shutdown first.
	_ = [exit(Pid, shutdown) || #child{pid=Pid} <- Children],
	%% Loop until that time or until all children are dead.
	before_terminate_loop(Children).

before_terminate_loop([]) ->
	ok;
before_terminate_loop(Children) ->
	%% Find the longest shutdown time.
	Time = longest_shutdown_time(Children, 0),
	%% We delay the creation of the timer if one of the
	%% processes has an infinity shutdown value.
	TRef = case Time of
		infinity -> undefined;
		_ -> erlang:start_timer(Time, self(), terminate)
	end,
	terminate_loop(Children, TRef).

terminate_loop([], _) ->
	ok;
terminate_loop(Children, TRef) ->
	receive
		{'EXIT', Pid, _} when TRef =:= undefined ->
			{value, #child{shutdown=Shutdown}, Children1}
				= lists:keytake(Pid, #child.pid, Children),
			%% We delayed the creation of the timer. If a process with
			%% infinity shutdown just ended, we might have to start that timer.
			case Shutdown of
				infinity -> before_terminate_loop(Children1);
				_ -> terminate_loop(Children1, TRef)
			end;
		{'EXIT', Pid, _} ->
			terminate_loop(lists:keydelete(Pid, #child.pid, Children), TRef);
		{timeout, TRef, terminate} ->
			%% Brutally kill any remaining children.
			_ = [exit(Pid, kill) || #child{pid=Pid} <- Children],
			ok
	end.

longest_shutdown_time([], Time) ->
	Time;
longest_shutdown_time([#child{shutdown=ChildTime}|Tail], Time) when ChildTime > Time ->
	longest_shutdown_time(Tail, ChildTime);
longest_shutdown_time([_|Tail], Time) ->
	longest_shutdown_time(Tail, Time).

-spec which_children(children(), module()) -> [{module(), pid(), worker, [module()]}].
which_children(Children, Module) ->
	[{Module, Pid, worker, [Module]} || #child{pid=Pid} <- Children].

-spec count_children(children()) -> [{atom(), non_neg_integer()}].
count_children(Children) ->
	Count = length(Children),
	[
		{specs, 1},
		{active, Count},
		{supervisors, 0},
		{workers, Count}
	].
