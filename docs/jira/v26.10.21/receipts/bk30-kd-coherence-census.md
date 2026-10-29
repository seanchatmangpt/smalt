# BK-30 — KD register coherence census (read-only audit)

**Standing:** **PARTIAL_ALIVE** (census executed and evidenced; 3 structural defects
and 1 pointer drift found — no register edits applied, BK lanes mid-flight)
Context: solo · Date: 2026-10-21 · Repo: /Users/sac/smalt
Subject: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (canonical) +
`docs/jira/v26.10.21/KNOWN_DIVERGENCES.md` (pointer). No register row was
flipped or edited; this receipt is the only file written.

## Method

Escaped-pipe-aware row parser (`re.split(r'(?<!\\)\|', ...)`) over every line
starting `| KD-`; status classified from the LAST cell (canonical rule per the
register's own 2026-10-18 recount prose). Structural check = exact cell count
per row (canonical shape is 6 cells). Cross-checked against
`python3 scripts/kd_flip.py` (what `just kd-stale` runs) and owner evidence in
`docs/jira/v26.10.21/receipts/bk11-kd-legacy-triage.md`,
`docs/jira/v26.10.21/_LANES.md` (BK lane table + BOARDV3 fold),
`docs/jira/v26.10.21/FINAL-RELEASE.md`, `docs/jira/v26.10.20/receipts/`.

## 1. Status census — 157 rows, ids KD-01..KD-160

| class | count |
|---|---|
| CLOSED-WITH-RECEIPT | 34 |
| CLOSED-SIMULATED | 92 |
| CLOSED-OBSOLETE | 10 |
| CLOSED (bare — KD-52, KD-63) | 2 |
| PINION / DISPOSITIONED-closed (KD-05, KD-101) | 2 |
| OPEN | 17 |
| **Total** | **157** |

Id space: no duplicate ids; ids 95, 96, 158 are absent (never minted — the
register prose confirms the KD-95/96 reservation window was consumed
differently; note KD-157 is present while 158 is not). CLOSED-class total =
140 (89.2%); OPEN-class = 17 (10.8%).

## 2. OPEN rows (17) with ownership

`python3 scripts/kd_flip.py` agrees with the table: FLIP-ELIGIBLE 0,
FLIP-PENDING-WITNESS 3.

| KD | status cell summary | owner / disposition evidence | ownerless? |
|---|---|---|---|
| KD-10 | KV PUT /keys/:name unrouted (blob catch-all re-witnessed) | BK-11 disposition: fix-and-witness, `put /keys/:name` in KvRoutes.ex (`receipts/bk11-kd-legacy-triage.md`). Shim already landed (`lib/smalt/egress/KvRoutes.ex`, mtime 2026-10-21 19:48) — flip pending witness | no |
| KD-14 | RS256 verify inversion LIVE | BK-11 disposition: fix-and-witness, RS256 sign-shape fix in KvRoutes.ex crypto face | no |
| KD-23 | bare-mixed `where ... \| project` 400 BadQuery | BK-11 disposition: fix-and-witness, extend `normalize_pipeline/1` (resource_graph.ex:189); row itself repaired 2026-10-21 | no |
| KD-75 | KV update face (shares KD-10 PUT route) | BK-11: fix-and-witness, shares the KD-10 route; shim landed in KvRoutes.ex — flip pending witness | no |
| KD-79 | loopback-by-design vaultUri | BK-11: documented-constant disposition | no |
| KD-86 | lazy queue-create | BK-11: fix-and-witness (config-flag gate); shim landed (`lib/smalt/messaging/amqp/queue_store.ex`, connection.ex — mtime 2026-10-21 19:50) — flip pending witness | no |
| KD-88 | EH checkpoint-store pump warm-up race | T24 wire-parity matrix names it "client-bound" (`docs/jira/v26.10.20/receipts/wire-parity-matrix.md`); no active smalt lane — awaits client-side fix | no (registered, client-bound) |
| KD-90 | affidavit b3sum spawn-floor perf | BK-11: fix-and-witness (perf), in-process blake3 NIF in `lib/smalt/affidavit/seal.ex` | no |
| KD-92 | ARM container vs data-plane store split | BK-11: fix-and-witness, mirror into `:smalt_blob_containers` (arm_gateway/router.ex) | no |
| KD-93 | cosmos query feed stale pre-seeded projection | BK-11: fix-and-witness, cosmos.ex db/coll scoping | no |
| KD-144/145/146 | blob ETag `0x…` formats, Put Blob empty-body | minted from W32 conformance census (`docs/jira/v26.10.20/receipts/w32-api-conformance.md`); named OPEN in FINAL-RELEASE §"KD-144..146" | no (window-close register; no active lane) |
| KD-153/154 | T24 wire-parity matrix open rows | named OPEN in `val-nfr-migrate.md` + VALIDATION.md NFR-COMPLIANCE row | no (registered, not hidden) |
| KD-159/160 | ifMatchEtag silent no-op (client guidance) / smalt 412 superset affordance | CAS412 evidence (`receipts/cas412-cosmos-replace-if-match.md`, `cas412r-postfix-regression.md`); KD-160 "OPEN by design until a client asks" | no |

**OWNERLESS: none.** Every OPEN row carries either an explicit BK-11
disposition (falsifier + next action), a minting-lane citation, or a typed
"registered, client-bound / by-design" note in the window-close docs.

## 3. Table structure (KD-23 regression check)

With the escaped-pipe-aware parser, 154/157 rows carry exactly 6 cells. Three
rows are structurally malformed (unescaped `|` inside a cell — the same class
BK-11 repaired on KD-23):

| row | cells | defect |
|---|---|---|
| KD-16 | 7 | divergence cell contains `encrypt\|decrypt` unescaped — splits the cell; renders as 7 columns |
| KD-56 | 7 | divergence cell `register\|unregister` unescaped — same class |
| KD-85 | 8 | divergence/close-condition cells carry `enqueuedTimeUtc\|... \|skew\|sane` unescaped — same class; `scripts/kd_flip.py` itself reports KD-85 as `[skew]` (its parser misreads the cell boundary) |

Status parsing still lands on the true last cell for all three (statuses read
correctly: all CLOSED-SIMULATED), so the census counts above are unaffected —
but these are KD-23-class regressions to repair (mechanical: escape the
pipes). KD-23 itself renders 6 cells — no regression there.

## 4. `just kd-stale` cross-check

```
$ just kd-stale
FLIP-PENDING-WITNESS: 3
```
`python3 scripts/kd_flip.py` detail: KD-10 and KD-75 — no post-shim receipt
newer than shim mtime (2026-10-21T19:48:26, KvRoutes.ex); KD-86 — same
(2026-10-21T19:50:44, queue_store.ex/connection.ex). Consistent with §2: these
are the mid-flight BK lane shims awaiting their PASS witnesses; flips are
correctly blocked. No row claims CLOSED while kd_flip sees an unflipped shim.

## 5. Sample witness verification (5 rows spot-checked)

| row | cited receipt | on disk |
|---|---|---|
| KD-36/08/09 | `docs/jira/v26.10.20/receipts/kd44-08-09-live-reprobe-witness.md` | EXISTS (3292 B) |
| KD-142 | `docs/jira/v26.10.21/receipts/bk18-blob-error-contract.md` | EXISTS (4962 B) |
| KD-85 | `docs/jira/v26.10.20/receipts/kd85-enqueued-time-sdk-witness.md` | EXISTS (2306 B) |
| KD-56 | `docs/jira/v26.10.20/receipts/kd56-provider-register-witness.md` | EXISTS (1483 B) |
| KD-16/11/17/33/34 | `docs/jira/v26.10.20/receipts/kd11-kd16-kd17-kd33-kd34-kv-wire-witness.md` | EXISTS (3741 B) |

5/5 cited witness receipts exist on disk.

## 6. Pointer-doc drift (v26.10.21 KNOWN_DIVERGENCES.md)

The pointer claims "rows KD-01..KD-157 as of 2026-10-21" and "Mint from
KD-143". On disk: 157 rows spanning KD-01..KD-160 — KD-144, KD-145, KD-146,
KD-153, KD-154, KD-159, KD-160 exist and are above the pointer's stated
ceiling, and KD-144..160 postdate "mint from KD-143". The table is ground
truth; the pointer prose is stale (FINAL-RELEASE.md:294 names the correct
open set at window close, minus KD-142/KD-157 which flipped after that
section was written via BK-18/BK-20 — those flips are receipt-gated and
witnessed, so FINAL-RELEASE's open list is also one wave stale).

## 7. Findings summary (report-only; no edits made)

1. **3 malformed rows** — KD-16, KD-56, KD-85: unescaped pipes, KD-23-class
   structural regression. Mechanical repair; kd_flip already misparses KD-85.
2. **Pointer doc stale** — v26.10.21 KNOWN_DIVERGENCES.md says KD-01..157 /
   mint-from-143; table carries KD-144..KD-160. Needs a one-line refresh by
   the kd-registrar/milestone-doc owner.
3. **FINAL-RELEASE open-row list one wave stale** — still lists KD-142 and
   KD-157 as open; both flipped receipt-gated (BK-18, BK-20).
4. Counts are coherent: table = ground truth, kd_flip agrees, no duplicate
   ids, no row claims closure without a cited witness (5/5 spot-checks hit).
5. OWNERLESS count: **0**.
