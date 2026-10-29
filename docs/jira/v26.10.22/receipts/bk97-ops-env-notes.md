# BK-97: ops-receipt environment notes (TMPDIR class)

**Standing:** ALIVE
Context: solo
Date: 2026-10-21

## Findings

- `$TMPDIR=/Users/sac/.cache/tmp` — the directory now exists on this host
  (`drwxr-xr-x`, 11 entries; ensured with `mkdir -p` as part of this WO).
  Two lanes hit the same environment wall: BK-90's witness run noted
  "`$TMPDIR=/Users/sac/.cache/tmp` did not exist in the lane shell"
  (`docs/jira/v26.10.22/receipts/bk90-witness-scope.md:65`), and BK-96's
  docs-dod run failed on the same missing directory
  (`docs/jira/v26.10.22/receipts/bk96-runbook-addendum.md`).

## Actions

- `mkdir -p ~/.cache/tmp` — done; directory verified present.
- Added one ops note to `docs/reference/just-recipes.md`
  ("Env setup — ensure `$TMPDIR` exists"): `mkdir -p "$TMPDIR"` before
  court/gate runs, citing BK-90/BK-96 (v26.10.22).

## Verification

```
$ just docs-dod-check; echo "EXIT=$?"
... 62 checks ...
OK    README.md
EXIT=0
```

docs-dod 62/62 OK, exit 0 (pre-existing TMPDIR failure from BK-96's
environment no longer reproduces; the gate itself is unchanged).
