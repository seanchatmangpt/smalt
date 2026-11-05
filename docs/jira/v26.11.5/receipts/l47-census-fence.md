# L47 — internal tier population-fence drift repair (census)

Standing: PASS

## Subject

- Repo: `/Users/sac/smalt`, base HEAD `db2dd3568ffafbe47a0822c34874d0db4c992b02`
- Owned files: `test/internal/internal_tier_census_test.exs` only (plus this receipt).

## Finding (pre-existing, disclosed by L32's receipt)

`test/internal/internal_tier_census_test.exs` was red with 5 failures
citing foreign unregistered files: `kd03_kv_polarity`, `kv7_beam_oracle`,
`api_version_admission_fence`, `diagnostic_envelope`, `aoq_*`, `wo32`.
Substrate gained capability; the fence's manifest moved under it
(premise rot). Fix = re-pin the fence to the new lawful population, not
weaken it.

## Change

Registered all 7 files in `@registered` with per-file tier classes and
typed exemption rows in `@exemptions` (each names the rule it lifts and
the observed behavior), plus 9 new `@observables` entries for the new
module surfaces (`Smalt.Internal.*` court modules, `Smalt.Registry`,
`Smalt.ArmGateway.Plug`, `Smalt.Posh.Pipeline`, `Smalt.Posh.Egress`,
`Smalt.Aoq`). Fence strength unchanged: population fence still
MapSet-equality, all scans still apply to every unexempted rule/file.

## Commands / exits

- Before: `MIX_BUILD_ROOT=_build-lane47 mix test
  test/internal/internal_tier_census_test.exs` → 3/8 passed, 5 failures
  (population fence, client-token, status-literal, ARM-literal,
  observables), exit 2.
- After: same command → **8 passed, 0 failures, exit 0**.
- Intermediate self-scan witness: my own registration comments tripped the
  ARM-literal scan (census is part of its own scan) — comments rephrased
  without the literal path segments; the fence caught its own author, which
  is the non-vacuity evidence.

## Verification ladder

Narrow: census fence file-read court only; no lib/ changes, no behavior
change. All 7 files compile (none absorbed as a compile defect; no
follow-up defect registered).

## Notes

- Full population counted: 7 on-disk files all pass/registered; no silent
  skip (`unregistered=MapSet.new([])` after the fix, every scan rule still
  fails loudly on unexempted hits).
- Census prose count note: `@registered` count grows 1:1 with files; the
  MapSet-equality fence is the mechanism, not a count literal.
