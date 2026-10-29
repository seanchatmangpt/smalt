# BK-2 — IMPL-14 ML-KEM Go-client leg (raw ML-KEM-768 interop)

Context: solo

Date: 2026-10-22 · Lane: bk2 · Repo: /Users/sac/smalt
Toolchain: OTP 29.1.2 (crypto 5.10, OpenSSL 3.6.4) / Go 1.24.0 (stdlib
`crypto/mlkem`, via system go1.23.4 + `GOTOOLCHAIN=go1.24.0`)
**Standing:** **ALIVE — both cross-implementation round-trips PASS; corrupted
ciphertext fails typed (implicit rejection, never the valid secret) on both
sides; probe exit 0.**

## What this closes

The IMPL-14 x25519mlkem768 flip (`lib/smalt/tls.ex`, landed v26.10.21,
`imp14-mlkem-flip.md`) carried a typed-open residual: smalt's ML-KEM surface
was proven only against itself (OTP-client legs) plus a TLS-handshake-shape
Go leg (`goleg-tls13-client.md`). This receipt adds the raw KEM leg: real
ML-KEM-768 encapsulate/decapsulate byte exchange between smalt's host OTP
crypto and a real external Go client. Note: smalt itself has no exported
key/ct API — its ML-KEM surface is the OTP 29 `crypto:mlkem768` NIF family
underneath the TLS listener; the probe exercises exactly that primitive.

## Harness (committed, real exchange, no mocks)

- `scripts/mlkem_go_probe/main.go` — Go probe over stdlib `crypto/mlkem`
  (mlkem768). Subcommands: `keygen`, `encap`, `decap`, `corrupt-decap`
  (the corrupt leg dies loudly if a corrupted ct yields the valid secret).
- `scripts/mlkem_go_probe/mlkem_otp_leg.erl` — OTP 29 escript leg over
  `crypto:generate_key(mlkem768, [])` / `encapsulate_key/2` /
  `decapsulate_key/3`.
- `scripts/mlkem_go_probe/run_probe.sh` — court driver; exit 0 pass /
  1 falsified; workdir is a fresh `mktemp -d` removed on exit.

## Format conversion (exact)

Interlop surface = raw FIPS 203 byte strings, no envelopes:

| object | bytes | OTP 29 | Go 1.24 |
|---|---|---|---|
| ek (encapsulation key) | 1184 | first elem of `generate_key(mlkem768, [])` | `EncapsulationKey768.Bytes()` |
| ct (ciphertext) | 1088 | 2nd elem of `encapsulate_key/2`'s `{Secret, EncapSecret}` | `Encapsulate()` 2nd return |
| ss (shared secret) | 32 | `decapsulate_key/3` result | `Decapsulate()` 1st return |

Conversion is the identity: files hold the exact byte strings (no
hex/base64/PEM/prefixes); what OTP writes, Go parses byte-for-byte.

Private-key serialization diverges and is documented as a divergence:
Go `DecapsulationKey768.Bytes()` returns the **64-byte `d||z` seed**, while
OTP `generate_key(mlkem768, [])` yields the **raw 2400-byte expanded dk**
(OTP has no seeded-keygen clause — `[{seed, _}]` is a function_clause,
witnessed). Each side therefore keeps its own private form; ek/ct/ss are the
portable surface. `decapsulate_key` argument order is `(Type, MyPrivKey,
EncapSecret)`; `encapsulate_key` returns **secret first**, ct second — both
shapes witnessed as failure modes during lane probing.

## Embedded probe output (real `bash run_probe.sh` run, exit 0)

```
=== BK-2 ML-KEM-768 cross-implementation probe (workdir /tmp/mlkem-bk2.VsVVoB) ===
OTP=29 (crypto 5.10)  GO=go1.24.0 darwin/arm64
--- Leg A: Go keygen -> OTP encapsulate -> Go decapsulate ---
WROTE /tmp/mlkem-bk2.VsVVoB/go_ek.bin 1184 bytes
WROTE /tmp/mlkem-bk2.VsVVoB/go_seed.bin 64 bytes
OTP-ENCAP ct=1088 ss=32 -> /tmp/mlkem-bk2.VsVVoB/ct_otp.bin, /tmp/mlkem-bk2.VsVVoB/ss_otp.bin
WROTE /tmp/mlkem-bk2.VsVVoB/ss_go.bin 32 bytes
LEG-A(Go->Elixir) ss_match=true bytes=32
--- Leg B: OTP keygen -> Go encapsulate -> OTP decapsulate ---
OTP-KEYGEN ek=1184 dk=2400 -> otp_ek.bin, otp_dk.bin
WROTE /tmp/mlkem-bk2.VsVVoB/go_ct.bin 1088 bytes
WROTE /tmp/mlkem-bk2.VsVVoB/go_ss.bin 32 bytes
LEG-B(Elixir->Go) ss_match=true bytes=32
--- Corrupt-ct legs (byte 0 flipped), both sides ---
corrupt fixture: ct_bad.bin written (byte 0 flipped)
GO-CORRUPT-CT ss_differs_from_valid=true ss_len=32 (no crash)
OTP-CORRUPT-CT implicit_rejection ss_differs_from_valid=true ss_len=32
=== PROBE COMPLETE: all interop legs PASS ===
```

Second run to confirm exit code: `EXIT=0`.

## Falsifier results

- smalt-side (OTP) encapsulation decapsulated by the Go client: PASS
  (Leg A, ss identical, 32 bytes).
- Go encapsulation decapsulated by smalt's host OTP: PASS (Leg B).
- Corrupted ct (byte 0 flipped) on both sides: never yields the valid
  secret; each implementation emits a deterministic 32-byte implicit-rejection
  secret (typed: the probe's `corrupt-decap` hard-fails if the valid secret
  ever matches — the court can flip, it is not vacuous). Additional witness
  from lane probing: Go stdlib `Decapsulate` returns a typed `error` for
  invalid ct per its contract; OTP's OpenSSL-backed decapsulate surfaces the
  corrupted-ct case as implicit rejection in this environment.

## Replay

```
export PATH=/usr/local/go/bin:$PATH
cd /Users/sac/smalt/scripts/mlkem_go_probe
GOTOOLCHAIN=go1.24.0 go build -o golegprobe .   # or let run_probe.sh build it
bash run_probe.sh                               # exit 0 = all legs PASS
```

## Notes / residual

- `filippo.io/mlkem` is retired (404 at filippo.io, absent from the Go
  proxy); the implementation lives in the Go 1.24+ stdlib as `crypto/mlkem`.
  The probe therefore has zero external Go dependencies.
- System `go` is 1.23.4 (no `crypto/mlkem`); the driver pins
  `GOTOOLCHAIN=go1.24.0` (cached toolchain).
- lib/smalt/tls.ex was NOT touched by this lane: the IMPL-14 flip and its
  supported_groups pin are already on HEAD; this receipt closes the
  raw-KEM Go-client residual that receipt carried.
