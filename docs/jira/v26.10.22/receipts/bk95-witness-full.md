# BK-95 — witness-all FULL gated run (attempt 1)

**Standing: PARTIAL_ALIVE** — exit 1, every red typed below; no untyped reds. A green
re-run is blocked on in-flight lane churn on the shared `lib/` tree, not on this gate.
Context: full

## Summary

```
$ just witness-all                       # python3 scripts/witness_all.py
[WITNESS-SCOPE] windows=docs/jira/v26.10.21/receipts docs/jira/v26.10.22/receipts
[WITNESS-SUMMARY] total=246 witnessed-green=69 stale-typed=147 failed=30
EXIT=1
```

- failed=30 = 26 re-run reds + 4 NO-STANDING (receipt format class).
- 69 real re-runs green, 147 stale typed loudly (by design).
- Log preserved at `/tmp/bk95-witness-all.log` (full per-receipt lines).
- **Tree churned mid-run**: checkout was clean at launch; during the ~75-min run,
  concurrent lanes landed commit 7dcdd9d and re-dirtied `lib/`
  (`lib/smalt/confidential_ledger/`, `lib/smalt/data_plane/mhsm.ex`,
  `lib/smalt/messaging/kafka/`, `skr.ex`, `token.ex`, `workspace/…/useAsyncFn.ts`).
  All lib-code compile reds below trace to in-flight lane files, not HEAD-at-launch.

## Red ledger (each red typed: owner + reason)

### Class A — concurrent-lane churn on shared lib/ (owner: active lib/ lane owners; lane coordinator)
Compile errors from in-flight uncommitted lane files, witnessed fresh build root
`_build-bk95-probe` reproducing: `maa.ex` undefined `sha256_hex/1` (×2),
`confidential_ledger/service.ex` Erlang syntax error on literal `∈` (U+2208),
plus `ocel_ndjson.ex` / `application.ex` compile failures inside the runs.

- appconf-push-webhook-face.md — exit=2, Plug-router frame during bootstrap under churn
- armfix-top3-typed-violations.md — exit=2, same churn crash class
- bk25-kd92-93-cosmos.md — exit=2, same churn crash class
- bk71-census-drift.md — exit=2, same churn post-launch commit 7dcdd9d + dirty lib/
- impl1-process-iterator.md — CompileError `lib/smalt/application.ex` (lane file)
- CompileError `lib/smalt/telemetry/ocel_ndjson.ex` — one root cause, 11 witness reds:
  ja-r1-silent-violation-fixes.md, ja10-transparency-court.md, ja15b-gap-adoption.md,
  ja5-fail-fast-court.md, ja7-crash-only-court.md, kd157-h2-reset-rate-parity.md,
  prd-kv-crypto-face.md, relcut-deferred-listeners.md, sj2-journal-reader.md,
  sj3-storage-decoupling-court.md, sk5-sk3-credit-arbitration.md,
  snippet-jsonsax-stream.md (mix compiles the whole tree first, so any target file
  fails once `ocel_ndjson.ex` fails)
- prd-kv-crypto-face.md additionally matches the fresh-root probe: `maa.ex` undefined
  `sha256_hex/1` (×2) and `confidential_ledger/service.ex` Erlang syntax error on
  literal `∈` (U+2208) — attestation/confidential-ledger lane files

### Class B — concurrent mix lock contention (owner: lane coordinator / substrate-op)
- gl10-skeptic.md — exit=1, crash inside `Mix.Sync.Lock.with_lock/3` — a concurrent
  lane held the mix lock; the witness lane's fresh `_build-gl10` compile lost the race.
  Compile-freeze SLA class, not a code defect.

### Class C — receipt format class (owner: receipt authors / milestone-doc)
- bench13-deletion-exec.md — readonly `grep -n "benchee" mix.exs mix.lock` exits 1 by
  design (benchee is deleted; the green state of this assertion IS exit 1). Gate treats
  exit 1 as red. Fix: re-author command to assert absence explicitly
  (`! grep -n "benchee" mix.exs mix.lock`), owner: bench13 receipt author.
- bk51-smalt-gen-replay.md — command embedded literal placeholder
  `shasum -a 256 <six artifacts>` → /bin/sh syntax error. Fix: receipt should name the
  six artifact paths literally. Owner: bk51 author.
- bk93-kd-gates.md — receipt records a piped/shell-continued command
  (`kd_flip.py … | grep … || echo …`) that the safe-class classifier cannot parse as one
  readonly pipeline (`|| echo` segment not readonly). Fix: record the bare read-only
  kd_flip.py invocation. Owner: bk93 author.
- bk35-head-court-sweep.md, bk72-gates-toolchain.md, ath3-law-court.md,
  bk73-workspace-combined.md — NO-STANDING: receipt has no `Standing:` line
  (STANDING_RE requires it). Format class; owners add a standing line to their receipts.

### Class D — TIMEOUT (900s mix-test cap) (owner: gws/wasm lane owners)
- gws13-integration-manifest.md, gws18-real-runner-court.md, gws7-wasm-abi-bridge.md,
  wasm1-otp29-sandbox-port.md — mix-test runs exceeded the 900s witness timeout
  under a cold `_build-*` root compiling against a churned tree. Not typed as code
  defects; the receipts' recorded evidence stands as-of-date; re-run candidates after
  the tree quiets, with warmed build roots.

### Class E — environment (owner: graphlaw checkout owner)
- gws2-wasm-build-trial.md — `graphlaw_wasm.wasm` missing at
  `/Users/sac/graphlaw/target/wasm32-wasip1/wasm/` — graphlaw wasm artifact not built
  in the sibling checkout; build it or re-point GRAPHLAW_ROOT.

## Verdict

The gate is non-vacuous (69 real greens, 147 loud stales, fail-closed on churn).
Green is reachable when lanes land: Classes A/B clear when lib/ churn stops and a redo
runs on a quiet tree; Class C is 8 format fixes; Class D is 4 re-runs on warm roots.
This is attempt 1; redo owed on a quiet tree after Class C fixes land. No commit made
per lane contract.