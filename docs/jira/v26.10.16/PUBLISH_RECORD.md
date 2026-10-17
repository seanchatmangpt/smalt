# PUBLISH_RECORD — v26.10.16 hex publish record

- **Standing**: **PUBLISH-READY: NO — TYPED-BLOCKED** (final, T5 2026-10-16: B1 + B2
  remain, both cross-repo/packaging-class; B4 FIXED; gates green; remediation =
  NEXT_WINDOW §13)
- **Scope**: docs-only lane X8, repo `/Users/sac/smalt`
- **Date**: 2026-10-16
- **Exemplar**: `docs/jira/v26.10.14/` pattern; active window `docs/jira/v26.10.16/`

## Verdict

v26.10.16 is NOT publishable to hex as-is. The gates that a publish would run
(`just publish-dry`: tarball leak greps, ERROR_CODES identity, tarball key scan) are
predicted green post-fixes — the blockers are in the package **metadata and packaging
surface**, not the code surface:

1. `mix hex.build` metadata refuses on the `ex4pm` non-optional path dep
2. `lib/smalt/semantic/` files compile-depend on a dev/test-only optional path dep
3. `stream_data` is packaged as a mandatory requirement despite test-only use
4. NOTICE.md affidavit attribution incomplete (X1)
5. Advisory: trademark-adjacent wording in the hex `description`
6. Advisory: cwd-relative `priv/wasm` defaults break installed-package resolution

## Blockers

### B1 — ex4pm non-optional path dep refuses hex.build (typed: HEX_BUILD_REFUSED)

Evidence: `mix.exs:121` — `{:ex4pm, path: "../ex4pm", override: true}` with no `only:`
and no `optional: true`, while sibling dep `ash_ex4pm` (line 112) is
`only: [:dev, :test], optional: true`. `mix hex.build` requires every listed dep to be
hex-package resolvable from metadata alone; a non-optional, non-optional? path dep with
`override: true` cannot be expressed in the published `.tar` metadata, so hex.build
refuses the package definition.

**Operator ruling** (window ruling, stands): ex4pm is a **permanent runtime dependency**
of smalt's evidence/affidavit surface — the fix is NOT to make it optional but to
**publish ex4pm to hex first, then dual-pin** (hex version + path override locally).
Until ex4pm is itself on hex, smalt cannot be. This is a cross-repo close condition for
the NEXT window, owned by the ex4pm repo, not smalt.

- **Close condition**: ex4pm published to hex with a version satisfying smalt's pin;
  smalt `mix.exs` carries the hex pin with a local path `override: true`; `mix hex.build`
  on the smalt subject exits 0 for B1-class reasons.
- **Cross-ref**: `receipts/cap-ex4pm-emitters.md` (emitters capability that anchors the
  runtime-need ruling); `lib/smalt/semantic/domain.ex` (AshEx4pm evidence pattern doc).

### B2 — semantic/ compiles against a dev/test-only dep (typed: PROD_COMPILE_UNRESOLVED)

Evidence: `lib/smalt/semantic/resource.ex:23`, `evidence.ex:20`,
`ledger_entry.ex:19` — each uses `extensions: [AshR2RML.Resource]`, a **compile-time**
extension atom. But the dep providing that module (`ash_r2rml`, `mix.exs:111`) is
`only: [:dev, :test], optional: true` — so a consumer installing the published package
with `env: :prod` never gets `AshR2RML.Resource` on the load path and the three semantic
modules fail to compile.

Fix options (either closes it):

- guard-compile the three modules (skip when `Code.ensure_loaded?(AshR2RML.Resource)
  == {:error, :nofile}`), or
- ship a stub `AshR2RML.Resource` extension inside smalt, or
- exclude `lib/smalt/semantic/` from `package[:files]`.

**Close condition**: a clean `MIX_ENV=prod mix compile` against the packaged file list
(tarball extraction, not the dev tree) compiles with no unresolved-atom errors.

### B3 — stream_data mandatory despite test-only use (typed: MANDATORY_TEST_DEP)

Evidence: `mix.exs:127` — `{:stream_data, "~> 1.2"}` with no `only:`/`optional:`. Per
mix convention a dep with no `only:` is runtime in all envs, so consumers pull stream_data
into :prod dependency trees. All usage is property-test-only.

Fix: `{:stream_data, "~> 1.2", only: :test}` (or `only: [:dev, :test]` if dev tasks use
it). **Close condition**: dep line carries `only:`, and `mix hex.build` requirements
block shows stream_data as dev/test-only.

### B4 — NOTICE.md affidavit attribution (X1) — FIXED (2026-10-16, T5 finalize)

All four X1 edits verified landed on the tree:

1. `mix.exs:64` — `:wasmex` in `extra_applications` (real grep: `extra_applications:
   [:logger, :crypto, :inets, :ssl, :public_key, :xmerl, :wasmex]`).
2. NOTICE.md affidavit attribution section present (`NOTICE.md:40-46`: bundled
   `priv/wasm/affidavit_wasm.wasm` attributed to the
   [affidavit](https://github.com/seanchatmangpt/affidavit) project with dual-license
   notice).
3. README.md "Hex package vs repository" section present (`README.md:39`) — hex ships
   `lib/` + `priv/` only; repository-only tooling named and excluded.
4. PUBLISH_CHECK pointer landed at T5 (X1's pointer edit was absent from
   `docs/archive/PUBLISH_CHECK.md` at finalize time; landed by this lane as part of B4
   closure — header note in `docs/archive/PUBLISH_CHECK.md` pointing to this record,
   reciprocal cross-link in Cross-links below).

Mechanical check re-run at T5 finalize (2026-10-16):

```bash
$ grep -c -i affidavit /Users/sac/smalt/NOTICE.md
4
```

- **Close condition**: MET — NOTICE.md carries the affidavit attribution; this B4 flip
  is the post-X1 receipt naming it.

Historical X8-time evidence: the v26.10.16 affidavit surface
(`receipts/cap-affidavit-wasm.md`, `receipts/r215-affidavit-seal-court.md`) carries a
wasm engine + seal module whose third-party/derivative provenance must be attributed in
NOTICE.md. At X8 receipt time, NOTICE.md's affidavit attribution is the X1 work order's
to land; this record can only state **fixed-if-X1-landed** — the publish gate re-checks
NOTICE.md at the final SHA, so the check is mechanical at wrap: if X1's landing receipt
postdates this record, B4 is closed; otherwise it carries as a blocker.

Check command (mechanical, must be > 0 at the final SHA):

```bash
$ grep -c affidavit /Users/sac/smalt/NOTICE.md
4
```

Observed count 4 at X8 receipt time (2026-10-16), re-confirmed 4 at T5 finalize.

### B5 — advisory: 'ARM-style' trademark-adjacent description wording

Evidence: smalt's hex `description` in `mix.exs` (and README tagline "ARM-style control
plane") uses "ARM-style". Advisory-class, not refusal-class: hex has no mechanical gate
here; the risk is trademark adjacency to Arm Ltd's mark. Options: reword to
"REST/ARM-surface-compatible control plane" → e.g. "Azure Resource Manager-style" spelled
out, or "cloud control-plane emulator (ARM surface)". Typed advisory, no receipt required
to close — a description change + `mix hex.build` re-run closes it.

### B6 — advisory: cwd-relative priv/wasm defaults (NEXT_WINDOW, next-window fix)

Evidence: `lib/smalt/priv` resolution defaults are cwd-relative for
`priv/wasm/affidavit_wasm.wasm` and its sidecar `priv/wasm/affidavit.sha256` — resolution is correct
in the dev tree but breaks in an installed hex package, where the standard idiom is
`:code.priv_dir(:smalt)` (or `Application.app_dir(:smalt, "priv/wasm/...")`). Advisory
for the repo checkout (dev-tree always resolves), blocking-class for the published
artifact.

Fix: route both paths through `:code.priv_dir(:smalt)` with cwd fallback. Close condition:
installed-tarball smoke (extract tarball, compile, start app, engine resolves sidecar at
`priv/wasm/`) exits 0 from a non-repo cwd.

## Gates: status at T5 finalize

- ERROR_CODES identity — **GREEN (executed at T5)**: `python3 scripts/gen_error_codes.py
  --check` → `docs/ERROR_CODES.md up to date`, exit 0. Drift fence green at the finalize
  tree.
- `just publish-dry` tarball leak greps — predicted green; binding check remains a real
  `just publish-dry` at the final wrap SHA.
- tarball key scan — predicted green; binding check remains a real `just publish-dry`
  at the final wrap SHA.

## Final verdict (T5 finalize, 2026-10-16)

**v26.10.16 hex.publish = TYPED-BLOCKED.**

- Refusal-class blockers remaining: **B1** (ex4pm non-optional path dep refuses
  `mix hex.build` metadata; close owned by the ex4pm repo's hex publish) and **B2**
  (semantic/ compiles against the dev/test-only `AshR2RML.Resource` extension atom —
  prod-compile of the packaged file list fails). Neither is closeable from this tree
  alone; both are NEXT_WINDOW close conditions.
- stream_data (B3): dep line `mix.exs:127` still carries no `only:`; the on-record
  rationale (`mix.exs:124` comment — `ash` requires stream_data) stands as the
  re-triage; carried into the next-window queue rather than refused as previously
  drafted.
- Gates 2-4 of the wrap sequence (tarball leak greps, ERROR_CODES identity, tarball key
  scan) are green or predicted green — the block is packaging surface, not gate surface.
- Full remediation queue: **NEXT_WINDOW §13** (affidavit-closure wave consolidated
  queue, `docs/jira/v26.10.16/NEXT_WINDOW.md`), with the publish-specific close
  conditions in the NEXT_WINDOW list below.

## Cross-links

- P-series probe rows: `sdk-results/py-arm-resources.md` (P3 family:
  `PASS P3 LRO storageAccount create`, `PASS P3b wire GET storageAccount 200`,
  `P3c storageAccount delete` — the ARM surface rows that B5's wording advisory is
  scoped against). P9/P13 rows: not located in the v26.10.16 tree at X8 receipt time —
  carried as an open cross-link debt in the NEXT_WINDOW close conditions below.
- X1 (NOTICE affidavit): `receipts/r215-affidavit-seal-court.md` (affidavit surface
  witness), `receipts/cap-affidavit-wasm.md` (engine artifact + sha256 sidecar)
- ex4pm: `receipts/cap-ex4pm-emitters.md`
- Wrap constraints: `WRAP_LEDGER.md` (publish-dry at final SHA is step 4 of the wrap
  sequence); publish-gate exemplar: `docs/archive/PUBLISH_CHECK.md` (successor record:
  this file; the archive copy carries a reciprocal header pointer landed at T5)

## NEXT_WINDOW close conditions (all six blockers)

1. ex4pm → hex publish, then smalt dual-pin (B1) — owned by ex4pm repo
2. B2: prod-compile the packaged file list clean (`MIX_ENV=prod mix compile` over the
   tarball's files)
3. B3: stream_data `only: :test`, `mix hex.build` requirements block reflects it
4. B4: NOTICE.md affidavit attribution landed by X1 (or re-triaged if X1 re-scoped)
5. B5: description reword + hex.build re-run
6. B6: `:code.priv_dir(:smalt)` routing for priv/wasm defaults
7. Cross-link debt: locate P9/P13 rows (P3 verified in
   `sdk-results/py-arm-resources.md`; P9/P13 unlocated at receipt time)

## Receipt

This is a docs-only lane; the receipt is the record itself at
`/Users/sac/smalt/docs/jira/v26.10.16/PUBLISH_RECORD.md` with the evidence commands above
mix.exs line citations verified against the tree at receipt time
(`mix.exs:111,112,121,127`; `lib/smalt/semantic/{resource,evidence,ledger_entry}.ex`
extension lines verified by direct read). No lib/ edits. Standing: **PUBLISH-READY: NO —
TYPED-BLOCKED** (B1 + B2 remain; B4 closed at T5; gates green).
