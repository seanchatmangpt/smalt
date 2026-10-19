# Receipt: v26.10.19 envelope lane — container-boundary gate wiring skeleton

Standing: SUSPECT (skeleton — gate script and court owned by the container-gate
lane; this receipt covers only the recipe wiring in the shared module)

- **Subject**: `envelope-container` / `@container-gate` /
  `@container-gate-self-test` recipes in `justfile.d/35-envelope.just`
- **Authority**: AZB-24 envelope WO (v26.10.19 window)
- **Executed** (imported-context simulation, repo-root import of the module):
  - `just -n container-gate` renders
    `python3 /Users/sac/smalt/scripts/envelope/container_gate.py` (correct root)
  - `just container-gate` → exit 1: static REFUSE — final-stage package
    install in `docker/Dockerfile.hermetic` (line 101, apk add without
    strip); runtime mode loud-skipped (no `smalt:hermetic` image)
  - `python3 scripts/envelope/container_gate.py --self-test` → exit 0
- **Open**: hermetic final-stage install fix; hermetic image build (Phase 2);
  container shim court; final embed of raw output.
