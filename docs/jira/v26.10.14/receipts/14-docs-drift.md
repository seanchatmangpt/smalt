# Receipt — V261014-14 Docs Drift Close-Out (lane 14)

- **Date:** 2026-10-15 · **Lane:** 14 (docs drift) · **Checkout:** `~/smalt` (canonical)
- **Status:** DONE with two disclosed cross-lane findings (below)

## Verification checklist (real output)

| Check | Command | Result |
|---|---|---|
| gen target | `just gen-error-codes` | exit 0, "wrote docs/ERROR_CODES.md (70 rows)" |
| Determinism | rerun + `cmp` | IDEMPOTENT (byte-identical on rerun) |
| Fence test | `mix test test/error_codes_doc_test.exs` | **7 tests, 0 failures** |
| Crash dump | `rm erl_crash.dump`; `git check-ignore erl_crash.dump` | file gone; check-ignore exit 0 (pattern pre-existing, `.gitignore:20-21`); `git status --porcelain` no longer lists it |
| `/Users/sac` gate grep | `grep -n '/Users/sac' docs/PUBLISH_CHECK.md docs/auth_regression_sweep.md` | 3 hits, ALL inside explicitly-labeled ALLOWLISTED EVIDENCE BLOCKS (PUBLISH_CHECK :173, :278, :281 — verbatim past transcripts, labeled, not scrubbed per WO) |
| release.txt | restamped | HISTORICAL header; no live "add a releases block" instruction; no "lane 19" claim; Port overridability section intact |
| ERROR_SWEEP | treatment (b) | top-of-doc "Receipt, not a living contract" stamp; as-of-sweep line cites disclosed (tls.ex:147→:283 drift and egress blob-rescue move named as examples) |
| NAMING_SWEEP verdict | — | **READY-MODULO-LANE-12-ALLOWLIST** (names `scripts/naming_sweep.sh`); v2+v3 NOT READY verdicts restamped HISTORICAL; "Resolved this sweep" table enumerates all five cites with verified state |
| ERROR_CODES.md | — | never hand-edited; regenerated only via the target |
| Counts in prose | `grep -iN 'rows' ...` | no error-code counts added to any touched prose |

## Task outcomes

1. **release.txt** — restamped HISTORICAL: mix.exs `releases` block landed
   (mix.exs:20-27, `include_executables_for: [:unix]` + `strip_beams:
   [compress: true]`) supersedes the proposed `include_executables: [:smalt]`;
   "lane 19 owns CI" marked VOID. Port-overridability section preserved
   verbatim as current reference.
2. **ERROR_SWEEP.md** — treatment (b): dated top-of-doc receipt stamp
   (as-of-sweep cites, not a living contract). No cite rewritten.
3. **NAMING_SWEEP.md** — verdict gated on `scripts/naming_sweep.sh` by name;
   five candidate wins enumerated in a "Resolved this sweep" table. **Finding:
   only 1 of the 5 verifies** (docker/README.md:42 phrasing). The other four
   (eh-run.mjs:14,143; dev_env.sh:33; vs_azurite.py:330,369; .env.example:12)
   are NOT LANDED in the working tree — still literal `/Users/sac/cai/legacy-client/...`
   defaults — and remain REPORTED-TO-LANE, allowlisted. WO explore facts were
   stale on these.
4. **auth_regression_sweep.md:3** — scrubbed to `` `~/smalt` (canonical
   checkout) ``. **PUBLISH_CHECK.md** — :69 and the struck-through ttl finding
   scrubbed (prose, no evidence altered); transcript quotations gated: two
   ALLOWLISTED EVIDENCE BLOCK comments label the v2 leak-scan block and the v3
   mcp-ttl transcript verbatim.
5. **justfile** — exactly one new target `gen-error-codes` (lanes 12's recipes
   untouched); **PUBLISH_CHECK 3a** — regen + `git diff --exit-code
   docs/ERROR_CODES.md` step added.
6. **erl_crash.dump** — deleted; check-ignore green pre- and post-delete;
   `.gitignore` untouched (pattern pre-existing).

## Cross-lane findings / disclosures

1. **Generator anchor drift (minimal unblock fix, disclosed per fan-out rule
   2):** a sibling lane's in-flight lro.ex refactor (uncommitted, 126 lines)
   renamed `defp evaluate(` → `def evaluate(`; `scripts/gen_error_codes.py`
   crashed (`ValueError: substring not found`) and the fence test was 7/3 red
   BEFORE any lane-14 edit (pre-existing failure, session-external). Applied
   the minimal def/p-def-tolerant anchor fix in `scripts/gen_error_codes.py`
   (extract_lro) and the same-tolerance regex in
   `test/error_codes_doc_test.exs:56`. Both files are shared seams; lro.ex
   itself untouched.
2. **Allowlist re-pin needed (lane 12):** lane-14 scrub/gate line shifts moved
   the matched lines in PUBLISH_CHECK. `scripts/naming_sweep.sh` currently
   FAILS with 5 violations. **Exact deltas** (lane 12 owns the edit):
   - ADD: `docs/PUBLISH_CHECK.md:173`, `:178`, `:278`, `:281`, `:282`
   - DROP (stale): `docs/PUBLISH_CHECK.md:69`, `:154`, `:159`, `:197`, `:199`,
     `:252`, `:255`, `:256`, `:258`, `:259` and `docs/auth_regression_sweep.md:3`
   - Post-re-pin expected: PASS 5 allowed / 0 violations.
3. **docs/ERROR_CODES.md working-tree diff vs HEAD (103 lines) is EXPECTED:**
   the regen legitimately picked up the sibling lro.ex refactor's new
   `{200, OperationRecordIncomplete}` row. Regeneration is idempotent and the
   fence test is green against the regenerated file. Not a hand edit.

## Standing

- Owned-file work: ALIVE (all checklist rows above carry real output).
- BLOCKED-FOR-LANE-12: naming-sweep gate green requires the re-pin in finding 2.
- Falsifiers run: `bash scripts/naming_sweep.sh` (currently FAIL on stale
  line-precise allowlist — the receipt's delta list is the fix);
  `grep -n '/Users/sac' docs/PUBLISH_CHECK.md docs/auth_regression_sweep.md`
  → evidence-block hits only.
