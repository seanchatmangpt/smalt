# L28r — AoQ as a bootable plane name (spec §1.3)

Standing: PARTIAL_ALIVE

Subject: `/Users/sac/smalt` — admit `:aoq` in `Smalt.Planes` so naming it
permits the AoQ gate; unknown names still refuse boot typed.

## Diff

- `lib/smalt/planes.ex` — `@known` gains `:aoq` (both the module attr and the
  `InvalidPlane` message copy), so `SMALT_PLANES=aoq` / `config :smalt, :planes,
  [:aoq]` resolves and unknown names still raise `{:invalid_plane, name}`.
- `config/env/az_prod_aoq.exs` — NEW plane profile, imported by
  `config/runtime.exs` only when `:aoq` is explicitly selected; sets
  `config :smalt, aoq: [enabled: true]` — the exact key the landed
  `Smalt.Plane.DataSupervisor.aoq_child/0` gate (L11, 73eeeee2) reads. The
  gate itself was NOT edited (profile mechanism already present).
- `lib/smalt/application.ex` — one line disclosed edit (off-lease, minimal):
  `plane_children` maps `:aoq -> [Smalt.Plane.DataSupervisor]` so `aoq` alone
  boots the plane through its single lawful start site.
- `test/smalt/planes_test.exs` — NEW: accept fixtures (config list + SMALT_PLANES
  CSV, `:aoq in Planes.known()`) + refusal fixtures (unknown atom name and
  unknown CSV name raise, built dynamically so the test never mints the atom
  the gate refuses).

`data_supervisor.ex` NOT touched (not strictly required — the profile flips the
gate; zero edit).

## Commands / exits

- `MIX_BUILD_ROOT=_build-lane28r mix test test/smalt/planes_test.exs` →
  **5 passed, exit 0** (compiled full project incl. application.ex edit).
- Gate probe `SMALT_PLANES=aoq mix run --no-start --eval`:
  `resolved: [:aoq]`, `aoq_cfg: [port: 9093, enabled: true]` → **exit 0**.
- Default-boot probe (no SMALT_PLANES): `aoq_default: [enabled: false, port: 9093]`
  → default boot byte-identical, gate OFF. exit 0.
- Full live-boot probe (does `SMALT_PLANES=aoq` start `Smalt.Aoq.Supervisor`
  under the real DataSupervisor): **BLOCKED** — compile-freeze by foreign
  in-flight lanes (`lib/smalt/aoq/session.ex` missing `end`, then
  `lib/smalt/arm_gateway/providers/management_policies_router.ex:117` missing
  delimiter, both modified mid-wave by other lanes). Two attempts, exit 1.
  Config-gate leg is proven above; the supervisor-start leg rides L11's
  landed court (`test/smalt/plane/data_supervisor_aoq_test.exs`).

## Falsifier status

"Naming aoq permits the AoQ gate" — CONFIRMED at the gate-read surface
(`Application.get_env(:smalt, :aoq)` flips true under `SMALT_PLANES=aoq`,
false by default). Unknown-name refusal — CONFIRMED by test.

## Pre-existing defect found (out of lease, flagged not fixed)

`.gitignore:53` `env/` (unanchored, a Python-venv rule) matches
`config/env/` — all four existing plane profiles (`az_prod_control/data/
identity/integration.exs`) are UNTRACKED on this checkout and always have
been (git log on the path is empty). A fresh checkout with
`SMALT_PLANES=<plane>` would crash on the missing profile. `az_prod_aoq.exs`
is `git add -f`-tracked by this lane; the four legacy profiles + the
gitignore anchor fix (`/env/` or `!config/env/`) are flagged for the
coordinator/backlog, not edited by this lane.

## Standing

PARTIAL_ALIVE: gate-permit + refusal + default-off all proven ALIVE on the
real subject; live supervised boot of the AoQ subtree under SMALT_PLANES=aoq
remains UNVERIFIED pending the shared checkout compiling (foreign in-flight
lanes, not this lane's files).
