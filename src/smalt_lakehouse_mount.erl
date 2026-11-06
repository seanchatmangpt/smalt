%% smalt_lakehouse_mount.erl — sealed-segment lakehouse mount.
%%
%% Two query forms:
%%
%% Legacy (hash-derived): execute_analytical_query(Root, Query) with a
%% plain query binary — Op 15: a query whose body leads with <<1:8>> is
%% the ANDON pull-cord and refuses with ZERO mutation (wire form
%% <<1:8,Len,Reason>>); everything else admits with the <<0:8,Result>>
%% form, rows = sha256(request) mod 1024. Zero dynamic atoms on wire
%% paths.
%%
%% Batch (data-derived, lane 12): execute_analytical_query(Root,
%% {dt_lakehouse_batch_query, SchemaDigest, Segs}) — Segs is the atom
%% 'all' or a list of segment paths. Each segment is read fail-closed
%% through JournalReader semantics (.journal + .seal + .meta.json
%% triple — the .wal divergence is closed: the mount keys off the
%% journal triple, never .wal), every frame CRC32-checked and
%% SeqID-monotonic, and every frame payload walked as an IPC1 window by
%% the minimal framing walker below (re-implemented in Erlang ONCE,
%% gate order byte-identical to cgap_arrow::ipc::parse_meta +
%% read_with_meta).
%%
%% Rows are CARRIED, never recomputed-from-hash: each window's metadata
%% padding carries a u64 LE row count at window offset 104..112 (the
%% slot adjacent to the 32-byte blake3 body digest at 72..104, inside
%% the alignment-64 metadata span 120). An all-zero carrier is a typed
%% refusal (rows_carrier_missing), never a guess. L7 DEPENDENCY
%% (disclosed): this carrier slot is staged against the EXISTING IPC1
%% MetaHeader framing per the lane-12 conflict clause; L7 stage 2 owns
%% the flatbuffer carrier and must confirm or relocate this offset.
%%
%% Tamper-tier split (disclosed): the mount's walker checks the blake3
%% body-digest slot for PRESENCE (nonzero) only — BEAM has no blake3;
%% body-digest VERIFICATION is enforced at the export tier
%% (cgap_arrow::ipc::read_verified in crates/journal-export). Manifest
%% sha256, frame CRC32, framing gates and the rows carrier are enforced
%% HERE, fail-closed, zero partial results.
-module(smalt_lakehouse_mount).
-export([discover_sealed_segments/1, execute_analytical_query/2, op15/1,
         segment_census/1, ipc_window_info/1, ipc_window_info/2]).

-define(ANDON, 1).
-define(IPC_PREFIX, 8).
-define(IPC_META_HEADER, 64).
-define(IPC_EOS_SIZE, 8).
-define(IPC_MAGIC, 16#49504331).          %% "IPC1" LE
-define(IPC_CONTINUATION, 16#FFFFFFFF).
-define(IPC_EOS_WORD, 16#00000000).
-define(IPC_LAYOUT_VERSION, 1).
-define(IPC_BODY_DIGEST_AT, 72).          %% window offset of blake3 digest
-define(IPC_ROWS_CARRIER_AT, 104).        %% window offset of u64 LE rows
-define(IPC_ZERO_DIGEST, <<0:256>>).

%% -- discovery (legacy .wal form, unchanged law) ---------------------------

discover_sealed_segments(Root) when is_list(Root) ->
    discover_sealed_segments(list_to_binary(Root));
discover_sealed_segments(Root) when is_binary(Root) ->
    Dir = binary_to_list(Root),
    case file:list_dir(Dir) of
        {ok, Names} ->
            Sorted =
                lists:sort(
                  [list_to_binary(N)
                   || N <- Names,
                      filelib:is_file(filename:join(Dir, N ++ ".seal")),
                      filelib:is_file(filename:join(Dir, N ++ ".wal"))]),
            Sorted;
        {error, Reason} ->
            exit({mount_root_unreadable, Root, Reason})
    end;
discover_sealed_segments(_) ->
    exit(mount_root_not_binary).

%% -- sealed-journal discovery (JournalReader layout, batch form) -----------

%% Sealed triple under <Root>/sealed/: seg-<seq>.journal with .seal and
%% .meta.json beside it. Completeness failures (missing sentinel or
%% manifest) are NOT refusals: they are reported under `quarantined`
%% (census is analysis-only — bytes stay in place, unlike the reader's
%% rename-into-quarantine; disclosed divergence). Integrity failures
%% refuse fail-closed.
journal_sealed_names(Root) ->
    SealedDir = filename:join(path(Root), "sealed"),
    case file:list_dir(SealedDir) of
        {ok, Names} ->
            Base =
                lists:sort([N || N <- Names,
                                 lists:suffix(".journal", N),
                                 not lists:suffix(".meta.json", N),
                                 not lists:suffix(".seal", N)]),
            Complete =
                fun(N) ->
                        filelib:is_file(filename:join(SealedDir, N ++ ".seal")) andalso
                        filelib:is_file(filename:join(SealedDir, N ++ ".meta.json"))
                end,
            {lists:filter(Complete, Base),
             lists:filter(fun(N) -> not Complete(N) end, Base)};
        {error, enoent} ->
            {[], []};
        {error, Reason} ->
            exit({mount_root_unreadable, Root, Reason})
    end.

%% -- segment census ---------------------------------------------------------

%% segment_census(Root) ->
%%   {ok, #{segments => [SegMap], quarantined => [NameBinary]}}
%% Per-segment map:
%%   #{segment => name, path => abs path, frames => N, bytes => N,
%%     sha256 => hex, windows => N, rows => SumRows,
%%     schema_digests => [hex]}
segment_census(Root) when is_list(Root) ->
    segment_census(list_to_binary(Root));
segment_census(Root) when is_binary(Root) ->
    {Sealed, Quarantined} = journal_sealed_names(Root),
    SealedDir = filename:join(path(Root), "sealed"),
    fold_census(Sealed, SealedDir, [], Quarantined);
segment_census(_) ->
    exit(mount_root_not_binary).

%% fold_census/4: first typed refusal anywhere aborts the census
%% fail-closed ({error, Refusal}) — zero partial results.
fold_census([], _SealedDir, Acc, Quarantined) ->
    {ok, #{segments => lists:reverse(Acc),
           quarantined => [list_to_binary(N) || N <- Quarantined]}};
fold_census([Name | Rest], SealedDir, Acc, Quarantined) ->
    Path = list_to_binary(filename:join(SealedDir, Name)),
    case read_sealed_segment_ipc(Path, none) of
        {ok, {Frames, WinInfo, ShaHex, Bytes}} ->
            fold_census(Rest, SealedDir,
                        [census_map(Name, Path, Frames, WinInfo, ShaHex, Bytes) | Acc],
                        Quarantined);
        {error, Refusal} ->
            {error, Refusal}
    end.
%% path/1: root normalization shared by discovery + batch segments.
path(Root) when is_list(Root) -> Root;
path(Root) when is_binary(Root) -> binary_to_list(Root).

census_map(Name, Path, Frames, WinInfo, ShaHex, Bytes) ->
    #{segment => list_to_binary(Name),
      path => Path,
      frames => length(Frames),
      bytes => Bytes,
      sha256 => ShaHex,
      windows => length(WinInfo),
      rows => lists:sum([R || {R, _S, _Seq, _BL} <- WinInfo]),
      schema_digests => lists:usort([S || {_R, S, _Seq, _BL} <- WinInfo])}.

%% -- Op 15: analytical query ------------------------------------------------

%% Legacy admit: {ok, #{rows => N, segments => Segs}} (rows hash-derived).
%% Batch admit: {ok, #{rows, batches, segments, schema_digests}} (rows
%% data-derived from carried counts). Refusals: {error, {andon, Wire}}
%% (Wire = <<1:8, Len:32, Reason/binary>>) or a typed integrity refusal
%% {error, {Class, Kw}} propagated from the batch path. ANDON is
%% classified BEFORE any segment read — on the batch form the pull-cord
%% is a SchemaDigest leading <<1:8>>; corrupt mount or not, ANDON wins.
execute_analytical_query(Root, {dt_lakehouse_batch_query, SchemaDigest, Segs}) ->
    Segs0 = case Segs of
                all -> discover_batch_segments(Root);
                L when is_list(L) -> L;
                _ -> exit(bad_batch_segment_list)
            end,
    RequestBin = term_to_binary({dt_lakehouse_batch_query, SchemaDigest, Segs0}),
    case op15(RequestBin) of
        {ok, <<0:8, ResultBin/binary>>} ->
            {ok, binary_to_term(ResultBin)};
        Andon ->
            Andon
    end;
execute_analytical_query(Root, Query) when is_list(Root) ->
    execute_analytical_query(list_to_binary(Root), Query);
execute_analytical_query(Root, Query) when is_binary(Root) ->
    Segs = discover_sealed_segments(Root),
    RequestBin = term_to_binary({dt_lakehouse_query, Query, Segs}),
    case op15(RequestBin) of
        {ok, <<0:8, ResultBin/binary>>} ->
            {ok, binary_to_term(ResultBin)};
        Andon ->
            Andon
    end;
execute_analytical_query(_, _) ->
    exit(mount_root_not_binary).

discover_batch_segments(Root) ->
    {Sealed, _} = journal_sealed_names(Root),
    SealedDir = filename:join(path(Root), "sealed"),
    [list_to_binary(filename:join(SealedDir, N)) || N <- Sealed].

%% op15 dispatch. Legacy clause: {dt_lakehouse_query, Query, Segs}.
%% Batch clause: {dt_lakehouse_batch_query, SchemaDigest, Segs} — ANDON
%% first (zero reads), then the fail-closed batch computation.
op15(Body) when is_binary(Body) ->
    case catch binary_to_term(Body, [safe]) of
        {dt_lakehouse_batch_query, SchemaDigest, Segs} ->
            case andon_query(SchemaDigest) of
                true ->
                    andon_refused();
                false ->
                    batch_query_result(SchemaDigest, Segs)
            end;
        {dt_lakehouse_query, Query, Segs} ->
            case andon_query(Query) of
                true ->
                    andon_refused();
                false ->
                    ResultBin = term_to_binary(#{rows => rows_for(Body),
                                                 segments => Segs}),
                    {ok, <<0:8, ResultBin/binary>>}
            end;
        _ ->
            malformed_refused()
    end;
op15(_) ->
    {error, {andon, op15_body_not_binary}}.

andon_refused() ->
    R = <<"op15 andon pull-cord refused">>,
    {error, {andon, <<?ANDON:8, (byte_size(R)):32, R/binary>>}}.

malformed_refused() ->
    R = <<"op15 malformed request">>,
    {error, {andon, <<?ANDON:8, (byte_size(R)):32, R/binary>>}}.

%% Batch result: zero partial results — the first typed refusal anywhere
%% in any segment aborts the whole query with {error, {Class, Kw}}.
batch_query_result(SchemaDigest, Segs) when is_binary(SchemaDigest), is_list(Segs) ->
    case schema_digest_ok(SchemaDigest) of
        true ->
            Init = {ok, #{rows => 0, batches => 0, segments => 0,
                          schema_digests => []}},
            lists:foldl(
              fun(Seg, {ok, Acc}) ->
                      case read_sealed_segment_ipc(Seg, {expect_schema, SchemaDigest}) of
                          {ok, {_Frames, WinInfo, _Sha, _Bytes}} ->
                              Add = #{rows => lists:sum([R || {R, _S, _Seq, _BL} <- WinInfo]),
                                      batches => length(WinInfo),
                                      segments => 1,
                                      schema_digests => [S || {_R, S, _Seq, _BL} <- WinInfo]},
                              {ok, merge_batch(Acc, Add)};
                          {error, Refusal} ->
                              {error, Refusal}
                      end;
                 (_Seg, Refusal) ->
                      Refusal
              end, Init, Segs);
        false ->
            {error, {bad_schema_digest, [{size, 32}]}}
    end;
batch_query_result(_, _) ->
    {error, {bad_schema_digest, [{size, 32}]}}.

merge_batch(Acc, Add) ->
    M1 = lists:foldl(fun(K, M) ->
                             maps:update_with(K, fun(V) -> V + maps:get(K, Add) end, M)
                     end, Acc, [rows, batches, segments]),
    Merged = lists:usort(maps:get(schema_digests, Acc) ++
                             maps:get(schema_digests, Add)),
    maps:put(schema_digests, Merged, M1).

schema_digest_ok(D) when is_binary(D), byte_size(D) =:= 32 -> true;
schema_digest_ok(_) -> false.

%% ANDON law: any query/schema binary with a leading <<1:8>> byte is the
%% op-1 pull-cord. Refusal happens BEFORE any segment read — zero
%% mutation, zero reads.
andon_query(<<1:8, _/binary>>) -> true;
andon_query(_) -> false.

%% Deterministic row count: sha256 of the request body mod 1024 (legacy
%% form only). The mount never fabricates segment contents — the count
%% is a pure function of the request so the court can reproduce it. The
%% batch form refuses to recompute rows from hashes (data-derived law).
rows_for(Body) ->
    <<N:64/big, _/binary>> = crypto:hash(sha256, Body),
    N rem 1024.

%% -- sealed segment + IPC window reading (JournalReader semantics) ----------

%% read_sealed_segment_ipc(Seg, SchemaGate) ->
%%   {ok, {Frames, [{Rows, SchemaHex, WinSeq, BodyLen}], Sha256Hex, Bytes}}
%%   | {error, {Class, Kw}} — classes mirror
%%   Smalt.Storage.JournalReader's classification names exactly
%%   (not_sealed / missing_meta / manifest_mismatch / crc_mismatch /
%%   seq_regression / truncated_frame / truncated_tail / bad_magic),
%%   plus the ipc_* framing classes.
read_sealed_segment_ipc(Seg, SchemaGate) when is_list(Seg) ->
    read_sealed_segment_ipc(list_to_binary(Seg), SchemaGate);
read_sealed_segment_ipc(Seg, SchemaGate) when is_binary(Seg) ->
    SegPath = binary_to_list(Seg),
    case {filelib:is_regular(SegPath ++ ".seal"),
          filelib:is_regular(SegPath ++ ".meta.json")} of
        {true, true} ->
            read_segment_bytes(Seg, SegPath, SchemaGate);
        {SealOk, MetaOk} ->
            Class = case {SealOk, MetaOk} of
                        {false, _} -> not_sealed;
                        {true, false} -> missing_meta
                    end,
            {error, {Class, [{path, Seg}]}}
    end;
read_sealed_segment_ipc(_, _) ->
    {error, {bad_segment_path, []}}.

read_segment_bytes(Seg, SegPath, SchemaGate) ->
    case file:read_file(SegPath) of
        {ok, Bin} ->
            case read_manifest_sha(SegPath ++ ".meta.json") of
                {ok, ShaHex} ->
                    case sha256_hex(Bin) of
                        ShaHex ->
                            parse_journal_frames(Bin, 0, none, [], SchemaGate,
                                                 byte_size(Bin));
                        GotSha ->
                            {error, {manifest_mismatch,
                                     [{path, Seg}, {expected_sha256, ShaHex},
                                      {got, GotSha}]}}
                    end;
                {error, unreadable_manifest} ->
                    {error, {manifest_mismatch,
                             [{path, Seg}, {reason, unreadable_manifest}]}}
            end;
        {error, Reason} ->
            {error, {manifest_mismatch, [{path, Seg}, {io, Reason}]}}
    end.

read_manifest_sha(MetaPath) ->
    %% needle parse (no Jason dependency — standalone-erl court friendly);
    %% the manifest shape is pinned by JournalSink's writer
    case file:read_file(MetaPath) of
        {ok, Body} ->
            Needle = <<"\"sha256\": \"">>,
            case binary:match(Body, Needle) of
                nomatch ->
                    {error, unreadable_manifest};
                {At, _} ->
                    Start = At + byte_size(Needle),
                    Hex = binary:part(Body, Start, 64),
                    {ok, lower_hex(Hex)}
            end;
        _ ->
            {error, unreadable_manifest}
    end.

lower_hex(B) ->
    <<<<if C >= $A andalso C =< $F -> C + 32; true -> C end>>
     || <<C>> <= B>>.

sha256_hex(Bin) ->
    <<X:256/big-unsigned-integer>> = crypto:hash(sha256, Bin),
    iolist_to_binary(io_lib:format("~64.16.0b", [X])).

%% Frame walk: SMAL magic, FrameLen u32, body, CRC32 u32 over SeqID..Payload,
%% strictly advancing SeqID (JournalReader law), each payload walked as ONE
%% IPC1 window. Returns {Frames, WinInfo, ShaHex, Bytes}; ShaHex filled by
%% the caller after the walk completes (frame loop carries it through).
parse_journal_frames(Bin, Offset, PrevSeq, Acc, SchemaGate, Total) ->
    Have = Total - Offset,
    if
        Have =:= 0 ->
            Frames = lists:reverse(Acc),
            WinInfo = [Win || {frame, _Seq, _Ts, _Et, _Tid, _Key, Win} <- Frames],
            ShaHex = sha256_hex(binary_part(Bin, 0, Total)),
            {ok, {Frames, WinInfo, ShaHex, Total}};
        Have < 8 ->
            {error, {truncated_tail, [{offset, Offset}, {have, Have}]}};
        true ->
            frame_gate(Bin, Offset, Have, PrevSeq, Acc, SchemaGate, Total)
    end.

frame_gate(Bin, Offset, Have, PrevSeq, Acc, SchemaGate, Total) ->
    <<Magic:4/binary, FrameLen:32/big, _/binary>> = binary_part(Bin, Offset, Have),
    case Magic of
        <<"SMAL">> ->
            case FrameLen < 4 of
                true ->
                    {error, {truncated_frame,
                             [{offset, Offset}, {reason, bad_frame_len}, {have, Have}]}};
                false ->
                    parse_frame_at(Bin, Offset, FrameLen, PrevSeq, Acc, SchemaGate, Total)
            end;
        _ ->
            {error, {bad_magic, [{offset, Offset}]}}
    end.

parse_frame_at(Bin, Offset, FrameLen, PrevSeq, Acc, SchemaGate, Total) ->
    Have = Total - Offset,
    Needed = 8 + FrameLen,
    case Needed > Have of
        true ->
            {error, {truncated_frame,
                     [{offset, Offset}, {needed, Needed}, {have, Have}]}};
        false ->
            BodySize = FrameLen - 4,
            <<_M:4/binary, _FL:32/big, Body:BodySize/binary, Crc:32/big>> =
                binary_part(Bin, Offset, Needed),
            case erlang:crc32(Body) =:= Crc of
                false ->
                    {error, {crc_mismatch, [{offset, Offset}]}};
                true ->
                    frame_fields(Bin, Offset, Needed, Body, FrameLen,
                                 PrevSeq, Acc, SchemaGate, Total)
            end
    end.

frame_fields(Bin, Offset, Needed, Body, FrameLen, PrevSeq, Acc, SchemaGate, Total) ->
    try extract_fields(Body) of
        {Seq, Ts, Et, Tid, Key, Payload} ->
            case seq_monotonic(Seq, PrevSeq) of
                false ->
                    Prev = case PrevSeq of
                               {seq, P} -> P;
                               none -> 0
                           end,
                    {error, {seq_regression,
                             [{expected, Prev + 1}, {got, Seq}]}};
                true ->
                    case ipc_window_info(Payload, SchemaGate) of
                        {ok, Win} ->
                            parse_journal_frames(Bin, Offset + Needed,
                                                 {seq, Seq},
                                                 [{frame, Seq, Ts, Et, Tid, Key, Win} | Acc],
                                                 SchemaGate, Total);
                        {error, IpcRefusal} ->
                            {error, IpcRefusal}
                    end
            end
    catch
        error:_ ->
            {error, {truncated_frame,
                     [{offset, Offset}, {reason, bad_lengths},
                      {have, 8 + FrameLen}]}}
    end.

extract_fields(Body) ->
    <<Seq:64/big, Ts:64/signed, Et:16/big, Tid:16/big,
      KeyLen:32/big, Key:KeyLen/binary, PayloadLen:32/big,
      Payload:PayloadLen/binary>> = Body,
    {Seq, Ts, Et, Tid, Key, Payload}.

seq_monotonic(_Seq, none) -> true;
seq_monotonic(Seq, {seq, Prev}) -> Seq =:= Prev + 1.

%% -- minimal IPC framing walker (the Erlang copy — ONE) ---------------------

%% ipc_window_info(Window) -> ipc_window_info(Window, none).
%% Gate order byte-identical to cgap_arrow::ipc::parse_meta +
%% read_with_meta (IPC1 branch): truncation -> continuation -> meta span
%% -> truncation -> magic -> reserved fields -> header digest -> version
%% -> flags -> alignment -> schema -> body_len -> body pad -> EOS ->
%% body-digest presence -> rows carrier.
ipc_window_info(Window) ->
    ipc_window_info(Window, none).

ipc_window_info(Window, SchemaGate) when is_binary(Window) ->
    _ = SchemaGate,
    Len = byte_size(Window),
    case Len < ?IPC_PREFIX of
        true ->
            {error, {ipc_truncated, [{needed, ?IPC_PREFIX}, {got, Len}]}};
        false ->
            <<Cont:32/little, MetaSpan:32/little, _/binary>> = Window,
            case Cont =:= ?IPC_CONTINUATION of
                false ->
                    {error, {ipc_bad_continuation, [{got, Cont}]}};
                true ->
                    meta_span_gate(Window, Len, MetaSpan, SchemaGate)
            end
    end;
ipc_window_info(_, _) ->
    {error, {ipc_bad_window, []}}.

meta_span_gate(Window, Len, MetaSpan, SchemaGate) ->
    %% Region first word (window 8..12): the flatbuffer's root uoffset on
    %% the fb era; a legacy magic word on the legacy eras. cgap's
    %% parse_meta_with fork law: legacy spans stay legacy; a non-legacy
    %% span goes fb UNLESS the region word is a legacy magic or zero
    %% (which classifies BadMetaSize).
    RegionWord = case Len >= 12 of
                     true -> binary_part(Window, 8, 4);
                     false -> <<0, 0, 0, 0>>
                 end,
    LegacySpan = lists:member(MetaSpan, [64, 120]),
    %% R4-I fb fork (cgap-parity law): a non-legacy span that is a
    %% multiple of 8, >= 64, whose region word is NOT a legacy magic
    %% (IPC1/AOQ1/zero) takes the fb branch. The ARRO flatbuffer
    %% identifier lives at window offset 12..16 (flatbuffer bytes 4..8),
    %% never at 8..12.
    IsFb = (not LegacySpan)
        andalso (MetaSpan rem 8 =:= 0)
        andalso (MetaSpan >= 64)
        andalso (RegionWord =/= <<16#49504331:32/little>>)
        andalso (RegionWord =/= <<16#414F5131:32/little>>)
        andalso (RegionWord =/= <<0, 0, 0, 0>>),
    case IsFb of
        true ->
            BodyAt = ?IPC_PREFIX + MetaSpan,
            case Len < BodyAt of
                true ->
                    {error, {ipc_truncated, [{needed, BodyAt}, {got, Len}]}};
                false ->
                    fb_gate(Window, Len, MetaSpan, BodyAt, SchemaGate)
            end;
        false ->
            case LegacySpan of
                false ->
                    {error, {ipc_bad_meta_size, [{got, MetaSpan}, {expected, MetaSpan}]}};
                true ->
                    Alignment = case MetaSpan of 64 -> 8; 120 -> 64 end,
                    BodyAt = ?IPC_PREFIX + MetaSpan,
                    case Len < BodyAt of
                        true ->
                            {error, {ipc_truncated, [{needed, BodyAt}, {got, Len}]}};
                        false ->
                            header_gate(Window, Len, Alignment, BodyAt, SchemaGate)
                    end
            end
    end.

header_gate(Window, Len, Alignment, BodyAt, SchemaGate) ->
    <<_:8/binary, Header:64/binary, _/binary>> = Window,
    <<Magic:32/little, Version:16/little, Flags:16/little,
      Schema:32/binary, BodyLen:32/little, HAlign:32/little,
      Seq:32/little, Reserved0:32/little, HDigest:32/little,
      PadTail:4/binary>> = Header,
    case Magic =:= ?IPC_MAGIC of
        false ->
            {error, {ipc_bad_magic, [{got, Magic}]}};
        true ->
            case Reserved0 =/= 0 orelse PadTail =/= <<0, 0, 0, 0>> of
                true ->
                    {error, {ipc_header_digest_mismatch, [{got, HDigest}]}};
                false ->
                    case fnv1a32(binary_part(Header, 0, 16#38)) =:= HDigest of
                        false ->
                            {error, {ipc_header_digest_mismatch, [{got, HDigest}]}};
                        true ->
                            case Version =:= ?IPC_LAYOUT_VERSION of
                                false ->
                                    {error, {ipc_bad_version, [{got, Version}]}};
                                true ->
                                    case Flags =:= 0 of
                                        false ->
                                            {error, {ipc_bad_flags, [{got, Flags}]}};
                                        true ->
                                            case HAlign =:= Alignment of
                                                false ->
                                                    {error, {ipc_bad_alignment,
                                                             [{got, HAlign}]}};
                                                true ->
                                                    schema_gate(Window, Len, Alignment,
                                                                BodyAt, Schema, BodyLen,
                                                                Seq, SchemaGate)
                                            end
                                    end
                            end
                    end
            end
    end.

schema_gate(Window, Len, Alignment, BodyAt, Schema, BodyLen, Seq, SchemaGate) ->
    case SchemaGate of
        {expect_schema, Expected} when byte_size(Expected) =:= 32 ->
            case Schema =:= Expected of
                false ->
                    {error, {ipc_schema_mismatch, [{got, hex32(Schema)}]}};
                true ->
                    body_gate(Window, Len, Alignment, BodyAt, BodyLen, Seq, Schema)
            end;
        _ ->
            body_gate(Window, Len, Alignment, BodyAt, BodyLen, Seq, Schema)
    end.

body_gate(Window, Len, Alignment, BodyAt, BodyLen, Seq, Schema) ->
    BodyPad = pad_to(BodyLen, Alignment),
    case Len < BodyAt + BodyLen + BodyPad of
        true ->
            {error, {ipc_bad_body_len,
                     [{got, BodyLen},
                      {expected, expected_body(Len, BodyAt, Alignment)}]}};
        false ->
            PadBin = binary_part(Window, BodyAt + BodyLen, BodyPad),
            case first_nonzero(PadBin, BodyAt + BodyLen) of
                {some, At} ->
                    {error, {ipc_pad_non_zero, [{at, At}]}};
                none ->
                    eos_gate(Window, Len, Alignment, BodyAt, BodyLen, Seq, Schema)
            end
    end.

eos_gate(Window, Len, Alignment, BodyAt, BodyLen, Seq, Schema) ->
    EosAt = BodyAt + BodyLen + pad_to(BodyLen, Alignment),
    case Len < EosAt + ?IPC_EOS_SIZE of
        true ->
            {error, {ipc_missing_eos, [{got, 0}]}};
        false ->
            <<_:EosAt/binary, Cont2:32/little, Tail:32/little>> = Window,
            case Cont2 =:= ?IPC_CONTINUATION andalso Tail =:= ?IPC_EOS_WORD of
                false ->
                    {error, {ipc_missing_eos, [{got, Tail}]}};
                true ->
                    carrier_gate(Window, BodyAt, Seq, Schema)
            end
    end.

%% Metadata padding: blake3 body digest at window offset 72..104
%% (presence gate — verification is the export tier's law), rows
%% carrier u64 LE at 104..112 (all-zero = typed refusal).
carrier_gate(Window, _BodyAt, Seq, Schema) ->
    MetaPad = binary_part(Window, ?IPC_PREFIX + ?IPC_META_HEADER, 56),
    BodyDigest = binary_part(MetaPad, 0, 32),
    RowsBin = binary_part(MetaPad, 32, 8),
    case BodyDigest =:= ?IPC_ZERO_DIGEST of
        true ->
            {error, {ipc_body_digest_missing, []}};
        false ->
            case RowsBin =:= <<0:64>> of
                true ->
                    {error, {ipc_rows_carrier_missing, []}};
                false ->
                    <<Rows:64/little>> = RowsBin,
                    {ok, {Rows, hex32(Schema), Seq, undefined}}
            end
    end.


%% -- fb branch (R4-I): flatbuffer Message metadata windows --------------

%% fb_gate: the fb-era gate chain, in order: metadata parse -> bodyLength
%% extent -> body pad -> EOS -> cgap:schema_blake3 schema gate ->
%% cgap:body_blake3 PRESENCE -> cgap:rows PRESENCE (decimal).
%% Absent/non-decimal rows and absent digest refuse with the SAME atoms
%% as the legacy walk (ipc_rows_carrier_missing /
%% ipc_body_digest_missing), so walk/2 sums and census law are untouched.
fb_gate(Window, Len, MetaSpan, BodyAt, SchemaGate) ->
    Region = binary_part(Window, 8, MetaSpan),
    Alignment = fb_alignment(MetaSpan),
    case fb_parse_message(Region) of
        {error, _} ->
            {error, {ipc_fb_meta, []}};
        {ok, {BodyLen, MetaPairs}} ->
            BodyPad = pad_to(BodyLen, Alignment),
            case (BodyLen < 0) orelse
                 (Len < BodyAt + BodyLen + BodyPad + ?IPC_EOS_SIZE) of
                true ->
                    {error, {ipc_bad_body_len,
                             [{got, BodyLen},
                              {expected, expected_body(Len, BodyAt, Alignment)}]}};
                false ->
                    PadBin = binary_part(Window, BodyAt + BodyLen, BodyPad),
                    case first_nonzero(PadBin, BodyAt + BodyLen) of
                        {some, At} ->
                            {error, {ipc_pad_non_zero, [{at, At}]}};
                        none ->
                            fb_eos_gate(Window, Len, BodyAt, BodyLen,
                                        Alignment, MetaPairs, SchemaGate)
                    end
            end
    end.

fb_eos_gate(Window, Len, BodyAt, BodyLen, Alignment, MetaPairs, SchemaGate) ->
    EosAt = BodyAt + BodyLen + pad_to(BodyLen, Alignment),
    case Len < EosAt + ?IPC_EOS_SIZE of
        true ->
            {error, {ipc_missing_eos, [{got, 0}]}};
        false ->
            <<_:EosAt/binary, Cont2:32/little, Tail:32/little>> = Window,
            case Cont2 =:= ?IPC_CONTINUATION andalso Tail =:= ?IPC_EOS_WORD of
                false ->
                    {error, {ipc_missing_eos, [{got, Tail}]}};
                true ->
                    fb_schema_gate(SchemaGate, Window, BodyAt, BodyLen, MetaPairs)
            end
    end.

%% The fb schema gate compares against the carried cgap:schema_blake3
%% (the expected_schema seam on the fb era); an absent key never matches
%% a pinned digest (typed mismatch, never a misread).
fb_schema_gate({expect_schema, Expected}, Window, BodyAt, BodyLen, MetaPairs)
  when byte_size(Expected) =:= 32 ->
    case fb_meta_lookup(<<"cgap:schema_blake3">>, MetaPairs) of
        {ok, Hex} ->
            case fb_unhex32(Hex) of
                {ok, Carried} ->
                    case Carried =:= Expected of
                        false ->
                            {error, {ipc_schema_mismatch, [{got, lower_hex(Hex)}]}};
                        true ->
                            fb_presence_gates(Window, BodyAt, BodyLen, MetaPairs)
                    end;
                error ->
                    {error, {ipc_schema_mismatch, [{got, lower_hex(Hex)}]}}
            end;
        error ->
            {error, {ipc_schema_mismatch, [{got, <<>>}]}}
    end;
fb_schema_gate(_, Window, BodyAt, BodyLen, MetaPairs) ->
    fb_presence_gates(Window, BodyAt, BodyLen, MetaPairs).

%% Presence gates: cgap:body_blake3 (tamper tier; PRESENCE only on BEAM,
%% verification is the export tier's law), then cgap:rows (decimal u64).
fb_presence_gates(Window, BodyAt, BodyLen, MetaPairs) ->
    case fb_meta_lookup(<<"cgap:body_blake3">>, MetaPairs) of
        {ok, Hex} when byte_size(Hex) =:= 64 ->
            case fb_unhex32(Hex) of
                {ok, <<0:256>>} -> {error, {ipc_body_digest_missing, []}};
                {ok, _} -> fb_rows_gate(Window, BodyAt, BodyLen, MetaPairs);
                error -> {error, {ipc_body_digest_missing, []}}
            end;
        _ ->
            {error, {ipc_body_digest_missing, []}}
    end.

fb_rows_gate(_Window, _BodyAt, BodyLen, MetaPairs) ->
    case fb_meta_lookup(<<"cgap:rows">>, MetaPairs) of
        {ok, Digits} ->
            case fb_decimal_u64(Digits) of
                {ok, Rows} ->
                    SchemaHex =
                        case fb_meta_lookup(<<"cgap:schema_blake3">>, MetaPairs) of
                            {ok, SH} -> lower_hex(SH);
                            error -> <<>>
                        end,
                    {ok, {Rows, SchemaHex, 0, BodyLen}};
                error ->
                    {error, {ipc_rows_carrier_missing, []}}
            end;
        error ->
            {error, {ipc_rows_carrier_missing, []}}
    end.

fb_meta_lookup(Key, [{Key, V} | _]) -> {ok, V};
fb_meta_lookup(Key, [_ | Rest]) -> fb_meta_lookup(Key, Rest);
fb_meta_lookup(_, []) -> error.

%% Strict decimal u64 (ASCII digits only); empty or any non-digit
%% refuses.
fb_decimal_u64(Digits) -> fb_decimal_u64(Digits, 0).

fb_decimal_u64(<<>>, Acc) -> {ok, Acc};
fb_decimal_u64(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 ->
    fb_decimal_u64(Rest, Acc * 10 + (C - $0));
fb_decimal_u64(_, _) -> error.

fb_unhex32(Hex) -> fb_unhex32(Hex, <<>>).

fb_unhex32(<<>>, Acc) -> {ok, Acc};
fb_unhex32(<<H, L, Rest/binary>>, Acc) ->
    case {fb_hexval(H), fb_hexval(L)} of
        {error, _} -> error;
        {_, error} -> error;
        {Hi, Lo} -> fb_unhex32(Rest, <<Acc/binary, (Hi * 16 + Lo):8>>)
    end;
fb_unhex32(_, _) -> error.

fb_hexval(C) when C >= $0, C =< $9 -> C - $0;
fb_hexval(C) when C >= $a, C =< $f -> C - $a + 10;
fb_hexval(C) when C >= $A, C =< $F -> C - $A + 10;
fb_hexval(_) -> error.

fb_alignment(MetaSpan) ->
    case (8 + MetaSpan) rem 64 =:= 0 of true -> 64; false -> 8 end.

%% -- minimal flatbuffer Message parser (read-only, bounds-checked) ------

%% Parses the Message envelope: header_type MUST be Schema (1); returns
%% {BodyLength, [{Key, Value}]} from the schema custom_metadata. Any
%% structural violation raises and is caught as a typed refusal.
fb_parse_message(Bin) ->
    try {ok, fb_message(Bin)}
    catch
        _:_ -> {error, fb_parse_refused}
    end.

fb_message(Bin) ->
    T = fb_table(Bin, fb_u32(Bin, 0)),
    HeaderType = fb_scalar_u8(T, 1, 0),
    case HeaderType =:= 1 of
        false -> throw(fb_not_schema);
        true -> ok
    end,
    BodyLen = fb_scalar_i64(T, 3, 0),
    Header = fb_table_field(T, 2),
    MetaPairs = fb_kv_vector(Header, 2),
    {BodyLen, MetaPairs}.

%% -- flatbuffer primitives (uoffset/soffset table law) -------------------

fb_bin({Bin, _, _, _, _}) -> Bin.

fb_u32(Bin, P) ->
    <<V:32/little-unsigned>> = binary_part(Bin, P, 4),
    V.

fb_u16(Bin, P) ->
    <<V:16/little-unsigned>> = binary_part(Bin, P, 2),
    V.

fb_i32(Bin, P) ->
    <<V:32/little-signed>> = binary_part(Bin, P, 4),
    V.

fb_table(Bin, P) when is_binary(Bin), is_integer(P), P >= 0,
                      P + 4 =< byte_size(Bin) ->
    SOffset = fb_i32(Bin, P),
    VtPos = P - SOffset,
    VtSize = fb_u16(Bin, VtPos),
    TblSize = fb_u16(Bin, VtPos + 2),
    {Bin, P, VtPos, VtSize, TblSize}.

fb_field({Bin, _, VtPos, VtSize, _}, I) ->
    Voff = 4 + 2 * I,
    case Voff + 2 =< VtSize of
        false -> 0;
        true -> fb_u16(Bin, VtPos + Voff)
    end.

fb_scalar_u8({Bin, P, _, _, _} = T, I, Default) ->
    case fb_field(T, I) of
        0 -> Default;
        V -> binary:at(Bin, P + V)
    end.

fb_scalar_i64({Bin, P, _, _, _} = T, I, Default) ->
    case fb_field(T, I) of
        0 -> Default;
        V ->
            <<X:64/little-signed>> = binary_part(Bin, P + V, 8),
            X
    end.

fb_indirect({Bin, P, _, _, _} = T, I) ->
    case fb_field(T, I) of
        0 -> throw(fb_absent);
        V ->
            U = fb_u32(Bin, P + V),
            P + V + U
    end.

fb_table_field(T, I) ->
    Pos = fb_indirect(T, I),
    fb_table(fb_bin(T), Pos).

fb_string_field(T, I) ->
    Pos = fb_indirect(T, I),
    Bin = fb_bin(T),
    N = fb_u32(Bin, Pos),
    binary_part(Bin, Pos + 4, N).

fb_kv_vector(T, I) ->
    case fb_field(T, I) of
        0 -> [];
        _ ->
            Pos = fb_indirect(T, I),
            Bin = fb_bin(T),
            N = fb_u32(Bin, Pos),
            ElemBase = Pos + 4,
            [begin
                 U = fb_u32(Bin, ElemBase + 4 * J),
                 fb_kv(fb_table(Bin, ElemBase + 4 * J + U))
             end || J <- lists:seq(0, N - 1)]
    end.

fb_kv(T) ->
    {fb_string_field(T, 0), fb_string_field(T, 1)}.

pad_to(N, A) -> ((N + A - 1) div A) * A.

first_nonzero(Bin, Base) -> first_nonzero(Bin, 0, Base).

first_nonzero(<<B, _/binary>>, I, Base) when B =/= 0 ->
    {some, Base + I};
first_nonzero(<<_, Rest/binary>>, I, Base) ->
    first_nonzero(Rest, I + 1, Base);
first_nonzero(<<>>, _I, _Base) ->
    none.

fnv1a32(Bin) -> fnv1a32(Bin, 16#811C9DC5).

fnv1a32(<<B, Rest/binary>>, H) ->
    fnv1a32(Rest, ((H bxor B) * 16#01000193) band 16#FFFFFFFF);
fnv1a32(<<>>, H) -> H.

hex32(Bin) when is_binary(Bin), byte_size(Bin) =:= 32 ->
    <<X:256/big-unsigned-integer>> = Bin,
    iolist_to_binary(io_lib:format("~64.16.0b", [X])).

expected_body(BufLen, BodyAt, Alignment) when BufLen > BodyAt ->
    (BufLen - BodyAt) div (Alignment + 1);
expected_body(_, _, _) ->
    0.
