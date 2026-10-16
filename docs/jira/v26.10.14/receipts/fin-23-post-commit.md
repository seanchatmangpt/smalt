# fin-23 — post-commit re-verification (fin lane)

Date: 2026-10-15, 19:40 PT. Repo: /Users/sac/smalt. Subject: commit 518b31a ("v26.10.14: release work-order landing …"), parent 3fc2543.

## Preconditions

- fin-21-final-wrap.md: FOUND (docs/jira/v26.10.14/receipts/fin-21-final-wrap.md, 1062 bytes, mtime 18:34).
- `git status --porcelain` (tracked): NEVER reached empty within the 60-min poll window (18:34–19:35 PT). Lanes kept landing in-flight edits while polling; tracked-dirty count went 20 → 27 (non-monotonic; briefly reached 0 at ~19:15 then rose again). Head moved 3fc2543 → 518b31a at 18:33. Gates were therefore run at 19:35–19:40 against the tree at HEAD=518b31a PLUS in-flight lane edits; per-file dirty set is listed under each gate's timestamp.

## Gate results (run 2026-10-15 ~19:35–19:40 PT)

### Gate 1 — `just doctor-dod`: PASS (0 FAIL)

- summary line: `summary: 0 FAIL, 1 WARN (exit 0 unless FAIL fired)`, exit 0.
- The 1 WARN: orphan lock holder `/tmp/smalt-substrate.lock` with no live smalt listeners on [9443, 8443] — environmental, not a DoD failure.
- Notable INFO: receipts freshness 85/85 inside 24h window; envelope/defect cross-check all 9 expected gap tokens present; gap register sync 2 CLOSED stamps + 9 live GAP tokens.

### Gate 2 — `python3 scripts/sdk_coverage.py`: PASS (exit 0)

- Totals line: `cells PASS: 2; MISSING=0 UNREGISTERED-GAP=0 REGISTERED-DIVERGENCE=13 SIM-PASS=0`.
- Expected `0 UNREGISTERED-GAP` — witnessed 0. All divergence is REGISTERED-DIVERGENCE (KD-xx cited) or MISSING-REGISTERED (KD-39..43, registered as missing).
- Per-service census line: `servicebus census CRC: registered=11 registered_total=14 +3 (test/sdk-smoke/sb-extra.probe.cjs) receipt_claim=11 header=11 -> OK`.

### Gate 3 — `just gap-sync`: FAIL (exit 1) — COMMIT-INTRODUCED DRIFT

- Output: OK census line prints first, then `gap-sync: DRIFT: missing /Users/sac/smalt/../docs/WIRE_PARITY.md` → exit 1.
- Root cause (verified by `just --dry-run gap-sync` from /tmp): recipe in `justfile.d/10-gap-register-sync.just:7` sets `REPO="{{justfile_directory()}}/.."`. For an *imported* recipe, `justfile_directory()` already resolves to the top-level Justfile dir `/Users/sac/smalt`, so `REPO` becomes `/Users/sac` and all three required files resolve outside the repo.
- Evidence the file checks would otherwise pass: `just -f justfile.d/10-gap-register-sync.just gap-sync` (direct file invocation, correct `justfile_directory()` = `/Users/sac/smalt/justfile.d` → REPO = repo root) passes all greps through the OK line, then fails on census — `expected 35 KD table rows, found 51` — because the working tree has 16 uncommitted lane edits to KNOWN_DIVERGENCES-adjacent registers (KD-36..51 pending landing).
- Pre-commit standing: this recipe file first appears in 518b31a itself (only commit touching it), so there is no pre-commit PASS standing to compare against; the gate as wired into `just gap-sync` (top-level Justfile import) has never passed on a committed tree.
- NOT FIXED per lane task — this is the exact drift to report.

## Verdicts

1. `just doctor-dod`: **PASS** (0 FAIL, 1 environmental WARN).
2. `scripts/sdk_coverage.py`: **PASS** (exit 0, UNREGISTERED-GAP=0).
3. `just gap-sync`: **FAIL** — path-resolution bug in the committed recipe (`{{justfile_directory()}}/..` → /Users/sac when imported by the top-level Justfile). Commit-introduced (recipe first landed in 518b31a). Not fixed per task instruction.
