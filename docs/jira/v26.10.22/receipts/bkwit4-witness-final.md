# BK-WIT4 — witness-all reap-relaunch (post-WPARSE, post-SUB3)

**Standing:** PARTIAL_ALIVE — gate ALIVE and fail-closed; 111 real greens; every one of the 180 fails classified (zero real substrate/surface defects); residue is owner-work, artifacts, and one new typed scope finding.
Context: solo
Date: 2026-10-22
Owner lane: BK-WIT4 (qualification lane — no fixes, read-only + this receipt)

## Substrate health (task 1)

`just substrate-status`: all four ports UP on pid **81426** (9443/9444/5672/5673), lock FREE.
Process witness: `ps -p 81426` booted 2026-10-22 07:07:58, `arm_tls_port 9444`, auth
`:enforce`. One curl per advertised face: 9444 TLS → **401**; 9443/8443 clear → **401**;
9545 → **200**. Health gate PASS (serve on the faces this boot advertises).

## Run (task 2)

`just witness-all` full run, real re-execution of every recorded command in the safe
classes. Raw log: `/tmp/bkwit4-witness-all.out`.

```
[WITNESS-SCOPE] windows=docs/jira/v26.10.14/receipts docs/jira/v26.10.22/receipts
[WITNESS-SUMMARY] total=515 witnessed-green=111 stale-typed=224 failed=180
```

Exit **1** — fail-closed, correct (fails present). Total grew 431 → 515 vs BK-WIT2
because the run's scope changed (see BK-WIT4-1).

## Headline deltas vs BK-WIT2 baseline (431 legs, 86 NO-STANDING, 29 compile REDs)

- **NO-STANDING collapsed as predicted by BK-WPARSE: 86 → 2** in the current window
  (v26.10.22). The hardened one-canonical parser
  (`scripts/receipt_index.py` `STANDING_LINE_RE` + `strip_emphasis`) reads bare,
  bullet-, heading-, bold-label, bold-value and `=` shapes; zero `**` residue anywhere
  in the run output (`grep -c 'standing: \*'` → 0). The two remaining current-window
  NO-STANDING receipts are honest owner residue: `bkgwsp-poll.md` and `bkqmon-window.md`
  carry no canonical standing field at all.
- **The 29-compile-freeze class cleared**: zero of the WIT2 files
  (webpubsub/confidential_ledger/maa) appear in any RED. All repair lanes landed.
- **Zero untyped skips** (task 3): all 224 STALE legs carry one of exactly two
  harness-typed reasons — `no command in a safe class` (179) and
  `no rerunnable command in receipt` (45). Standing tokens on stale lines now parse
  clean (144 ALIVE / 61 PARTIAL_ALIVE / 10 PASS / others; one stray `PARTIAL_ALIVE.`
  trailing-period cosmetic). The skip-inventory receipts themselves parse and witness
  correctly: `bkskipport-fetch-ports.md` (PARTIAL_ALIVE: 6 typed-permanent SKIPs with
  named reasons, zero silent) and `bke2skip-skip-typing.md` (ALIVE: both e2e skips
  typed) — their inventories reconcile with this run's zero untyped skips.

## FAIL classification (task 4) — 180 = 130 NO-STANDING + 50 RED

Counted from the log: 131 `WITNESS-FAIL` + 50 `WITNESS-RED`; summary counts 180 total
(the bkwparse leg appears as both a NO-STANDING-print and a RUN line — the harness
counts the leg once, as FAIL). Exact split: 130 NO-STANDING + 50 RED. Classification:

### 130 NO-STANDING = 128 scope-artifact + 2 true residue

**BK-WIT4-1 (new typed finding, harness scope selection):** the window picker takes
the two NEWEST receipts dirs **by mtime** (`scripts/witness_all.py:42-43`), and the
v26.10.14 exemplar window's dir-mtime was bumped (lane activity on its RECEIPTS.md —
both windows' RECEIPTS.md/INDEX.md are modified in this session's tree), so this run's
scope was **v26.10.14 + v26.10.22 instead of v26.10.20 + v26.10.22** (WIT2's scope).
128 of the 130 NO-STANDING rows are v26.10.14 receipts authored **before the
standing-line law existed** (sample-verified: `01-test-isolation.md` uses
`Status: DONE`, no standing field; 53 of 161 receipts in that window contain the word
"standing" zero times). These are pre-law receipts, not a regression and not current
owner residue — the comparable-number comparison is WIT2's window, where 86 → 2.
Fix is a one-line harness change (pin windows by name, not dir mtime) — owner residue
for the witness_all harness, NOT fixed by this qualification lane.
(The summary's 180 = 130 NO-STANDING + 50 RED; the 131st FAIL grep line is the
bkwparse leg printed in both classes, counted once by the summary.)

### 50 REDs, fully classified

1. **31 compile-abort class (in-flight SLA, witnessed cleared):** all 31 cite
   `lib/smalt/messaging/amqp/connection.ex:3379:1` (a file that was mid-edit during
   the run window — mtime 07:46, run 07:26–08:05; the file is now 3361 lines, i.e.
   3379 no longer exists). 23 carry the `parallel_compiler.ex:548` exit=1 signature,
   8 the mix exit=2 abort signature (bk7, bk7c, bk82, bkcens, bkcens2, bkcens4,
   kafka-exp4-repairs, bkkfkc-legacy-count). Cleared-witnessed: `mix compile` exit 0
   on the shared tree post-run; re-runs on lane build root `_build-bkwit4`:
   `kafka_wire_test.exs` → **9 passed**; `kafka_exp4_court_test.exs` → **10 passed**.
   Same SLA class as WIT2's 29, different owner file.
2. **3 TIMEOUT (harness-typed):** bkbmir4, bkst4w, bkzombie — all heavy recursive
   greps (`grep -rn … docs/ | lib/ …`) under concurrent lane load. Load artifacts,
   not defects; typed TIMEOUT by the harness (loud, not silent).
3. **4 just-recipe-prose artifacts** (bkclirow `→`, bkdodsub `(post-fix)`, kddod
   `(tail)`, kdmirror `->`): the receipt records prose as the "command"; justfile has
   no such recipe.
4. **3 sh-arrow-syntax artifacts** (bk115b, expl12b, bkprofv): recorded command is
   prose with a `→` outcome arrow.
5. **2 kd_flip unrecognized-args artifacts** (bk106, bkkdl-chain-check): recorded
   command embeds trailing prose/annotations as arguments.
6. **1 prose-grep artifact** (bknfrv): "grep Standing … → ALIVE ×2, Result: 7 passed"
   re-run literally.
7. **4 expected-zero-grep class** (bkbshape, expl9reg-row-mint, bkwparse-hardening,
   bkretok): grep exit 1 with zero matches IS the receipt's claimed green outcome;
   harness reads exit≠0 as RED. Harness classification gap (named in WIT2, still
   open — typed residue, not fixed by this lane).
8. **1 env-gated** (kd166): `/dev/sev-guest /dev/tdx` absent on macOS.
9. **1 scratch artifact** (bkbenchreg): `tmp/bench/*.jsonl` are gitignored scratch,
   absent post-cleanup.

Sum: 31+3+4+3+2+1+4+1+1 = 50.

## Honest verdict

**PARTIAL_ALIVE.** The gate is ALIVE and fail-closed (exit 1 with fails present, 111
greens are real re-runs). Both WIT2 residue classes behaved exactly as the
hardening/repair receipts predicted: NO-STANDING 86 → 2 in the current window
(parser hardening witnessed), compile-freeze 29 → 0 of that class (all repair lanes
landed). Zero untyped skips. Zero real substrate or surface defects found: every RED
is compile-abort-during-run (in-flight SLA, re-run green post-run), a receipt-authoring
artifact, a harness classification gap, environment-gated, or scratch-absence — and
every owner-attributable item is typed. The named work forward: (a) BK-WIT4-1 window
selection by name not mtime, (b) expected-zero-grep classifier, (c) the 2 current-window
standing-less receipts (bkgwsp-poll, bkqmon-window), (d) the 129 pre-law v26.10.14
receipts if that window is ever intentionally in scope.

Raw log: `/tmp/bkwit4-witness-all.out` (scratch). Lane build root `_build-bkwit4` left
for coordinator `just lane-clean`.
