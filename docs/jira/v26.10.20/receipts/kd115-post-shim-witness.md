# KD-115 Post-Shim Witness (W16-A)

- **Standing: PASS**
- Date: 2026-10-20 23:07–23:08 PDT
- Subject: `/Users/sac/smalt` @ branch `main`, HEAD `9c64f17` (working tree unchanged by this lane; no lib edits, no git ops)
- Shim: `lib/smalt/messaging/amqp/connection.ex` line 1595 carries `# KD-COVERS: KD-115 — deliver_available/1 runs only on the :flow path`
- Shim mtime: **2026-10-20 23:01:52** — this witness (artifacts below) postdates it, curing the W13-J receipt-predates-shim condition for the `kd_flip.py --apply` gate.
- Falsifier artifacts re-run post-shim, both green:
  1. `mix test test/internal/kd115_credit_first_delivery_test.exs` (MIX_BUILD_ROOT=_build-w16a, toolchain via asdf shims)
  2. `node verification/ts/kd115.probe.cjs` (3 legs, private block b13, port sweep at exit)

## Leg 1 — internal-tier gate

Command: `MIX_BUILD_ROOT=_build-w16a mix test test/internal/kd115_credit_first_delivery_test.exs`

```
Running ExUnit with seed: 768328, max_cases: 32

.
Finished in 7.1 seconds (0.00s async, 7.1s sync)

Result: 1 passed
EXIT=0
```

## Leg 2 — TS falsifier probe

Command: `node verification/ts/kd115.probe.cjs`

```
PASS plain-credit-first: received 3/3 (credit-first, no reflow)
PASS session-credit-first: received 3/3 (credit-first, no reflow)
PASS kd116-session-settle: settled 3/3, re-receive 0 (expect 0)
EXIT=0
```

## Verdict

Both post-shim legs PASS, exit 0. The KD-115 credit-first-delivery fix (deliver_available on the
ingest tail) holds under both the internal Elixir gate and the real-transport TS probe after the
shim landed. Fresh witness postdates shim mtime 23:01:52 — the flip precondition is met.

**Flip was NOT performed** (W16-A is witness-only; flip belongs to `kd_flip.py --apply` per lane law).
