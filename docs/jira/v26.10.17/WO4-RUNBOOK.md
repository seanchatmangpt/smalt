# WO-4 Runbook — Version Bump 26.10.16 → 26.10.17

Rehearsed end-to-end on a scratch materialization (`just wt-scratch HEAD`)
on 2026-10-17. Every step below was executed for real; scratch deleted
after. No edits in the canonical checkout.

## Findings from rehearsal

- **Three files carry the version, not two.** Besides `mix.exs:4`
  (`@version`) and `workspace/package.json` (`"version"`), the bump must
  also touch `workspace/package-lock.json` (the version appears TWICE, at
  lines 3 and 9 — top-level `version` and `packages[""].version`). Update
  all three occurrences (or run `npm install --package-lock-only` inside
  `workspace/`).
- **Canonical rider regen RUNS in the scratch** (deps resolve via
  `mix deps.get`, exit 0; `mix run -e 'Smalt.Projection.Canonical.write()'`
  exit 0, full app self-boots on ephemeral ports). It does NOT need to run
  in-tree only. It changes exactly two fields in `docs/capabilities.json`:
  `"semanticEpoch": "26.10.16" → "26.10.17"` and the derived
  `contentSha256`. `docs/THIRD_PARTY.md` stays byte-identical (mix.lock
  unchanged) — its diff must be EMPTY.
- **CHANGELOG prepend rehearsal**: extracting everything from
  `## [26.10.17]` (draft line 12) to EOF and inserting after the FIRST
  `## [Unreleased]` (CHANGELOG.md:9) renders cleanly — heading order
  `## [Unreleased] → ## [26.10.17] → ## [26.10.16] → ## [26.10.14]`,
  `### Fixed/Added/Changed` subsections land under the new section.
  The `<date>` placeholder (draft line 12) must be replaced with the
  bump date at insert time.
- **Pre-existing drift (do NOT fix in WO-4, disclose instead)**: a stray
  second `## [Unreleased]` heading at `CHANGELOG.md:469`, leftover under
  the 26.10.14 section. The insert anchors on the FIRST occurrence, so it
  is unaffected; leave it, disclose in the WO-4 receipt.
- Draft banner line 1 (104 chars) is a gate header, not inserted; the
  inserted section itself is within the 100-char line budget.

## Steps (in order)

1. **Precondition**: two-green (or the documented typed-RED waiver) landed.
   Confirm standing per `docs/jira/v26.10.17/FINAL.md`.
2. **Bump versions** (from repo root `/Users/sac/smalt`):

   ```bash
   sed -i '' 's/@version "26.10.16"/@version "26.10.17"/' mix.exs
   sed -i '' 's/"version": "26.10.14"/"version": "26.10.17"/' \
     workspace/package.json workspace/package-lock.json
   ```

   The `package-lock.json` sed hits both occurrences (lines 3 and 9).
   Alternative: `cd workspace && npm install --package-lock-only`.

3. **Regenerate Canonical riders in-tree**:

   ```bash
   mix run -e 'Smalt.Projection.Canonical.write()'
   ```

   Exits 0; self-boots the app on ephemeral ports (expected log noise:
   Bandit listeners 9443/9444/8443/9545/5672/5673). Do not hand-edit the
   outputs.

4. **CHANGELOG insert** — extract from `## [26.10.17]` to EOF of
   `docs/jira/v26.10.17/CHANGELOG-26.10.17.draft.md`, replace `<date>`
   with the release date (`2026-10-17`), insert after the FIRST
   `## [Unreleased]`:

   ```bash
   awk '/^## \[26.10.17\]/{f=1} f' \
     docs/jira/v26.10.17/CHANGELOG-26.10.17.draft.md > /tmp/section.md
   python3 - <<'EOF'
   s = open('/tmp/section.md').read().replace('<date>', '2026-10-17')
   t = open('CHANGELOG.md').read()
   assert '## [Unreleased]' in t
   t = t.replace('## [Unreleased]\n', '## [Unreleased]\n\n' + s, 1)
   open('CHANGELOG.md', 'w').write(t)
   EOF
   ```

   This is the exact script exercised in the scratch rehearsal (anchor =
   FIRST `## [Unreleased]` via `str.replace(..., 1)`; the stray second
   one at line 469 is untouched).

5. **Verification greps** (all must pass before commit):

   ```bash
   grep -n '@version "26.10.17"' mix.exs                     # line 4
   grep -n '"version": "26.10.17"' \
     workspace/package.json workspace/package-lock.json      # lock: lines 3 AND 9
   grep -c '26.10.17' docs/capabilities.json                 # >= 1 (semanticEpoch)
   grep -n '"semanticEpoch"' docs/capabilities.json          # "26.10.17"
   diff docs/THIRD_PARTY.md <(git show HEAD:docs/THIRD_PARTY.md)  # empty
   grep -n '^## \[26.10.17\] - 2026-10-17' CHANGELOG.md      # line 11
   ! grep -n '<date>' CHANGELOG.md                           # placeholder gone
   ```

   Plus docs DoD: `just docs-dod-check` must pass (receipt paths in docs
   exist on disk).

6. **Residual checks**: `git diff --stat` should show exactly:
   `mix.exs`, `workspace/package.json`, `workspace/package-lock.json`,
   `docs/capabilities.json`, `CHANGELOG.md` — five files, no more. Any
   sixth file means an unexpected side effect; investigate before commit.

## Out of scope (other lanes)

- `git commit` / publish-dry / court-x2 — coordinator owns transitions.
- Deleting the draft file after insert (keep; it is the WO-4 input
  provenance) — coordinator call.
