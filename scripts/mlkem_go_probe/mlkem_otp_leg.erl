#!/usr/bin/env escript
%% BK-2 IMPL-14 ML-KEM Go leg — OTP 29 side of the raw ML-KEM-768 interop
%% probe. Real files, real crypto:mlkem768, no mocks.
%% Modes:
%%   keygen <dir>            -> <dir>/otp_ek.bin (1184), <dir>/otp_dk.bin (2400)
%%   encap <ek-file> <ct-out> <ss-out>
%%   decap <dk-file> <ct-file>
%%   decap-implicit <dk-file> <ct-file> <valid-ss-file>   (corrupt-ct leg)
main([Mode | Args]) ->
    case Mode of
        "keygen" ->
            [Dir] = Args,
            {Ek, Dk} = crypto:generate_key(mlkem768, []),
            ok = file:write_file(filename:join(Dir, "otp_ek.bin"), Ek),
            ok = file:write_file(filename:join(Dir, "otp_dk.bin"), Dk),
            io:format("OTP-KEYGEN ek=~p dk=~p -> otp_ek.bin, otp_dk.bin~n",
                      [byte_size(Ek), byte_size(Dk)]);
        "encap" ->
            [EkFile, CtOut, SsOut] = Args,
            {ok, Ek} = file:read_file(EkFile),
            true = byte_size(Ek) =:= 1184 orelse erlang:error({bad_ek_size, byte_size(Ek)}),
            {Ss, Ct} = crypto:encapsulate_key(mlkem768, Ek),
            ok = file:write_file(CtOut, Ct),
            ok = file:write_file(SsOut, Ss),
            io:format("OTP-ENCAP ct=~p ss=~p -> ~s, ~s~n",
                      [byte_size(Ct), byte_size(Ss), CtOut, SsOut]);
        "decap" ->
            [DkFile, CtFile] = Args,
            {ok, Dk} = file:read_file(DkFile),
            {ok, Ct} = file:read_file(CtFile),
            true = byte_size(Dk) =:= 2400 orelse erlang:error({bad_dk_size, byte_size(Dk)}),
            true = byte_size(Ct) =:= 1088 orelse erlang:error({bad_ct_size, byte_size(Ct)}),
            Ss = crypto:decapsulate_key(mlkem768, Dk, Ct),
            io:format("OTP-DECAP ss=~s~n", [binary:encode_hex(Ss)]);
        "decap-implicit" ->
            [DkFile, CtFile, SsFile] = Args,
            {ok, Dk} = file:read_file(DkFile),
            {ok, Ct} = file:read_file(CtFile),
            {ok, SsValid} = file:read_file(SsFile),
            Result = (try crypto:decapsulate_key(mlkem768, Dk, Ct) catch _:_ -> error end),
            case Result of
                Ss when is_binary(Ss) ->
                    io:format("OTP-CORRUPT-CT implicit_rejection ss_differs_from_valid=~p ss_len=~p~n",
                              [Ss =/= SsValid, byte_size(Ss)]);
                error ->
                    io:format("OTP-CORRUPT-CT typed_refusal (crypto exited, no secret emitted)~n")
            end
    end.
