#!/bin/bash
# BK-2 IMPL-14 ML-KEM Go leg — full interop court driver.
# Real exchange: OTP 29 crypto:mlkem768 <-> Go 1.24 stdlib crypto/mlkem
# (mlkem768), via real files on disk (raw FIPS 203 byte strings).
# No mocks, no stubs. Exit 0 = all legs pass; exit 1 = any leg falsified.
set -euo pipefail
cd "$(dirname "$0")"
D=$(mktemp -d /tmp/mlkem-bk2.XXXXXX)

ERL="${ERL:-$HOME/.asdf/installs/erlang/29.1.2/bin/escript}"
ERLBIN="${ERLBIN:-$HOME/.asdf/installs/erlang/29.1.2/bin/erl}"
GOBIN="${GOBIN:-go}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-go1.24.0}"

OTP_REL=$("$ERLBIN" -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')
OTP_VER=$("$ERLBIN" -noshell -eval 'io:format("~s", [maps:get(otp_crypto_version, crypto:info(), na)]), halt().')

cleanup() { rm -rf "$D"; }
trap cleanup EXIT

fail() { echo "FALSIFIED: $*" >&2; exit 1; }

echo "=== BK-2 ML-KEM-768 cross-implementation probe (workdir $D) ==="
echo "OTP=$OTP_REL (crypto $OTP_VER)  GO=$("$GOBIN" version | sed 's/go version //')"

echo "--- Leg A: Go keygen -> OTP encapsulate -> Go decapsulate ---"
[ -x ./golegprobe ] || "$GOBIN" build -o golegprobe .
./golegprobe keygen "$D/go_ek.bin" "$D/go_seed.bin"
"$ERL" mlkem_otp_leg.erl encap "$D/go_ek.bin" "$D/ct_otp.bin" "$D/ss_otp.bin"
./golegprobe decap "$D/go_seed.bin" "$D/ct_otp.bin" "$D/ss_go.bin"
"$ERLBIN" -noshell -eval "
    begin
        {ok, A} = file:read_file(\"$D/ss_otp.bin\"),
        {ok, B} = file:read_file(\"$D/ss_go.bin\"),
        case A =:= B of
            true  -> io:format(\"LEG-A(Go->Elixir) ss_match=true bytes=~p~n\", [byte_size(A)]);
            false -> io:format(\"LEG-A ss MISMATCH~n\"), halt(1)
        end
    end,
    halt()."

echo "--- Leg B: OTP keygen -> Go encapsulate -> OTP decapsulate ---"
"$ERL" mlkem_otp_leg.erl keygen "$D"
./golegprobe encap "$D/otp_ek.bin" "$D/go_ct.bin" "$D/go_ss.bin"
"$ERLBIN" -noshell -eval "
    begin
        {ok, Dk} = file:read_file(\"$D/otp_dk.bin\"),
        {ok, Ct} = file:read_file(\"$D/go_ct.bin\"),
        {ok, SsGo} = file:read_file(\"$D/go_ss.bin\"),
        SsOtp = crypto:decapsulate_key(mlkem768, Dk, Ct),
        case SsOtp =:= SsGo of
            true  -> io:format(\"LEG-B(Elixir->Go) ss_match=true bytes=~p~n\", [byte_size(SsOtp)]);
            false -> io:format(\"LEG-B ss MISMATCH~n\"), halt(1)
        end
    end,
    halt()."

echo "--- Corrupt-ct legs (byte 0 flipped), both sides ---"
"$ERLBIN" -noshell -eval "
    begin
        {ok, Ct} = file:read_file(\"$D/go_ct.bin\"),
        <<H, T/binary>> = Ct,
        ok = file:write_file(\"$D/ct_bad.bin\", <<(H bxor 255), T/binary>>),
        {ok, Ss} = file:read_file(\"$D/go_ss.bin\"),
        ok = file:write_file(\"$D/ss_valid_ref.bin\", Ss),
        io:format(\"corrupt fixture: ct_bad.bin written (byte 0 flipped)~n\")
    end,
    halt()."
./golegprobe corrupt-decap "$D/go_seed.bin" "$D/ct_bad.bin" "$D/ss_valid_ref.bin"
"$ERL" mlkem_otp_leg.erl decap-implicit "$D/otp_dk.bin" "$D/ct_bad.bin" "$D/ss_valid_ref.bin"

echo "=== PROBE COMPLETE: all interop legs PASS ==="
