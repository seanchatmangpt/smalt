# BK-LANEAUD — in-flight lane audit (post-BK-8)

**Standing:** ALIVE · Context: solo · Date: 2026-10-22 · Repo: /Users/sac/smalt

## Work order

BK-8's `_LANES.md` named an in-flight-no-receipt set (BK-119, BK-148,
BK-142/142r, AZ-1, AZCLI-3/4, plus already-receipted rows). Hours later,
re-verify each row on disk and flip proven-landed rows; type dead rows
loudly for coordinator reap decision. Update `_LANES.md` only.

## Per-lane evidence (re-read from disk, not recalled)

| Lane | Verdict | Evidence executed this session |
|---|---|---|
| BK-119 (useWebLocks PR branch) | **DEAD-NO-ARTIFACT** | `git branch -a`: main only (no PR branch ever pushed); no receipt file; no doc mention beyond checkpoint name-drops (7dcdd9df..17848b75); BK-150 (`receipts/bk150-finisher-sweep.md:37,80`) independently typed it missing/429-killed / not-started. Coordinator reap decision owed. |
| BK-148 (W3C GAP ledger) | **LANDED (fold)** | Commit 8475ca49 shown: 19-line diff on `docs/jira/v26.10.22/W3C-FORMALIZATION.md`; file on disk carries GAP ledger final (GAP-6a CLOSED via bk111 + bk129rr receipts both on disk; GAP-1a/4a UPSTREAM-OPEN w/ falsifiers; disposition ledger + typed flip rule); BK-150 corroborates docs-dod 65/65. |
| BK-142/142r (pillar matrix) | **LANDED (fold)** | `docs/jira/v26.10.22/pillars-cross-industry.md` on disk (5 pillars × 6 industries, disk-truth method stated in header); landing commits 3e8baf0f (BK-142 PARTIAL_ALIVE fold) + da0a434c (BK-142r PARTIAL_ALIVE fold); sole open cell (aero P3) closed by `receipts/bk143rr-aero-p3.md` (ALIVE, own ledger row) + `receipts/bk146r-pillar-consumers.md` (ALIVE). |
| AZ-1 (kafka wire court) | **LANDED-via-successor** | Kafka wire court/repairs on disk: `receipts/kafka-exp4-repairs.md` (KAFKA-EXP4, ALIVE, Context solo — recordsCount cross-check + unknown-partition EC=3, real-binary CRC32C court, owner files `lib/smalt/messaging/kafka/records.ex` + `log.ex`, commit 853ca62c 04:44); `receipts/erl3-kafka-wormhole-proposer.md` (ERL-3, ALIVE — kafka produce/fetch byte-exact wire, court 8/8 ×2, commit 18c0d354). AZ-1's checkpoints (kafka court+probe, e8e46a47/6e3e77eb/999553f1) converge into exactly these surfaces. |
| AZCLI-3 (cli.py commands) / AZCLI-4 (typer pack) | **LANDED-via-successor** | Owned artifacts on disk and courted: `smalt-cli/smalt_cli/cli.py` + 5 Typer command groups (storage/cosmosdb/servicebus/keyvault/deployment) + `smalt-cli/tests/test_ty_*.py`; courted by `receipts/bk149-smaltcli-closeout.md` (PARTIAL_ALIVE, 12/12 ty_* probes) and `receipts/bk149b-cli-green.md` (stale-claim sweep, ty_* green vs live substrate). The AZCLI lanes' work is subsumed — no separate receipt owed. |

Already-receipted rows in BK-8's in-flight list (WPS-EXP4, WIRE-EXP4,
EXP1-A, BK-7, KD-143, KD-AMQP, KD-CONF, KD-BLOB, BK-85, BK-143rr) were
already ledgered with receipt paths by BK-8; re-confirmed present on disk.

## Result

- 6/7 distinct named rows proven LANDED (3 as folds into milestone docs,
  2 via successor receipts) — `_LANES.md` in-flight section rewritten with
  per-row verdicts.
- 1 row typed **DEAD-NO-ARTIFACT**: BK-119 (no branch, no receipt, no
  artifact; BK-150 concurs). Coordinator reap decision; no processes
  killed by this lane.
- 0 rows genuinely-in-flight.

## Falsifier

A row flipped LANDED whose receipt/artifact is absent from disk: false —
every evidence path above was existence-checked this session
(`ls`/`git show`/`grep` outputs embedded in session transcript; W3C +
pillars files read directly). A row wrongly typed DEAD: BK-119 has no
branch on any remote and zero non-checkpoint doc trace — the DEAD typing
matches BK-150's independent census, two auditors one verdict.

## Scope

Only `docs/jira/v26.10.22/_LANES.md` + this receipt written/committed.

---

## RE-WITNESS addendum (BK-REWIT wave 1, 2026-10-22)

Original evidence above untouched. Disk-existence evidence re-executed with
exit capture. The BK-119 branch check (`git branch -a`) is NOT re-run — git
state commands are outside lane authority in this fan-out; the DEAD typing
was BK-150-corroborated at write time and stands as typed.

```
$ ls docs/jira/v26.10.22/W3C-FORMALIZATION.md docs/jira/v26.10.22/pillars-cross-industry.md
both present (9673 / 9648 bytes); grep -c GAP W3C-FORMALIZATION.md -> 11
$ for f in kafka-exp4-repairs erl3-kafka-wormhole-proposer bk149-smaltcli-closeout \
    bk149b-cli-green bk143rr-aero-p3 bk146r-pillar-consumers; do [ -f receipts/$f.md ]; done
all OK; smalt-cli/smalt_cli/cli.py present; ls smalt-cli/tests/test_ty_*.py | wc -l -> 5
existence exit=0
```

Re-witness verdict: every LANDED fold/successor artifact the receipt cites is
on disk today. Standing: ALIVE (unchanged).
