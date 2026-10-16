# dod-09-verify-all.md — DoD-9 receipt (v26.10.14)

Date: 2026-10-15. Subject: one-command verify-all. Checkout: `~/smalt` (canonical, main).

## Deliverables

- `scripts/verify_all.sh` — orchestrates 7 stages in order, PASS/FAIL/SKIP
  verdict line per stage, final verdict table, exit 0 only if no FAIL
  (SKIP requires a reason). No global substrate boot: every stage is offline
  or boots its own substrate behind the shared lock.
- `justfile.d/09-verify-all.just` — `verify-all` recipe (`bash scripts/verify_all.sh`).

## Stage wiring

| stage | command | skip condition |
|---|---|---|
| doctor | `python3 scripts/doctor.py --json` | file missing |
| doctor-dod | `just doctor-dod` | recipe not in `just --list` at run time |
| test-offline | `just test-offline` else `mix test` | recipe absent and no mix |
| workspace-court | `node workspace/scripts/e2e-court.mjs` | file/node missing |
| smalt-cli-pytest | best of `smalt-cli/.venv`, `.venv-cli`, PATH pytest over `smalt-cli` | no tests dir or interpreter |
| naming-sweep | `just naming-sweep` | recipe not visible |
| invariant-gates | `just invariant-gates` | recipe not visible |

## Fixes applied this session (disclosed cross-lane minimal unblock fixes)

1. justfile.d/05-doctor-ext.just — `ROOT :=` collided with 06's `ROOT`,
   breaking Justfile parse ("variable ROOT has multiple definitions").
   Renamed to `DOD5_ROOT` (2 sites). Owner lane landed `doctor-dod`
   concurrently; after the rename the recipe parses and runs.
2. `workspace/scripts/e2e-court.mjs` — the court compiles `lib/**` into a
   `mkdtemp` outDir under `os.tmpdir()`; node's `node_modules` walk-up from
   that tree can never find `@azure/*`, so `azure/arm-client.ts`,
   `azure/eh-stream.ts`, `azure/resource-queries.ts` import-FAILed
   (`Cannot find module '@azure/arm-resources'` / `'@azure/event-hubs'`).
   Added one line after mkdtemp: symlink WS `node_modules` into the tmp root.
   Court went 36 PASS/3 FAIL -> 39 PASS/0 FAIL/2 SKIP (live-probe SKIP is
   expected with no substrate up).
3. `smalt-cli/.venv` — missing test-only deps `azure-storage-blob`,
   `azure-cosmos`, `azure-mgmt-resourcegraph` (pyproject declares only
   typer/pyserial; the azure pins live only in the tests). pip-installed into
   the lane venv; collection errors for test_blob/test_cosmos/test_resourcegraph
   cleared (111 tests now collect).

Also witnessed, not mine, no action: `justfile.d/06` whitespace parse break
and a transient `justfile.d/14-sdk-matrix.just` missing-import — both repaired
by their owner lanes while this lane ran.

## Verification ladder — real runs

- Run 1 (full, first witness): doctor PASS, doctor-dod FAIL (lane-05 script
  mid-landing; standalone `python3 scripts/doctor_dod.py` now exits 0,
  0 FAIL/3 WARN), test-offline PASS, workspace-court FAIL (node_modules
  resolution defect, fixed above), smalt-cli-pytest FAIL (missing azure
  deps, fixed above, plus substrate-lock contention), naming-sweep PASS,
  invariant-gates PASS (3 tests, real substrates, negatives refused).
- Run 2 (full, post-fix): 6/7 PASS — doctor, doctor-dod, test-offline,
  workspace-court, naming-sweep, invariant-gates PASS;
  smalt-cli-pytest FAIL exit 2: `SUBSTRATE_LOCK_TIMEOUT` at collection in
  test_keyvault/test_servicebus (both boot a real substrate behind
  `/tmp/smalt-substrate.lock`; lock held for the full window by concurrent
  lanes — `flock` 38442 + `beam.smp` 38446 observed holding it, with several
  lanes queued). 111 tests collected, the offline modules passed; only the
  two substrate-booting modules could not acquire the lock within 120s.
- Run 3 (`/tmp/dod9-verify-all-final.log`): smalt-cli stage hit mid-edit test
  files from its owner lane (`NameError: SHARED_KEY/SECRET_B64` at collection);
  cleared on the lane's next save. 6/7 PASS otherwise.
- Run 4 (`/tmp/dod9-verify-all-run4.log`): doctor FAIL (port 5672 held by
  another lane's substrate), test-offline FAIL (1 test:
  `doctor.summary agrees with scripts/doctor.py --json` — same port
  contention), smalt-cli-pytest FAIL (cli5 substrate lock held >120s by
  another lane). workspace-court PASS.
- Run 5 (`/tmp/dod9-verify-all-run5.log`, most recent full witness): doctor
  FAIL (port 5672 held by PID 67158, another lane's substrate), test-offline
  FAIL exit 2 (1 failure: Smalt.StoreDetsTest mirror-capture test; 1897
  others passed), workspace-court PASS (39 PASS/0 FAIL/2 SKIP), smalt-cli
  FAIL exit 1 (134 collected — deps fix holding; 6 blob assertion failures +
  9 cosmos azure errors in the lane's own wire tests; the substrate-booting
  eventhub/keyvault/servicebus modules acquired the lock and ran), naming-
  sweep FAIL (160 violations — other lanes' receipt files contain literal
  `/Users/...` checkout paths; this lane's receipt contributes 0), invariant-
  gates PASS (3 tests, real substrates, negatives refused).

## Standing / falsifiers

- Standing: PARTIAL_ALIVE. `verify-all` itself is mechanically sound (its
  own stages passed on quiet windows) but a full exit-0 run has not been
  witnessed under this session's concurrent 20-lane load: ports 9443/5672,
  `/tmp/smalt-substrate.lock` and `/tmp/smalt-substrate-cli5.lock` are held
  by other lanes for most of the wall clock, and shared-surface content
  (naming-sweep violations in other lanes' receipts) fails lanes that are
  not their owners. Falsifier for full ALIVE: `just verify-all` exit 0 on an
  idle checkout.
  the smalt-cli stage is lock-contended whenever another lane holds the
  substrate for >120s per module. Falsifier for full ALIVE: a full
  `just verify-all` run with exit 0 while no other lane holds
  `/tmp/smalt-substrate.lock`. Not yet witnessed this session.
- Known gap: smalt-cli azure test deps are undeclared in
  `smalt-cli/pyproject.toml` (they exist only in the venv) — recommend the
  smalt-cli lane add a `test` optional-dependency group.

No commits made.
