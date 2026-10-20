# Receipt — V261019-09 (py-external-suite)

Context: solo(V261019-09) — census commands executed in this lane, 2026-10-19 ~10:10 PDT.
Standing: **PARTIAL / IN-FLIGHT** — the suite surface exists on disk
(`verification/py/`: conftest.py, harness/, pyproject.toml, run.sh,
test_wf1..test_wf5) but the suite has NOT landed: no green pytest run is
recorded this window, and the portable-target gate currently exits 1
against the tree (see V261019-08 for the shared RED evidence).
Base: 64f6099663a4ec32fd9478c4c39fca49ab1961f8 (shared checkout, 143 dirty paths)
Date: 2026-10-19

## What changed

- The external Python suite moved from the old plan's `smalt-cli/tests/` to
  `verification/py/` per the clean-room reset. On disk right now:
  `conftest.py` (from the deleted suite's lift,
  `docs/jira/v26.10.19/lifts/conftest.py`), `harness/`, `pyproject.toml`
  (`smalt-py-verification` editable install into `.venv`), `run.sh`, and
  five workflow test files `test_wf1_governance.py` … `test_wf5_throttling.py`.
- ADR-PY-002 interpreter discipline (`.venv-cli` only, bare `.venv` never
  created) predates the reset; the on-disk tree currently has a
  `verification/py/.venv/` editable install — the py suite owner must
  reconcile with the ADR before close (disclosed, not fixed, by this lane).
- No suite-owned fixes landed in this lane's file set.

## Verification (real output tails)

```
$ grep -rn "def test_" verification/py/ | wc -l
38
```

```
$ grep -rln "def test_" verification/py/*.py | wc -l
5
```

38 pytest items across the 5 test_wf*.py files — censused, not executed.

```
$ cd smalt-cli && .venv-cli/bin/python -m pytest tests/ smalt_cli/ -q   # NOT EXECUTED
```

Not run: `smalt-cli/tests/` is the pre-reset surface; the reset moved the
external suite to `verification/py/`. The suite owner's run (`run.sh` /
`.venv-cli`) is pending and will be recorded in the suite owner's receipt.

```
$ cd smalt-cli && .venv-cli/bin/python -m pytest tests/test_w3_session_ops.py   # NOT EXECUTED
```

The v26.10.18 residual faces (`i29-verify-residual.md` §2, the 3
`test_w3_session_ops.py` failures) cannot be re-statused this session: the
file is deleted with the old suite; status carries as still-listed against
the new suite's first executed run.

## Acceptance greps

- `grep -rn "def test_" smalt-cli/tests smalt-cli/smalt_cli | wc -l` — not
  censused (surface replaced by verification/py; 38-item census above is the
  post-reset count).
- `grep -rn "python3 " scripts/ justfile.d/ | grep -v ".venv-cli"` — not run
  this lane; deferred to the suite owner's close receipt.

## Deviations

1. Skeleton assumed `smalt-cli/tests/` + `smalt_cli/` lanes; the reset moved
   the external Python suite to `verification/py/` (test_wf1..wf5 layout).
2. Standing is PARTIAL/IN-FLIGHT: no executed pytest run exists on the tree
   this session; the v26.10.18 residual faces are unresolved, and a
   `verification/py/.venv` exists on disk contra ADR-PY-002 as written.
3. Pending command (exact): `cd verification/py && ./run.sh` (pytest over
   `test_wf1..test_wf5`, 38 censused items, via `.venv-cli` per ADR-PY-002
   reconciliation) — **BLOCKED during in-flight court**: the suite's conftest
   boots the substrate, forbidden while a court is in flight. Suite owner
   executes post-court and embeds the pytest tail here.

## Phase-3 execution (suite owner, 2026-10-19, post-court)

Standing: **ALIVE** (was PARTIAL/IN-FLIGHT — the pending `run.sh` execution
recorded below closes it).

Pinned SHA: `a45cf03bdb6d72ffcd970c8783f0163c96fe5950` (`git rev-parse HEAD`,
matches expected a45cf03...).

Command (×3 consecutive, back-to-back, zero manual retries):

```
cd /Users/sac/smalt/verification/py && bash run.sh
```

Run 1 tail:
```
XFAIL test_wf3_messaging.py::test_eventhub_checkpoint_roundtrip - SUBSTRATE_EH_PYAMQP_OPENFRAME_DIVERGENCE: EH Open frame omits locale fields required by azure-eventhub pyamqp — list index out of range
XFAIL test_wf4_crypto.py::test_soft_delete_recover_purge - SUBSTRATE_VAULT_DELETED_STATE_LOST: :smalt_vault_deleted_keys ETS owned by per-request process, no heir — deleted-key bundle 404s across requests (witness GET -> 404, error ResourceNotFoundError)
9 passed, 2 xfailed, 6 warnings in 28.84s
[py-lane] PASS (or honest skips)
```

Run 2 tail:
```
9 passed, 2 xfailed, 6 warnings in 23.62s
[py-lane] PASS (or honest skips)
```

Run 3 tail:
```
9 passed, 2 xfailed, 6 warnings in 23.19s
[py-lane] PASS (or honest skips)
```

Assertions:

- **Zero flakiness**: identical pass set ×3 (9 passed, 2 xfailed, rc=0
  each run; same xfail IDs both runs, KD-cited:
  `SUBSTRATE_EH_PYAMQP_OPENFRAME_DIVERGENCE`,
  `SUBSTRATE_VAULT_DELETED_STATE_LOST`).
- **Zero manual retries**: three invocations, no re-run between them.
- **Retry activity**: the only retry traffic is SDK-internal 429 handling in
  wf5 (`test_arm_rate_limit_429`) — LAWFUL by the lane contract. Observed:
  run1 `19 x 200, 181 x 429 (retry-after=1)`, run2 `20 x 200, 180 x 429
  (retry-after=1)`, run3 `19 x 200, 181 x 429 (retry-after=1)`. No
  test-level retries; no retries outside wf5.

Note (pre-existing, disclosed by the earlier section): the suite ran via
`verification/py/.venv` created by `run.sh` (bare `.venv`, contra
ADR-PY-002 as written) — the reconciliation item carries.

Deviation 3 above (BLOCKED during in-flight court) is resolved: substrate
booted via `scripts/substrate-ctl up --block v1 --auth enforce`, torn down
by the run.sh trap after each run. Full logs: `/tmp/py-run-{1,2,3}.log`.
