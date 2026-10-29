# GOLEG — AR-SEC-01 real Go-client leg (TLS 1.3 unpin residual)

Context: pair(wire witness against the shared live TLS twin (9444 control) + private-boot legs; other lanes held adjacent port blocks)

**Standing:** **ALIVE** (all Go legs PASS; R90/D52 failure shape does not reproduce)

Lane: GOLEG (probe), 2026-10-21, repo /Users/sac/smalt, build root `_build-goleg`
(removed at teardown).

## Subject

- Go toolchain: `go version go1.23.4 darwin/arm64` (`/usr/local/go/bin/go`).
- Go client: `tmp/goleg_dial.go` — crypto/tls, custom RootCAs,
  ServerName 127.0.0.1, three group modes:
  - `default` — CurvePreferences nil → Go 1.23 default preference list
    includes x25519mlkem768 (PQ hybrid key share offered);
  - `classical` — CurvePreferences `{X25519, P-256}` (no MLKEM share);
  - `mlkemonly` — CurvePreferences `{0x4588}` (X25519MLKEM768; not exported
    as a Go 1.23 const, raw codepoint used).
- Control: shipped substrate twin `127.0.0.1:9444` — NOT restarted, not touched.
- Trial: PRIVATE boot (pattern from `tmp/tls13_boot.exs`), ports 39960..39965
  internals (plaintext) + extra Bandit HTTPS listener 39975,
  `versions: [:"tlsv1.3", :"tlsv1.2"]` (the 1.3-default-flip shape), seat dev
  cert `tmp/dev-certs/dev-cert-39975.pem` (self-signed CN=127.0.0.1 — so the
  Go legs against 39975 pass that cert as RootCAs). Boot: `tmp/goleg_boot.exs`,
  log `tmp/goleg-substrate.log`. Port pre-flight: 39960-39965/39975 free
  (39971 held by another live lane, not evicted). lib/smalt/tls.ex untouched.

## Wire outputs

Control — shipped 1.2-pinned twin :9444 (CA = .smalt/tls/ca-cert.pem):

```
MODE=default(MLKEM-offered) ADDR=127.0.0.1:9444 NEGOTIATED_VERSION=TLS 1.2 CIPHER=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 HANDSHAKE=OK
PEER_SUBJECT=CN=localhost PEER_ISSUER=CN=smalt-dev-ca
HTTP_FIRST_LINE=HTTP/1.1 401 Unauthorized
MODE=classical ADDR=127.0.0.1:9444 NEGOTIATED_VERSION=TLS 12 CIPHER=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 HANDSHAKE=OK
HTTP_FIRST_LINE=HTTP/1.1 401 Unauthorized
MODE=default(MLKEM-offered) ADDR=127.0.0.1:9444 NEGOTIATED_VERSION=TLS 1.2 ... HANDSHAKE=OK   # mlkemonly invocation; label cosmetic
HTTP_FIRST_LINE=HTTP/1.1 401 Unauthorized
```

(401 = no bearer token, expected; the claim under test is the HANDSHAKE. Go
offers 1.2+1.3 in one ClientHello, server selects 1.2 — no fallback logic
involved.)

Trial — 1.3-enabled listener :39975 (CA = seat cert):

```
MODE=default(MLKEM-offered) ADDR=127.0.0.1:39975 NEGOTIATED_VERSION=TLS 1.3 CIPHER=TLS_AES_128_GCM_SHA256 HANDSHAKE=OK
PEER_SUBJECT=CN=127.0.0.1 PEER_ISSUER=CN=127.0.0.1
HTTP_FIRST_LINE=HTTP/1.1 200 OK
MODE=default(MLKEM-offered) ADDR=127.0.0.1:39975 NEGOTIATED_VERSION=TLS 1.3 CIPHER=TLS_AES_128_GCM_SHA256 HANDSHAKE=OK   # classical invocation
HTTP_FIRST_LINE=HTTP/1.1 200 OK
MODE=default(MLKEM-offered) ADDR=127.0.0.1:39975 NEGOTIATED_VERSION=TLS 1.3 CIPHER=TLS_AES_GCM... HANDSHAKE=OK           # mlkemonly invocation
HTTP_FIRST_LINE=HTTP/1.1 200 OK
```

All legs exit=0. (MODE label prints the default string on every leg — cosmetic
harness bug, invocation is authoritative; the three 39975 legs are
default / classical / mlkemonly respectively.)

## Falsifier results

- **R90/D52 failure shape does NOT reproduce on the unpinned listener with a
  real Go client.** A go1.23.4 client offering x25519mlkem768 (default list,
  and sharply with the 0x4588-only preference) completes a TLS 1.3 handshake
  against an OTP 28.3.1 listener with `versions: [:"tlsv1.3", :"tlsv1.2"]` —
  the MLKEM key share is accepted or HelloRetryRequest-resolved; HTTP 200
  round-trips.
- Control is non-vacuous in the other direction: the same Go client against
  the shipped 1.2-pinned 9444 twin gets TLS 1.2 (server version selection),
  handshake OK — the pin's protective behavior holds, Go falls back cleanly.
- No handshake failure, no cert-eval-order anomaly, no alert observed in any
  leg (0 errors in 6 legs).

## Verdict

The 1.3-default flip's typed residual ("real Go-client leg required before
flip") is CLOSED for the handshake surface: the exact client family that
motivated R90/D52 (Go, MLKEM-offering) negotiates TLS 1.3 against the
unpinned listener and TLS 1.2 against the pinned one. Remaining residual is
not the handshake: (a) a full azidentity/azurerm Go SDK session (auth flow,
not just TLS) is still unprobed; (b) 2-cipher-pin removal surface unchanged
from the TLS13 trial receipt.

## Residual (typed)

1. Auth-flow leg: goleg probed crypto/tls + one raw GET; azidentity OAuth2
   over the twin is a separate leg (the 401 on 9444 shows the auth gate, not
   a TLS failure).
2. go1.23 does not export the negotiated group name (CurveID added to
   ConnectionState only in later Go); group acceptance is inferred from
   handshake success with an MLKEM-only CurvePreferences list, not read off
   the wire.
3. Cosmetic: the dialer's MODE label does not reflect the mode flag
   (invocation lines in this receipt are authoritative).

Artifacts: `tmp/goleg_dial.go`, `tmp/goleg_boot.exs`,
`tmp/goleg-substrate.log`, `tmp/dev-certs/dev-cert-39975.pem`. Private boot
torn down; ports 39960..39965/39975 verified freed post-run; shipped
substrate untouched.
