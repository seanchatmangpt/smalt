# V261019-04 — azb-18 cgroup soak: mount gaps + memory ceiling + defaults

- **Release:** v26.10.19
- **Lane:** burn (azb-18 soak)
- **Base:** HEAD `502c4ed` (per `docs/jira/v26.10.18/receipts/i29-azb20-postfix.md`)
- **Status:** ready-for-work
- **Source WO:** `docs/jira/v26.10.19/WORK_ORDERS.md` WO-4

## Objective

Close the azb-18 cgroup-constrained soak. Standing is
**PARTIAL_ALIVE / BLOCKED[unledgered-failure-faces + harness-mount-gap]** per
`docs/jira/v26.10.18/receipts/azb-18-cgroup-soak.md`: both executed soak cycles
were refused by the gate (`STANDING_REFUSED`, 4x DIRTY_ROW UNHANDLED_EXIT);
data+identity completed the suite (2740 tests, 44/45 failures), control+integration
were SIGKILLed. Dominant face is a harness mount-surface gap —
`.ggen_igniter/receipts` absent inside the container — plus a memory diagnosis
that `SMALT_SOAK_MEM_LIMIT=2g` is insufficient for the 2.0-CPU planes
(control, integration per the fixed ladder in `docker/burn/cgroup-soak.sh`).
Close condition is the soak gate exiting 0 with derived standing ALIVE (all
plane rows clean) per the fixed `scripts/validate_burn.py`
(`docs/jira/v26.10.18/receipts/i29-validator-standing-fix.md` — validator
derives standing from plane rows, caps non-clean at PARTIAL_ALIVE, exits
non-zero).

## Files owned

- `docker/burn/cgroup-soak.sh`
- `docker/burn/compose.cgroup.yml` (GENERATED via `--emit-compose`; never hand-edited)
- `docker/burn/cgroup_suite_runner.sh`
- `docs/jira/v26.10.18/azsim-burn/AZB23-PREFLIGHT.md` B-rows only if the soak
  rows live there; receipt at `docs/jira/v26.10.19/receipts/azb-18-soak-close.md`

## Tasks

### T1 — mount `../ggen_igniter` read-only into the soak harness (closes the UNHANDLED_EXIT mount gap)

The compose `x-soak-common` block in `cgroup-soak.sh` `emit_compose` mounts
`../burn`, `./results`, `../../test`, `../../lib` — but not `../ggen_igniter`.
The container leg hits the missing receipt surface and dies UNHANDLED_EXIT.

1. In `emit_compose`, add under `volumes:`
   `- ../ggen_igniter:/burn/ggen_igniter:ro` (read-only — the harness must not
   be able to mutate the igniter tree it consumes).
2. Regenerate via `--emit-compose` (do NOT hand-edit `compose.cgroup.yml`).
3. Extend the preflight with a mount-surface check mirroring the existing
   HOST_PORT_PUBLISH_REFUSED guard: verify the resolved compose carries the
   read-only ggen_igniter mount (e.g. `docker compose config | grep` for the
   target path) — refusal exit 2 with `GGEN_IGNITER_MOUNT_MISSING` if absent,
   so the exact azb-18 failure class is caught pre-run, not post-refusal.

### T2 — memory ceiling: raise `SMALT_SOAK_MEM_LIMIT` to 4g for the 2.0-CPU planes (or stagger compile)

Evidence: the receipt's own remediation line — `mem_limit 1g` default is far
below what a 2.0-CPU plane needs; at 2g the control/integration containers
were SIGKILLed mid-suite.

1. Change the default `MEM_LIMIT="${SMALT_SOAK_MEM_LIMIT:-1g}"` → `4g` in
   `cgroup-soak.sh` (both the shell default and the two `${SMALT_SOAK_MEM_LIMIT:-1g}`
   interpolations in `emit_compose` — keep them consistent).
2. Alternatively/additionally: stagger the compile phase so 4 containers do not
   compile concurrently inside 4g each (compile is the memory spike; the suite
   proper fits). If staggering, do it in `cgroup_suite_runner.sh` (per-service
   start offset via `BURN_SERVICE`), not by serializing whole services.
3. Keep the env-overridable contract: `SMALT_SOAK_MEM_LIMIT` /
   `SMALT_SOAK_PIDS_LIMIT` must be settable from the caller (receipt's fix 3:
   these are currently session-set; persist the defaults in the script itself
   so a bare `bash docker/burn/cgroup-soak.sh` reproduces the accepted ceiling).

### T3 — re-run the soak to a clean gate

1. `bash docker/burn/cgroup-soak.sh --cycles 1` (ladder up to the AZB-18 accept
   shape `3 rounds x 3 quota tiers` once 1 cycle is clean).
2. Gate: `python3 scripts/validate_burn.py --gate <merged.jsonl>` exit 0, all
   4 plane rows clean (no DIRTY_ROW/MISSING_CELL/UNHANDLED_EXIT).
3. FLAKE_LEDGER classification host-side: any face → ledger row FIRST
   (`docs/jira/v26.10.17/FLAKE_LEDGER.md`), then re-burn. Zero UNLEDGERED.

## Acceptance falsifiers

- [ ] `--emit-compose` output contains the read-only `../ggen_igniter` mount;
      removing it from the compose and re-running preflight yields
      `GGEN_IGNITER_MOUNT_MISSING` exit 2 (non-vacuity: the check must fire
      when the mount is absent — that is the exact witnessed failure class).
- [ ] Reverting T2 (back to `1g`) with the real run reproduces the
      control/integration SIGKILL → UNHANDLED_EXIT row; the 4g default
      eliminates it (red-before/green-after at the harness level).
- [ ] `bash docker/burn/cgroup-soak.sh --cycles N` exits 0 with
      `VERDICT: CLEAN` — gate exit 0, derived standing ALIVE, zero unledgered faces.
- [ ] Bare invocation without session-exported env vars resolves the persisted
      4g/512 defaults (`--dry-run` print shows `mem=4g pids=512`).
- [ ] Receipt at `docs/jira/v26.10.19/receipts/azb-18-soak-close.md` cites the
      merged JSONL; a further gate failure invokes the third-strike rule
      (retire the soak shape) per WO-1's precedent.
