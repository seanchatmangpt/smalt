# Invariant Gates — invariant-gate-pack integration

Adapted from `ggen-marketplace/packs/invariant-gate-pack`
(templates/invariant_gate.py.tmpl + templates/test_invariants.sh.tmpl):
stdlib-only executable checkers whose exit code is the verdict, plus a
positive/negative fixture harness (each mutated fixture copy must be refused,
proving the gate is non-vacuous).

The pack's original checkers are file/graph statics; here the pattern is
lifted to live-substrate invariants. Each checker boots the smalt substrate on
private ports (boot pattern from `scripts/bench.py` +
`scripts/stress/amqp_throughput.py`: `MIX_ENV=test`, `SMALT_TEST_*_PORT`
env, probed-free ports, killpg + lsof teardown sweep), exercises the
invariant over the real wire surface, applies the same verdict function to
mutated copies of the observations (negative fixtures), and writes a
fail-closed verdict receipt to `tmp/invariant-gates/<gate>-receipt.json`.

## Gates

- `cosmos-etag-cas` (`gates/cosmos_etag_cas_gate.py`) — Cosmos ETag CAS,
  exactly-one-winner: 6 concurrent If-Match PUTs must yield exactly one 200
  and five 412 PreconditionFailed; etag quoted 64-hex, stable across reads,
  refreshed on write; stale-etag reuse refused. Fixtures: two-winners,
  no-winner, etag-not-refreshed, stale-write-accepted, bad-etag-format.
- `blob-worm` (`gates/blob_worm_gate.py`) — blob WORM: while a legal hold is
  set, overwrite and delete of the blob must both return
  409 `ContainerLocked`; clearing the hold lets delete through (the lock was
  real, not vacuous). Fixtures: overwrite-accepted, delete-while-locked-accepted,
  wrong-error-code, lock-never-bound.
- `ledger-chain` (`gates/ledger_chain_gate.py`) — Confidential Ledger Merkle
  chain: client-side re-derivation of
  `merkle_root = sha256(prev_hash <> data_hash)`, strict prev-linkage,
  genesis prev of 64 zeros, `transactionId = "<seq>.1"`, duplicate contents
  refused with 409. Fixtures: broken-link, wrong-root, tampered-contents,
  nonzero-genesis, duplicate-accepted.
- `queue-capacity` (`gates/queue_capacity_gate.py`) — AMQP queue capacity
  4096: the driver (`gates/amqp_invariant_driver.exs`, raw FrameCodec client,
  CBS put-token auth) fills a fresh queue with 4096 settled transfers and the
  4097th unsettled; the broker must close with
  `amqp:link-message-size-exceeded` and `:capacity` in the description.
  Fixtures: overfill-accepted, wrong-condition, silent-socket-drop.
- `lock-clamp` (`gates/lock_clamp_gate.py`) — lock-duration clamp 100..30000
  ms: ARM PUT of a namespace + queues with `lockDuration` PT1H / PT0S / PT5S,
  then the driver reads `x-opt-locked-until` off a real delivery; the observed
  lock delta must equal the CLAMPED value (30000 / 100 / 5000), not the
  requested one. Fixtures: unclamped-high, zero-delta, unclamped-low,
  missing-delivery.

## Running

```sh
python3 gates/cosmos_etag_cas_gate.py   # any single gate; exit 0 = hold
python3 test/invariant_gates_test.py    # all five, unittest
```

## Fail-closed contract

Exit 0 requires ALL of:

1. positive capture against the LIVE substrate passes the verdict function;
2. every negative fixture (mutated observation copy) is refused by the same
   verdict function;
3. receipt on disk at `tmp/invariant-gates/<gate>-receipt.json` with
   `verdict=PASS`, `positive=PASS`, and every fixture `detected=true`.

Any boot failure, capture error, positive failure, or undetected fixture is a
gate FAIL (exit 1), with the receipt recording why.

## Substrate notes (load-bearing for the gates)

- Boot is `mix run --no-start -e 'Application.put_env(:smalt, :mcp_port, N);
  Application.put_env(:smalt, :sb_shared_key, "..."); ensure_all_started;
  sleep'` — `:mcp_port` has no `SMALT_TEST_*` env override, and another
  lane's substrate may hold the default 9545, so it is put_env'd to a probed
  free port BEFORE app start.
- The AMQP driver runs under `mix run --no-start` so it does not boot a second
  substrate; it authorizes each connection with a CBS put-token signed with
  the substrate's shared key.
- ServiceBus ARM surface requires api-version 2021-04-01 and
  `skuName` on namespace PUTs (GraphLaw/SHACL enforcement).

## Wiring (D2 owns the Justfile — do not wire from this lane)

Recipe line to add:

```just
gates:
    python3 test/invariant_gates_test.py
```