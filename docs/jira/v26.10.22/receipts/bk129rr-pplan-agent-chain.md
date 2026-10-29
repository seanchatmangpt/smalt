# BK-129rr — pplan half of W3C GAP-6a: PROV-O Agent chain

**Standing**: PASS
**Context**: solo
**Date**: 2026-10-22
**Subject**: `lib/smalt/pplan/receipt_engine.ex`, `test/internal/pplan_receipt_engine_test.exs` @ HEAD `23823584` (work committed in the mass-429 checkpoint; this relaunch is the court pass, zero code diffs)

## Scope

Closes the pplan half of W3C GAP-6a. Receipts carry:

- `prov:Agent` typed neutral agent IRI (`urn:smalt:agent:<session>`, `:agent` opt override)
- `prov:wasAssociatedWith` (Activity→Agent, one per step)
- `prov:wasAttributedTo` (Entity→Agent per step + run-level)
- `prov:endedAtTime` / `prov:generatedAtTime` (ISO8601 from step `ts`)
- `verify_chain/1` fail-closed: `:ok` only when all three chain terms present, else `{:error, missing_terms}`

## Court

Command:

```
export PATH=~/.asdf/shims:$PATH && MIX_BUILD_ROOT=_build-bk129rr mix test test/internal/pplan_receipt_engine_test.exs
```

Output:

```
Running ExUnit with seed: 110283, max_cases: 32
..........
Finished in 0.2 seconds (0.00s async, 0.2s sync)
Result: 10 passed
```

Exit: **0**

Court legs (all inside the 10):

- **chain-present**: sealed receipt names the default agent, all three chain faces asserted verbatim, `verify_chain/1 == :ok`
- **per-term tamper**: stripping each of the 3 required terms individually returns `{:error, [term]}` — fail-closed, named missing term
- **agent override**: `:agent` opt lands in `receipt.agent` + every chain edge (1 type, 2 association, 3 attribution), no node() leak
- **time relations**: `endedAtTime` on Activity, `generatedAtTime` on Entity, both from injected step `ts`

Note: first run under `elixir 1.19.5` (homebrew default) refused at the version gate (`mix.exs` pins `~> 1.20`) — rerun under asdf shim `1.20.4-otp-29` per `.tool-versions`.

## Diffs

None this relaunch — implementation landed via checkpoint `23823584` (bk129r partial work was complete on disk, including the GAP-6a chain, time relations, and the 5 court tests). Pre-existing working-tree modifications (confidential_ledger, KD/RECEIPTS docs) belong to other lanes; untouched.

## Build isolation

`MIX_BUILD_ROOT=_build-bk129rr`. Lane build root subject to coordinator `lane-clean` at integration.

## Falsifier status

Not falsified: tamper legs flip `:ok` → `{:error, ...}` for every required term (non-vacuous chain check).
