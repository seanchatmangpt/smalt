# BK-DRAIN3 — drain sequencer: 7-lane wait-bounded reap + seal verdict

- **Lane**: BK-DRAIN3 (`/Users/sac/smalt`, canonical checkout, read-only except this receipt)
- **Standing**: ALIVE (all census values are disk/ps/`just quiet-check` reads, not inferred)
- **Context**: solo
- **Date**: 2026-10-22, observed 07:13–08:00 PDT (bounded polls ~2.5–5 min)

## (1) Wait-bounded outcome for the 7 lanes (BK-DRAIN2's remaining set)

| lane | receipt | landed | standing |
|---|---|---|---|
| BK-CENS5 | bkcens5-wave5.md (07:16:31) | YES | ALIVE (JA10 dead-law fix, census green 6 passed ×2, no loosening) |
| BK-MON3 | bkmon3-final-standing.md (07:20:08) | YES | PARTIAL_ALIVE (metrics 500 gone, CLI face honest; accumulator fallback join predicate dead code — BK-MON3-F1 HIGH, owner EXPL12-B/BK-MON2 lineage) |
| BK-BQUIET | bkbquiet-quiesced-bench.md (07:21:40) | YES | PARTIAL_ALIVE (4 of 5 SUSPECT-PERMANENT rows re-measured PASS load-typed; 1 FAIL typed louder) |
| BK-SEAL5 | bkseal5-close.md (07:27:48) | YES | ALIVE (seal close condition MET on its run: verbatim full `mix test` result line, all gate stages green, census 6/6) |
| BK-POWLH2 | bkpowlh2-loop-compile.md (07:31:38) | YES | PARTIAL_ALIVE (HIGH-2 closed with typed disposition — loop net unsound, not a loop-back-edge patch; fix landed + courted on lane root, full-court/cross-SDK census not run) |
| BK-WIT4 | bkwit4-witness-final.md | NO — run COMPLETE, receipt pending | PENDING-RECEIPT: `just witness-all` ran 07:30–07:56, output `/tmp/bkwit4-witness-all.out`, `[WITNESS-SUMMARY] total=515 witnessed-green=111 stale-typed=224 failed=180`, `EXIT=1` (recipe exit 1). Process finished; receipt not yet written as of 08:00. Log stale-then-complete, process gone. |
| BK-GWSSKEP | bkgwsskep-wave-audit.md | NO | FROZEN for reap — typed by poll lane BK-GWSP (bkgwsp-poll.md 07:28): newest write in `_build-bkgwsskep` ≈06:24, age 62 min at census, zero files newer than 25 min, two orphan `--hang` stub_runner beams (PPID 1). Successor `_build-bkgwsskep2` active since 07:31 (GWSSKEP2), receipt `bkgwsskep-wave-audit.md` still absent at 08:00. |

**BK-WIT3 typed DEAD for reap**: no receipt path was ever named for WIT3;
BK-SEAL5's drain poll independently confirmed the lane's effects landed under
successor names (bkrewit3-wave3, bkmon-monitor-truth, bkcens4-wave4, etc.), no
`_build-wit3`-class root, no active surface. Reap is safe.

## (2) Re-census at 08:00 (embedded, real output)

```
8:00  up 1 day, 22:36, 4 users, load averages: 12.26 15.07 26.11
beams: 36 (1 hot >50% CPU)
build roots: 85 / 37,862 MiB (~37.0 GiB)
```

Load 1m 12.26 ≪ BK-DRAIN 115.90 / BK-DRAIN2 67.33; 1m < 5m < 15m ordering
persists (genuine drain to near-baseline). Beam count 46 → 36, distribution
collapsed to 1 hot. Build roots 44 → 85 / 37 GiB — the growth is the witness-all
itself minting `_build-witness` (fresh writes at 07:35+, verified above) plus
per-receipt witness runs; coordinator-reclaimable once WIT4's receipt lands.

## (3) quiet-check (typed output, 08:00:27)

```
QUIET-CHECK REFUSE (typed violations):
  - court port 9443 occupied
  - court port 8443 occupied
  - court port 5672 occupied
  - court port 5673 occupied
  - court port 9444 occupied
  - concurrent suite/court processes: 1788 /Users/sac/.erlmcp/otp-28.3.1/.../beam.smp
  - load 11.5/14.7 > threshold (16 cpus)
QUIETCHECK-EXIT=1
```

(The court-port occupancy is the shared substrate — BK-SUB3's 81426 beam —
still up; the erlmcp beam is out-of-repo. Both are named, typed violations,
not silent passes.)

## (4) Seal verdict: NO-GO

GO requires QUIET + census green + fresh witness-all + full-suite result line
all on disk. Three of four hold; two fail:

1. **QUIET: FAIL** — `just quiet-check` REFUSE (exit 1) at 08:00:27: substrate
   on court ports, load 11.5/14.7 above threshold.
2. **Fresh witness-all: FAIL** — the BK-WIT4 run completed but with `EXIT=1`
   and `failed=180` (total=515, green=111, stale=224) and its receipt
   `bkwit4-witness-final.md` has not landed. An exit-1 witness-all with 180
   failed witnesses is not a green fresh witness-all.
3. **Census: green (drained)** — load near baseline, 1 hot beam.
4. **Full-suite result line: PRESENT** — BK-SEAL5's receipt carries a verbatim
   full `mix test` result line (ALIVE).

Path to GO: `just substrate-down` (or quiesce), coordinator lane-clean of the
85 roots (~37 GiB) after WIT4's receipt lands, and a green witness-all re-run
(witness the 180 failed — most receipts have commands in unsafe classes; the
witness harness's safe-class list is the constraint) → then re-run quiet-check.

## Falsifier

A `bkwit4-witness-final.md` or `bkgwsskep-wave-audit.md` lands between the last
poll (08:00) and this commit, or quiet-check passes on a re-run after the
substrate recycles. First checked at write time (08:02): neither receipt on
disk; `/tmp/bkwit4-witness-all.out` EXIT=1 stands.
