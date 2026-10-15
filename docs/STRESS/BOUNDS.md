# BOUNDS Stress Receipt

Harness: `scripts/stress/bounds.py` (stdlib-only; boots its own substrate via
`gates/common.py` on private `SMALT_TEST_*_PORT` ports, kills it in a
`finally` trap). Receipt: `tmp/invariant-gates/bounds-receipt.json`
(schema `smalt-bounds-receipt/v1`). Fail-closed: exit 0 only when every
documented bound engages at its documented edge; any non-engaging bound is a
FINDING and exits 1.

## Bounds Table

| # | Bound | Documented | Engaged at (measured) | Error shape (measured, live substrate) | Verdict |
|---|---|---|---|---|---|
| 1 | Queue capacity | 4096 messages/queue | 4097th transfer, exactly at the boundary | link close `amqp:link-message-size-exceeded` + `:capacity` (`QueueStore.enqueue {:error,:capacity}`) | ENGAGED |
| 2a | Blob PUT payload | TWO bounds: (i) 1 MiB per-PUT blob fence (`blob_storage.ex:62 @max_put_bytes 1_048_576`, checked in `put_blob/5` after container-exists, so 404 `ContainerNotFound` outranks 413); (ii) 8,000,000-byte egress request-body cap (`egress_router.ex:868 read_body length: 8_000_000` -> `{:more, ...}` -> 413) | Wire probe (2026-10-15, bounds.py run): 1MiB-1 / 1MiB -> **201**; 1MiB+1 -> **413** `RequestBodyTooLarge` "Blob exceeds the 1,048,576-byte per-PUT limit"; 8,000,000 -> 413; 8,000,001 -> 413 | HTTP 413 `{"error":{"code":"RequestBodyTooLarge","message":"Blob exceeds the 1,048,576-byte per-PUT limit (RequestBodyTooLarge)."}}` | ENGAGED — both fences measured live; the earlier "no 1MiB blob bound" F1 doc-fix is superseded by the blob lane's fence landing (blob_hardening_test.exs ST6 B) |
| 2b | AMQP message body | 1 MiB max body | 1MiB-1 accepted, 1MiB accepted at boundary (`>` not `>=`), 1MiB+1 refused | link close `amqp:link-message-size-exceeded` + `:too_large` (`QueueStore @max_body`) | ENGAGED |
| 3 | Lock duration clamp | 100..30000 ms | PT1H->30000, PT0S->100, PT5S->5000 (deltas 29999/99-100/5000, tol 2s) | `x-opt-locked-until` delta matches the clamped duration, not the requested one (`LockManager.clamp_duration`) | ENGAGED |
| 4 | CBS claims cap | 128 claims; over-capacity put-token -> 429 `CLAIM_CAPACITY` | fresh claim #123 of the probe = claim #128 total (6 pre-existing claims from prior probe authorizations: capacity 1 + lockclamp 3 + payload 1 + frame 1), i.e. the 129th fresh claim -> 429 | monotone 200s then 429s; `{429, "CLAIM_CAPACITY"}` (`CbsRouter @max_claims 128`) | ENGAGED (cap total = 128; documented "129th" is true only on a fresh claims table) |
| 5 | KQL caps | 2000 chars / depth 20 / take 1000 | len 2001 -> 400, depth 21 -> 400, take 1001 -> 400; take 1000 ok, 20-term `and` chain ok. NOTE: an exact-2000-char query with a string literal also -> 400, because the KQL-subset parser does not support string literals right of `==` ("expected number after ==") — unrelated to the length gate (in-process: byte_size 2000 passes the length check, 2001 -> `{:limit, "query length exceeds 2000"}`) | 400 `BadQuery` `{limit, ...}` from `KQL.run` via ResourceGraph (api-version 2022-10-01) | ENGAGED |
| 6 | Ledger dedup | duplicate append -> 409 `LedgerItemAlreadyExists` | 100 rapid duplicate appends -> exactly 1x201 + 99x409 | 409 under full-rate repetition (no dedup decay at scale) | ENGAGED |
| 7 | AMQP frame size | frame > 1 MiB refused | declared frame size 1MiB+4KiB, refused on the declared size before the body arrives | connection close `amqp:internal-error` with `:frame_too_size` (`FrameCodec @max_frame_size` = 1 MiB+512). NOTE: over-the-wire shape is `internal-error`/`frame_too_size`, not `link-message-size-exceeded` | ENGAGED |

## Findings

- **F1 (bound 2a, RESOLVED 2026-10-15)**: the "no 1 MiB blob-size bound"
  finding is superseded — the blob lane landed the real fence
  (`blob_storage.ex:62 @max_put_bytes 1_048_576` -> 413
  `RequestBodyTooLarge` at 1 MiB+1, `put_blob/5` checks container-exists
  first so 404 outranks 413; pinned by `blob_hardening_test.exs` ST6 B).
  The 8,000,000-byte egress request-body cap
  (`lib/smalt/egress_router.ex:868 read_body length: 8_000_000` -> 413)
  remains as the second, distinct bound. Wire probe receipt: 1MiB-1/1MiB ->
  201, 1MiB+1 -> 413 per-PUT-limit message. See updated bound 2a row above.
- **F1.5 (vacuity fix, applied)**: the KQL HTTP probes originally used
  `api-version=2021-03-01`; every request returned 400 `InvalidApiVersion`
  BEFORE reaching KQL, so "len2001/depth21/take1001 -> 400" passed for the
  wrong reason. Fixed to `api-version=2022-10-01` (resource_graph.ex:14);
  the 400s are now genuine `BadQuery` from `KQL.run`.
- **F2 (bound 4, observation)**: the CBS cap is a hard 128 total claims, not
  "128 per probe" — authorizations from earlier probes occupy claims, so a
  driver that authorizes first sees its first 429 before its own 129th
  put-token. The cap itself is fail-closed and monotone (no 200 after the
  first 429). Docs quoting "129th put-token -> 429" should state it holds on
  a fresh claims table.

## Repro

```
python3 scripts/stress/bounds.py          # exit 0 = all bounds engaged, 1 = FINDING
SMALT_GATE_LOG=tmp/bounds-substrate.log python3 scripts/stress/bounds.py
```

AMQP probes run via an embedded Elixir driver written to
`tmp/bounds_driver.exs` (scratch; one `mix run` covers payload + frame + CBS
to keep the run under the compile overhead of repeated VM boots). Probes 1/3
reuse `gates/amqp_invariant_driver.exs` modes `capacity`/`lockclamp` through
`gates/common.py`.

Last full run (after the 2a gate doc-fix and the KQL api-version vacuity
fix): **20/20 checks PASS, verdict PASS, exit 0**, receipt
`tmp/invariant-gates/bounds-receipt.json`, 2026-10-15, MIX_ENV=test substrate
on private ports (arm 52275 / amqp 52278 / egress 52277 / mcp 52280).
Later run same day (docs-corpus lane, post-blob-fence): **verdict FAIL, exit
1** — the gate still asserts the superseded 2a contract (no 1 MiB bound) and
observed len2001 -> HTTP 200 on bound 5; row 2a above documents the new
fence. `scripts/stress/bounds.py` needs its 2a expectation updated (and
bound-5 length-gate engagement re-checked) before the gate returns PASS.

Complementary in-process exact-boundary receipt (own VM + Store): earlier
`tmp/bounds-receipt.json` phase A — capacity 4096 accepted / 4097th
`{:error,:capacity}` / drain-and-reaccept; CBS 128x200 then 129th
`{429,"CLAIM_CAPACITY"}` on a fresh claims table; ledger 1500 distinct
appends + 5/5 duplicate re-appends refused with chain tip 1500.1; lock clamp
99/100/30000/30001/nil; SB payload 1048575/1048576 accepted, 1048577
`:too_large`; FrameCodec at-limit `{:more, 1049088}`, over `:frame_too_size`.

## See Also

- `gates/queue_capacity_gate.py`, `gates/lock_clamp_gate.py` (single-bound
  gates with negative fixtures)
- In-process exact-boundary drivers preserved in `tmp/bounds_elixir.exs`
  (store-layer 4096/4097, 128/129 fresh-table, 1500-append dedup) — embedded
  evidence for rows 1/4/6 at the exact boundary, independent of wire timing
- `docs/STRESS/AMQP_TPUT.md` (AMQP driver pattern source)
- `docs/ERROR_CODES.md` (status/error-code surface)
