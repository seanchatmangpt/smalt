# BK-WIT4F — witness-all scope pinned by name (BK-WIT4-1 repair)

**Standing:** ALIVE
Context: solo
Date: 2026-10-22
Owner lane: BK-WIT4F (harness-owner repair lane for BK-WIT4-1)

## Change

`scripts/witness_all.py` `discover_receipts_dirs()` no longer picks scope
windows by dir mtime. Windows are **pinned by name** to the standing-contract
scope — current window `v26.10.22` + exemplar window `v26.10.20` (the BK-WPARSE
contract: "witness-all dry-run over the two newest windows (v26.10.20 +
v26.10.22)"). `WITNESS_RECEIPTS_DIRS` env override preserved verbatim (explicit
env wins outright). Fail-closed gate, safe-class re-run machinery, and
typed-skip machinery untouched.

## Before / after (real runs, dry-run mode)

Before (BK-WIT4 run, mtime picker — from `bkwit4-witness-final.md`):

```
[WITNESS-SCOPE] windows=docs/jira/v26.10.14/receipts docs/jira/v26.10.22/receipts
[WITNESS-SUMMARY] total=515 witnessed-green=111 stale-typed=224 failed=180
```

After (this lane, dry-run):

```
[WITNESS-SUMMARY] total=588 witnessed-green=0 stale-typed=385 failed=2 (DRY-RUN)
```

- **v26.10.14 fully excluded**: zero v26.10.14 receipts in the run output; the
  only two `v26.10.14` strings in output are command paths *inside*
  v26.10.22 receipts (`kd_flip.py --scan-root docs/jira/v26.10.14/...`,
  a grep against v26.10.14/KNOWN_DIVERGENCES.md) — commands, not scope.
- **NO-STANDING 130 → 2**: only the two true current-window residues
  (`bkgwsp-poll.md`, `bkqmon-window.md` — no canonical standing field) fail.
  The 128 pre-law v26.10.14 receipts are gone from the sweep.
- Fail-closed preserved: receipts in a PINNED window without standing still
  flag (the 2 above), and the gate exits non-zero when fails are present.
- Env override witnessed: `WITNESS_RECEIPTS_DIRS=/tmp/a:/tmp/b` returns
  exactly those dirs.

## Verification

```
$ python3 -c "import sys; sys.path.insert(0,'scripts'); import witness_all as w; print(w.discover_receipts_dirs())"
['/Users/sac/smalt/docs/jira/v26.10.20/receipts', '/Users/sac/smalt/docs/jira/v26.10.22/receipts']
$ python3 scripts/witness_all.py --dry-run | grep -c 'v26.10.14'   # scope rows only
2  (both are command paths inside v26.10.22 receipts, not scope rows)
```

No witness_all-specific tests exist in `test/` (grep: zero files reference
witness_all) — verified via the scope-selection function directly + dry-run.

## Standing

ALIVE — scope selection is deterministic by name, mtime drift class eliminated;
gate remains fail-closed; the two known standing-less receipts still flag.
