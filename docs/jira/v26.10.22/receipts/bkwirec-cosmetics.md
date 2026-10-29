# BK-WIREC — wire.py cosmetic residue repair (EXPL12-F owner notes)

**Standing**: ALIVE · **Context**: solo · Date: 2026-10-22

## Scope (EXPL12-F typed residue, read-only-lane owner notes)

Two cosmetic defects in `smalt-cli/smalt_cli/wire.py`, both named in
`docs/jira/v26.10.22/receipts/expl12f-auth-final.md`:

1. **Stale comment (wire.py ~line 73-76)**: auth header block claimed
   "Failure degrades to tokenless (anonymous planes accept tokenless traffic)"
   — contradicting the code, where `bearer_for_arm()` andons on STS mint
   failure (loud, exit 1). Fixed: the comment now states the typed-ANDON
   truth ("Mint failure is a typed ANDON (loud, exit 1) — never a silent
   degrade to tokenless").
2. **Duplicated idempotent line (wire.py:114-115)**:
   `_token_cache[arm] = (time.time() + 300, tok)` appeared twice; deduped to
   one (behavior identical — idempotent assignment).

No other changes to wire.py or any other file owned by this lane.

## Grep receipts (post-edit, on disk)

```
$ grep -n "degrades to tokenless\|_token_cache\[arm\]" smalt-cli/smalt_cli/wire.py
114:    _token_cache[arm] = (time.time() + 300, tok)
```

Stale prose: zero matches. Cache line: exactly one occurrence (was two).

## Verification (fresh suites, SMALT_CLI_LANE=bkwirec, .venv-cli)

```
$ SMALT_CLI_LANE=bkwirec .venv-cli/bin/python -m pytest \
    tests/test_ty_storage.py tests/test_ty_arm_handshake.py -rs
collected 8 items
tests/test_ty_storage.py .....           [ 62%]
tests/test_ty_arm_handshake.py ...       [100%]
============================== 8 passed in 32.62s ==============================
```

First run of the same pair (substrate warm-up window): `5 passed, 3 skipped
in 87.32s` — the skips were warm-up-timing skips, not test failures; the
fresh re-run is 8/8 passed, 0 skipped. Behavior unchanged, as expected for a
comment + idempotent-line dedupe.

## Landing provenance (disclosure)

Coordinator tick checkpoint **cfde55d8** swept this lane's wire.py edit to
HEAD as an in-flight snapshot ("BK-WIREC" named in the checkpoint message);
this commit carries the receipt only. wire.py at HEAD is byte-identical to
what this lane verified (grep + suites above ran against that exact content).

## Notes

- Anonymous-mode arms of the suites exercise the ANDON path via mocked-free
  real wire traffic against the shared substrate; all green.
- No lib/, test/, canonical-register, or other-lane file touched.
