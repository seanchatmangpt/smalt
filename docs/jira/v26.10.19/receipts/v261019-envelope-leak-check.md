# Receipt: v26.10.19 envelope lane — leak-check wiring receipt

Standing: SUSPECT (skeleton — leak_detector.sh owned by its landing lane; this
receipt covers only the `leak-check` recipe wiring)

- **Subject**: `leak-check` recipe in `justfile.d/35-envelope.just`
- **Authority**: AZB-24 envelope WO (v26.10.19 window)
- **Executed**:
  - pre-landing: typed SKIP exit 3 verified live —
    `[LEAK-CHECK] SKIP (typed 3) — scripts/leak_detector.sh not landed (PENDING)`
  - post-landing: `just leak-check` → exit 0
    (`scripts/leak_detector.sh` on disk and clean)
- **Open**: final embed of raw leak-check output at wrap.
