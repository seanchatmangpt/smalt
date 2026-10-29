# BK-ECREG: docs/ERROR_CODES.md regeneration (BK-149b residual 1)

**Standing:** ALIVE

Context: solo

Lane: bk-ecreg, 2026-10-22, repo /Users/sac/smalt, MIX_BUILD_ROOT=_build-bkecreg (unused — no compile needed).

## Precondition gate

`git status --porcelain lib/smalt/egress_router.ex` → empty (file landed/clean; no
bounded wait needed). Regeneration proceeded.

## Regen

Recipe: `just gen-error-codes` (justfile:144 → `python3 scripts/gen_error_codes.py`).

```
python3 scripts/gen_error_codes.py
wrote /Users/sac/smalt/docs/ERROR_CODES.md (248 rows)
 docs/ERROR_CODES.md | 60 ++++++++++++++++++++++++++---------------------------
 1 file changed, 30 insertions(+), 30 deletions(-)
```

Diff content: pure line-number refresh of the 30 egress rows — every
`lib/smalt/egress_router.ex:NNNN` citation shifted +5 (concurrent-lane lib edit
landed above the error sites). The two rows bk149b flagged as new
(InvalidCloudEvent :3542, InvalidEventGridEvent :3634) were already present from
the prior regen; only their citations moved (3537→3542, 3629→3634). No row added
or removed in this regen (248 rows before and after).

## Verification

Drift fence:

```
$ python3 scripts/gen_error_codes.py --check
docs/ERROR_CODES.md up to date
check exit=0
```

Test (smalt-cli .venv-cli, substrate-independent — passed without booting the
substrate):

```
$ cd smalt-cli && .venv-cli/bin/python -m pytest tests/test_error_codes_doc.py -v
tests/test_error_codes_doc.py::test_error_codes_doc_is_byte_identical_projection PASSED [ 33%]
tests/test_error_codes_doc.py::test_mutation_refused_literal_and_doc_row_agree PASSED [ 66%]
tests/test_error_codes_doc.py::test_bearer_subcodes_section_matches_bearer_source_literals PASSED [100%]
============================== 3 passed in 0.13s ===============================
```

BK-149b residual 1: CLOSED.
