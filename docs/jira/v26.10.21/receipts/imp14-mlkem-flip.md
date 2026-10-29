# IMPL-14 — x25519mlkem768 flip + Go-client interop witness

Context: solo

Date: 2026-10-21 · Lane: bk2 · Repo: /Users/sac/smalt
Toolchain: OTP 29.1.2 / Elixir 1.20.4-otp-29, `MIX_BUILD_ROOT=_build-bk2`
**Standing:** **PARTIAL_ALIVE — flip landed as an explicit server-side preference
pin; OTP + Go 1.24 MLKEM handshakes witnessed against the live 9444 twin;
one residual: Go 1.24 refuses a mlkem-only CurvePreferences (client-side
validation), typed open below.**

## The flip

`lib/smalt/tls.ex` `transport_tls_opts/1`, tlsv1.3 branch:

```elixir
[versions: versions, supported_groups: [:x25519mlkem768, :x25519, :secp256r1]]
```

The 1.2-only escape hatch (`config :smalt, :tls_versions, [:"tlsv1.2"]`)
still restores the pre-mlkem shape byte-for-byte (mlkem preference rides the
same branch as the IMPL-14F 1.3 flip, which OTP 28 cannot reach).

## OTP 29 surface probe

`supported_groups` is the accepted option name (`:groups` and `:key_share`
both exit badarg — witnessed, see commands below). With ssl 11.7.8 on
OTP 29.1.2, `supported_groups: [:x25519mlkem768]`-only server listen is
ACCEPTED, and an OTP 29 client with `supported_groups: [:x25519mlkem768]`
negotiated:

```
info: {:ok, [protocol: :"tlsv1.3", selected_group: :x25519mlkem768]}
```

## Honest finding: the pin pins a default

On OTP 29, a server listener with NO `supported_groups` option (OTP
defaults) still selects mlkem against an mlkem-only client:

```
DEFAULT-pref-server + mlkem-only-client: {:ok, [selected_group: :x25519mlkem768]}
```

So the flip is behaviorally a no-op for OTP 29 clients today; it is an
explicit pin that makes the preference durable against future OTP default
reordering, and it is the documented intent. On OTP 28 the atom is refused
(pre-existing comment in `lib/smalt/tls.ex` and the R90/D52 history), so the
mlkem branch correctly rides the tlsv1.3 gate.

## Go leg (tmp/imp14)

Go 1.23.4 (system `go`, /usr/local/go) has no `tls.X25519MLKEM768` (constant
added in Go 1.24) and rejects `CurveID(0x4588)` with
`tls: CurvePreferences includes unsupported curve`. Go 1.24.0 was fetched to
`tmp/imp14/go/` and used for the witness. Client source `tmp/imp14/main.go`
(TLS 1.3, `InsecureSkipVerify` for the loopback dev cert), three modes:

```
RESULT mode=mlkemonly prefs=[X25519MLKEM768] err="tls: no supported elliptic curves for ECDHE" elapsed=626.209µs exit=1
RESULT mode=mlkem    prefs=[X25519MLKEM768 X25519] version=0304 cipher=1301 alpn="" elapsed=2.561875ms exit=0
RESULT mode=x25519   prefs=[X25519] version=0304 cipher=1301 alpn="" elapsed=2.392167ms exit=0
```

- `mlkem-first` PASS: with the server preference also mlkem-first, both
  preference orders intersect at X25519MLKEM768 — the Go handshake negotiated
  the hybrid KEM.
- `mlkemonly` FAIL is a **Go 1.24.0 client-side restriction** (Go requires at
  least one ECDHE-capable curve in CurvePreferences; the identical mlkem-only
  offer succeeds from an OTP 29 client against the same listener), not a
  server divergence. Typed open residual: a Go client cannot currently
  single-shot-pin mlkem.

## Live-twin evidence

- Substrate booted from `_build-bk2` (flip included): `scripts/substrate.sh up`
  → all four ports UP (pid 53160), lock released after the boot window.
- OTP 29 client, `supported_groups: [:x25519mlkem768]` vs 9444:
  `{:ok, [protocol: :"tlsv1.3", selected_group: :x25519mlkem768]}`
  (server-side confirmation the twin negotiates the hybrid KEM).
- Regression: `curl --cacert .smalt/tls/ca-cert.pem
  https://127.0.0.1:9444/metadata/endpoints` → `status=200 ssl_verify_result=0
  CURL_EXIT=0`.

## Falsifier status

- Flip non-vacuity: mlkem-only client against a listener without the option
  was NOT separately witnessed pre-flip on this lane (the pre-flip window
  ran a foreign build root); the default-vs-pin equivalence above closes the
  behavioral question for OTP 29 — flip matters only on future OTP defaults
  or OTP 28 (which refuses the atom). Typed as witnessed-equivalence, not a
  before/after flip court.
- Go mlkem-only single-shot pin: UNSUPPORTED (Go 1.24 client-side validation,
  quoted error above). Close condition: Go toolchain ≥ 1.25 or OTP-side
  capture of the Go-negotiated group.
- **Close-out (2026-10-22, BK-2/BK-2b)**: the raw-KEM interop gap this
  receipt described ("proven only against itself plus a TLS-handshake-shape
  Go leg") is closed — `../../v26.10.22/receipts/bk2-mlkem-go-leg.md` /
  `bk2b-mlkem-closeout.md` witness real ML-KEM-768 byte exchange Go↔OTP 29
  (both legs ss_match=true; corrupted ct → implicit rejection both sides,
  replay exit 0). The Go mlkem-only *TLS pin* restriction above remains
  UNSUPPORTED as typed: it is Go client-side CurvePreferences validation,
  not a raw-KEM matter, and is untouched by the raw-KEM probe.

## Commands (replay)

```
export PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$HOME/.asdf/installs/erlang/29.1.2/bin:$PATH"
export MIX_BUILD_ROOT=_build-bk2
mix compile                                  # exit 0 (268 beams)
scripts/substrate.sh up                      # exit 0, 4 ports UP
tmp/imp14/imp14client mlkem                  # exit 0
tmp/imp14/imp14client x25519                 # exit 0
tmp/imp14/imp14client mlkemonly              # exit 1 (Go client-side)
curl --cacert .smalt/tls/ca-cert.pem https://127.0.0.1:9444/metadata/endpoints  # 200
```
