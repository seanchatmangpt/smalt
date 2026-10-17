# COUNTERS — v26.10.17 canonical counter home

Single home for cross-doc cumulative counters. Every entry names its
DERIVATION COMMAND; the number is re-derived at execution time from the
referent on disk and is never restated from prose (stale-by-default
law). An entry with no command is not a counter entry.

## arm_lines_deleted (W6 route shells)

- **Seed: 0** (no route-macro family deletion has landed under W6 yet).
- **Derivation command** — total line count of the route macro families
  pre-W6 vs at execution time; deleted = pre − post, summed over the
  family files:

  ```bash
  PRE_W6_SHA=<first-commit-before-the-first-W6-family-deletion>
  for f in lib/smalt/arm_gateway/router.ex lib/smalt/egress_router.ex; do
    pre=$(git show "$PRE_W6_SHA:$f" | wc -l)
    post=$(wc -l < "$f")
    echo "$f: $pre -> $post (deleted $((pre - post)))"
  done
  ```

  (The plan's ~2,400-2,800 arm + ~300 egress figures in
  `docs/jira/v26.10.16/PROJECTION-ARCH-PLAN.md` §1 W6 are a planning
  PROJECTION, not a measurement; only the command output above is a
  counter datum. The seed flips from 0 on the first W6 family receipt.)

## KD register totals (pointer)

- **Derivation command** — per-row split on the LAST status cell with an
  escaped-pipe-aware split (KD-23's status sits behind `\|`; naive awk
  field positions shift):

  ```bash
  python3 - <<'EOF'
  import re
  closed = open_ = 0
  for line in open('docs/jira/v26.10.14/KNOWN_DIVERGENCES.md'):
      s = line.strip()
      if not (s.startswith('|') and s.endswith('|')): continue
      core = [c.strip() for c in re.split(r'(?<!\\)\|', s.strip('|'))]
      if len(core) < 3 or not core[0].startswith('KD-'): continue
      u = core[-1].upper()
      if 'CLOSED' in u: closed += 1
      elif 'OPEN' in u: open_ += 1
  print(f'{closed} CLOSED / {open_} OPEN')
  EOF
  ```

  Referent: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (canonical table).
  Do not restate the figure here; run the command.

## Receipt index totals (pointer)

- **Derivation command**: `just receipt-index` (summary line of
  `python3 scripts/receipt_index.py`; fields
  `receipts= sdk= total= suspects=`). Referent:
  `docs/jira/v26.10.16/receipts/INDEX.md` regenerated at execution
  time. Do not restate the figure here; run the command.

## Court-x2 ledger (pointer)

- **Derivation command** — count completed invocations from the ledger,
  not prose:

  ```bash
  grep -c 'COURT_X2_RC=' tmp/court-x2-wrap-run*.log 2>/dev/null | tail -1
  # ledger of record: docs/jira/v26.10.16/WRAP_LEDGER.md
  # "Court ledger extension — runs 30-32": 32 completed invocations,
  # 0 two-green (read from disk, 2026-10-17)
  ```
