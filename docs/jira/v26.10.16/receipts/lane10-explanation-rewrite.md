# Lane 10 — explanation rewrite (why-docs, receipt-anchored)

- Standing: **ALIVE** (gate exit 0 witnessed below)
- Window: v26.10.16, 2026-10-16
- Gate spec: `docs/jira/v26.10.16/DOCS-INVENTORY.md` (lane 6, landed
  mid-lane; this lane polled and proceeded once it landed)
- Scope: `docs/explanation/` only (+ one receipt pointer edit); no
  moves, no shared-file edits (12-docs-dod.just untouched).

## What landed

Five new why-docs, each receipt-anchored:

1. `docs/explanation/emulation-stance.md` — 80/20 stance, KD register
   as honesty mechanism. Anchors: KNOWN_DIVERGENCES.md,
   docs/reference/kd-register.md, WIRE_PARITY.md,
   cap-cosmos-throughput / r153 / r163 census receipts.
2. `docs/explanation/two-green-court-law.md` — two-run court law,
   post-mortem-as-evidence. Anchors: r216-court-x2-run8-red.md,
   r216-court-x2-run12-red.md (shifting-failure diff = flake detector),
   r35-court-x2-judge-log.md, FINAL.md standing line.
3. `docs/explanation/ggen-projection-law.md` — replay-identity
   admissibility, single pack identity, athena-matter-pack precedent.
   Anchors: semantic-kernel-roadmap.md, canonical-projection.md,
   r08 drift gate, r36 bench fail-closed, pack paths (external,
   verified on disk).
4. `docs/explanation/chatman-invariant.md` — seal path + invariant
   gates + SPC bands. Anchors: cap-affidavit-wasm.md,
   r215-affidavit-seal-court.md, gates/, config/bands.yaml,
   spc-bands.md, nfr4-identity-proof.md.
5. `docs/explanation/docs-from-first-principles.md` — the method;
   derivation = DOCS-INVENTORY.md + docs-restructure-plan.md.

Existing docs already in the anchored register, kept with one
addition: `two-tier-enclave.md` See Also extended with the T5
cleanroom receipt trio (receipts/t5-cleanroom-validation.md,
sdk-results/t5-cleanroom.md, sdk-results/native-lifecycle.md).

Archive disposition: scanned all of docs/explanation/ for genuinely
misfiled reference material — none found (reference material already
lives in docs/reference/: arm-gateway, egress-data-plane, ets-tables,
just-recipes, kd-register, ports-and-planes,
reference-affidavit-wasm). Zero moves; no archive churn.

## Path verification

Every path cited in the new/edited docs was checked for existence in
one shell loop before the gate run: zero MISS lines (loop covered 41
repo paths + 2 external pack dirs; output: "check done").

## Gate

```
$ just docs-dod-check
OK    docs/jira/v26.10.14/receipts/ws-12-e2e.md
... (51 OK lines, 0 MISS)
OK    README.md
EXIT=0
```

Full 51/51 OK listing in the session log; final line `EXIT=0`.
docs-dod-check exits 0 with the five new explanation docs' citations
resolving (their pins are not yet in justfile.d/12-docs-dod.just —
pin additions belong to the docs-dod lane per the restructure plan §3;
this lane did not edit the shared recipe).
