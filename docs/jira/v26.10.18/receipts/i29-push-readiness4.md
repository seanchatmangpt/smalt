# i29-push-readiness4 — Push-Readiness Audit (read-only)

- **Date**: 2026-10-19
- **Subject**: unpushed range `1eb89df..HEAD` (8b4f74f), 68 commits
Context: solo (read-only audit lane; no mutations performed; working tree was already dirty at lane start with 11 modified files from other in-flight lanes)
- **Standing**: PARTIAL_ALIVE — 3 of 4 audit legs green; publish-dry gate 4 FAIL blocks READY

## Method

1. Range census: `git rev-list --reverse 1eb89df..HEAD | wc -l` → **68** (dispatch
   estimated ~43; actual is 68 — the range has grown since the estimate).
2. Per-commit secret-pattern grep (`git show <sha>` piped through
   private-key / AKIA / AccountKey= / SharedAccessKey / sig= / ghp_ / sk- /
   password= / sb://...@ credential-URL patterns), `docs/jira/` excluded from
   hits, placeholder/example values filtered.
3. Files-changed counts per commit (non-jira).
4. `just publish-dry` at HEAD (exit code + per-gate lines).

## Results

### Secret sweep — 68/68 commits, 1 hit, judged benign

Single flagged commit: **bf8a464** (`fix(amqp,e2e): s5 real lib defects + e2e
harness contract fixes`), test/e2e/s5_sessions/sessions.test.cjs lines 609-610:

```
`SharedAccessKeyName=RootManageSharedAccessKey;` +
`SharedAccessKey=${KEY};UseDevelopmentEmulator=true`;
```

`KEY` is an interpolated shell/dev-env variable, not a literal. The
`RootManageSharedAccessKey` name is the well-known Azure Service Bus emulator
connection-string literal. **Benign** — no real credential material in the
range. Other 67 commits: 0 hits.

Full per-commit log: `/tmp/i29_pushreadiness_grep.txt` (68 lines CLEAN/flagged
+ counts).

### Files-changed counts

Non-jira files per commit ranged 0-8; 20 of 68 commits touch zero non-jira
files (pure receipt/doc commits). Largest: bf8a464 (8 non-jira files,
test/e2e harness). No commit touches dotfiles, CI secrets, or packaging
manifests beyond what publish-dry gate 2/3 already cleared.

### publish-dry at HEAD — EXIT 1

```
-- gate 1: mix hex.build -o /tmp/hex-publish-dry/smalt.tar
   PASS (tarball: 803840 bytes; log: /tmp/hex-publish-dry/smalt.tar.build.log)
-- gate 2: inner-tar key grep (pattern: signing.key|verifying.key|\.ggen|keys/)
   PASS (0 matches in contents.tar.gz listing)
-- gate 3: packaged-set leak grep (pattern: athena|/Users/sac)
   PASS (0 hits in packaged set)
-- gate 4: python3 scripts/gen_error_codes.py --check
   FAIL: docs/ERROR_CODES.md is stale. Run: python3 scripts/gen_error_codes.py
== summary ==
FAIL (see per-gate lines above)
error: recipe `publish-dry` failed on line 8 with exit code 1
```

Gate 4 diff is **line-number drift only** in `docs/ERROR_CODES.md` rows citing
`lib/smalt/egress_router.ex:NNNN` — caused by the **uncommitted** working-tree
edits to `lib/smalt/arm_gateway/router.ex`,
`lib/smalt/data_plane/{cosmos,blob_storage,key_vault_actions}.ex` (+340/-36
across 4 lib files, owned by other lanes). The last ERROR_CODES regen commit
(fc44902) was current at its commit; the drift is introduced by dirty-tree lib
edits, not a landed regression. `--check` compares on-disk file vs regenerated,
so the dirty tree is what fails.

## Verdict: **BLOCKED**

Blocking condition (single): publish-dry gate 4 — `docs/ERROR_CODES.md` stale
relative to the dirty lib/ working tree. Unblock path (owner action, not this
lane): land or regenerate-then-commit `docs/ERROR_CODES.md` alongside the
in-flight lib edits (`just gen-error-codes`), then re-run `just publish-dry`
expecting exit 0. No secret-leak blocker exists; gates 1-3 all PASS.
