# BK-FIN4 — FINAL-RELEASE refresh: census re-run, gate-ledger refresh, seal-inputs freshness

- **Date**: 2026-10-22
- **Lane**: BK-FIN4
- **Context**: solo (shared checkout; other lanes landing through the window)
- **Standing**: **ALIVE** — all four task items executed mechanically; doc updated with re-run census, gate-ledger rows that moved since BK-FIN3, and honestly-typed seal inputs.
- **Subject**: `/Users/sac/smalt` @ tree at refresh time; file owned `docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md` + this receipt.

## 1. Mechanical KD census (bk10c convention)

`awk -F'|'` status-cell (`$(NF-1)`) extraction over every `| KD-nn |` row in
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`, prefix-classified (a naive
substring scan over- and under-counts because status prose embeds the words
"OPEN"/"CLOSED" — one CLOSED-with-receipt cell quotes an audit note containing
"OPENdivergence" and must classify CLOSED):

```
TOTAL 178
CLOSED 166
OPEN 6
PINION-family 4
ENV-PINION 1
UNSUPPORTED-BY-COST 1
DUPS 0
OPEN rows: KD-168, KD-174, KD-177, KD-178, KD-179, KD-181
Highest minted id: 181
```

166+6+4+1+1 = 178, no skew, 0 duplicate ids. Delta vs BK-FIN3 (177/166/5):
KD-181 minted (Kafka Fetch-v0 legacy-face magic-2 verbatim-serve, lane KD-FV0,
`receipts/kdfv0-row.md` ALIVE); KD-180 was minted AND closed in the same
window so it moved CLOSED-count-neutral. Pointer
`docs/jira/v26.10.22/KNOWN_DIVERGENCES.md` names KD-181 highest / KD-182 next
— consistent with the canonical table.

## 2. Gate-ledger refresh (rows that moved since BK-FIN3)

| Row | Old standing | New standing | Receipts (all `[ -f ]` OK, standing lines read at use time) |
|---|---|---|---|
| BK-44 witness-all | BK-WIT4 IN-FLIGHT | PARTIAL_ALIVE landed, green still absent | `bkwit4-witness-final.md` (PARTIAL_ALIVE — 111 real greens, 180 fails all classified, zero real substrate/surface defects) + `bkwit4f-scope-fix.md` (ALIVE — scope pinned by name) |
| BK-SEAL full-green sweep | BK-SEAL5 IN-FLIGHT | **ALIVE — close condition MET** | `bkseal5-close.md` (ALIVE — full `mix test` verbatim `Result: 868/872 passed, Failed: 4`, all 4 classified load-contention flakes green in isolation; census 6/6; invariant-gates 6/6; sleep-gate + court non-vacuous; docs-dod OK; kd-fence OK; receipt-index regenerated clean; kd_flip 0 eligible; run under load 42-121, typed REFUSE quiesce in-receipt) |
| monitor face | PARTIAL_ALIVE | **ALIVE** | `bkmon3r-deadjoin-fix.md` (ALIVE — BK-MON3-F1 dead join predicate fixed end to end) → `bkmon4-final-verify.md` (ALIVE @ `daea2d87`) → `bkmon5-metrics-verify.md` (ALIVE @ `39bffd77`) → `bkmon6-integrity-verify.md` (ALIVE — exact-equality filter, zero cross-resource leakage) |
| kafka legacy face | CLOSED-WITH-EVIDENCE | same + merged verify | `bkkfkcw-merged-verify.md` (ALIVE) appended to the chain |
| COURT-CLI-SURFACE / auth uniformity | already in BK-FIN3 doc | unchanged | `bkclirow-cells.md` / `expl12f-auth-final.md` (already cited; re-verified on disk) |
| fence exemption | CLOSED — ALIVE | unchanged | `bkxprif` + `bkxpriv` re-verified on disk |
| F1-A mirror | CLOSED — ALIVE | unchanged | `bkf1a`/`bkfondv`/`bkfondw`/`bkbmir3` re-verified on disk |
| store4 disposition | typed | + census-fence closure note | `test/internal/internal_tier_census_test.exs` registers the BK-ST4W file (BK-SEAL5 SLA unblock, disclosed) |
| NEW: b4 sender-link | — | ALIVE | `bkb4r-sender-link.md` → `bkb4rc-send-gate-court.md` → `bkb4rd-json-route-verify.md` → `bkb7cr-consume-scope.md` (all ALIVE) |
| NEW: wasm sandbox gates | — | ALIVE | `bkgwsskep-wave-audit.md` (PARTIAL_ALIVE) → `bkgws7v-gate5.md` (ALIVE — gate-6 race fixed via bounded poll) → `bkgwsq-discharge.md` (ALIVE 3/3) → `bkgwsskep2-wave-verify.md` (ALIVE) + `kdfv0-row.md` (KD-181) |
| NEW: powl2 chain | — | ALIVE | `bkpinit-stale-delete.md` → `bk1safe-safeness.md` → `bkpowlv-loop-verify.md` → `bkpowlh3-walk-fix.md` → `bkpowlh4-pattern-fix.md` (all ALIVE) |
| NEW: bench gate F1 | — | CLOSED — ALIVE | `bkbgf-annotate.md` (ALIVE — BENCH-CLASS annotation, gate exit 1→0, non-vacuity held) |
| census | waves 4/5 green | waves 4/5/6 green | `bkcens6-wave6.md` (ALIVE — bkmon3r registered, BK-POWLH3-1 closed) |

Unchanged still-MISSING expected receipts (re-checked this refresh, each
typed in its row, none smoothed): `fr-snc-005`, `fr-snc-006`,
`bk44-witness-all`, `bk35-head-court-sweep`, `ttv7b-quiesced-flip`,
`bk53-finalrelease-seal`, `ttv5-store-partitioning`.

## 3. Seal inputs (typed honestly)

- Court census: **GREEN**, now three waves (4/5/6) — `bkcens4`, `bkcens5`,
  `bkcens6` all ALIVE.
- witness-all: **IN-FLIGHT (no green yet)** — BK-WIT4 landed PARTIAL_ALIVE
  (111/180 all classified), scope closed by BK-WIT4F; the green
  `bk44-witness-all.md` does not exist. Typed IN-FLIGHT, not smoothed.
- Full suite: **close condition MET (ALIVE)** via `bkseal5-close.md` —
  868/872 with 4 classified contention flakes, all green isolated. Caveat
  typed in doc and receipt: the run was under load 42-121 (quiesce REFUSE
  verbatim in-receipt); the coordinator owes a post-quiet x2 rerun at seal
  time. Not smoothed to "quiescent green".

## 4. Path verification (embedded output)

24 newly cited paths OK, 7 still-MISSING expected receipts (verbatim from
`for f in …; do [ -f ] …`):

```
OK bkwit4-witness-final / bkwit4f-scope-fix / bkseal5-close / bkcens6-wave6
OK bkgws7v-gate5 / bkgwsq-discharge / bkgwsskep-wave-audit / bkgwsskep2-wave-verify
OK kdfv0-row / bkbgf-annotate
OK bkb4r-sender-link / bkb4rc-send-gate-court / bkb4rd-json-route-verify / bkb7cr-consume-scope
OK bkmon3r-deadjoin-fix / bkmon5-metrics-verify / bkmon6-integrity-verify / bkdrain3-sequencer
OK bkkfkcw-merged-verify
OK bkpinit-stale-delete / bk1safe-safeness / bkpowlv-loop-verify / bkpowlh3-walk-fix / bkpowlh4-pattern-fix
MISSING fr-snc-005 fr-snc-006 bk44-witness-all bk35-head-court-sweep
MISSING ttv7b-quiesced-flip bk53-finalrelease-seal ttv5-store-partitioning
(24 OK / 7 MISSING — grep -c on /tmp/bkfin4-pathcheck.txt)
```

## 5. Gates after the edit

```
just docs-dod-check  -> pre-receipt MISS on receipts/bkfin4-refresh.md only (self-cite);
                        post-receipt rerun: exit 0, "OK (all receipt paths exist; kd-fence OK)",
                        793 cites, 7 typed-gap skips
just receipt-index   -> exit 0; receipts=1559 sdk=61 total=1620 suspects=1
                        (SUSPECT: bkstand6-final.md, pre-existing PARTIAL_ALIVE flag, not this lane's)
```

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH"
cd /Users/sac/smalt
awk -F'|' '/^\| KD-[0-9]+ \|/{s=$(NF-1); gsub(/^ +| +$/,"",s); t++;
  if(s~/^CLOSED/)c++; else if(s~/^OPEN/){o++;print "OPEN",$2}
  else if(s~/^PINION/)p++; else if(s~/^ENVIRONMENT-PINION/)e++;
  else if(s~/^UNSUPPORTED/)u++; else x++}
  END{print t,c,o,p,e,u,x}' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md
just docs-dod-check && just receipt-index
```

## Falsifier

Any count above not reproducible by the replay awk; any cited path absent;
docs-dod-check exit ≠ 0 after this receipt lands.
