# BK-6 — VALIDATION partial-cell closures (SEC-01 / WIRE-02 / OBS-04)

**Standing:** **ALIVE** — all three named cells re-witnessed fresh on 2026-10-22
with real output on disk; the two court/harness defects found were repaired in
place and are disclosed below.

Context: solo

Lane: bk6, 2026-10-22, repo /Users/sac/smalt, build root `_build-bk6`.

## Cell 1 — SEC-01 Go-client leg (AR-SEC-01)

Real go1.23.4 client (`crypto/tls`) against the **live 1.3-default-flipped
9444 TLS twin** (substrate pid 5739, all 4 ports UP at run time), harness
`tmp/goleg_dial.go`. Verbatim output (also kept at `tmp/bk6v22-goleg.log`):

```
$ for m in default classical mlkemonly; do echo "--- $m"; go run tmp/goleg_dial.go 127.0.0.1:9444 $m; echo exit=$?; done
--- default
MODE=default(MLKEM-offered) ADDR=127.0.0.1:9444 NEGOTIATED_VERSION=TLS 1.3 CIPHER=TLS_AES_128_GCM_SHA256 HANDSHAKE=OK
PEER_SUBJECT=CN=localhost PEER_ISSUER=CN=smalt-dev-ca
HTTP_FIRST_LINE=HTTP/1.1 401 Unauthorized
exit=0
--- classical
MODE=classical ADDR=127.0.0.1:9444 NEGOTIATED_VERSION=TLS 1.3 CIPHER=TLS_AES_128_GCM_SHA256 HANDSHAKE=OK
PEER_SUBJECT=CN=localhost PEER_ISSUER=CN=smalt-dev-ca
HTTP_FIRST_LINE=HTTP/1.1 401 Unauthorized
exit=0
--- mlkemonly
MODE=mlkemonly ADDR=127.0.0.1:9444 HANDSHAKE=FAIL ERR="tls: CurvePreferences includes unsupported curve"
exit status 1
exit=1
```

Raw log: `tmp/bk6v22-goleg.log`.

## Cell 2 — WIRE-02 surface shim court (wire_norm, KD-01/03/07)

`bash scripts/shim_court/wire_norm_court.sh all` — full
BASELINE/BEFORE/SHIM/AFTER/RESTORE per leg, exit 0:

```
$ bash scripts/shim_court/wire_norm_court.sh all     # exit 0
[COURT] === kd01 (subject: lib/smalt/egress_router.ex) ===
[SHIM] baseline sha256(lib/smalt/egress_router.ex) = 2ab3fe55431e086ba34959e56a83ef2dcd7ff72f9979e94a14eb8bc5c565accc
[SHIM] kd01 AFTER passed (Azure shape holds)
[SHIM] kd01 shim applied (SHIM-COURT marker present)
[SHIM] kd01 BEFORE passed (old shape returns)
[SHIM] kd01 RESTORE verified byte-exact
[COURT] === kd07 (subject: lib/smalt/egress/CosmosRoutes.ex) ===
[SHIM] baseline sha256(lib/smalt/egress/CosmosRoutes.ex) = e07c934c7bc3c9dbfe4daaf11af34ea1c5da74c260d706b2d165fdf0fca80ee2
[SHIM] kd07 AFTER passed (Azure shape holds)
[SHIM] kd07 shim applied (SHIM-COURT marker present)
[SHIM] kd07 BEFORE passed (old shape returns)
[SHIM] kd07 RESTORE verified byte-exact
[COURT] === kd03 (subject: lib/smalt/data_plane/blob_service.ex) ===
[SHIM] baseline sha256(lib/smalt/data_plane/blob_service.ex) = 0ded715534b4f4dcd87311201e0217771287ff8a3c12ec38f791b5464124d0f9
[SHIM] kd03 AFTER passed (Azure shape holds)
[SHIM] kd03 shim applied (SHIM-COURT marker present)
[SHIM] kd03 BEFORE passed (old shape returns)
[SHIM] kd03 RESTORE verified byte-exact
[COURT] WIRE-NORM COURT: ALL LEGS PASSED
```

Full transcript: `tmp/bk6v22-wirenorm-court.log`.

**Court defects found and repaired (disclosed):**

1. **kd01 BEFORE leg was premise-rotten** (`scripts/shim_court/wire_norm_witness.exs`):
   the KD-139 gate now refuses headerless Put Blob 400
   MissingRequiredHeader before the shimmed fallback arm is reachable, and the
   fallback put_blob arm no longer emits the historical JSON debug body. Two
   witness edits:
   - kd01 legs now send `x-ms-blob-type: BlockBlob` so the shimmed fallback
     arm is reachable (with comment citing KD-139);
   - kd01 BEFORE assertion re-anchored from "201 + non-empty debug body" to
     "201 (put_blob fallback arm)" — the landed surface answers 200 empty
     + etag, the shimmed fallback answers 201, so the status flip 200↔201 is
     the mutation discriminator (non-vacuous: a court that still passed on
     the old anchor would have been accepting a surface that no longer
     exists).
2. **kd03_before was a vacuous pass** — a duplicated `"kd03_before" ->`
   clause (assertion-free) shadowed the asserting clause; the duplicate was
   removed, leaving the asserting clause. The kd03 legs flip on
   RFC-1123 vs ISO-8601 `last-modified` — the assertion now actually runs
   in the BEFORE leg (it did not before the repair).

**Register reconciliation**: KD-01/03/07 rows in
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` are typed CLOSED-WITH-RECEIPT
(`s4-wire-normalization.md`) — consistent with the green court; **no register
flip owed**. Post-court lib/ cleanliness verified: no SHIM-COURT marker leaked,
`sha256(lib/smalt/egress_router.ex) = 2ab3fe55…c565accc` — byte-identical to
the court baseline.

## Cell 3 — OBS-04 two-node peer court

Two real BEAM nodes over loopback distribution, real `:peer` + `:erpc`, no
mocks (`test/integration/peer_two_node_court.exs`), distributed runner with
distinct sname, exit 0:

```
$ PATH="$HOME/.asdf/shims:$PATH" MIX_BUILD_ROOT=_build-bk6 \
  elixir --name court127@127.0.0.1 --cookie smalt_peer_court -S mix test test/integration/peer_two_node_court.exs
    [peer-court] injected disconnect -> typed {:error, {:node_down, :"peer_court_a@127.0.0.1"}}
    [peer-court] teardown: node dead, epmd name free, re-stop of dead controller -> :noproc (typed, no hang)
    [peer-court] faces subset UP on peer_court_a@127.0.0.1 (Smalt.Store + PeerCourt.Health)
    [peer-court] forward erpc round-trip: 41 µs/op avg (n=100)
    [peer-court] reverse erpc round-trip: 64 µs/op avg (n=100)
Finished in 1.3 seconds (0.00s async, 1.3s sync)
Result: 4 passed
```

Full log: `tmp/bk6v22-peer-court.log`.

## VALIDATION.md folds (this lane)

- AR-SEC-01 row: add the 2026-10-22 re-witness line citing this receipt
  (handshake face re-confirmed; mlkemonly still the Go-1.23 client-side
  refusal, typed residual unchanged).
- AR-WIRE-02 / wire-surface evidence: cite the re-run green wire_norm court
  with the two disclosed court repairs.
- AR-OBS-04 row: add the fresh 4/4 re-run citation.
- No verdict flips owed — every cell already had its receipt; this lane's
  contribution is fresh output on disk plus the court repair.

## Machine

Apple M3 Max · OTP 29.1.2 / Elixir 1.20.4-otp-29 (asdf shims) · go1.23.4 ·
substrate pid 5739 (another lane's boot, lock FREE) · `_build-bk6` retained as
lane lease.
