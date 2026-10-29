# BK-WRAP2 — post-surge receipt-index regen + gate pass (quiet-tree read)

- **Standing**: ALIVE — all four steps executed with embedded real output; regen committed.
- **Context**: solo

## 1. `python3 scripts/receipt_index.py` — exit 0

```
receipts=1370 sdk=61 total=1431 suspects=43
...
wrote /Users/sac/smalt/docs/jira/v26.10.14/RECEIPTS.md (+ receipts/INDEX.md)  [all 8 windows]
wrote .../v26.10.14, 16, 17, 18, 19, 20, 21, 22 (RECEIPTS.md + receipts/INDEX.md each)
EXIT=0
```

16 files written; 6 had diffs: v26.10.14 (×2), v26.10.21 (×2), v26.10.22 (×2) —
+18/−6 total. New rows: bk70rr-head-repair (PARTIAL_ALIVE, v26.10.21);
expl9r1-egress-guards, expl9r2-arm-guards, kd169r-cred-gate (ALIVE), kdfixf-register-prose
(PASS), mcpt1-descriptor-regen (ALIVE) in v26.10.22. Index total 1418 → 1431 (+13 receipts
since BK-WRAP).

## 2. Gates

- `python3 scripts/kd_flip.py` (read-only) — **exit 1** (was exit 0 at KD-FIXF time):
  - FLIP-ELIGIBLE: 0
  - FLIP-PENDING-WITNESS: 1 — KD-168 (mention-only receipt `kdfixf-register-prose.md`
    refused; no close evidence yet)
  - WITNESS-AMBIGUOUS: 2 — **KD-169** (2 candidate witnesses: `kd169r-cred-gate.md`,
    `kdfixf-register-prose.md`) and **KD-174** (3: `expl9r1-egress-guards.md`,
    `expl9r2-arm-guards.md`, `kdfixf-register-prose.md`) — legit flips owed via
    `kd_flip.py --apply --witness KD-ID=<path>` by their owners (EXPL9 / KD-169R lanes +
    kd-registrar), not flipped here.
  - Exit 1 cause: `UNKNOWN KD IDS in KD-COVERS tokens: KD-175`
    (`lib/smalt/egress_router.ex` carries `# KD-COVERS: KD-175` but KD-175 has no row in
    KNOWN_DIVERGENCES.md yet) — register sync owed by the KD-169R/egress lane.
- `python3 scripts/kd_receipt_fence.py` — exit 0 (`checked 309 receipt cites across 6
  registers -> OK`).
- `just docs-dod-check` — exit 0 (all 62 OK lines, includes kd-receipt-fence OK).

## 3. VALIDATION.md PENDING count

`grep -c PENDING docs/jira/v26.10.22/VALIDATION.md` → **8** mentions (was 11 at BK-WRAP).
Row-level PENDING cells per the board's own §4 ledger: **0** (was 3 at BK-WRAP; §4 now
states 0 with the closures cited). Remaining mentions are prose/lineage + the §3
Gate-3-seal `PENDING-GATE` residue.

## 4. Dirty-file census (coordinator quiet-tree read; nothing staged/edited by this lane)

| file | owner lane (per checkpoint 70405ff6 + receipts) |
|---|---|
| `lib/smalt/egress_router.ex` (M) | KD-169R — Web PubSub server-face credential gate; carries `# KD-COVERS: KD-175` (unregistered id, see gate exit 1 above) |
| `smalt-cli/tests/conftest.py` (M) | BK-CONF — conftest lanes |
| `workspace/scripts/.bke2skip-e2e-court.mjs` (D) + `?? bke2skip-skip-typing.md` | BK-E2SKIP — skip-typing of e2e court helper |
| `?? bkwp2-whitepaper-drift.md` | BK-WP2 — whitepaper drift receipt |
| `A docs/jira/v26.10.22/receipts/bkeplaw2-bench-fences.md` (staged, uncommitted) | BK-EPLAW2 — bench self-boot fences; **not indexed**: receipt uses plain `Standing:` not `**Standing**:` so `receipt_index.py` skips it (43-suspect set unaffected) — owner should normalize the standing line before seal |
| `?? kd169r-cred-gate.md` | KD-169R (now indexed, ALIVE) |

Everything else clean. Files committed by this lane: the 6 regenerated index files + this
receipt only (committed via explicit paths; BK-EPLAW2's staged file untouched).

## Falsifier

Re-run `python3 scripts/receipt_index.py` on a clean tree — idempotent, `suspects=43`,
`total=1431`. If KD-175 gains a register row, `kd_flip.py` read-only returns exit 0 again.
