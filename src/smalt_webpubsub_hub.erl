%% smalt_webpubsub_hub.erl — ERL-2 pg-scoped WebPubSub hub (operator
%% reference architecture; coexists with the Elixir lib/smalt/webpubsub/
%% faces like the ERL-1 arm-router pattern).
%%
%% Packet-4 binary frame envelope — exact 41-byte layout:
%%
%%   << MAGIC:32, CRC32:32, Version:8, Flags:8, Seq:64,
%%      PayloadLen:8, Payload:PayloadLen/binary, Pad:0..22 >>
%%
%%   bytes 0..3   MAGIC  0x534D4C54 ("SMLT")
%%   bytes 4..7   CRC32  (ISO-HDLC, over bytes 8..40 — everything after
%%                        the CRC field itself)
%%   byte  8      Version = 4
%%   byte  9      Flags
%%   bytes 10..17 Seq    (big-endian unsigned)
%%   byte  18     PayloadLen (0..22)
%%   bytes 19..40 Payload + zero padding to exactly 41 bytes
%%
%% Any size/magic/version/CRC deviation is an ANDON refusal — the frame is
%% never journaled and never fan-outs.
%%
%% Journal + merkle receipt: ERL-1-style adapters ride in-module (named
%% ordered_set ETS journal; receipt = phash2 chain over prev-hash + seq +
%% CRC). pg carries group membership; fan-out message shape:
%%   {webpubsub_binary_frame, Group, Seq, PayloadBinary}
-module(smalt_webpubsub_hub).
-export([start/0, stop/0, join_group/2, leave_group/2, broadcast_frame/2,
         verify_frame/1, journal_size/0, journal_last/0, last_receipt/0,
         members/1]).
-export([encode_frame/3]).
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(MAGIC, 16#534D4C54).
-define(VERSION, 4).
-define(FRAME_BYTES, 41).
-define(PG_SCOPE, smalt_webpubsub_hub_pg).
-define(JTAB, smalt_webpubsub_journal).
-define(RTAB, smalt_webpubsub_receipts).

start() ->
    case whereis(?MODULE) of
        undefined ->
            {ok, _} = gen_server:start_link(
                        {local, ?MODULE}, ?MODULE, init, []),
            ok;
        _ ->
            {error, already_started}
    end.

stop() ->
    case whereis(?MODULE) of
        undefined -> ok;
        _ -> gen_server:stop(?MODULE), ok
    end.

%% == pg group membership ==============================================

join_group(Group, Pid) when is_atom(Group), is_pid(Pid) ->
    pg_join(Group, Pid).

leave_group(Group, Pid) when is_atom(Group), is_pid(Pid) ->
    pg_leave(Group, Pid).

members(Group) ->
    pg:get_members(?PG_SCOPE, Group).

%% == Packet-4 envelope ================================================

encode_frame(Seq, Flags, Payload) when
      is_integer(Seq), Seq >= 0, Seq =< 16#FFFFFFFFFFFFFFFF,
      is_integer(Flags), Flags >= 0, Flags =< 255,
      byte_size(Payload) =< 22 ->
    Body = <<?VERSION:8, Flags:8, Seq:64, (byte_size(Payload)):8,
             Payload/binary>>,
    PadBits = (22 - byte_size(Payload)) * 8,
    Frame = <<Body/binary, 0:PadBits>>,
    CRC = erlang:crc32(Frame),
    <<?MAGIC:32, CRC:32, Frame/binary>>.

%% verify_frame/1 -> {ok, #{seq => .., flags => .., payload => ..}}
%%                 | {error, bad_size | bad_magic | bad_version | bad_crc}
verify_frame(Frame) when is_binary(Frame) ->
    case Frame of
        <<?MAGIC:32, CRC:32, ?VERSION:8, Flags:8, Seq:64, Len:8,
          Payload:Len/binary, Pad/binary>> ->
            case byte_size(Frame) =:= ?FRAME_BYTES of
                false ->
                    {error, bad_size};
                true ->
                    case byte_size(Pad) =:= 22 - Len
                         andalso erlang:crc32(
                                   <<?VERSION:8, Flags:8, Seq:64, Len:8,
                                     Payload/binary, Pad/binary>>) =:= CRC of
                        true ->
                            {ok, #{seq => Seq, flags => Flags,
                                   payload => Payload}};
                        false ->
                            {error, bad_crc}
                    end
            end;
        <<?MAGIC:32, _/binary>> ->
            {error, bad_version};
        _ ->
            case byte_size(Frame) =:= ?FRAME_BYTES of
                true -> {error, bad_magic};
                false -> {error, bad_size}
            end
    end;
verify_frame(_) ->
    {error, bad_size}.

%% == broadcast + journal + merkle receipt =============================

broadcast_frame(Group, Frame) when is_atom(Group), is_binary(Frame) ->
    case verify_frame(Frame) of
        {error, Reason} ->
            %% ANDON: invalid frame refused loudly, nothing journaled,
            %% nothing fanned out
            {error, {andon, Reason}};
        {ok, #{seq := Seq, flags := _Flags, payload := Payload}} ->
            Receipt = journal_append(Seq, erlang:crc32(Frame), Frame),
            [Pid ! {webpubsub_binary_frame, Group, Seq, Payload}
             || Pid <- members(Group)],
            {ok, Receipt}
    end.

%% == journal + merkle receipt adapters (ERL-1 style, in-module) =======

journal_size() ->
    ets:info(?JTAB, size).

journal_last() ->
    ets:last(?JTAB).

last_receipt() ->
    case ets:lookup(?RTAB, latest) of
        [{latest, R}] -> {ok, R};
        [] -> {error, none}
    end.

%% == gen_server (owns ETS tables + pg scope) ==========================

init(init) ->
    process_flag(trap_exit, true),
    {ok, _} = pg:start_link(?PG_SCOPE),
    ets:new(?JTAB, [named_table, ordered_set, public,
                    {read_concurrency, true}]),
    ets:new(?RTAB, [named_table, set, public]),
    ets:insert(?RTAB, {latest, {merkle_receipt, 0, 0, 0}}),
    {ok, #{}}.

handle_call(_Req, _From, S) -> {reply, ok, S}.
handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Msg, S) -> {noreply, S}.
terminate(_Reason, _S) ->
    catch pg:stop(?PG_SCOPE),
    catch ets:delete(?JTAB),
    catch ets:delete(?RTAB),
    ok.
code_change(_Old, S, _Extra) -> {ok, S}.

%% -- internal ----------------------------------------------------------

journal_append(Seq, CRC, Frame) ->
    N = case ets:last(?JTAB) of
            '$end_of_table' -> 1;
            PrevN -> PrevN + 1
        end,
    {merkle_receipt, _N0, PrevHash, _H0} = current_receipt(),
    Hash = erlang:phash2([PrevHash, Seq, CRC, Frame]),
    R = {merkle_receipt, N, PrevHash, Hash},
    ets:insert(?JTAB, {N, Seq, CRC, Frame}),
    ets:insert(?RTAB, {latest, R}),
    R.

current_receipt() ->
    case ets:lookup(?RTAB, latest) of
        [{latest, R}] -> R;
        [] -> {merkle_receipt, 0, 0, 0}
    end.

pg_join(Group, Pid) ->
    case pg:join(?PG_SCOPE, Group, Pid) of
        ok -> ok;
        {'EXIT', _} -> exit({pg_scope_down, ?PG_SCOPE})
    end.

pg_leave(Group, Pid) ->
    pg:leave(?PG_SCOPE, Group, Pid).
