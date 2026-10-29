# BK-WRAP3 — post-surge receipt-index regen + gates (seal feed)

- **Standing**: ALIVE — all four steps executed with embedded real output; regen committed.
- **Context**: solo

## 1. `python3 scripts/receipt_index.py` — exit 0

```
receipts=1454 sdk=61 total=1515 suspects=23
```

16 files written across all 8 windows; 4 had diffs vs the committed index:
v26.10.14 (RECEIPTS.md + receipts/INDEX.md) and v26.10.22 (RECEIPTS.md +
receipts/INDEX.md), +16/−4 total. New rows in both windows' tables: bkcert-certify-audit
(ALIVE), bkegs1-fallback-fence (ALIVE), bkf6r-receive-bound (ALIVE),
bkstand3-proseonly (PARTIAL_ALIVE), bkxpri-cross-milestone (PARTIAL_ALIVE),
expl12d-sb-residual (ALIVE). Index totals: 1431 → 1515 (+84 since BK-WRAP2);
suspects 43 → 23 (BK-WPARSE hardening + owner normalizations landed).

## 2. Gates

- `python3 scripts/kd_flip.py` (read-only) — **exit 0** (BK-WRAP2 was exit 1 on the
  unregistered KD-175; the KD-169R lane's register sync landed). 121 KD ids from 144
  files covered. **FLIP-ELIGIBLE: 0. FLIP-PENDING-WITNESS: 2** (not flipped here —
  owner residue):
  - **KD-168**: registrar hold — cross-id evidence matches refused. Owner: kd-registrar.
  - **KD-174**: no post-shim receipt newer than shim mtime (2026-10-22T06:22:22).
    Owner: EXPL9 / arm_gateway lane.
- `python3 scripts/kd_receipt_fence.py` — exit 0: `checked 325 receipt cites across
  6 registers + 2 pattern docs -> OK` (325 cites, was 309 at BK-WRAP2).
- `just docs-dod-check` — exit 0 (all OK lines incl. kd-receipt-fence OK).

## 3. VALIDATION.md PENDING count

`grep -c PENDING docs/jira/v26.10.22/VALIDATION.md` → **8** mentions, **0 row-level
PENDING cells** (board §4 states 0 with closures cited; remaining mentions are prose,
lineage, and the §3 Gate-3-seal `PENDING-GATE` residue). Unchanged from BK-WRAP2.

## 4. Dirty-file census (coordinator quiet-tree read; as of BK-WRAP3 run, pre-commit)

| file | owner lane (per in-file markers + checkpoint messages) |
|---|---|
| `lib/smalt/arm_gateway/router.ex` (M) | **BK-XPRIF** — typed plug-status < 500 fence exemption (closes the BK-XPRI HIGH regression class: typed 400 no longer swallowed by the 500 envelope) |
| `lib/smalt/mcp/router.ex` (M) | **BK-XPRIF** — same typed plug-status exemption on Mcp.Router |
| `lib/smalt/egress_router.ex` (M) | **BK-XPRIF** — same exemption on EgressRouter |
| `smalt-cli/smalt_cli/commands/login.py` (M) + `?? smalt-cli/tests/test_ty_login.py` | TY login lane (cli probe tests) |
| `?? smalt-cli/tests/test_ty_monitor.py` | TY monitor lane (cli probe tests) |
| `test/internal/internal_tier_census_test.exs` (M) | internal-tier census lane |
| `test/internal/kafka_exp4_court_test.exs` (M) | kafka EXP4 court lane |
| regenerated index files (M ×4) | this lane (BK-WRAP3), committed here |

BK-WRAP2's previously-dirty files (conftest.py, BK-E2SKIP, BK-WP2, BK-EPLAW2 staged
receipt, kd169r-cred-gate.md) no longer present — landed or resolved since.

## Falsifier

Re-run `python3 scripts/receipt_index.py` on the post-commit tree — idempotent,
`suspects=23`, `total=1515`. kd_flip read-only stays exit 0 unless a new unregistered
KD id lands in `lib/`.
