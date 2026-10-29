# BK-AZDT — azdata runtime untrack (azurite churn removal)

Standing: ALIVE — Context: solo.

## Finding

`popcorn_demo/azurite-spike/azdata/` (azurite local blob DB: `__azurite_db_blob__.json`,
`__azurite_db_blob_extent__.json`, 50 `__blobstorage__` extents, `AzuriteConfig`) was
tracked despite `.gitignore` line 140 already carrying
`popcorn_demo/azurite-spike/azdata/` (landed at bd964672, "azurite-spike azdata
gitignored") — files tracked before the rule landed stay tracked, so every coordinator
tick checkpoint re-committed 3 runtime files (2× json + one ~2.5 MB extent), witnessed
across ≥8 consecutive tick commits (e3e351fc, 37568d4c, abb8c139, 433c50ce, d6c4bc0a,
5211bda3, 2bcfe382, bd964672). Pure runtime state: no code/config/test references the
paths (grep over ex/exs/mjs/sh/json/md/toml: only the spike's own RECEIPT.md and a
witness receipt mention them).

## Capital preserved

`error-census.jsonl` is **capital** (BK-18 blob error-contract, KD registrar receipts
reference it) and lives at `azurite-spike/` root, **outside** `azdata/` — untouched,
still tracked (`git ls-files` confirms). Only the `azdata/` file class removed from the
index; files remain on disk.

## Action

`git rm -r --cached popcorn_demo/azurite-spike/azdata` — 53 files staged for removal
from index only, all still on disk. `.gitignore` needed no edit (rule already present).

## Verification

- `git ls-files popcorn_demo/azurite-spike/azdata` → 0 after staging.
- Post-commit `git status` carries no azdata churn (previously guaranteed churn every tick).
- Mock-write test: appended a line to the DB json → only the staged-D entries showed;
  after commit a write shows nothing (ignored).
- Receipt of the recovery: the mock write landed on the live DB json before the ignore
  took effect; restored from `git show HEAD:` (older snapshot — runtime DB is
  regenerable, azurite re-seeds at next boot per BK-91 idempotent seeding). JSON
  re-validated with python3 json.load.

## Residual

If `AzuriteConfig` is wanted as a committed fixture (53-byte config), it is now untracked
too; re-add with `git add -f` only if a court depends on a pinned copy. Current grep
found no consumer.

## Addendum — concurrent-lane mechanics (post-commit)

- Commit 9ed57f87 (receipt) accidentally folded two concurrently-staged files authored
  by other lanes (`kd175f-flip.md`, KNOWN_DIVERGENCES edits) — shared-index sweep at
  amend time; content intact, landed early, no loss.
- Coordinator tick 9b980c8a landed on top of the untrack commit c7cec270 and its
  index-commit re-added the 53 azdata files (stale shared index carried them as staged
  adds). Final surgical removal landed as 69401015 (temp-index commit-tree, FF-verified,
  zero collateral paths).
- Verified end state on disk+index: `git ls-files azdata` = 0; `error-census.jsonl`
  still tracked; mock write to the DB json produces zero status churn (grep exit 1);
  DB json restored from 9ed57f87 and JSON-validated (azurite re-seeds at next boot).
