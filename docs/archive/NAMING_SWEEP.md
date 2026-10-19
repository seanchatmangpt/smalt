# Naming Sweep — Pre-Publication Contamination Audit

2026-10-14. Sweep: `grep -rniE 'athena|/Users/sac|courtroom|\bcai\b|morluto'`
over the full repo, excluding `deps/`, `_build/`, `.git/`, `tmp/`, `.elixir_ls/`.

## Hit table (final state, post-fix re-run)

| file:line | term | class | verdict |
|---|---|---|---|
| `ggen_igniter.pack.lock:7` | `/Users/sac/ggen-marketplace/...` | build-tool lockfile source path | REPORTED-TO-LANE (pack/ggen lane — machine-generated lockfile; not hand-editable prose) |
| `docker/README.md:42` | `Athena` | docs prose, **outside owned scope** (`docker/` is not root `*.md` or `docs/`) | REPORTED-TO-LANE (docker docs owner) |
| `test/sdk-smoke/run.mjs:10` | `/Users/sac/smalt` | JS harness hardcoded path | CONFIRMED FIXED (re-verified 2026-10-15 docs-corpus-lens-8: `REPO` now resolves from `process.cwd()`/`SMALT_REPO`, no hardcoded path) |
| `test/sdk-smoke/census-run.mjs:12` | `/Users/sac/smalt` | JS harness hardcoded path | CONFIRMED FIXED (re-verified 2026-10-15 docs-corpus-lens-8: `REPO` now `SMALT_REPO`/cwd) |
| `test/sdk-smoke/amqp.test.cjs:15` | `/Users/sac/cai/athena/...` | JS fallback path + legacy project name | CONFIRMED FIXED (re-verified 2026-10-15 docs-corpus-lens-8: `SMALT_SDK_ROOT` gate, no athena fallback) |
| `test/sdk-smoke/blob.test.cjs:9` | `/Users/sac/cai/athena/...` | JS fallback path + legacy project name | CONFIRMED FIXED (re-verified 2026-10-15 docs-corpus-lens-8: zero athena hits in the file) |
| `test/sdk-smoke/cosmos.test.cjs:10` | `/Users/sac/cai/athena/...` | JS fallback path + legacy project name | CONFIRMED FIXED (re-verified 2026-10-15 docs-corpus-lens-8: zero athena hits) |
| `test/sdk-smoke/census.test.cjs:2` | `/Users/sac/cai/athema` (sic) + `athena` | ported-from comment + fallback path | CONFIRMED FIXED (re-verified 2026-10-15 docs-corpus-lens-8: :2 is a neutral "reference servicebus-local court script" comment; :16 is the `SMALT_SDK_ROOT` gate, no athena) |
| `test/sdk-smoke/census.test.cjs:16` | `/Users/sac/cai/athena/...` | JS fallback path | CONFIRMED FIXED (re-verified 2026-10-15 docs-corpus-lens-8, with :2 above) |
| `test/data_plane/sdk_probe.mjs:3,8` | `/Users/sac/cai/athena/...` | comment + `createRequire` anchor path | REPORTED-TO-LANE (data-plane lane) |
| `test/mutation_court/README.md:19` | `/Users/sac/smalt` | docs prose under `test/` — outside owned scope | REPORTED-TO-LANE (mutation-court lane) |
| `scripts/mutation_court.py:34,301` | `/Users/sac/smalt` | Python harness hardcoded repo path | REPORTED-TO-LANE (mutation-court lane) |
| `lib/smalt/generated/registry.ex:4` | `Project Athena` | @moduledoc comment in `.ex` | CONFIRMED FIXED (file no longer exists — registry projects to `lib/smalt/registry.ex`, zero `athena` hits in `lib/`; re-verified 2026-10-15 docs-corpus cycle 9) |
| `lib/smalt/egress_router.ex:3` | `Athena Data Plane Egress Router` | @moduledoc comment in `.ex` | CONFIRMED FIXED (re-verified 2026-10-15 lens-6: the @moduledoc now reads "Subsystems 3 & 4 + Data Plane Egress Router (Port 8443)" — no `Athena` in lib @moduledocs; remaining `athena` hits in scripts/test are SMALT_SDK_ROOT default paths and prose, out of the sweep's class) |
| `lib/smalt/arm_gateway/router.ex:4` | `15 Athena services` | @moduledoc comment in `.ex` | CONFIRMED FIXED (re-verified 2026-10-15 lens-6: @moduledoc now reads "smalt-arm-gateway (Control Plane REST Mux) ... all 15 emulated services" — no `Athena`) |

## FIXED (this sweep)

| file:line | before → after |
|---|---|
| `docs/archive/CHEAT_SCAN.md:4` | `/Users/sac/anti-llm-cheat-lsp` → "the `anti-llm-cheat-lsp` repo" |
| `docs/archive/CHEAT_SCAN.md:10` | `/Users/sac/smalt` → `~/smalt` |
| `docs/QUICKSTART_RECEIPT.md:3` | `/Users/sac/smalt` → `~/smalt` |

## Verified-clean items

- **No `morluto` hits** anywhere in the tree.
- **No `courtroom` hits** anywhere in the tree.
- **No `cai` (word-boundary) hits** outside the `/Users/sac/cai/...` path
  fragments above.
- **No `athena-*` test fixture names remain** — lane 16's rename is confirmed
  complete (`test/fixtures/` does not exist; zero `athena-` prefix matches).
- No `.exs` file content hits for any swept term (report-only class came up
  empty for `.exs`).
- Wire-parity literals intact in `lib/` (8 matches for
  `management.azure.com` / `login.microsoftonline.com` /
  `azure-compliant-cvm`) — whitelisted, publication-safe.

## Residual counts (post-fix)

| term | residual hits |
|---|---|
| `/Users/sac` | 14 |
| `athena` (incl. `/Users/sac/cai/athena` path fragments) | 12 lines / 13 matches |
| `cai` (word-boundary) | 8 lines, all inside `/Users/sac/cai/...` path fragments |
| `courtroom` | 0 |
| `morluto` | 0 |

All 17 residual hit lines are in **non-owned files**: 3 `.ex` comments (lib),
9 JS harness lines (test/), 1 Python harness (2 lines), 1 lockfile, 2 docs
files outside owned scope (`docker/README.md`, `test/mutation_court/README.md`).

## Re-verification addendum (2026-10-15, docs-corpus-lens4 cycle 3)

The residual table above is as-of 2026-10-14; the tree grew since. Same
sweep re-run with the same exclusions (`deps/`, `_build/`, `.git/`, `tmp/`,
`.elixir_ls/`):

| term | fresh hits | dominant clusters |
|---|---|---|
| `/Users/sac` | 317 | `.ggen_igniter/receipts/2026-10-15.jsonl` (216, machine receipt — ggen lane), `docs/NAMING_SWEEP.md` self-quotes (41, this audit), `.ggen_igniter/manifest.json` (17, machine), `cli/ggen.toml`/`ggen.lock` (12, machine locks), `.env.example` (5, **REPORTED**), `docker/BUILD_RECEIPT.md` (5) |
| `athena` | 41 | this audit's self-quotes + `test/sdk-smoke/*` fallback paths + `.env.example:12` (`/Users/sac/cai/athena/...` legacy path — REPORTED) |
| `cai` | 21 | path fragments `/Users/sac/cai/...` only |
| `courtroom`/`morluto` | 8 / 0 | all 8 are this audit's own "Verified-clean" quotes — zero real hits |

REPORTED to the env/dx lane: `.env.example` (a root published template) ships
absolute personal defaults including the legacy `cai/athena` path
(`.env.example:12,15,19,20,24`). FIRST_RUN.md points readers at this file.
`docs/archive/PUBLISH_CHECK.md`'s line-192 finding (`smalt_mcp_surface.ttl:8`) is
HEALED — the ttl greps 0 for `/Users/sac` and `athena`.

## Resolved this sweep

Status of the five v26.10.14 candidate wins, verified against the working tree
2026-10-15 (docs-drift lane 14):

| cite | claimed win | verified state |
|---|---|---|
| `test/sdk-smoke/eh-run.mjs:14,143` | hardcoded REPO/fallback paths | **NOT LANDED** — both lines still carry hardcoded `/Users/sac/...`; allowlisted under `scripts/naming_sweep.sh` (sdk-smoke owner) |
| `scripts/dev_env.sh:33` | `DEFAULT_SDK_ROOT` interpolation | **NOT LANDED** — literal default remains; `SMALT_SDK_ROOT` env override exists; allowlisted (scripts owner) |
| `scripts/stress/vs_azurite.py:330,369` | cleaned | **NOT LANDED** — `SMALT_SDK_ROOT` env-first with literal fallback default; allowlisted (stress owner) |
| `.env.example:12` | `SMALT_SDK_ROOT` placeholder form | **NOT LANDED** — literal legacy `cai/athena` path remains; allowlisted (env owner) |
| `docker/README.md:42` | "Athena data-plane egress router" phrasing, no path | **VERIFIED** — the line carries the `Athena` prose phrase only, no absolute path; allowlisted (docker docs owner) |

None of the four unlanded items are fixable in the docs lane's scope; each is
gated behind **lane 12's naming-sweep allowlist** (`scripts/naming_sweep.sh`,
line-precise entries) pending its owning lane.

## Publication hygiene verdict

**READY-MODULO-LANE-12-ALLOWLIST.** Zero hits remain in owned docs (this
ledger excluded as meta self-reference). Residual contamination lines are
**not lane-fixable here** — gated behind lane 12's naming-sweep allowlist
(`scripts/naming_sweep.sh`): publication is admissible exactly when that gate
runs clean (`just naming-sweep` exit 0), and the residual hand-written lines
above are the allowlist's remaining coverage debt. Historical v2 blockers,
all REPORTED-TO-LANE at the time (superseded by the v3 verdict below):

1. Hardcoded `/Users/sac` paths in `test/sdk-smoke/*.mjs|cjs` and
   `scripts/mutation_court.py` — replace with `process.env`/relative
   resolution (most already fall back to `SMALT_SDK_ROOT`).
2. Legacy project name `Athena` in 3 `@moduledoc`s in `lib/` and
   `docker/README.md:42`.
3. `ggen_igniter.pack.lock` machine-local source path.
4. `test/mutation_court/README.md:19` local checkout path.

---

# Sweep v3 — 2026-10-15 (post ~40-file landing wave)

Re-run of the full grep (`athena|/Users/sac|courtroom|\bcai\b|morluto`) over
everything except `deps/`, `_build*`, `.git/`, `tmp/`, `node_modules/`,
following the I1-I16 / compliance / e2e s1-s10 / redteam r1-r3 / sdk-full /
py-court wave.

## FIXED (v3, this sweep — owned `docs/` + root `*.md` scope)

Path de-identification across 22 owned files: `/Users/sac/smalt` → `~/smalt`,
`/Users/sac/ggen-marketplace` → `~/ggen-marketplace`,
`/Users/sac/ggen_igniter` → `~/ggen_igniter`,
`/Users/sac/cai/athena/...` → `<legacy-sdk-root>`.

| file | lines fixed |
|---|---|
| `docs/CENSUS.md:13` | legacy SDK path → `<legacy-sdk-root>/playground/node_modules` |
| `docs/archive/CHEAT_SCAN.md:5,7` | scanner repo path → "the `anti-llm-cheat-lsp` repo"; `/Users/sac/smalt` → `~/smalt` (v2 fix had been overwritten by a later lane edit; re-applied) |
| `docs/JUST_REFERENCE.md:5` | `/Users/sac/smalt` → `~/smalt` |
| `docs/DEV_ENV.md:19,38-42` | legacy SDK path + 4 `/Users/sac/smalt` paths |
| `docs/ERROR_SWEEP.md:3` | `/Users/sac/smalt` → `~/smalt` |
| `docs/archive/PUBLISH_CHECK.md:156` | pack query path → `~/ggen-marketplace/...` |
| `docs/compliance/C1_ARM_REST.md:22`, `C3_COSMOS.md:27`, `C4_BLOB.md:8` | `cd /Users/sac/smalt` / subject paths → `~/smalt` |
| `docs/STRESS/AZURITE_COMPARE.md:17`, `TLS_CHURN.md:10`, `SUITE_STABILITY.md:3,113` | legacy SDK path + `/Users/sac/smalt` paths |
| `docs/PACK_INTEGRATION/*.md` (runtime-contracts 3,28; semantic-epoch 8; mcp-a2a 3,70; ea-projection 3,56; ash-extension 5,23; REMAINING_CENSUS 3; ash-pplan 4,35,53,72,92; ash-ocel-revops 8; otel-weaver 3; canonical-projection 3) | 15 lines of checkout/pack-root paths → `~/smalt`, `~/ggen-marketplace`, `~/ggen_igniter` |

Total: 45 lines fixed across 22 owned files.

## Prior-lane residuals now confirmed fixed (v2 REPORTED-TO-LANE items landed)

- `lib/smalt/generated/registry.ex`, `lib/smalt/egress_router.ex`,
  `lib/smalt/arm_gateway/router.ex` — `Athena` @moduledocs gone. Zero hits in
  `lib/` outside generated ttl (below).
- `test/sdk-smoke/run.mjs`, `census-run.mjs`, `amqp|blob|cosmos|census.test.cjs`
  — fallback paths fixed. **One new file regressed the dir**:
  `test/sdk-smoke/eh-run.mjs:14,143` (see below).
- `test/data_plane/sdk_probe.mjs`, `test/mutation_court/README.md`,
  `scripts/mutation_court.py` — clean.

## New residuals (v3) — all REPORTED-TO-LANE, none in owned scope

### ALLOWED-WIRE (whitelisted, publication-safe)

- 11 matches in `lib/` for `management.azure.com` /
  `login.microsoftonline.com` / `azure-compliant-cvm` — wire-parity literals,
  intact.

### New-dir sweep results

| dir | hits |
|---|---|
| `gates/` | 0 |
| `test/sdk-full/` | 0 (excl. `node_modules/`) |
| `test/py-court/` | 0 |
| `cli/` (Rust) — `src/`, `tests/`, `Cargo.toml` | 0 |
| `cli/ggen.toml:14-19`, `cli/ggen.lock:4-24` | 12 lines of `/Users/sac/ggen-marketplace` pack roots — machine-generated config/lockfile, same class as `ggen_igniter.pack.lock` |
| `cli/.ggen-v2/receipt*.json|jsonl` | machine receipts embedding local paths (hash-chained, not hand-editable) |

### REPORTED-TO-LANE (v3 residuals, file:line + owning surface)

| file:line | term | owning surface |
|---|---|---|
| `.env.example:12,15,19,20,24` | `/Users/sac/...` + `cai/athena` | env-template owner |
| `test/sdk-smoke/eh-run.mjs:14,143` | `/Users/sac/smalt`, `/Users/sac/cai/athena/...` fallback | sdk-smoke lane (regression on a new file) |
| `scripts/dev_env.sh:33`, `scripts/sb_census_replay.sh:21` | `/Users/sac/cai/athena/...` | scripts owner |
| `scripts/stress/lro_storm.py:34`, `telemetry_overhead.py:28` (erlmcp bin; repo/SDK pins retired), `tls_churn.py:34`, `vs_azurite.py:330,369` | hardcoded repo/legacy SDK paths (tls_churn/lro_storm already read `SMALT_REPO`/`SMALT_SDK_ROOT` env first) | stress-scripts owner |
| `test/e2e/s7_worm/run.sh:21`, `worm.test.cjs:11` | `/Users/sac/smalt/test/sdk-full/node_modules` fallback (both already honor `SMALT_SDK_ROOT`) | e2e s7 owner |
| `test/e2e/s9_lro_chain/lro_chain.test.mjs:2` | `athena's terraform verbs` comment | e2e s9 owner |
| `test/azapi_actions_test.exs:3` | `athena's terraform` comment | test owner |
| `test/redteam/r1_input_fuzz/receipt.txt:2`, `r2_state/findings.md:4` | `/Users/sac/smalt` in captured receipt/prose | redteam r1/r2 owners |
| `test/e2e/s4_oauth_negatives/.work/*.log` (18), `s10_attest_adversary/.logs/substrate.log:935` | machine-written run logs embedding absolute paths | e2e harness owner (add `.work/`, `.logs/` to sweep excludes) |
| `lib/smalt/mcp/gen/smalt_mcp_surface.ttl:8` | `/Users/sac/...` comment in generated ttl | MCP surface lane (also `docs/archive/PUBLISH_CHECK.md:192` known-issue) |
| `ggen_igniter.pack.lock:7` | unchanged from v2 | pack/ggen lane |
| `docker/README.md:42`, `docker/BUILD_RECEIPT.md:5,16,17,28` | `Athena` prose + local paths | docker docs owner (v2 open item) |
| `.ggen_igniter/manifest.json` (16 lines), `.ggen_igniter/receipts/*.jsonl` (105 lines) | machine-generated manifest/receipt paths | ggen_igniter lane — machine artifacts, hash-chained, not hand-editable |

### Intentional (meta self-reference, exempt)

- `docs/NAMING_SWEEP.md` itself (this ledger — quotes the grep terms).
- `docs/archive/PUBLISH_CHECK.md:69,154,192` — quote the scan terms `/Users/sac` and
  `athena` as the terms the publication checklist instructs to scan for; not
  leaks.

## Residual counts (v3, post-fix, excl. deps/_build/.git/tmp/node_modules)

| term | residual lines | vs v2 |
|---|---|---|
| `/Users/sac` | ~230 total, of which 105+16+~12+~4 = ~137 in machine artifacts (`.ggen_igniter/`, `cli/.ggen-v2/`, `cli/ggen.lock`, `cli/ggen.toml`, `ggen_igniter.pack.lock`) and 20 in e2e run logs | hand-written prose: **45 lines fixed this sweep; remaining hand-written ~55 lines**, all REPORTED-TO-LANE |
| `athena` | 9 lines excl. NAMING_SWEEP/PUBLISH_CHECK meta (docker README 1, docker/BUILD_RECEIPT 1, azapi test 1, s9 comment 1, sdk-smoke/eh-run 1, scripts 4 — re-counted 2026-10-15 docs-corpus-lens-8 over named roots README/CHANGELOG/NOTICE/docs/cli/lib/scripts/test/docker/.env.example) | down from 12/13 |
| `cai` (word-boundary) | 7 lines outside NAMING_SWEEP (`scripts/dev_env.sh:33`, `sb_census_replay.sh:21`, `vs_azurite.py:330,369`, `sdk-smoke/eh-run.mjs:143`, `docker/BUILD_RECEIPT.md`, `.env.example:12` — re-pinned lens-8) | down from 8 |
| `courtroom` | 0 real (3 self-reference lines in this ledger) | 0 |
| `morluto` | 0 real (3 self-reference lines in this ledger) | 0 |

## Publication hygiene verdict (v3, superseded 2026-10-15 — see READY-MODULO-LANE-12-ALLOWLIST)

**HISTORICAL v3 verdict: NOT READY — zero residual hits in owned scope; ~55
residual hand-written lines, all REPORTED-TO-LANE at the time.** Every owned
`docs/**/*.md` and root `*.md` is
now path-clean (verified: `grep -rn '/Users/sac'` over `docs/` + root `*.md`
returns only this ledger and PUBLISH_CHECK's scan-term self-references).
Blockers unchanged in class from v2: hardcoded local paths in test/script
harnesses (env-var fallbacks already present in most), `Athena` in
`docker/README.md:42` (v2 open), `athena` comments in 3 test files, machine
artifacts (`cli/` ggen config/lock/receipts, `.ggen_igniter/`) whose paths are
regenerated rather than edited. Fastest remaining wins: `eh-run.mjs`,
`dev_env.sh`, `vs_azurite.py`, `.env.example` (all already env-var-driven or
one-line fallback changes).
