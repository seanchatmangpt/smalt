# Pack Integration: ash-extension-pack -> `substrate_resource` extension

- Date: 2026-10-14
- Lane: ash-extension (owned files only: `lib/smalt/ash_extension/`, `test/ash_extension_test.exs`, this doc)
- Pack: `~/ggen-marketplace/packs/ash-extension-pack` v0.5.0 (canonical; its
  ash-extension-core-pack / ash-extension-starter-pack variants are SUPERSEDED per pack.toml)
- Consumer: smalt 26.10.14

## What was manufactured

Custom Ash DSL extension `Smalt.AshExtension.SubstrateResource` bundling the substrate's
Store-manual-read + matter-scope idiom. A resource declares:

    substrate do
      store_table(:smalt_resources)
      matter_scope([:private])
    end

instead of hardcoding per-resource clauses in a shared manual-read module.

## Pack consumption: SYNC-OR-ADAPTED (both)

Generated via `mix ggen_igniter.sync --engine oxigraph --verify-cwd ~/ggen_igniter`
from a spec ontology (`aex:AshExtensionSpec`, spec IRI
`http://ggen.io/spec/smalt-substrate-resource`) against the pack templates.

| file | template | disclosed hand-adaptation |
|---|---|---|
| `generated_extension.ex` | `templates/extension.ex.tmpl` | none (verbatim) |
| `generated_persist.ex` | `templates/persist.ex.tmpl` | reads section OPTIONS via `get_option/3` — the template reads entities, but `:substrate` is a schema-field section, so Spark stores its fields as section options, not entities |
| `generated_verify.ex` | `templates/verify.ex.tmpl` | filled the two declared-open verifier bodies with the real checks; re-pointed `check_read_only_surface` to `dsl_state`; actions entity path is `[:actions]` |
| `generated_info.ex` | `templates/info.ex.tmpl` | singleton unwrap in `store_table_result/1` / `matter_scope_result/1`; `[]` least-privilege matter-scope default |

Hand-written (disclosed; no pack template covers the `Ash.Resource.ManualRead` behaviour):
`lib/smalt/ash_extension/manual_read.ex` — generic Store scan driven by the compiled
`store_table`, projecting row keys (atom or string) onto resource attributes and attaching
the declared matter-scope into `__metadata__.matter_scope`.

## Verifier constraints (real, negative-witnessed in the gate)

1. `read_only_surface` — only `:read` actions permitted (matter-isolation law).
2. `store_table_declared` — `store_table` must be a `smalt_`-prefixed atom;
   `matter_scope` (optional) within vocabulary `[:private, :public]` (least privilege).

The spec ontology lives at `/tmp/smalt-aex/spec.ttl` (session-scratch; NOT preserved —
regeneration requires re-authoring it; its full content is quoted in the session receipt).

## Gates (actual output, 2026-10-14)

    $ MIX_ENV=test mix test --no-start test/ash_extension_test.exs
    8 tests, 0 failures

    $ MIX_ENV=test mix test --no-start test/semantic_projection_test.exs   # canary
    7 tests, 0 failures

    $ MIX_ENV=test mix compile --warnings-as-errors   # generated files compile clean
    0 errors

## Run-mode disclosure (--no-start)

Without `--no-start` both gates fail at APP BOOT, pre-existing and environmental: the app's
MCP listener binds FIXED port 9545 (`lib/smalt/application.ex:24`, no probe in
`config/test.exs`), and a concurrent substrate keeper on this checkout holds it
(`:eaddrinuse` before any test runs; also reproduced on the unmodified canary).
`--no-start` + in-suite boot of Store + `:ash`/`:spark` makes both gates runnable alongside
other lanes; the unmodified canary passes identically under `--no-start` (7/7), so the run
mode is gate-faithful for these suites.

## Partial-state note

The prior attempt died before writing; nothing was found on disk at session start
(`lib/smalt/ash_extension/` absent). No git operations performed; all edits confined to
owned files.
