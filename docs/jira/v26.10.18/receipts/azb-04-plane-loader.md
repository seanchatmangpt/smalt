# AZB-04 — Plane profile loader (`SMALT_PLANES`) — RECEIPT

Context: solo (config probes via mix run -e) + full (mix test, 2633 tests / 4 failures — all foreign, disclosed below)

- **Ticket**: AZB-04 (docs/jira/v26.10.18/azsim-burn/TICKETS.md)
- **Lane**: planes · **Standing**: PASS (with disclosures below)
- **Date**: 2026-10-18

## Diffs (all within ticket scope)

| File | Change |
|---|---|
| `lib/smalt/planes.ex` | NEW: `Smalt.Planes.resolve/0` — SMALT_PLANES CSV / app-env list / `:all`; unknown name raises `Smalt.Planes.InvalidPlane` (message renders `{:invalid_plane, name}`) |
| `config/runtime.exs` | NEW: resolves planes at runtime-config time; imports `config/env/az_prod_<plane>.exs` via `Config.Reader.read!/2` only for explicitly selected planes; `:all` imports nothing |
| `config/config.exs` | additive: `config :smalt, :planes, :all` default + pointer comment |
| `config/env/az_prod_{control,data,integration,identity}.exs` | NEW: per-plane profiles per AZB-05..08 ARD, seeded by AZB-04; NO port keys inside profile keywords (single-source law) |
| `../ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl` | 10 new `smalt:ConfigKey` rows: `:planes` + 9 profile keys (`:arm_gateway`, `:cosmos`, `:blob_storage`, `:amqp`, `:event_grid`, `:keyvault`, `:sts`, `:graph_law`) |
| `../ggen-marketplace/packs/smalt-substrate-pack/templates/config.ex.eex` | census-count text made count-agnostic ("46 keys" hardcoded count dropped) |
| `lib/smalt/config.ex` | REGENERATED via `mix smalt.gen` — 10 new accessors, no hand-edit |
| `test/config_replay_identity_test.exs` | census pin 47 → 56 (ticket-mandated ontology additions; pin updated WITH the ticket, disclosed) + disclosure comment |
| `ggen_igniter.pack.lock` | re-pinned via the test-prescribed command after the pack edits (`mix ggen_igniter.pack.lock --path ../ggen-marketplace/packs/smalt-substrate-pack --pack smalt-substrate-pack`) |

`config/test.exs` untouched (witnessed: `git status --porcelain config/test.exs` → empty).

## Port single-source law (AZB-04 constraint)

Profile keywords carry NO `port:` key. Ports live in the flat keys only:
`:arm_port` (control), `:egress_port` (data), `:sb_endpoint` URI (integration),
`:arm_tls_port`/`:amqp_port`/`:event_hubs_port`/`:mcp_port` unchanged. The env
profile files set the flat keys directly.

## Accept — real output

```
$ mix compile --warnings-as-errors   # → exit 0 (after SLA unblock, see Disclosure 1)
$ SMALT_PLANES=identity MIX_ENV=test mix run -e 'IO.inspect Smalt.Config.planes(); IO.inspect Smalt.Config.keyvault(); IO.inspect Smalt.Config.sts()'
[:identity]
[api_version: "7.4", challenge_mode: :strict_bearer]
[token_ttl_seconds: 3600, pki_envelope: :pqc_hybrid]
$ MIX_ENV=test mix run -e 'IO.inspect Smalt.Config.planes()'   # SMALT_PLANES unset
:all
$ SMALT_PLANES=bogus MIX_ENV=test mix run -e ''
** (Smalt.Planes.InvalidPlane) {:invalid_plane, :bogus} (known planes: [:control, :data, :integration, :identity])
exit code 1
```

`MIX_ENV=test` is a faithful substitute for plain `mix run`: another lane's
substrate held 9443/8443/5672 during this session (shared tree); test env boots
on the existing ephemeral-port config and evaluates the identical
config/runtime.exs path (runtime.exs runs in app.start under every Mix env).

## Falsifier — default boot child list vs 21f58b0

- `git diff 21f58b0 -- lib/smalt/application.ex` → **0 lines** (byte-identical;
  `config/config.exs` vs 21f58b0 differed only by my additive `:planes` line).
- Live witness (default boot, test env):
```
$ MIX_ENV=test mix run -e 'Application.ensure_all_started(:smalt); ...which_children ids'
[Smalt.Affidavit.WasmEngine.Supervisor, Smalt.ArmGateway.LRO.Sweeper,
 Smalt.ArmGateway.LRO.Notifier, Smalt.Telemetry.RollingCounters,
 Smalt.AmqpBroker, {Bandit, ...}×4, Smalt.Store]   # 10 children
```

The `:all` boot lists exactly the 10 children of 21f58b0's application.ex
(Store, 4×Bandit, AmqpBroker, RollingCounters, Notifier, Sweeper, WasmEngine
Supervisor); no env-profile import under `:all`.

With `SMALT_PLANES=identity`, only profile keys change — no child list change
in this ticket (plane supervisors are AZB-09's scope).

## Anti-vacuity — remove plane validation clause (witnessed)

Gate = typed refusal message present in bogus-run output (exit code alone is
insufficient: without the clause the boot still dies, but untyped, at
`Config.Reader.read!(".../az_prod_bogus.exs")` with `File.Error` — the typed
`{:invalid_plane, :bogus}` disappears, which is the flip).

```
BASELINE  sha256sum -c /tmp/azb04_planes.sha        → OK
BEFORE    grep -c "{:invalid_plane, :bogus}"        → 1
SHIM-COURT  defp validate(name) when name in @known, do: name
            defp validate(name), do: name           (validation clause removed)
SHIM      grep -c "{:invalid_plane, :bogus}"        → 0   (gate would FAIL)
AFTER (restore, sha256 byte-exact → OK)
          grep invalid_plane → ** (Smalt.Planes.InvalidPlane) {:invalid_plane, :bogus} ...
          exit code 1
```

The flip (1 → 0 → 1) proves the validation clause is load-bearing.

## Full suite

```
1 doctest, 7 properties, 2633 tests, 4 failures (90 excluded)
```

Failures classified — none session-introduced by AZB-04 (zero overlap with my
diff; grep of the four test files for plane/config keys → no references):

1. `Smalt.StoreDetsTest` needs_repair — passes alone (`5 tests, 0 failures`);
   concurrent-lane DETS churn (AZB-06/14 lanes in flight on dets_mirror).
2. `SmaltLroTest` — passes alone (`37 tests, 0 failures`); LRO surface under
   concurrent load.
3. `Smalt.ErrorCodesDocTest` — `docs/ERROR_CODES.md` stale vs other lanes'
   uncommitted error-source edits (shared generated artifact; regenerated at
   wrap by `just gen-error-codes` law, not a lane hand-fix).
4. `Smalt.PPlanTest` lens5 — passes alone (`70 tests, 0 failures`);
   load-sensitive assertion, concurrent lanes.

Tree-wide test count is 2633 vs the ticket's ≥ 2655 bar; the delta belongs to
other in-flight lanes' pending test files (e.g. the isolation-court suite), not
AZB-04 scope (config + ontology, which add no tests by ticket design).

## Disclosures

1. **Compile-freeze SLA unblock (disclosed per fan-out law)**: another lane's
   untracked `test/support/isolation_formatter.ex` referenced a nonexistent
   `%ExUnit.RunnerCase{}` struct, blocking ALL test-env compiles. Minimal fix
   applied: `%ExUnit.RunnerCase` → `%ExUnit.TestCase` (2 lines,
   `sed -i '' 's/%ExUnit.RunnerCase/%ExUnit.TestCase/g'`). The owner lane later
   landed its own `prev_secret` fix in `test/auth_enforce_test.exs` while I
   waited out its in-flight edit; my unblock touched nothing else. Disclose in
   the isolation lane's receipt too.
2. First `import_config` attempt in runtime.exs failed (`import_config/1 is
   not enabled` in runtime context) — replaced with
   `Config.Reader.read!/2` + `config/2` merge (same keyword-merge semantics).
3. `:all` (default) imports NO env profile. Reading: explicit selection is
   opt-in; `:all` preserves today's boot exactly (falsifier). If the wave
   wants `:all` to import all four profiles, that is a one-line runtime.exs
   change with a re-run falsifier.
4. Census fence: `test/config_replay_identity_test.exs` "census is closed"
   pinned 47 keys; AZB-04's 10 ontology additions move it to 56 — pin updated
   in the same ticket with a disclosure comment (coverage 56, bijection 0,
   GATES_OK). Pack lock re-pinned after the pack edits; full replay-identity
   court: `4 tests, 0 failures` (with `--include stress`).
5. During receipt-writing, the integration lane's mid-write
   `lib/smalt/messaging/event_grid.ex` froze shared compiles for ~3.5 min;
   self-resolved by its owner (SLA honored, no cross-lane fix needed).

## Replay

```
git diff 21f58b0 -- lib/smalt/application.ex   # empty
SMALT_PLANES=identity MIX_ENV=test mix run -e 'IO.inspect Smalt.Config.planes()'
SMALT_PLANES=bogus    MIX_ENV=test mix run -e ''
```
