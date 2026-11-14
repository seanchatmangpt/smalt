# TODO-FIX-AND-FINISH (smalt)

Standing: UNVERIFIED

Source: `ash_surface/docs/jira/v26.11.11/PROJECT-REVIEWS.md` R11, re-read where marked confirmed.

## Fix

- HIGH `scripts/sleep_gate.py:131` `SLEEP_RE` uses `\b(?:Process|:timer)\.sleep\b`; `\b` before
  `:` needs a word char, so `:timer.sleep` is missed (regex confirmed; 5 `:timer.sleep` in
  test/ confirmed). Check: planted `:timer.sleep` fails `just sleep-gate`.
- HIGH `scripts/sdk_coverage.py:278-295` `load_kd` reads `parts[5]` as status (confirmed);
  register column layout vs 7 columns UNVERIFIED. Registers at `docs/jira/v26.10.16/
  KNOWN_DIVERGENCES.md` and `posh/KNOWN_DIVERGENCES.md`. Check: all KD rows load.
- HIGH `justfile.d/18-shim-court.just:40-49` skip/BLOCKED counted but exit depends on `fail`
  only (confirmed). Check: skipped court makes aggregate exit nonzero.
- MED `scripts/shim_court/lib.sh:136` only greps for `SHIM-COURT` marker (confirmed).
- MED `sdk_coverage.py` grounding/parse_receipt issues (:~705,:245-262) UNVERIFIED.
- MED `KinesisRoutes` auth admission, non-constant-time compare UNVERIFIED (not read).
- LOW `lib/smalt/data_plane/azure_cache.ex:95` and `lib/smalt/cluster.ex:234` `String.to_atom`
  on request/IP-derived strings (confirmed).
- LOW `test/integration/bk69r_probe_tmp_test.exs:35` `assert true` (confirmed).

## Finish

- Add `:timer.sleep` case to sleep-gate court (`just sleep-gate-court`).
- Make shim-court aggregate fail on SKIP unless allowlisted. Check: `just shim-courts` exit.
- Share one KD parser between `sdk_coverage.py` and `kd_flip.py`. Check: row counts equal.

## Commit hygiene

- Tree nearly clean: only `docs/jira/v26.10.16/sdk-results/spc-bands.md` modified (confirmed).

## Decide

- Courts naming removed files: delete them or restore subjects (UNVERIFIED, not enumerated).

## Reuse

- `kd_flip.py:82-142` layout-robust parser; `sleep_gate.py:96-195` adjacency allowlist.

## See Also

- `ash_surface/docs/jira/v26.11.11/PROJECT-REVIEWS.md` R11
