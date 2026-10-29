# BK-71: Internal-tier census drift reconciliation

**Standing: PASS** (census 6/6 green ×2 runs, one fixed-seed replay; non-vacuity shim court flipped the gate to typed refusal)
**Context: solo** (internal tier; real file-read court over `test/internal`, no mocks; shared `lib/` compile freeze from a sibling's in-flight `store.ex` observed and polled through, not worked around)

## Drift list and dispositions

Base census run (pre-fix): 0/6 passed. Files on disk: 53 (17 registered). Root cause:
lanes added internal-tier files without registering them in
`test/internal/internal_tier_census_test.exs` (population fence + token scans +
observables allowlist all drift as one registry).

| File | Disposition | Evidence |
|---|---|---|
| `powl10c_debug_test.exs` | **Deleted** (`git rm`) | Pure `IO.puts` AST-print scratch, zero assertions, no receipt/lane references; real court counterpart `powl2_compiler_test.exs` covers `Smalt.Powl2.Compiler.compile/1` |
| `impl18_heap_probe_test.exs` | **Registered** (`:observer` class) | Receipt `impl18-vm-census-processiter-adoption.md` §Disclosures defers intake to coordinator; kept as heap-probe fixture (2 zero-delta census-semantics tests, cited by bk10-citation-audit) |
| 34 other unregistered files (powl2_*, ja15, bk14, ath1, gld6, sql_ingest, rg404, ws_amqp_relay, w3cb, deferred_listeners, eh_throttle_wiring, impl25, impl6, spofb, ets_auto, petri_net, process_iterator_court, etc.) | **Registered** with per-file class (:observer / :internal / :wire) + typed per-rule exemption rows | Real committed courts/tests, each lane's work; classified from observed behavior (wire courts vs in-process internal tests vs residual observers) |
| `spofb_eh_atom_court_test.exs` | **Registered** | Sibling SPOF-B lane file that landed mid-session; registered same-session so the fence is exact |

The `@exemptions` map lifts exactly one named rule (:client_token / :status_literal /
:arm_literal) per file with justification — a registered file growing a NEW forbidden
behavior still fails; unregistered files trip the population fence first.

## Scan-rule reconciliation (registry to reality, not masking)

- Pacing scan: now strips `#` comments (comment false-positive: powl2_change_feed) and
  honors the no-sleep doctrine's inline `# SLEEP-CLASS:` typed classification on the
  sleep line or within 3 preceding lines (impl6 same-line, gld6/sql_ingest
  POLL-STEP-annotated `wait_listening/2` bounded poll steps). gld6/sql_ingest files NOT
  touched — their annotations were already in place.
- Status/client/ARM scans: per-file typed exemptions as above; the :wire class does not
  get a blanket exemption (each lift is a named row).

## Verification

```
$ MIX_BUILD_ROOT=_build-bk71 mix test test/internal/internal_tier_census_test.exs
Finished in 0.8 seconds (0.8s async, 0.00s sync)

Result: 6 passed
(exit 0)

$ ... --seed 0
Result: 6 passed
```

## Non-vacuity (shim court)

```
$ printf '# SHIM-COURT BK-71...\nProcess.sleep(250)\n' > test/internal/zz_bk71_shim_probe.exs
$ MIX_BUILD_ROOT=_build-bk71 mix test test/internal/internal_tier_census_test.exs
  test/internal population drifted: on_disk=MapSet.new(["zz_bk71_shim_probe.exs"])
  unaudited pacing outside the helper: [{"zz_bk71_shim_probe.exs", "Process.sleep(250)"}]
Result: 4/6 passed   → mix exit 1 (gate REFUSES)
$ rm shim; restore confirmed (file absent)
```

A gate that accepts the shim exits 1 as VACUOUS — this one refused both on population
fence and pacing scan. First shim attempt is disclosed as invalid (ran from
`test/internal` cwd → wrong test path, exit 1 was path-not-found, not a refusal); the
valid run above is from repo root.

## Working-tree diff at receipt time

`test/internal/internal_tier_census_test.exs` (final two fixes: `Smalt.Impl25/Impl6.*Test`
allowlist prefixes; `Enum.with_index` yields {element, index} — pacing scan destructured
backwards, crashing strip_comment with the integer index). Earlier rewrite portions were
absorbed by coordinator checkpoint commit 02c6a85. `powl10c_debug_test.exs` deletion staged
via `git rm`. Sibling in-flight edits (`plane_blast_radius_test.exs`,
`spofb_eh_atom_court_test.exs`) NOT touched.

## Falsifiers

- Re-adding any unregistered file to test/internal → population fence refuses (witnessed via shim).
- Un-annotated Process.sleep in a registered file → pacing scan refuses (witnessed via shim).
- Deleting an exemption row re-arms the corresponding scan for that file (typed refusal names file+rule).

## Standing note

The census is a living registry court: every future internal-tier file must be registered
(class + any typed exemptions) or the fence fails loudly. Population as of receipt: 52
registered files.
