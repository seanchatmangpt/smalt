# KD-193 Engine-Owner Verdict — sh:closed OOV admission on the real graphlaw engine

Standing: PASS

## Ruling

CORRECT-SEMANTICS. The pinned graphlaw wasm engine evaluates `sh:closed`
per-node, driven by each shape's `sh:targetClass`: it fires on the node whose
shape governs it and never transfers one shape's closed property set onto a
different subject. The KD-193 finding was a mis-read of node subjects plus
the L9 heredoc corruption channel — not an engine defect.

## Subject identity

- Engine artifact: `/Users/sac/ash_graphlaw/priv/graphlaw/graphlaw.wasm`,
  sha256 `34fd4ada7ffe57f3f07de14232f8faacab67ef78a4d9afc3a12e79d78f865d08`,
  byte-identical to `priv/graphlaw/MANIFEST.json` `artifact.sha256` (pin
  verified this session).
- Wrapper: `AshGraphLaw.Capability.Shacl.run/2` (ggen-generated wrapper in
  `/Users/sac/ash_graphlaw/lib/ash_graphlaw/capability/shacl.ex`), executed
  from `/Users/sac/smalt` via the smalt `_build/dev` dep beams for
  `:ash_graphlaw` with `ASH_GRAPHLAW_PATH=/Users/sac/ash_graphlaw` (the
  canonical checkout; no writes to either repo's lib/).
- Probe scripts: `/tmp/kd193_probe2.exs`, `/tmp/kd193_detail.exs`;
  case files `/tmp/kd193_cases/*.ttl` (column-0 Turtle). Real engine run
  2026-11-04.

## Probe output (real engine, real output)

```
A_conforming => ADMIT
B_oov_on_frame => REFUSE ? | ? | ?
C_oov_on_source => REFUSE ? | ? | ?
D_frame_only_oov => REFUSE ? | ? | ? ;; ? | ? | ?
E_frame_only_conforming => REFUSE ? | ? | ?
```

Violation carriers from the detail run (`/tmp/kd193_detail.exs` output):

- B: `ClosedConstraintComponent`, shape `prov:StreamFrameShape`,
  focus `<https://smalt.example/frame/3>`, path `<https://e/unmodeled>`,
  value `"42"^^xsd:integer`.
- C: `ClosedConstraintComponent`, shape `cimi:StreamSourceShape`,
  focus `<https://smalt.example/stream/eh-1>`, path `<https://e/unmodeled>`.
- E: `ClassConstraintComponent`, shape bnode under
  `prov:StreamFrameShape`, path `prov:used`, value `<.../stream/eh-1>`
  (dangling reference refuses independent of sh:closed).

## Case table

| case | document | verdict | violation carrier |
|---|---|---|---|
| A | conforming (typed source + frame) | ADMIT | — |
| B | OOV predicate on the FRAME node, source block present | REFUSE | ClosedConstraintComponent @ prov:StreamFrameShape (focus = frame) |
| C | conforming frame + OOV on the SOURCE node | REFUSE | ClosedConstraintComponent @ cimi:StreamSourceShape (focus = source) |
| D | OOV on frame, frame-only doc | REFUSE | 2 violations: ClosedConstraintComponent @ StreamFrameShape + ClassConstraintComponent @ prov:used |
| E | conforming frame, frame-only doc | REFUSE | ClassConstraintComponent @ prov:used (dangling <stream> ref) |

## Interpretation

1. The engine's closed-set application is per-node: B fires on the frame,
   C fires on the source using the source's OWN closed set, and neither
   shape's property set transfers to the other subject.
2. The L9-witnessed "admits-when-source-present" outcome is NOT
   reproducible on the pinned engine with clean column-0 Turtle: the exact
   doc class (OOV-on-frame + typed source, = case B) REFUSES with the OOV
   refusal carried by ClosedConstraintComponent on the frame's own shape.
3. The L9 variants (`oov-end`/`oov`) are consistent with the KD-193 row's
   own theory: an indented/corrupted heredoc lost the frame's
   `a prov:Activity` type declaration, so StreamFrameShape
   (targetClass prov:Activity) never targeted the frame node and no closed
   violation can lawfully fire. A missing type declaration is a data defect,
   not an engine defect.
4. D/E additionally prove the engine evaluates the prov:used sh:class
   constraint on the referenced node (frame-only docs refuse even when the
   frame itself conforms), so the earlier frame-only refusals were NOT
   tautologically carried by sh:closed alone — the class constraint on the
   dangling reference is an independent refusal carrier.

## Verification ladder / non-vacuity

- A ADMITs while B/C/D/E refuse in the SAME run — the admit/refuse flip is
  witnessed in one execution, so the harness is not a vacuous
  refuse-everything harness.
- The fixed G2 court test 5
  (`test/integration/graphlaw_canonical_shapes_court_test.exs`,
  OOV-on-frame + typed source, asserting a ClosedConstraintComponent-only
  violation list) is consistent with probe B; L9's 33-passed run includes
  the fixed court.

## Disposition

CORRECT-SEMANTICS. No engine file:line defect exists to name (the engine is
a wasm artifact pinned by digest; the Elixir wrapper is ggen-generated).
KD-193 closes as a mis-read of node subjects plus the heredoc corruption
channel. The KD-193 row flips to CLOSED-WITH-EVIDENCE, close condition
met by this receipt.
