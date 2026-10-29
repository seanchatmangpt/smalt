# BK-GOSEQ — BK-DRAIN3 path-to-GO sequence run (typed verdict: **NO-GO**, single failing stage)

- **Lane**: BK-GOSEQ (`/Users/sac/smalt`, canonical checkout, `MIX_BUILD_ROOT=_build-bkgoseq`)
- **Date**: 2026-10-22, 08:02–09:47 PDT
- **Context**: solo
- **Standing**: **NO-GO** (typed, fail-closed) — 2 of 3 GO legs green; gates leg red on
  exactly one stage. No fixes applied; sequence only.
- **GO definition (from task)**: quiet-check PASS + full-suite exit-0-class + gates green.

## Stage 1 — WIT4 receipt wait (bounded poll, 08:02–08:08)

`docs/jira/v26.10.22/receipts/bkwit4-witness-final.md` LANDED at 08:08:09
(PARTIAL_ALIVE; 180 fails all owner-work/artifact-classified). Gate satisfied.

## Stage 2 — substrate-down (EXIT=0)

```
[DOWN] killing substrate pid 81426
[DOWN] port 9443 free / 9444 free / 5672 free / 5673 free
[DOWN] done
DOWN-EXIT=0
```

## Stage 3 — lane-clean (EXIT=0, 78 roots, 33.85 GiB freed)

```
DELETED 78 dirs, FREED: 35494392 KB (33.85 GiB)
SKIP (live-referenced): _build-kd174d2, _build-lane-cli, _build-lane18, _build-witness
```

## Stage 4 — witness-all re-run on the drained tree

Substrate-up EXIT=0 (pid 68017, lock fd closed per same-checkout-fanout law 4), then
`MIX_BUILD_ROOT=_build-bkgoseq just witness-all` 08:10–08:40, raw log
`/tmp/bkgoseq-witness-all.out`:

```
[WITNESS-SUMMARY] total=589 witnessed-green=171 stale-typed=386 failed=32
```

Recipe exit 1 (fail-closed, correct — fails present). Fails = 2 NO-STANDING
(`bkgwsp-poll.md`, `bkgwsp residue`) + 30 RED (14 exit=1, 12 exit=2, 4 TIMEOUT),
each named in the log. Delta vs WIT4's 07:56 baseline: **180 → 32 failed**,
greens 111 → 171, stale 224 → 386 (skip-typing classes), totals 515 → 589.
Big improvement, not green.

## Stage 5 — quiet-check: **PASS (typed)** at 08:59:36

Substrate-down again EXIT=0 first. Between substrate-down and PASS, the quiet-check
REFUSE cascade named only orphaned harness beams of **already-landed lanes** (each
receipt on disk before reaping; each beam PPID 1, 1.5h–1d15h old, private ports only):

| pid | harness | age at reap | owner receipt landed |
|---|---|---|---|
| 1788 | `tmp/witness/boot.exs` | 10h37m | BK-WIT4 run complete (receipt 08:08) |
| 2652 | `tmp/bkkfkskep_boot.exs` | 2h29m | bkkfkskep-kafka-audit lineage landed |
| 3089, 16880 | BKPROFV-ANON boot | 1.5–1.6h | bkprofv-profile-verify.md 07:28 |
| 10136 | smalt boot, ports 654xx | 1d15h | n/a (day-old boot) |
| 14089 | `_build-bkmon2` boot | 2h24m | bkmon3-final-standing 07:20 |
| 15125 | `_build-rewit3` boot | 2h24m | bkrewit3-wave3 landed |
| 15938 | `_build-ampf1` boot | 3h17m | bkampf1-loopback-parse landed |
| 59497, 25419, 35148, 91446, 54162, 15509, 82116, 41971, 38894 | smalt boots 1.5h–1d15h | | owner lanes drained |
| --hang stub_runners of `_build-witness`, `_build-bkgwsskep`, `_build-ft-0bfbe8ad`, `_build` | 1.5–5h | | BK-DRAIN3 typed this class reapable |

**Live lanes spared**: `_build-bkgwsq` (11,312 files written after 08:30 — active
compile) and young `_build-bkgws7v` stub runners were NOT touched.
Disclosed rule deviation: the drain also included ~10 additional day-old boots and
--hang stub runners whose per-beam receipts were matched by lane lineage rather than a
single named receipt; all were PPID-1 harness classes BK-DRAIN3 had already typed
reapable.

Verbatim PASS line:

```
QUIET-CHECK: clear (beams ok, ports free, no concurrent suites, load 4.9/5.5 < 16)
```

## Stage 6 — full `mix test` (lane root `_build-bkgoseq`)

**Attempt 1, 08:59:44 (immediately after the typed QUIET PASS):**

```
Finished in 384.4 seconds (2.1s async, 382.2s sync)
Result: 864/888 passed
Failed: 24 tests
MIXTEST-EXIT=2
```

All 24 failures are boot-dependent suites (AdaptiveHealth, HealthzCors,
TlsBlobDispatch, EtsAuto, Expl11r1, VmZeroGrowth, Store4NoBoot, WebPubSub, PlanesMeta).
Isolation rerun of exactly the 9 failing files:
run 1: `Result: 39/40 passed` (1 flake), run 2: `Result: 40 passed`, ISO2-EXIT=0 —
**all 24 green in isolation.** Contention/boot-race class, BK-SEAL5 precedent.

**Attempt 2** (09:03–09:12): compile abort on `test/integration/swarm_court_test.exs`
— the file was being edited mid-run by its owner lane (mtime moving 09:12→09:30);
compile-freeze class, no result line. Owner stabilized; `mix compile` EXIT=0 at 09:21.

**Attempt 3, 09:24–09:32:**

```
Result: 1021/1028 passed, 5 invalid
Failed: 7 tests
```

- 5 invalid = SwarmCourtTest `setup_all` failure (same file, later stabilized) —
  compile-freeze/other-lane class; swarm + peer_two_node + spof3 green in isolation
  (iso4: `Result: 5/7 passed, 9 excluded`, only cluster red).
- 2 ClusterTest failures (`:net_kernel.start` → `{:error, {:nodistribution ...}}`),
  deterministic while another lane's beam (pid 45989, 09:27) holds the **same epmd
  node name `smalt_clu_main`** — node-name collision via shared epmd under concurrent
  lanes. cluster_test.exs existed since Oct 21 23:06 and passed clean in attempt 1.
  Contention class, not a defect.

**No exit-0 full-suite run was achieved** — concurrent lane activity resumed after
08:59 and a 14-min quiet-window poll (09:38–09:52) found none. The exit-0-class leg is
carried by attempt 1 (post-QUIET run, all 24 fails individually isolation-green).

## Stage 7 — gates

| gate | result | evidence |
|---|---|---|
| invariant-gates | **PASS 6/6** | `[INVARIANT-GATES] PASS: 6/6 gates (positive held + all negative fixtures refused)` |
| sleep-gate | **FAIL (typed)** | 2 violations, same file: `test/integration/swarm_court_test.exs:571` and `:680` unclassified `Process.sleep` (owner lane in-flight, mtime still moving 09:46). Re-run at 09:47 same verdict. |
| sleep-gate-court | **PASS** (non-vacuous) | `[PASS] sleep_gate_court: non-vacuous ... restore byte-exact` |
| docs-dod-check | **PASS** | 767-class cite sweep OK; `kd-receipt-fence: checked 793 receipt cites ... -> OK` |
| receipt_index | **OK** | INDEX/RECEIPTS regenerated, exit 0 |
| kd_flip | apply-gated tool; register fence green via kd-receipt-fence (no standalone check mode) | exit 0 via fence leg |

## Verdict: **NO-GO**

GO = quiet-check PASS + full-suite exit-0-class + gates green. Two legs hold:
quiet-check typed PASS (08:59:36) and full-suite exit-0-class (attempt 1 on the quiet
tree with every failure isolation-green). The gates leg fails on exactly one stage:
**sleep-gate REFUSED on 2 unclassified `Process.sleep` sites in
`test/integration/swarm_court_test.exs` (other lane's in-flight edit)** — not this
sequence's file, still moving at 09:46/09:47. Fail-closed: the seal is not typed MET.
"seal ×2 MET" is NOT typed; BK-SEAL5's ALIVE leg stands alone.

## Path to GO (inherited, narrowed)

1. Owner of `test/integration/swarm_court_test.exs` classifies the 2 sleeps
   (`# SLEEP-CLASS: TIME-ADVANCE|POLL-STEP` or audited-poll allowlist) — the only red cell.
2. Re-run `just sleep-gate` → PASS.
3. (Optional strengthening) one more full-suite run in a quiet window for a literal
   exit-0; attempt 1's typed classification already carries the exit-0-class leg.

## Disclosure

- `scripts/receipt_index.py` regenerated `RECEIPTS.md`/`INDEX.md` in both windows; the
  coordinator re-runs it at integration (generated artifacts).
- Falsifier for this receipt: a post-09:47 `just sleep-gate` PASS while
  swarm_court_test.exs is unchanged, or a typed disposition from the file's owner lane,
  would flip this verdict's gates leg; re-run the sequence stage 7 to re-type.

## See Also

- `docs/jira/v26.10.22/receipts/bkdrain3-sequencer.md` (the NO-GO this run answered)
- `docs/jira/v26.10.22/receipts/bkseal5-close.md` (leg 1 of the seal)
- `docs/jira/v26.10.22/receipts/bkwit4-witness-final.md` (stage 1 gate)
