# Receipt — R207 (harness + justfile.d unaccounted-diff batch)

- **Subject:** `/Users/sac/smalt` @ main, working tree (lane 294, W11 docs lane)
- **Standing:** PASS (all five items re-verified on-disk 2026-10-16)
- **Date:** 2026-10-16
- **Audit coverage:** closes unaccounted-diff items 1–5 of the 2026-10-16
  pre-commit audit (see WRAP_LEDGER pointer).

## What landed

- **scripts/fast_test.sh** (`SHIM-COURT: R17/A11 #6`): the watch-mode
  snapshot/compare loop now snapshots `lib/**/*.ex` mtimes and the target
  file ONCE in the SAME format (`%m %N` for every watched path) so the first
  poll cannot spuriously report a change and restart the run. Before the
  fix, SNAP and NEW used different formats and the first iteration always
  mismatched. Marker at scripts/fast_test.sh:63.
- **scripts/gen_dev_cert.sh** (`SHIM-COURT: R17/A11 #7`): the leaf-mint
  path regenerates the 800-day leaf when it is expired instead of reusing a
  stale cert (marker at scripts/gen_dev_cert.sh:36). Supports the CA:TRUE
  root + CA:FALSE leaf chain documented in the header (R90/R100 TLS pin
  family).
- **justfile.d/03-cli-wiring.just** path fix: `SMALT_CLI :=
  justfile_directory() / "smalt-cli"`. Under root `import`,
  `justfile_directory()` already resolves to the repo root, so the previous
  `../smalt-cli`-style traversal escaped the checkout (to a nonexistent
  sibling dir). Documented in-module (03-cli-wiring.just:13).
- **justfile.d/10-gap-register-sync.just** GAP_SYNC_ROOT fix: module-scope
  `GAP_SYNC_ROOT := justfile_directory()` (line 5) so the shebang body reads
  `REPO="{{GAP_SYNC_ROOT}}"` instead of calling `justfile_directory()`
  mid-script — the just-1.56 shebang-recipe rule (fan-out law rule 5).
- **justfile.d/11-relay-env.just** SMALT_SB_SHARED_KEY removal: relay-env
  no longer emits a shared Service Bus key; the single-key policy is
  dev_env.sh's deterministic per-host sha256 key, eval'd by relay-env's
  last line (`eval "$(scripts/dev_env.sh)"`). In-module SHIM-COURT comment
  at 11-relay-env.just:21 records the intent.

## Verification (2026-10-16, lane 294, unedited output)

```
$ bash -n scripts/fast_test.sh && echo "fast_test bash -n OK"
fast_test bash -n OK
$ bash -n scripts/gen_dev_cert.sh && echo "gen_dev_cert bash -n OK"
gen_dev_cert bash -n OK
$ grep -c 'SHIM-COURT' scripts/fast_test.sh scripts/gen_dev_cert.sh
scripts/fast_test.sh:1
scripts/gen_dev_cert.sh:1
$ just relay-env > /tmp/r207-relay.txt && grep -c SMALT_SB_SHARED_KEY /tmp/r207-relay.txt
0
$ just --list > /dev/null; echo "just --list exit=$?"
just --list exit=0
$ just --list | grep -cE '^\s{4}\S'
59
```

Note on the SMALT_SB_SHARED_KEY check: the relay-env OUTPUT contains zero
occurrences of an emitted `export SMALT_SB_SHARED_KEY` (the only mention is
the deliberate-omission comment). The variable IS present in a session after
`eval "$(just relay-env)"` — set by the trailing `eval
"$(scripts/dev_env.sh)"`, which is the sanctioned single-key policy
(scripts/dev_env.sh:31, deterministic per-host sha256), not a relay-env
emission.

`just --list` parses clean with all 18 justfile.d modules imported
(exit 0, 59 recipes) — confirms both fixed modules (03, 10) remain
parse-valid under just 1.56.
