# exit-codes

Canonical exit-code matrix for the posh v26.10.30 court/gate fleet (lane 5,
2026-10-30). One code, one meaning **per script family**; where the same code
carries a different meaning in another family, the Collisions section names it.

## Legend

- PASS = the property under audit holds.
- FAIL = the property under audit is violated (mutation landed, drift found).
- SKIP = loud, typed preconditions missing; never a fake pass (3 = SKIP in the
  gate family).
- REFUSE = fail-closed preflight refusal (the audited subject never ran).
- Usage = the caller misinvoked the script (nothing was audited).

## Canonical codes

| code | meaning | scripts |
|---|---|---|
| 0 | PASS / GREEN | all |
| 1 | FAIL / RED | see list A below |
| 2 | REFUSE / BLOCKED / INCONCLUSIVE (family-scoped; see Collisions) | see list B below |
| 3 | SKIP (gate family) / NONE-UNKNOWN (discriminator family) | see list C below |
| 4 | TF-ARCHIVED refusal (unique) | justfile.d/57-tf-provider.just recipes (mix.exs absent) |
| 5 | import-court id mismatch (leg code) | import_roundtrip_court.sh |
| 9 | import-court cd failure (leg code) | import_roundtrip_court.sh |
| 124 | SLA expiry (internal; runner rewrites to 1) | posh_sla.sh |

Script families per code (continuation of the table):

- **code 1 (FAIL/RED)** — courts: posh_mutation_court.py,
  import_roundtrip_court.sh; gates: posh_coverage.py, compat_pin_check.py,
  posh_invariant_gate.py, guard_local_apply.sh,
  egress_plane_discriminator.sh (DEFER-VOID); posh_sla.sh (rewrites 124);
  doctors: posh doctor, doctor_dod.py, doctor.py; docs-dod-check.
- **code 2 (REFUSE/BLOCKED/INCONCLUSIVE)** — posh_sla.sh (refusal, child not
  run), cmd/andon (BLOCKED), guard_local_apply.sh (usage),
  court_plane_discriminator.sh (KIND/SPLIT),
  egress_plane_discriminator.sh (INCONCLUSIVE), posh doctor (usage/config).
- **code 3 (SKIP / NONE-UNKNOWN)** — posh-generate/-vet/-smalt-wire and
  posh-court SKIP legs, _check_posh_tools, _check_provider_tools,
  compat_pin_check.py, posh_invariant_gate.py (pack missing),
  court_plane_discriminator.sh (NONE/UNKNOWN).

## Collisions (registered, not silently left)

1. **exit 2 carries three meanings**: SLA/andon REFUSE/BLOCKED (fail-closed
   infra) vs guard usage error vs discriminator INCONCLUSIVE/KIND/SPLIT (a
   verdict, not an error). Scope is the script; consumers must read the
   typed `[TAG]` line, not the code alone.
2. **exit 3 carries two meanings**: SKIP (gate family, loud) vs NONE/UNKNOWN
   (court discriminator, fail-closed). The typed tag disambiguates; 3 never
   reads as pass anywhere.
3. **exit 1 is NOT uniform**: in the egress discriminator 1 = DEFER VOID
   (apply the pre-staged fix), everywhere else 1 = FAIL. Typed `[EGRESS-...]`
   tag disambiguates.
4. `posh_invariant_gate.py` docstring declared 0/1/2 but the code exits 3 on
   a missing pack — doc/code skew, fixed in the same commit as this table
   (gaps/58).
5. `doctor_dod.py` exits 0 on WARN alone; posh doctor `-strict` promotes
   YELLOW to 1. Intentional, registered.

## Non-vacuity: where each code is asserted

| family | asserted by |
|---|---|
| guard 0/1/2 | scripts/guard_local_apply_test.sh (7 legs, incl. exit 2 usage) |
| SLA 1 + refusal 2 + 3-passthrough | just posh-court-sla-test (control, timeout RED, refusal leg) |
| andon 0/1/2 | posh/internal/andon/andon_test.go (YELLOW=0, RED=1); cmd/andon tests (BLOCKED=2) |
| invariant 1 + court flip | just posh-invariant-court (orphan flip to 1, sha256 restore) |
| mutation court 0/1 | posh_mutation_court.py self-court (4 tamper legs) |
| import court 0/1 (legs 4/5/9) | leg-level record() rows; leg 5 per gaps/36 |
| TF-ARCHIVED 4 | none (archived tree, mix.exs absent) — REGISTERED GAP |
| discriminator 0/2/3 | none automated (live witness only) — REGISTERED GAP |
| compat 0/1/3, coverage 0/1, docs-dod 0/1, posh doctor 0/1/2 | none — REGISTERED GAP |
