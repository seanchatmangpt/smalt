# Receipt r01 — ash_gen W2a flags + W4 slice-1 landing (Microsoft.Network)

Standing: **ALIVE** (all commands below executed this session, exits shown).

## What landed
- W2a task flags: `--provider` slice filter (prefix-match, unknown -> typed
  ArgumentError naming the known set), registry read-modify-write merge
  (slice-composable; full run = fixed point), non-tty `run/1` override
  injecting `--yes` (`:io.getopts()[:terminal]` probe) — root cause of the
  CI crash: igniter's handle_long_diff prompts via Igniter.Util.IO.select/3
  even under --dry-run and String.trim(:eof) crashes redirected runs.
- W4 slice 1: `lib/smalt/network.ex` (domain, 176 registrations) +
  `lib/smalt/network/*.ex` (177 resources) + `lib/smalt/ash_gen/registry.ex`
  (201 {provider, type_path} entries, defmodule-wrapped).
- Generator hardening (court-caught, fixed): registry body now defmodule-
  wrapped (create_new_file writes raw — tests never compile the test
  project, so only the real landing could catch this); domain resources
  block dedup+sorted (type-path collisions like dnsZones/A vs
  privateDnsZones/A both derive Smalt.Network.A); module names always
  derived by the fixed naming law (ttl ashResource bug rode through:
  CustomIpPrefixe); test_mode? guard on the disk-existence arm (host disk is
  not virtual-project state); zero-scan existence via proper_location +
  File.exists?/Rewrite.has_source? (Igniter.Project.Module.module_exists/
  find_module deep-glob timed out 2x on this repo; **beam purge without
  manifest invalidation poisons the build** — force-recompile required).

## Verification ladder (exit codes inline)
    mix test test/smalt_ash_gen_test.exs   # 5/5 passed, exit 0
    MIX_ENV=dev mix compile                # exit 0 (slice compiles: 178 files)
    mix smalt.gen.ash tmp/azure_8020.ttl --provider Microsoft.Network  # exit 0
    ... second run                         # exit 0, file counts stable (idempotent)
    MIX_ENV=dev mix run --no-start -e 'IO.inspect(Smalt.AshGen.Registry.lookup("Microsoft.Network", "virtualNetworks"))'
    # lookup: {Smalt.Network.VirtualNetwork, "2026-03-01"}; entries: 201

## Falsifiers (any of these would have flipped standing)
- compile-abort census: phase-1 exit 1 would be BLOCKED (0 tests), not a
  failure count. Witnessed live: the defmodule-less registry tripped it.
- idempotency: file-count drift or registry churn on second run.
- registry probe: lookup returning nil/wrong module.

## Known limits (honest)
- 176 registrations / 177 files: one file per distinct module; the resources
  block references modules, not files, so 201 type_paths -> 177 modules is
  the intended many-to-one (leaf-naming collisions documented in
  ash-wave-resolutions.md).
- test-env build may need `MIX_ENV=test mix compile --force` once if beams
  were purged mid-session (same manifest trap).
- router.ex mount (W2) and replay fence (W3) remain open per wave plan;
  router.ex is hot with a concurrent lane.
