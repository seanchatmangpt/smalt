%% court_lakehouse_ipc_SUITE.erl — lane-12 common_test court for the
%% lakehouse mount batch-census surface (smalt_lakehouse_mount).
%%
%% Chicago discipline: real files, real crypto (crypto:sha256,
%% erlang:crc32), real term_to_binary wire envelopes — no mocks. Runs
%% under mix test via test/courts/court_lakehouse_ipc_ct_test.exs
%% (erlc + :ct.run).
%%
%% Window byte map (alignment-64 IPC1, prefix 8 + meta span 120):
%%   0..8 continuation+meta_span | 8..12 magic | 12 version | 14 flags
%%   16..48 schema | 48..52 body_len | 52..56 alignment | 56 seq
%%   60 reserved0 | 64 header_digest | 68..72 pad_tail
%%   72..104 body-digest slot | 104..112 rows carrier | 112..128 zero pad
%%   128..136 body (8 bytes) | 136..200 body pad | 200..208 EOS
%%
%% Covers: census discovery (2 sealed + 1 incomplete -> exactly 2 listed
%% + 1 quarantined, zero mutation), manifest sha256 flip, frame CRC
%% flip, seq-regression flip, truncated-tail flip, every IPC walker gate
%% flip by exact variant, gate ORDER precedence, batch query sums
%% exactly (data-derived carried rows), batch refusal = zero partial
%% results, ANDON precedence over a corrupt mount, legacy hash-derived
%% form unchanged (admit + pull-cord), schema-gate mismatch.
-module(court_lakehouse_ipc_SUITE).
-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").

-define(SCHEMA_A, binary:copy(<<16#AA>>, 32)).

-define(FB_FIXTURE_HEX,
    "ffffffff780200000c0000004152524f00000000fcffffff0c0016001a00230028002c000000000000000000"
    "00000400000000000000000100000000120000000c00000000000000000000000000fcffffff0a0014001800"
    "1e002600000000000000000000000000000000006c010000000000000400000003000000d400000048000000"
    "04000000fcffffff0800100014001c0000000000000000001700000000000000070000000000000100000033"
    "00000009000000636761703a726f77730000000000000000fcffffff0800100014001c000000000000000000"
    "5800000000000000080000000000000040000000646630376634393034613763636232303364633933356461"
    "6537626166346134633166306162393237396138363361363931303962653734663236303332656600000000"
    "10000000636761703a626f64795f626c616b65330000000000000000fcffffff0800100014001c0000000000"
    "0000000056000000000000000800000000000000400000003633663363386365663037633737653936376165"
    "3633356165663939626462326634663539373761333461303833336166326431383562633739643338323763"
    "000012000000636761703a736368656d615f626c616b65330000000000000000010000000800000000000000"
    "fcffffff0c001400180023002b00300000000000000000003f00000000000000000000010000000000000002"
    "0000000004000000fcffffff0800100014001f00000000000000000020000000000000000000000000000001"
    "0000007600000000000000000000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000100000002000000030000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000ffffffff00000000").

-define(FB_NO_ROWS_HEX,
    "ffffffff380200000c0000004152524f00000000fcffffff0c0016001a00230028002c000000000000000000"
    "00000400000000000000000100000000120000000c00000000000000000000000000fcffffff0a0014001800"
    "1e002600000000000000000000000000000000002c0100000000000008000000000000000200000090000000"
    "04000000fcffffff0800100014001c0000000000000000005800000000000000080000000000000040000000"
    "6466303766343930346137636362323033646339333564616537626166346134633166306162393237396138"
    "36336136393130396265373466323630333265660000000010000000636761703a626f64795f626c616b6533"
    "0000000000000000fcffffff0800100014001c00000000000000000056000000000000000800000000000000"
    "4000000036336633633863656630376337376539363761653633356165663939626462326634663539373761"
    "333461303833336166326431383562633739643338323763000012000000636761703a736368656d615f626c"
    "616b65330000000000000000010000000800000000000000fcffffff0c001400180023002b00300000000000"
    "000000003f000000000000000000000100000000000000020000000004000000fcffffff0800100014001f00"
    "0000000000000000200000000000000000000000000000010000007600000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    "0000000001000000020000000300000000000000000000000000000000000000000000000000000000000000"
    "000000000000000000000000000000000000000000000000000000000000000000000000ffffffff00000000").

-define(FB_SCHEMA_HEX, "63f3c8cef07c77e967ae635aef99bdb2f4f5977a34a0833af2d185bc79d3827c").

%% -- CT boilerplate ----------------------------------------------------------

init_per_suite(Config) ->
    Unique = integer_to_list(erlang:phash2(make_ref())),
    Dir = filename:join(filename:absname("tmp"), "lakehouse_ct_" ++ Unique),
    ok = filelib:ensure_dir(filename:join([Dir, "sealed", "x"])),
    Segs = build_fixture_mount(Dir),
    FbDir = filename:join(Dir, "fb_root"),
    write_fb_segment(FbDir, "seg-fb-00000000000000000001",
                     fb_fixture_bin(?FB_FIXTURE_HEX)),
    Fb2Dir = filename:join(Dir, "fb2_root"),
    write_fb_segment(Fb2Dir, "seg-fb-00000000000000000002",
                     fb_fixture_bin(?FB_NO_ROWS_HEX)),
    [{mount_dir, Dir}, {segs, Segs},
     {fb_dir, FbDir}, {fb2_dir, Fb2Dir} | Config].

end_per_suite(Config) ->
    case proplists:get_value(mount_dir, Config) of
        undefined -> ok;
        Dir -> os:cmd("rm -rf " ++ Dir)
    end,
    ok.

all() ->
    [all_census_discovery, all_manifest_mismatch, all_crc_mismatch,
     all_seq_regression, all_truncated_tail, all_ipc_gate_flips,
     all_ipc_gate_precedence, all_batch_query_sums_exactly,
     all_batch_refusal_zero_partial, all_andon_precedence_over_corruption,
     all_legacy_form_unchanged, all_schema_gate_mismatch,
     all_fb_shared_fixture, all_fb_without_rows, all_fb_span_fuzz].

%% -- fixtures ------------------------------------------------------------------

build_fixture_mount(Dir) ->
    Sealed = filename:join(Dir, "sealed"),
    ok = filelib:ensure_dir(filename:join([Sealed, "x"])),
    Bodies1 = [<<16#0102030405060708:64>>, <<16#1112131415161718:64>>,
               <<16#2122232425262728:64>>],
    Bodies2 = [<<16#3132333435363738:64>>, <<16#4142434445464748:64>>],
    Rows1 = [11, 22, 33],
    Rows2 = [44, 55],
    {ok, P1} = write_segment(Sealed, "seg-00000000000000000001", 1,
                             Bodies1, Rows1),
    {ok, P2} = write_segment(Sealed, "seg-00000000000000000002", 10,
                             Bodies2, Rows2),
    %% incomplete tail: .journal + .seal but NO .meta.json
    Inc = filename:join(Sealed, "seg-00000000000000000009.journal"),
    ok = file:write_file(
           Inc, journal_bytes(9, [<<0:64>>], [1], ?SCHEMA_A, 7)),
    ok = file:write_file(Inc ++ ".seal", <<"sealed\n">>),
    [P1, P2].

write_segment(Sealed, Name, FirstSeq, Bodies, Rows) ->
    Path = filename:join(Sealed, Name ++ ".journal"),
    Bin = journal_bytes(FirstSeq, Bodies, Rows, ?SCHEMA_A, 1000),
    ok = file:write_file(Path, Bin),
    Meta = ["{\"segment\": \"", Name, "\", \"bytes\": ",
            integer_to_list(byte_size(Bin)), ", \"frames\": ",
            integer_to_list(length(Bodies)), ", \"sha256\": \"",
            sha256_hex(Bin), "\"}"],
    ok = file:write_file(Path ++ ".meta.json", Meta),
    ok = file:write_file(Path ++ ".seal", <<"sealed\n">>),
    {ok, Path}.

%% Sequential SMAL frames, one IPC window per payload, keys <<"seg">>,
%% strictly advancing seq.
journal_bytes(FirstSeq, Bodies, Rows, Schema, Ts) ->
    Pairs = lists:zip(Bodies, Rows),
    Indexed = lists:zip(Pairs, lists:seq(0, length(Pairs) - 1)),
    Frames =
        [begin
             Win = emit_ipc_window(Body, R, Schema, FirstSeq + I),
             Key = <<"seg">>,
             FrameBody = <<(FirstSeq + I):64, Ts:64/signed, 5:16, 7:16,
                           3:32, Key/binary,
                           (byte_size(Win)):32, Win/binary>>,
             Crc = erlang:crc32(FrameBody),
             <<<<"SMAL">>/binary, (byte_size(FrameBody) + 4):32,
               FrameBody/binary, Crc:32>>
         end || {{Body, R}, I} <- Indexed],
    iolist_to_binary(Frames).

%% Fixture emitter: wire-law twin of cgap_arrow::ipc::emit_verified
%% (alignment-64 IPC1) plus the lane-12 rows carrier at window offset
%% 104..112. The blake3 body-digest slot carries a nonzero placeholder —
%% the Erlang walker gates PRESENCE only (blake3 verification is the
%% export tier's law, courted in journal-export's fidelity test).
emit_ipc_window(Body, Rows, Schema, Seq) ->
    BodyLen = byte_size(Body),
    %% cgap pad_to law: the pad rounds UP to a full 64-byte block
    PadLen = ((BodyLen + 63) div 64) * 64,
    BodyPad = binary:copy(<<0>>, PadLen),
    DigestSlot = binary:copy(<<16#A5>>, 32),
    Header0 = <<16#49504331:32/little, 1:16/little, 0:16/little,
                Schema:32/binary, BodyLen:32/little, 64:32/little,
                Seq:32/little, 0:32/little, 0:32/little, 0:32/little>>,
    HDigest = fnv1a32(binary_part(Header0, 0, 56)),
    Header = <<Header0:56/binary, HDigest:32/little, 0:32/little>>,
    MetaPad = <<DigestSlot:32/binary, Rows:64/little, 0:128>>,
    <<16#FFFFFFFF:32/little, 120:32/little,
      Header:64/binary, MetaPad:56/binary,
      Body:BodyLen/binary, BodyPad:PadLen/binary,
      16#FFFFFFFF:32/little, 0:32/little>>.

%% -- byte-level helpers ----------------------------------------------------------

fnv1a32(Bin) -> fnv1a32(Bin, 16#811C9DC5).
fnv1a32(<<B, Rest/binary>>, H) ->
    fnv1a32(Rest, ((H bxor B) * 16#01000193) band 16#FFFFFFFF);
fnv1a32(<<>>, H) -> H.

sha256_hex(Bin) ->
    <<X:256/big-unsigned-integer>> = crypto:hash(sha256, Bin),
    iolist_to_binary(io_lib:format("~64.16.0b", [X])).

meta_json(Bin) ->
    ["{\"sha256\": \"", sha256_hex(Bin), "\"}"].

read_seg(Seg) ->
    {ok, B} = file:read_file(Seg),
    B.

%% nth frame's {Offset, TotalLen} in a segment binary.
nth_frame_span(Bin, 1) ->
    <<_:4/binary, FrameLen:32/big, _/binary>> = Bin,
    {0, 8 + FrameLen};
nth_frame_span(Bin, N) ->
    <<_:4/binary, FrameLen:32/big, Rest/binary>> = Bin,
    {Next, _} = nth_frame_span(Rest, N - 1),
    {Next + 8 + FrameLen, 8 + FrameLen}.

frame_fields_at(Bin, Offset) ->
    Body = binary:part(Bin, Offset + 8, byte_size(Bin) - Offset - 8),
    <<Seq:64/big, Ts:64/signed, Et:16/big, Tid:16/big,
      KeyLen:32/big, Key:KeyLen/binary, _/binary>> = Body,
    {Seq, Ts, Et, Tid, Key}.

%% Window payload offset of frame N (fixture keys are <<"seg">>).
payload_off(Bin, N) ->
    {Off, _} = nth_frame_span(Bin, N),
    Off + 8 + 8 + 8 + 2 + 2 + 4 + 3 + 4.

win_len_at(Bin, PayloadOff) ->
    %% meta span is the SECOND word (window offset 4..8)
    <<_:4/binary, MetaSpan:32/little>> = binary:part(Bin, PayloadOff, 8),
    %% body_len lives in the header at window offset 48 (8 + 0x28)
    <<BodyLen:32/little>> = binary:part(Bin, PayloadOff + 48, 4),
    Alignment = case MetaSpan of 64 -> 8; 120 -> 64 end,
    BodyPad = ((BodyLen + Alignment - 1) div Alignment) * Alignment,
    8 + MetaSpan + BodyLen + BodyPad + 8.

flip_byte(Win, Off, B) ->
    Pre = binary:part(Win, 0, Off),
    <<_:8, Rest/binary>> = binary:part(Win, Off, byte_size(Win) - Off),
    <<Pre:Off/binary, B, Rest/binary>>.

%% Rebuild frame N wholesale around a new window payload, re-signing
%% frame_len + CRC, keeping every other byte of the segment identical.
%% SeqOverride: none keeps the original frame seq; {seq, S} rewinds it.
replace_window(Seg, Bin, N, NewWin) ->
    replace_window(Seg, Bin, N, NewWin, none).

replace_window(Seg, Bin, N, NewWin, SeqOverride) ->
    {Off, _Total} = nth_frame_span(Bin, N),
    {Seq0, Ts, Et, Tid, Key} = frame_fields_at(Bin, Off),
    Seq = case SeqOverride of none -> Seq0; {seq, S} -> S end,
    KeyLen = byte_size(Key),
    FrameBody = <<Seq:64, Ts:64/signed, Et:16, Tid:16,
                  KeyLen:32, Key/binary,
                  (byte_size(NewWin)):32, NewWin/binary>>,
    Crc = erlang:crc32(FrameBody),
    Frame = <<<<"SMAL">>/binary, (byte_size(FrameBody) + 4):32,
              FrameBody/binary, Crc:32>>,
    Head = binary_part(Bin, 0, Off),
    TailAt = Off + 8 + byte_size(FrameBody) + 4,
    Tail = binary:part(Bin, TailAt, byte_size(Bin) - TailAt),
    Rebuilt = iolist_to_binary([Head, Frame, Tail]),
    ok = file:write_file(Seg, Rebuilt),
    ok = file:write_file(Seg ++ ".meta.json", meta_json(Rebuilt)),
    Rebuilt.

%% Flip a header FIELD (inside the FNV digest span): write the new
%% value LE at header offset (FieldWinOff - 8), recompute the digest
%% like a lawful emitter with a bad field, re-sign frame + manifest.
flip_header_field(Seg, Bin, N, FieldWinOff, FieldLen, NewValue) ->
    PayloadOff = payload_off(Bin, N),
    WinLen = win_len_at(Bin, PayloadOff),
    Win0 = binary:part(Bin, PayloadOff, WinLen),
    HOff = FieldWinOff - 8,
    HeaderLen = 64,
    <<PreH:HOff/binary, _:FieldLen/binary, PostH/binary>> =
        binary_part(Win0, 8, HeaderLen),
    Field = case FieldLen of
                2 -> <<NewValue:16/little>>;
                4 -> <<NewValue:32/little>>
            end,
    Header1 = <<PreH:HOff/binary, Field/binary, PostH/binary>>,
    HD = fnv1a32(binary_part(Header1, 0, 56)),
    Header = <<Header1:56/binary, HD:32/little, 0:32/little>>,
    NewWin = binary:replace(Win0, binary_part(Win0, 8, HeaderLen), Header),
    replace_window(Seg, Bin, N, NewWin).

%% Write tainted bytes, assert segment_census refuses with the exact
%% class, restore. Runs against the mount dir derived from Seg.
flip_and_expect(Bin, Seg, N, WinOff, NewByte, Expect) ->
    PayloadOff = payload_off(Bin, N),
    WinLen = win_len_at(Bin, PayloadOff),
    Win = binary:part(Bin, PayloadOff, WinLen),
    NewWin = flip_byte(Win, WinOff, NewByte),
    Rebuilt = replace_window(Seg, Bin, N, NewWin),
    Dir = dirname2(Seg),
    Expect(smalt_lakehouse_mount:segment_census(Dir)),
    ok = file:write_file(Seg, Bin),
    ok = file:write_file(Seg ++ ".meta.json", meta_json(Bin)),
    Rebuilt.

dirname2(Seg) ->
    filename:dirname(filename:dirname(Seg)).

%% -- test cases ----------------------------------------------------------------

all_census_discovery(Config) ->
    Dir = proplists:get_value(mount_dir, Config),
    {ok, #{segments := Segs, quarantined := Quarantined}} =
        smalt_lakehouse_mount:segment_census(Dir),
    2 = length(Segs),
    1 = length(Quarantined),
    [S1, S2] = Segs,
    <<"seg-00000000000000000001.journal">> = maps:get(segment, S1),
    <<"seg-00000000000000000002.journal">> = maps:get(segment, S2),
    3 = maps:get(frames, S1),
    3 = maps:get(windows, S1),
    11 + 22 + 33 = maps:get(rows, S1),
    44 + 55 = maps:get(rows, S2),
    HexLen = byte_size(maps:get(sha256, S2)),
    64 = HexLen,
    [Hex] = maps:get(schema_digests, S1),
    64 = byte_size(Hex),
    %% schema hex is the RAW O-ABI digest rendered, not a sha256 of it
    Hex = list_to_binary([io_lib:format("~2.16.0b", [C]) || <<C>> <= ?SCHEMA_A]),
    %% zero mutation: the incomplete tail stays in place (census is
    %% analysis-only; disclosed divergence from the reader's rename)
    true = filelib:is_file(
             filename:join([Dir, "sealed",
                            "seg-00000000000000000009.journal"])),
    ct:comment("census discovery exact, zero mutation"),
    ok.

all_manifest_mismatch(Config) ->
    Dir = proplists:get_value(mount_dir, Config),
    Seg = hd(proplists:get_value(segs, Config)),
    Bin = read_seg(Seg),
    <<H:16/binary, _:8, T/binary>> = Bin,
    ok = file:write_file(Seg, <<H:16/binary, 16#EF:8, T/binary>>),
    {error, {manifest_mismatch, _}} =
        smalt_lakehouse_mount:segment_census(Dir),
    ok = file:write_file(Seg, Bin),
    ct:comment("manifest sha256 flip refused typed"),
    ok.

all_crc_mismatch(Config) ->
    Dir = proplists:get_value(mount_dir, Config),
    Seg = hd(proplists:get_value(segs, Config)),
    Bin = read_seg(Seg),
    %% flip frame 1's CRC without re-signing (CRC layer, not manifest layer)
    {_, Total} = nth_frame_span(Bin, 1),
    CrcAt = Total - 4,
    Head = binary_part(Bin, 0, CrcAt),
    Tail = binary_part(Bin, Total, byte_size(Bin) - Total),
    Tainted = iolist_to_binary([Head, <<16#DEADBEEF:32>>, Tail]),
    ok = file:write_file(Seg, Tainted),
    %% re-sign the manifest so ONLY the CRC layer trips (check order:
    %% manifest is gate 1)
    ok = file:write_file(Seg ++ ".meta.json", meta_json(Tainted)),
    {error, {crc_mismatch, _}} =
        smalt_lakehouse_mount:segment_census(Dir),
    ok = file:write_file(Seg, Bin),
    ct:comment("frame CRC flip refused typed"),
    ok.

all_seq_regression(Config) ->
    Dir = proplists:get_value(mount_dir, Config),
    Seg = hd(proplists:get_value(segs, Config)),
    Bin = read_seg(Seg),
    %% frame 2 lawful seq is 2 (first=1); rewind the FRAME seq to 1
    %% (window unchanged, CRC + manifest re-signed)
    PayloadOff = payload_off(Bin, 2),
    WinLen = win_len_at(Bin, PayloadOff),
    Win = binary:part(Bin, PayloadOff, WinLen),
    replace_window(Seg, Bin, 2, Win, {seq, 1}),
    {error, {seq_regression, Kw}} =
        smalt_lakehouse_mount:segment_census(Dir),
    2 = proplists:get_value(expected, Kw),
    1 = proplists:get_value(got, Kw),
    ok = file:write_file(Seg, Bin),
    ok = file:write_file(Seg ++ ".meta.json", meta_json(Bin)),
    ct:comment("seq regression refused typed"),
    ok.

all_truncated_tail(Config) ->
    Dir = proplists:get_value(mount_dir, Config),
    Seg = lists:nth(2, proplists:get_value(segs, Config)),
    Bin = read_seg(Seg),
    Trunc = binary:part(Bin, 0, byte_size(Bin) - 3),
    ok = file:write_file(Seg, Trunc),
    ok = file:write_file(Seg ++ ".meta.json", meta_json(Trunc)),
    %% journal_reader.ex law: a tail too short to size the NEXT frame is
    %% truncated_tail; a frame whose declared length overruns the file is
    %% truncated_frame (which this cut produces).
    {error, {truncated_frame, _}} =
        smalt_lakehouse_mount:segment_census(Dir),
    ok = file:write_file(Seg, Bin),
    ok = file:write_file(Seg ++ ".meta.json", meta_json(Bin)),
    ct:comment("truncated tail refused typed"),
    ok.

all_ipc_gate_flips(Config) ->
    Seg = hd(proplists:get_value(segs, Config)),
    Bin = read_seg(Seg),
    %% continuation word
    flip_and_expect(Bin, Seg, 1, 0, 16#0,
                    fun({error, {ipc_bad_continuation, _}}) -> ok end),
    %% meta span word -> 5 (not 64/120)
    flip_and_expect(Bin, Seg, 1, 4, 5,
                    fun({error, {ipc_bad_meta_size, _}}) -> ok end),
    %% magic low byte
    flip_and_expect(Bin, Seg, 1, 8, 16#AA,
                    fun({error, {ipc_bad_magic, _}}) -> ok end),
    %% reserved0 dirty (window offset 60) — cgap maps to
    %% HeaderDigestMismatch before the digest compare
    flip_and_expect(Bin, Seg, 1, 60, 1,
                    fun({error, {ipc_header_digest_mismatch, _}}) -> ok end),
    %% header digest itself wrong (window offset 64)
    flip_and_expect(Bin, Seg, 1, 64, 16#42,
                    fun({error, {ipc_header_digest_mismatch, _}}) -> ok end),
    %% version/flags/alignment live INSIDE the FNV digest span — a
    %% lawful emitter with a bad field recomputes the digest, so these
    %% flips re-seal the header (every corruption class stays reachable)
    ok = file:write_file(Seg, Bin),
    ok = file:write_file(Seg ++ ".meta.json", meta_json(Bin)),
    flip_header_field(Seg, Bin, 1, 12, 2, 99),
    {error, {ipc_bad_version, _}} =
        smalt_lakehouse_mount:segment_census(dirname2(Seg)),
    ok = file:write_file(Seg, Bin),
    ok = file:write_file(Seg ++ ".meta.json", meta_json(Bin)),
    flip_header_field(Seg, Bin, 1, 14, 2, 1),
    {error, {ipc_bad_flags, _}} =
        smalt_lakehouse_mount:segment_census(dirname2(Seg)),
    ok = file:write_file(Seg, Bin),
    ok = file:write_file(Seg ++ ".meta.json", meta_json(Bin)),
    flip_header_field(Seg, Bin, 1, 52, 4, 8),
    {error, {ipc_bad_alignment, _}} =
        smalt_lakehouse_mount:segment_census(dirname2(Seg)),
    ok = file:write_file(Seg, Bin),
    ok = file:write_file(Seg ++ ".meta.json", meta_json(Bin)),
    %% body pad (window offset 136, first pad byte)
    flip_and_expect(Bin, Seg, 1, 136, 16#FF,
                    fun({error, {ipc_pad_non_zero, _}}) -> ok end),
    %% EOS (window offset 200)
    flip_and_expect(Bin, Seg, 1, 200, 16#AA,
                    fun({error, {ipc_missing_eos, _}}) -> ok end),
    %% rows carrier zeroed (window offset 104)
    flip_and_expect(Bin, Seg, 1, 104, 0,
                    fun({error, {ipc_rows_carrier_missing, _}}) -> ok end),
    %% body-digest slot zeroed ENTIRELY (window offset 72..104): the
    %% walker gates presence (nonzero), so a single zeroed byte is
    %% lawfully admitted — only the full slot clears the gate
    PayloadOff72 = payload_off(Bin, 1),
    WinLen72 = win_len_at(Bin, PayloadOff72),
    Win72 = binary:part(Bin, PayloadOff72, WinLen72),
    ZeroSlot = binary:copy(<<0>>, 32),
    NewWin72 = binary:replace(Win72, binary:part(Win72, 72, 32), ZeroSlot),
    replace_window(Seg, Bin, 1, NewWin72),
    {error, {ipc_body_digest_missing, _}} =
        smalt_lakehouse_mount:segment_census(dirname2(Seg)),
    ok = file:write_file(Seg, Bin),
    ok = file:write_file(Seg ++ ".meta.json", meta_json(Bin)),
    ct:comment("all IPC walker gates flip by exact variant"),
    ok.

all_ipc_gate_precedence(Config) ->
    Seg = hd(proplists:get_value(segs, Config)),
    Bin = read_seg(Seg),
    PayloadOff = payload_off(Bin, 1),
    WinLen = win_len_at(Bin, PayloadOff),
    Win = binary:part(Bin, PayloadOff, WinLen),
    %% continuation corruption beats a later magic corruption
    W1 = flip_byte(flip_byte(Win, 0, 16#0), 8, 16#AA),
    replace_window(Seg, Bin, 1, W1),
    {error, {ipc_bad_continuation, _}} =
        smalt_lakehouse_mount:segment_census(dirname2(Seg)),
    %% version beats flags (both fields re-sealed, both bad)
    ok = file:write_file(Seg, Bin),
    ok = file:write_file(Seg ++ ".meta.json", meta_json(Bin)),
    flip_header_field(Seg, Bin, 1, 12, 2, 99),
    Bin2 = read_seg(Seg),
    flip_header_field(Seg, Bin2, 1, 14, 2, 1),
    {error, {ipc_bad_version, _}} =
        smalt_lakehouse_mount:segment_census(dirname2(Seg)),
    ok = file:write_file(Seg, Bin),
    ok = file:write_file(Seg ++ ".meta.json", meta_json(Bin)),
    ct:comment("gate precedence: continuation wins, version wins"),
    ok.

all_batch_query_sums_exactly(Config) ->
    Dir = proplists:get_value(mount_dir, Config),
    {ok, #{rows := Rows, batches := Batches, segments := Segs,
           schema_digests := Digs}} =
        smalt_lakehouse_mount:execute_analytical_query(
          Dir, {dt_lakehouse_batch_query, ?SCHEMA_A, all}),
    11 + 22 + 33 + 44 + 55 = Rows,
    5 = Batches,
    2 = Segs,
    [Hex] = Digs,
    Hex = list_to_binary([io_lib:format("~2.16.0b", [C]) || <<C>> <= ?SCHEMA_A]),
    ct:comment("batch query sums exactly, data-derived carried rows"),
    ok.

all_batch_refusal_zero_partial(Config) ->
    Dir = proplists:get_value(mount_dir, Config),
    [S1, S2] = proplists:get_value(segs, Config),
    Bin2 = read_seg(S2),
    Meta = read_seg(S2 ++ ".meta.json"),
    ok = file:write_file(S2 ++ ".meta.json",
                         binary:replace(Meta, sha256_hex(Bin2),
                                        binary:copy(<<"0">>, 64))),
    {error, {manifest_mismatch, _}} =
        smalt_lakehouse_mount:execute_analytical_query(
          Dir, {dt_lakehouse_batch_query, ?SCHEMA_A, all}),
    {error, {manifest_mismatch, _}} =
        smalt_lakehouse_mount:execute_analytical_query(
          Dir, {dt_lakehouse_batch_query, ?SCHEMA_A, [S1, S2]}),
    ok = file:write_file(S2 ++ ".meta.json", Meta),
    ct:comment("batch refusal: zero partial results"),
    ok.

all_andon_precedence_over_corruption(Config) ->
    Dir = proplists:get_value(mount_dir, Config),
    [_, S2] = proplists:get_value(segs, Config),
    Bin2 = read_seg(S2),
    Meta = read_seg(S2 ++ ".meta.json"),
    ok = file:write_file(S2 ++ ".meta.json",
                         binary:replace(Meta, sha256_hex(Bin2),
                                        binary:copy(<<"0">>, 64))),
    AndonQ = <<1:8, "pull the cord">>,
    {error, {andon, <<1:8, Len:32, R/binary>>}} =
        smalt_lakehouse_mount:execute_analytical_query(
          Dir, {dt_lakehouse_batch_query, AndonQ, all}),
    true = byte_size(R) > 0,
    Len = byte_size(R),
    ok = file:write_file(S2 ++ ".meta.json", Meta),
    ct:comment("ANDON wins over a corrupt mount, zero reads"),
    ok.

all_legacy_form_unchanged(Config) ->
    Dir = proplists:get_value(mount_dir, Config),
    {ok, #{rows := Rows, segments := Segs}} =
        smalt_lakehouse_mount:execute_analytical_query(Dir, <<"sum(v)">>),
    RequestBin = term_to_binary(
                   {dt_lakehouse_query, <<"sum(v)">>,
                    smalt_lakehouse_mount:discover_sealed_segments(Dir)}),
    <<N:64/big, _/binary>> = crypto:hash(sha256, RequestBin),
    Expected = N rem 1024,
    Expected = Rows,
    true = is_list(Segs),
    {error, {andon, <<1:8, _:32, _/binary>>}} =
        smalt_lakehouse_mount:execute_analytical_query(Dir, <<1:8, "andon">>),
    ct:comment("legacy hash-derived form unchanged, both wire forms"),
    ok.

all_schema_gate_mismatch(Config) ->
    Dir = proplists:get_value(mount_dir, Config),
    OtherSchema = binary:copy(<<16#BB>>, 32),
    {error, {ipc_schema_mismatch, _}} =
        smalt_lakehouse_mount:execute_analytical_query(
          Dir, {dt_lakehouse_batch_query, OtherSchema, all}),
    ct:comment("schema gate mismatch refused typed"),
    ok.

%% ===========================================================================
%% R4-I fb-era cases (repositioning wave): the shared cross-repo fixture
%% (committed byte-for-byte on the cgap side,
%% crates/cgap-arrow/tests/ipc_courts.rs f4_shared_fixture_identical_
%% classification) classifies IDENTICALLY here. Any asymmetry = F4
%% coordination violation.
%% ===========================================================================


% Decode a ?FB_FIXTURE_HEX-shaped hex macro to a binary.
fb_fixture_bin(Mac) ->
    Hex = list_to_binary(lists:flatten(Mac)),
    << << (fb_hexval_hi(H) * 16 + fb_hexval_hi(L)):8 >>
       || <<H, L>> <= Hex >>.

fb_hexval_hi(C) when C >= $0, C =< $9 -> C - $0;
fb_hexval_hi(C) when C >= $a, C =< $f -> C - $a + 10;
fb_hexval_hi(C) when C >= $A, C =< $F -> C - $A + 10.

fb_raw_schema() ->
    Hex = list_to_binary(?FB_SCHEMA_HEX),
    << << (fb_hexval_hi(H) * 16 + fb_hexval_hi(L)):8 >>
       || <<H, L>> <= Hex >>.

write_fb_segment(Dir, Name, Win) ->
    Sealed = filename:join(Dir, "sealed"),
    ok = filelib:ensure_dir(filename:join([Sealed, "x"])),
    Seq = 1,
    FrameBody = <<Seq:64, 1000:64/signed, 5:16, 7:16, 3:32, "seg",
                  (byte_size(Win)):32, Win/binary>>,
    Crc = erlang:crc32(FrameBody),
    Frame = <<<<"SMAL">>/binary, (byte_size(FrameBody) + 4):32,
              FrameBody/binary, Crc:32>>,
    Path = filename:join(Sealed, Name ++ ".journal"),
    ok = file:write_file(Path, Frame),
    Meta = ["{\"sha256\": \"", sha256_hex(Frame), "\"}"],
    ok = file:write_file(Path ++ ".meta.json", Meta),
    ok = file:write_file(Path ++ ".seal", <<"sealed\n">>),
    Path.


all_fb_shared_fixture(Config) ->
    Dir = proplists:get_value(fb_dir, Config),
    {ok, #{segments := [Seg], quarantined := []}} =
        smalt_lakehouse_mount:segment_census(Dir),
    1 = maps:get(windows, Seg),
    3 = maps:get(rows, Seg),
    [SchemaHex] = maps:get(schema_digests, Seg),
    true = binary_to_list(SchemaHex) =:= ?FB_SCHEMA_HEX,
    %% batch query with the fb schema gate (expected = the carried
    %% cgap:schema_blake3 raw bytes)
    {ok, #{rows := 3}} =
        smalt_lakehouse_mount:execute_analytical_query(
          Dir, {dt_lakehouse_batch_query, fb_raw_schema(), all}),
    ct:comment("shared fb fixture classified identically (F4 guard)"),
    ok.

all_fb_without_rows(Config) ->
    Dir2 = proplists:get_value(fb2_dir, Config),
    {error, {ipc_rows_carrier_missing, []}} =
        smalt_lakehouse_mount:segment_census(Dir2),
    %% window-level classification, same class as cgap IpcError::
    %% RowsCarrierMissing (F4 coordination guard)
    Win = fb_fixture_bin(?FB_NO_ROWS_HEX),
    {error, {ipc_rows_carrier_missing, []}} =
        smalt_lakehouse_mount:ipc_window_info(Win),
    ct:comment("fb-without-rows refuses ipc_rows_carrier_missing"),
    ok.

all_fb_span_fuzz(_Config) ->
    Win = fb_fixture_bin(?FB_FIXTURE_HEX),
    <<Pre:4/binary, _OldSpan:4/binary, Post/binary>> = Win,
    Bad = <<Pre/binary, 634:32/little, Post/binary>>,
    {error, {ipc_bad_meta_size, _}} =
        smalt_lakehouse_mount:ipc_window_info(Bad),
    ct:comment("non-multiple-of-8 span refuses ipc_bad_meta_size"),
    ok.
