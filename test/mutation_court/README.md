# Mutation Court: GraphLaw Hard-Crash Gate Non-Vacuity

# Mutation Court

Proves the 422/400 hard-crash admission gate
(`lib/smalt/graphlaw/validator.ex`, refusal envelope code
`InvalidResourceShape`, pinned in
`lib/smalt/arm_gateway/router.ex` `send_graphlaw_refusal/2`) is
**non-vacuous**: reverting the enforcement flips wire outcomes.

## Run

```bash
python3 scripts/mutation_court.py              # full court (boots substrate)
python3 scripts/mutation_court.py --self-check # restore-failure detection only
```

Stdlib-only Python 3. No git operations. Requires `mix` on PATH and the
canonical checkout at `~/smalt` (override via SMALT_REPO env).

## Phases

1. **BEFORE (gate present)** — boot substrate (`mix run --no-halt`, waits
   for port 9443), then wire probes:
   - **M1** valid VM PUT (`location` + `properties.vmSize`) -> admission
     (200/201; virtualMachines is an LRO type, so the substrate's admission
     code is **202** + `Azure-AsyncOperation`).
   - **M2** VM PUT missing required `vmSize` -> `400 InvalidResourceShape`.
     Note: the pinned validator subset enforces `sh:minCount` only, so the
     violable input class is a *missing required property*, not a junk
     value.
   - **M3** `virtualNetworks` PUT missing `location` -> `400 InvalidResourceShape`.
   - **M4** unadmitted type (`Microsoft.Foo/bars`) -> `400 InvalidResourceShape`
     (router-side `check_admitted`; refused in both phases by construction).
2. **AFTER (gate absent)** — stop substrate, inject a clearly-marked
   `MUTATION-COURT` string-replacement into `validator.ex` making
   `validate_resource/2` return `{:ok}` unconditionally, reboot, re-run
   M2/M3 — they **must now be admitted (2xx)**. If the gate's absence is
   not observable, the gate is vacuous.
3. **Restore + confirm** — restore `validator.ex` from backup, verify
   **byte-exact via sha256**, reboot, re-run M2 -> refusal must be back.

## Verdict and exit codes

Exit `0` only if: gate-present refuses (M2/M3/M4) AND gate-absent admits
(M2/M3 -> 2xx) AND restore sha256-verified AND post-restore M2 refuses.
Exit `1` = gate vacuous or a probe failed. Exit `2` = **BLOCKED** honestly
(boot/compile failure after 3 retries, 60s apart — shared-checkout
compile freeze), never faked.

## Self-check

`--self-check` exercises the restore-failure detection on a **temp copy**
of `validator.ex` (never the real file): a clean restore must verify, and
a deliberately corrupted restore must be detected. This is a real
collaborator exercise on real bytes, not a mock.

## Disclosure

The court transiently edits `lib/smalt/graphlaw/validator.ex` (the single
mutation under test), restores it byte-exact with sha256 verification, and
fails closed (refuses to mutate, exits) if the anchor text is absent.
Boot logs go to `/tmp/mutation_court_boot_*.log`.
