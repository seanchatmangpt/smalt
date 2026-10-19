# Receipt — V261019-07 (reset-inventory)

Context: solo(V261019-07) — commands executed 2026-10-19 10:00–10:12 PDT in this lane.
Standing: **LANDED** — deletion landed at commit `64f6099663a4ec32fd9478c4c39fca49ab1961f8`;
censuses below are real post-deletion output from this session.
Base: 64f6099663a4ec32fd9478c4c39fca49ab1961f8 (shared checkout, 143 dirty paths at receipt time)
Date: 2026-10-19

## What changed

- Reset/restore surface inventoried **after** the clean-room deletion
  (commit `64f6099`, "feat(reset): V261019-11 — clean-room deletion of the
  legacy test suite"). The 303-path delete manifest is the receipt artifact:
  `docs/jira/v26.10.19/receipts/reset-delete-manifest.txt` (303 lines,
  `wc -l` verified in this session).
- Post-deletion tracked test tree is exactly one file:

```
$ git ls-files test/
test/test_helper.exs
```

- Untracked residual tier (not yet committed, owned by V261019-10):
  `dets_mirror_recovery_test.exs`, `internal_tier_census_test.exs`,
  `plane_blast_radius_test.exs`, `poll_helper.exs`,
  `vm_zero_growth_test.exs`, `wasm_nif_lifecycle_test.exs` (6 files under
  `test/internal/`).
- Canonical reset entry point: `scripts/lib/substrate_boot.sh` /
  `scripts/substrate-ctl` (V261019-14 lane) — the deleted per-harness
  reset machinery (`SmaltTest.Lifecycle.ensure_store_up`, `restore_app`,
  `ts-run.mjs` boot block) is not present in the residual tree; the census
  greps below confirm zero matches.

## Verification (real output tails)

```
$ git show --stat 64f6099 | head -40
commit 64f6099663a4ec32fd9478c4c39fca49ab1961f8
Author: Sean Chatman <136349053+seanchatmangpt@users.noreply.github.com>
Date:   Mon Oct 19 09:34:23 2026 -0700

    feat(reset): V261019-11 — clean-room deletion of the legacy test suite
    ...
 .../lifts/assert_eventually-reference.exs          |    0
 docs/jira/v26.10.19/lifts/conftest.py              |  486 +++
 .../jira/v26.10.19/lifts}/ts-run.mjs               |    0
 .../v26.10.19/receipts/reset-delete-manifest.txt   |  303 ++
 mix.exs                                            |    2 +-
 test/admission_projection_test.exs                 |  533 ---
 test/affidavit_ingestion_functor_test.exs          |  240 --
 ... (303 deleted test/ paths; full stat: 107k lines deleted)
```

```
$ wc -l docs/jira/v26.10.19/receipts/reset-delete-manifest.txt
303 docs/jira/v26.10.19/receipts/reset-delete-manifest.txt
```

```
$ grep -rn "Application.stop(:smalt)\|restore_app\|ensure_store_up" test/ | wc -l
       0
```

```
$ grep -rn "restore_app()" test/ --include="*_test.exs" -l | sort
(no output — zero matches)
```

## Acceptance greps

- `git ls-files test/` => `test/test_helper.exs` (1 tracked file) — matches
  the expected post-deletion state.
- `grep -rn "restore_app\|ensure_store_up" test/ | wc -l` => `0` — the legacy
  reset surface is gone from the residual tree.

## Deviations

1. The skeleton's `mix test test/canonical_projection_test.exs
   test/store_churn_test.exs` precondition commands reference deleted files;
   not executable post-deletion. Replaced by the residual-tier run recorded
   in `v261019-10-residual-elixir-tier.md` (20 tests, 0 failures, this
   session).
