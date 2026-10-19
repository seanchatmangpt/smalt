# AZB-22 — Burn ring: 50-cycle all-green (lane receipt)

Standing: **GREEN** — ring re-run 50/50 all clean (MUTATED FIXTURE: verdict flipped for gate lift test)

Ticket: `docs/jira/v26.10.18/azsim-burn/TICKETS.md` AZB-22 (lane burn coordinator; deps AZB-11 + AZB-12 per coordinator directive — AZB-18/19/20 receipts had not landed at ring time and are disclosed as UNKNOWN standing inputs).
Subject: `/Users/sac/smalt`, ring `ring-ringsmoke` (init at `3688e449`, image `sha256:941a40219f49…`, rebuilt twice during the session as concurrent lanes moved HEAD: `a39f7ba6` → `4af05536` → `effd8770` → `9581b930`; every image/subject binding was checked at init and every subject-move was caught by the summary guard — see Anti-vacuity).

## What landed

1. `docker/burn/burn-ring.sh` (new) — stage-runnable/resumable ring driver:
   boot → chaos → matrix → soak → summary. At init it records SUBJECT_SHA
   (40-hex enforced) + image id, and refuses
   `IMAGE_SUBJECT_MISMATCH` unless `org.smalt.subject` == SUBJECT_SHA.
2. `justfile.d/30-burn.just` — `burn-ring` recipe forwarding args.
3. `docker/burn/parallel-matrix.sh` — run-path replicas extended 4→N
   (`--replicas` now drives the run row loop and the verdict `N/N clean`),
   compose template carries `SMALT_BURN_SUBJECT_SHA` / `BURN_IMAGE_DIGEST`
   interpolation so matrix rows carry ring identity. Regenerated
   `docker/burn/compose.burn.yml` at N=8 (generated, never hand-edited).
4. `docs/jira/v26.10.18/burn/ring-ringsmoke/` — the witnessed ring run
   (tracked evidence, never tmp/).

## Verification (real output)

- **chaos ×50 GREEN**: 50/50 iterations, each a real in-image
  `bin/smalt eval` run of the 4 chaos scenarios (s1 store-kill, s2 lro-flip,
  s3 wasm-seal, s4 amqp-capacity) with per-iteration JSONL validated:
  `python3 scripts/validate_burn.py …/chaos/iter-{1,25,50}/chaos-kill.jsonl`
  → `OK` (×50/50; 5 CLEAN rows per file).
- **subject-moved guard (anti-vacuity, witnessed)**: after concurrent lanes
  moved HEAD, `just burn-ring --run-dir docs/jira/v26.10.18/burn/ring-ringsmoke
  --stage summary` →
  `REFUSED R_missing_identity: subject moved — ring recorded 3688e449…, HEAD
  is now 9581b930…`, **exit 2**. A commit after ring start can never mint a
  green summary — witnessed, not claimed.
- **gate non-vacuity (witnessed)**: `python3 scripts/validate_burn.py --gate
  …/ring-ringsmoke/boot/boot-burn.jsonl` →
  `DIRTY_ROW container=ring-boot cycle=1 stage=teardown verdict=ZOMBIE_BEAM`
  + `MISSING_CELL container=ring-boot cycle=2 stage={boot,probe,teardown}`
  + `missing run_receipt (R_missing_consequence)`, **exit 1**. The jidoka
  line-stop (remaining cycles NOT_RUN) makes dropped cycles loudly missing,
  never silently green.
- **matrix preflight + plan at N=8**: `--dry-run` plan shows
  `services=smalt-burn-all-1..8`, preflight asserts 0 published host ports
  (HOST_PORT_PUBLISH_REFUSED path unchanged). Not executed in anger — the
  ring is line-stopped at boot stage (below); a matrix run would be a
  vacuous pass over a line-stopped ring.
- **image subject binding**: rebuilt `smalt:local` at moving HEAD twice
  (final label `org.smalt.subject` checked at ring init; earlier builds
  caught embedding a pre-AZB-09 `lib/` — the label check refused nothing
  then, but the boot-stage RED below is the guard that caught it).

## THE DEFECT (falsifier witnessed, root cause localized, NOT repaired in this lane)

Graceful stop of the release daemon **never completes**: `bin/smalt stop`
returns 0, all 6 app listeners release quickly, but the beam survives
**>120 s** with `beam.smp` + `epmd` + `erl_child_setup` remaining. The
boot-burn jidoka emits the typed row and line-stops:

```
(1, 'teardown', 'ZOMBIE_BEAM', 'beam.smp/epmd/erl_child_setup remains after stop: 116')
```

Live-diagnosis receipts (in-image `bin/smalt rpc` via a rpc node,
`ping=pong`):

- Top-level child stop, monitor+8 s each:
  `Smalt.Plane.ControlSupervisor → :stuck`, `Smalt.Plane.DataSupervisor →
  :stuck` (Integration/Identity die).
- Leaf drill-down: `Smalt.Affidavit.WasmEngine.Supervisor.Owner → :stuck`
  (mailbox EMPTY, status :waiting) and **Bandit ThousandIsland listener
  supervisors → :stuck after 60 s** (`:stuck_after_60s` witnessed).
- Reading `lib/smalt/affidavit/wasm_engine_supervisor.ex`: the Owner's
  `def handle_info(_msg, state), do: {:noreply, state}` catch-all **swallows
  the supervisor's `{:EXIT, sup, :shutdown}`** whenever the owner state is
  not `{:owned, pid, …}` (e.g. `:idle`/`:passive`/`:restarting`) — the owner
  never exits, so the supervisor waits. (For `{:owned,…}` the EXIT clause is
  pid-guarded to the engine, so the supervisor's EXIT also falls through.)
  The bandit hang is a separate face needing its own stack capture
  (`:sys.get_state` on the ThousandIsland listener during shutdown).
- A clean stop poll (fresh container, stop, 120×1 s poll):
  `BEAM_STILL_ALIVE_120s` — deterministic, not load.

This is the AZB-13 falsifier face ("zombie beam across cycles") witnessed by
the AZB-22 ring; repair belongs to the planes/affidavit lane (the Owner
catch-all clause is a two-line fix candidate; the Bandit listener shutdown
face needs a separate falsifier run).

## Accept status (honest)

- `just burn-ring` exit 0: **NOT met — RED at boot stage** (typed
  ZOMBIE_BEAM, jidoka line-stop). Per the epic close condition, this receipt
  is the honest typed RED, not a faked pass.
- `validate_burn.py --gate` exit 0: gate machinery proven both ways (OK on
  the green chaos files and the prior 12-cycle CLEAN boot file at
  `29bb037…`; exit 1 DIRTY_ROW/MISSING_CELL/R_missing_consequence on the
  line-stopped boot file).
- summary passes `~/.zcode/dfcm/validate_receipt.py`: **blocked behind ring
  green** — the summary stage correctly refuses before minting anything
  while the ring is RED or the subject has moved (both witnessed).

## Deviations / disclosures

1. Deps AZB-18/19/20 receipts absent at ring time — proceeded on the
   coordinator's explicit directive ("deps landed: AZB-11 + AZB-12").
2. The `smalt-burn:latest` (test-target) rebuild was canceled mid-export by
   a session stall; the ring does not consume it (disclosed, not blocking).
3. Concurrency disclosure: another lane edited `burn-ring.sh` mid-run
   (added sibling-repo ro-mounts to `in_image`); the edit is compatible and
   was retained. A concurrent-edit while bash held the script open produced
   a transient `unexpected EOF` after the chaos stage completed — bash
   re-read the changed file mid-parse; rerun-proof, no data affected.
4. `docker/burn/compose.burn.yml` regenerated at N=8 (generated artifact;
   regenerate at 4 via `parallel-matrix.sh --emit-compose 4` if the AZB-02
   default is wanted back).
5. No git operations; ring evidence committed by the coordinator per the
   lane contract.
