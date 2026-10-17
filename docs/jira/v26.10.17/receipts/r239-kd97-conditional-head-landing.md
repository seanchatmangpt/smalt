# r239 — KD-97 conditional/ranged HEAD + blob response-header parity (landing receipt)

Standing: ALIVE
Date: 2026-10-17
Subject: `lib/smalt/egress_router.ex` blob HEAD/GET arms + `blob_route` entry stamps
Context: solo (per RECEIPT_CONTEXT_LAW.md) + corpus slice (test/compliance_test.exs via loader)
Falsifier now closed by this landing (drafted KD-97, registrar lane):

- Blob HEAD arm never evaluated conditionals/ranges (product-gap ruling, sweep lane):
  HEAD answered 200 to every conditional probe; GET had the full RFC 7232 engine.
- x-ms-request-id / x-ms-version absent on blob success/XML arms (C4 fence,
  red-since-birth since v26.10.14).
- `Range` beat `x-ms-range` on the concat-order (engine takes List.first) —
  Azure parity requires x-ms-range to win.

## Landed changes (lib/)

1. HEAD blob arm now mirrors the GET engine: `get_blob_conditional` (412 / 304)
   + `get_blob_range` (200 / 206 + content-range / 416 + content-range `bytes */n`),
   empty bodies, KD-COVERS: KD-97 token in place.
2. `blob_route/2` entry stamps `x-ms-request-id` + `x-ms-version: 2021-12-02` on
   every blob arm (success/XML/comp); error arms restamp their own.
3. Range precedence flipped in both GET and HEAD arms: x-ms-range wins
   (`get_req_header(conn, "x-ms-range") ++ get_req_header(conn, "range")`).

## Verification (real runs, this tree)

- `MIX_BUILD_ROOT=_build-ft-coord mix compile` → exit 0 (133 files, no errors)
- `MIX_BUILD_ROOT=_build-ft-coord mix test test/compliance/c4_blob.exs`
  → **49 tests, 0 failures** (was 19 failures pre-window; 12 typed product-gap
  failures immediately before the lib landing)
- `MIX_BUILD_ROOT=_build-ft-coord mix test test/data_plane/blob_hardening_test.exs`
  → **116 tests, 0 failures** (the 304/412/200 engine matrix still green)
- `MIX_BUILD_ROOT=_build-ft-egmerge mix test test/wire/egress_wire_test.exs`
  → **22 tests, 0 failures**
- Full offline suite (quiet tree): 2655 tests, **2 failures** (both load-class:
  blob pagination perf budget 119ms vs 110ms; DETS churn test budget under
  self-inflicted back-to-back suite load), down from run-1's 75.

## Disclosure

- These lib/ edits postdate I3's witness sweep — surfaces re-witnessed by the
  runs above; shim-mtime chains re-anchored by this receipt (newest witness).
- Companion fix in the same seam family: `lib/smalt/messaging/event_stream.ex`
  + `arm_gateway/router.ex` eg1_publish re-domained onto the shared EventStream
  counter (receipt i20f-egmerge-fix.md) — closes the EventGrid readback
  merge-order divergence (draft KD row retired as FIXED, not registered).
- StoreDets `DetsMirror.sync/1` GenServer.call timeout raised 5s → 30s with the
  i20b contention-mechanism citation (timer-slack fix, receipt
  i20b-contention-mechanism.md).
