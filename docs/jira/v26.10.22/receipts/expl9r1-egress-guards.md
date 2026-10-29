# EXPL9-R1 — egress router read_body guards + crash-path fence (EXPL-9 F2/F4)

**Standing:** ALIVE
Context: solo
Date: 2026-10-22
Lane: EXPL9-R1 (owns lib/smalt/egress_router.ex + court test)

## Repairs

Source of findings: `docs/jira/v26.10.22/receipts/expl9-egress-arm-errc.md`
(F2 HIGH witnessed, F4 LOW).

### F2a — put_range read_body guard (KD-COVERS: KD-174)

`lib/smalt/egress_router.ex`, `{:put_range, s, p}` arm: the unguarded
`{:ok, body, _conn} = Plug.Conn.read_body(conn)` is now the canonical
`blob_block_arm` case shape (egress_router.ex ~2549):

- `{:ok, body, _conn}` → unchanged `FileShare.put_range` dispatch
- `{:more, partial, _conn}` → `send_file_error(conn, 413, "RequestBodyTooLarge", …)`
  (file-face XML envelope, x-ms-request-id + x-ms-error-code headers)
- `{:error, reason}` → typed 400 `InvalidRequestBody`

### F2b — Plug.ErrorHandler crash-path fence (GAP-AZB20-3 class)

Added `use Plug.ErrorHandler` + `defp handle_errors/2` to
`Smalt.EgressRouter` (arm_gateway router's GAP-AZB20-3 handler is the
in-repo template). Any unhandled crash now renders the Storage
`<Error><Code>InternalServerError</Code>…` XML envelope with a fresh
`x-ms-request-id` — never a naked Bandit adapter 500. The handler is
state-guarded (`conn.state in [:unset, :set]`) and logs the crash reason
(`egress_router crash 500: …`).

### F4 — service-properties arm same guard

`put "/:account"` (`?restype=service&comp=properties`) arm: same canonical
case; `{:more,_,_}` → `blob_error 413 RequestBodyTooLarge` (blob face, so
the XML envelope via BlobError), `{:error,_}` → 400 `InvalidRequestBody`.
Happy path moved verbatim into the `{:ok, body, conn}` arm — semantics
unchanged.

## Court

`test/internal/expl9r1_egress_guard_court_test.exs` — real HTTP (:httpc)
against the REAL self-booted EgressRouter on the ephemeral test egress
port, real 9MB bodies, no mocks, no sleeps.

```
$ MIX_BUILD_ROOT=_build-expl9r1 MIX_ENV=test mix test test/internal/expl9r1_egress_guard_court_test.exs
...
05:10:17.972 info[] PUT /expl9r1share-absent-7684/d/f.txt
05:10:17.973 info[] Sent 404 in 183µs
Finished in 15.3 seconds (0.00s async, 15.3s sync)

Result: 5 passed
```

Falsifier legs:

1. **F2 flip**: 9MB `PUT /expl9r1share/expl9r1dir/expl9file.txt?comp=range`
   → **413 RequestBodyTooLarge** XML envelope with `x-ms-request-id` +
   `x-ms-error-code`. The EXPL-9 witness (P3: HTTP=500, EMPTY body, no
   envelope, no request id) is flipped — never a naked 500, never a
   MatchError.
2. **F2 baseline**: small-body `comp=range` on an absent share keeps the
   typed **404 ShareNotFound** envelope (route reachability unchanged).
3. **F4 flip**: 9MB `PUT /:account?restype=service&comp=properties` with a
   valid `x-ms-version` → **413 RequestBodyTooLarge**.
4. **F4 baseline**: small `<StorageServiceProperties />` stays typed
   (202 accepted / 400 parse), no crash.
5. **F2b fence**: source-level fence leg — `use Plug.ErrorHandler` +
   `handle_errors` rendering `error_xml("InternalServerError", …)` with
   `x-ms-request-id` (wire-level deliberate-crash injection is out of scope
   for this lane; the handler is the GAP-AZB20-3 template shape).

## Regression

```
$ MIX_BUILD_ROOT=_build-expl9r1 MIX_ENV=test mix test test/internal/kd_blob_court_test.exs test/internal/kd_conf_court_test.exs test/integration/blob_kd_fixes_test.exs test/integration/blob_xml_error_test.exs
Result: 35 passed
```

kd_blob / kd_conf / blob courts green — small-body behavior byte-identical.

## Disclosed compile-freeze unblock (another lane's file)

`lib/smalt/attestation/maa.ex` was dirty in the session snapshot and did
not compile (in-flight edit bound `reserved` in a `with` clause and read it
in the `else` block — with/else scoping makes that an undefined variable,
confirmed by the compiler error). Under the compile-freeze SLA I applied a
minimal faithful unblock: hoist the pure `decode_runtime/1` call above the
`with` so the else derives the reserved nonce from the result; clause order
(error precedence) unchanged. `mix test test/internal/az2_maa_attestation_court_test.exs`
→ **7 passed**. The owning lane subsequently landed its own KD-169R unblock
comment in the same file; both edits coexist. **I did NOT stage maa.ex** —
it belongs to the owning lane.

## KD note

`# KD-COVERS: KD-174` fences are in place at both guard sites and the
crash-path fence. The KD-174 row itself ("egress file/service-properties
faces answer naked 500 instead of 413 RequestBodyTooLarge on >8MB bodies;
no crash-path fence") is minted/closed by the kd-registrar per register
law — close condition satisfied by falsifier legs 1 and 3 above.

## Footer

Build root `_build-expl9r1` (lane-owned; coordinator reclaims at
integration). Files touched: `lib/smalt/egress_router.ex`,
`test/internal/expl9r1_egress_guard_court_test.exs` (new), this receipt.

## KD-175 Disposition

KD-175 (oversized-body naked 500) is closed by this receipt: the repair
landed in dd73b160 with `# KD-COVERS: KD-175` fences at
`lib/smalt/egress_router.ex` (5 sites), court 5/5 passed (Standing: ALIVE
above), and this receipt postdates the shim mtime. Disposition: flip
KD-175 OPEN → CLOSED-WITH-EVIDENCE via `scripts/kd_flip.py --apply`,
witness = this receipt. Appended by lane KD-175F 2026-10-22 (the row's
close condition names this receipt as the flip witness; the body above is
EXPL9-R1's, unmodified).
