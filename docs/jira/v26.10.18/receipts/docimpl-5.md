# Receipt — docimpl-5: D15 Diataxis gap pages (7)

Standing: **ALIVE**

Date: 2026-10-18. Window: v26.10.18, docs-audit D15
(`docs/jira/v26.10.18/docs-audit/d15-diataxis-gaps.md`).

## Scope

Wrote the 7 missing Diataxis pages named by D15, each grounded in the tree
(every command/claim verified against source files), each cross-linked from
at least one pre-existing page:

| page | grounded in |
|---|---|
| `docs/tutorials/planes-profiles.md` | `lib/smalt/planes.ex` (InvalidPlane message, resolve law), `config/runtime.exs`, `lib/smalt/plane/*_supervisor.ex` moduledocs, `docs/reference/ports-and-planes.md` |
| `docs/how-to/how-to-run-burn.md` | `justfile.d/30-burn.just` (recipe names/args), `docker/burn/{soak,parallel-matrix,boot-burn,burn-ring}.sh` headers (exit contracts, preflight, jidoka, subject-moved law), `scripts/validate_burn.py` docstring |
| `docs/how-to/how-to-write-tests.md` | `test/support/{case,assert_eventually,store_resilient,singleton,env,sleep_windows}.ex` (read in full), `lib/smalt/store.ex` (put/get/prefix_keys verified), `docs/TEST_ISOLATION.md` |
| `docs/how-to/how-to-add-config-key.md` | `lib/smalt/config.ex` header (projection law), `lib/mix/tasks/smalt.gen.ex` (six stanzas), `test/config_replay_identity_test.exs` (census CLOSED at 56 + coverage/bijection gates), `justfile` `gen:` recipe (verified on disk) |
| `docs/reference/test-isolation-law.md` | absorbs `docs/TEST_ISOLATION.md` sections 1-5 (ported content), adds §4 async topology, §6 isolation court (`scripts/isolation_court.py` read in full head), §7 runtime twin + exemption registry (`test/support/isolation_runtime_exemptions.exs` read in full) |
| `docs/reference/burn-receipt-schema.md` | `docs/jira/v26.10.18/burn/burn-row.schema.json` (read in full; field table + conditional broken_term coupling law), `scripts/validate_burn.py` exit contract; sample row parsed from `burn/boot-burn.jsonl` |
| `docs/explanation/no-sleep.md` | `docs/NO_SLEEP_DOCTRINE.md` (read in full), `justfile.d/29-sleep.just` (`sleep-gate`/`sleep-gate-court` verified), rewrite-drafts (`NO-SLEEP-DOCTRINE.md`, `sleeps.md`, `fence10-ratio.md` — all verified present), receipt `azb-21-zero-sleep.md` (verified present) |

## Cross-links added (existing pages)

- `docs/reference/ports-and-planes.md`: new `## SMALT_PLANES` section
  (D15 secondary) linking the tutorial; See Also + tutorial + burn schema.
- `docs/reference/courts.md`: new `## Test-isolation courts` section
  (D15 secondary: leak-court / isolation-court / isolation-court-runtime
  table) linking `test-isolation-law.md`, `no-sleep.md`; See Also + both
  reference pages.
- `docs/how-to/dev-loop.md` See Also: + how-to-run-burn, how-to-write-tests,
  how-to-add-config-key.
- `docs/TEST_ISOLATION.md` header pointer -> `test-isolation-law.md`.
- `docs/NO_SLEEP_DOCTRINE.md` header pointer -> `explanation/no-sleep.md`.

## DoD gate

`justfile.d/12-docs-dod.just` extended with the 7 new page paths. Real run:

```
$ just docs-dod-check; echo "EXIT=$?"
...
OK    docs/tutorials/planes-profiles.md
OK    docs/how-to/how-to-run-burn.md
OK    docs/how-to/how-to-write-tests.md
OK    docs/how-to/how-to-add-config-key.md
OK    docs/reference/test-isolation-law.md
OK    docs/reference/burn-receipt-schema.md
OK    docs/explanation/no-sleep.md
...
OK    README.md
EXIT=0
```

(full output: 61 OK, 0 MISS, exit 0.)

## Verification (commands run against the tree this session)

- `grep -n "def get\|def put\|def prefix_keys\|def clear\|def
  compare_and_swap" lib/smalt/store.ex` -> all names present (Store API in
  the worked example).
- `sed -n '73,77p' justfile` -> `gen:` recipe = `mix smalt.gen`.
- `python3` parse of `docs/jira/v26.10.18/burn/boot-burn.jsonl` line 2 ->
  schema `smalt-burn/v2` row with verdict CLEAN (schema doc restates a real
  row).
- `grep -rn "SMALT_PLANES"` -> `lib/smalt/planes.ex` resolve law + refusal
  vocabulary verified verbatim.
- `ls docs/jira/v26.10.18/rewrite-drafts/` -> NO-SLEEP-DOCTRINE.md,
  sleeps.md, fence10-ratio.md all present (cited in no-sleep.md).
- Recipe names in how-to-run-burn verified against
  `grep -n "^@" justfile.d/30-burn.just` (burn-soak, burn-chaos,
  burn-matrix, burn-ring, burn-clean, burn-ocel, burn-boot).

## Corrections during the lane

- First draft of `test-isolation-law.md` went garbled mid-write; detected
  and fully rewritten before landing (the landed file is the clean
  rewrite).
- Transient typo `v26.1018` in burn-receipt-schema.md fixed immediately.

## Not done (out of scope / not receipted)

- No git operations (per work order).
- `docs/JUST_REFERENCE.md` burn-recipe block remains open under the D2
  audit lane (how-to-run-burn notes the gap).

## Replay

```
just docs-dod-check          # exit 0
ls docs/tutorials/planes-profiles.md docs/how-to/how-to-run-burn.md \
   docs/how-to/how-to-write-tests.md docs/how-to/how-to-add-config-key.md \
   docs/reference/test-isolation-law.md docs/reference/burn-receipt-schema.md \
   docs/explanation/no-sleep.md
```
