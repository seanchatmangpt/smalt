# TAG-PREP — smalt v26.10.16 tag-prep lane

Standing: **PREP-ONLY — no tag executed.** Prepared 2026-10-17, docs-only lane.
All values read from disk at this edit; re-verify before execution.

## State at prep time

- **HEAD**: `7275032bca5007fbacceb7421a7fda6e501298a0`
  (`7275032` — "chore: park v26.10.16 wrap state (index-exclusion marker, r224
  diagnosis, receipts)")
- **Landing lineage**: `f0d2f47` ("chore(tools): substrate/doctor/court/receipt
  tooling") — verified ancestor of HEAD (`git merge-base --is-ancestor f0d2f47
  HEAD` → ancestor; `git log --oneline f0d2f47..HEAD | wc -l` → 12 commits).
  The tag annotates this lineage.
- **KD register**: 94 rows (KD-01..KD-94), canonical table at
  [`../v26.10.14/KNOWN_DIVERGENCES.md`](../v26.10.14/KNOWN_DIVERGENCES.md)
  (`grep -c '^| KD-' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` → 94).
- **Court standing at prep**: NO two-green receipt yet. Latest completed gate:
  **run-27** (`tmp/court-x2-wrap-run27.log`, 2026-10-17 00:30-01:14 local):
  run 1 exit 2 (`2435 tests, 1 failure` — `Smalt.AffidavitWasmTest`
  `test/smalt_affidavit_wasm_test.exs:80`, one-per-run flake class), run 2
  exit 1 with **0 test failures** (3 SDK-smoke legs red:
  blob/cosmos/amqp). `COURT_X2_RC=1`. **run-29 was IN-FLIGHT at prep**
  (log header only; `scripts/court_x2.sh` running). Do not flip any standing
  line until a run logs `[COURT-X2] RECEIPT: gate PASSED`.
- Existing tags on the repo: **0** (`git tag -l | wc -l` → 0). This is the
  first annotated tag in the repo.

## 1. Annotated tag (coordinator-run, NOT executed here)

```bash
git tag -a v26.10.16 -m "smalt v26.10.16 — BEAM-native local cloud-edge emulator. Court-x2 verdict: <RUN-VERDICT from the first two-green run receipt, e.g. 'run-30 two-green, runs 1+2 exit 0, 2435 tests / 0 failures'>. Landing lineage f0d2f47..7275032 (12 commits; f0d2f47 verified ancestor). KD register 94 rows (KD-01..KD-94), canonical table docs/jira/v26.10.14/KNOWN_DIVERGENCES.md. Receipts: docs/jira/v26.10.16/receipts/ (312 md + 49 sdk per INDEX)."
```

- `<RUN-VERDICT>` placeholder is filled ONLY from the real two-green receipt —
  a court verdict is never paraphrased into a tag from memory. If no two-green
  run exists at tag time, the tag is not cut (Variant B of
  [post-commit-checklist.sh](post-commit-checklist.sh) step 5 applies: the
  tag message quotes the real non-PASS verdict verbatim instead).
- Preconditions before the tag: wrap commits landed, `just court-x2` has a
  verdict, `bash docs/jira/v26.10.16/post-commit-checklist.sh <verdict>` has
  run (it fills FINAL.md PENDING-POST-COMMIT, flips CHANGELOG/RELEASE_NOTES,
  regenerates the receipt index, gates on `just docs-dod-check`), and the
  resulting docs edits are committed.

## 2. Post-tag push

```bash
git push origin v26.10.16
```

Verify:

```bash
git ls-remote --tags origin | grep v26.10.16
```

## 3. Fresh-clone proof

```bash
git clone --depth 1 --branch v26.10.16 <origin-url> /tmp/smalt-tag-proof && \
  git -C /tmp/smalt-tag-proof rev-parse HEAD && \
  git -C /tmp/smalt-tag-proof describe --tags && \
  diff <(git -C /tmp/smalt-tag-proof rev-parse HEAD^{commit}) \
       <(git rev-parse v26.10.16^{commit}) && echo FRESH-CLONE-PROOF-OK
```

Expected: the cloned HEAD equals the annotated tag's commit (`^{commit}`
dereferences the tag object through to the landing commit), `describe --tags`
prints `v26.10.16`, and the proof exits 0 with `FRESH-CLONE-PROOF-OK`.
Delete the scratch clone after the proof (`rm -rf /tmp/smalt-tag-proof`).

## Sequence (order matters)

1. run-29 (or later) lands a two-green `[COURT-X2] RECEIPT: gate PASSED`
   (log + receipt in `receipts/`).
2. `bash docs/jira/v26.10.16/post-commit-checklist.sh PASS` — flips
   FINAL/CHANGELOG/RELEASE_NOTES standing lines; regenerates
   `receipts/INDEX.md`; gates on `just docs-dod-check` (exit 0).
3. Commit the flipped docs (`git commit -F <msgfile>`).
4. Run the annotated-tag command above with the real run verdict.
5. `git push origin v26.10.16` + `git ls-remote` verify.
6. Fresh-clone proof (command above), then remove the scratch clone.
7. Update `release-announcement-draft.md` standing line to the real verdict,
   then `just receipt-index` once more before publish-dry.
