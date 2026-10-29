# KD-115 Post-Shim Witness 2 (B-K3, mtime cure)

- **Standing: PASS**
- Date: 2026-10-21 10:14–10:19 PDT
- Subject: `/Users/sac/smalt` @ branch `main`, HEAD `63b42c7` (committed tree; this lane made no lib edits, no git ops)
- Shim: `lib/smalt/messaging/amqp/connection.ex` carries `# KD-COVERS: KD-115 — deliver_available/1 runs only on the :flow path` (ingest-tail dispatch)
- Shim mtime: **2026-10-21 00:38:49** (`stat connection.ex` re-read this lane, 10:04 PDT) — both falsifier artifacts below (10:14–10:19 PDT) postdate it, curing the receipt-predates-shim condition on `kd115-post-shim-witness.md` (Oct 20 23:08) for the `kd_flip.py --apply` gate.
- Toolchain: host asdf pin `elixir 1.20.3-otp-28` (via `~/.asdf/shims`; note `elixir` on the ambient PATH is homebrew 1.19.5 — all commands below ran with shims first).

## Leg 1 — internal-tier gate

Command: `MIX_BUILD_ROOT=_build-bk3 mix test test/internal/kd115_credit_first_delivery_test.exs` (private build root, not the shared `_build`)

```
Running ExUnit with seed: 737277, max_cases: 32

.
Finished in 10.9 seconds (0.00s async, 10.9s sync)

Result: 1 passed
EXIT=0
```

## Leg 2 — TS falsifier probe (private block b42, swept at exit)

Command: `KD115_BLOCK=b42 node verification/ts/kd115.probe.cjs`

```
PASS plain-credit-first: received 3/3 (credit-first, no reflow)
PASS session-credit-first: received 3/3 (credit-first, no reflow)
PASS kd116-session-settle: settled 3/3, re-receive 0 (expect 0)
EXIT=0
```

Block b42 sweep verified post-exit: ports 39420–39425 have no LISTEN sockets.

## Disclosures (honest log)

- Compile-freeze window, not a KD-115 failure: this lane's first leg-1 run
  (started ~10:05) executed the test and failed at the test's port-boot line
  while a concurrent lane's IN-FLIGHT edits had `lib/smalt/egress_router.ex`
  (MismatchedDelimiterError at :1609) and `lib/smalt/data_plane/blob_error.ex`
  (missing Plug imports) failing to compile (files mtimes 10:06:00/10:06:36).
  Per the compile-freeze SLA I polled with a bounded loop; the owner healed the
  tree at ~10:09 (egress_router.ex mtime 10:09:19), compile went green, and the
  green runs above are the witness. The pre-heal failure was transport noise
  from the shared-tree break, not the KD-115 surface.
- Prior receipt not superseded on findings — this is a fresh mtime-cured
  re-witness of the same two falsifiers on the current committed tree.
- Flip NOT performed (witness-only lane; flip belongs to `kd_flip.py --apply`).
