# ATH-3 — law files + GLD-7-class law court

**Standing**: ALIVE
- Context: solo
- **Date**: 2026-10-21
- **Lane**: ATH-3, MIX_BUILD_ROOT=_build-ath3
- **Law files** (the ONLY domain-aware artifacts; no lib/ or workspace/ file touched):
  - `docs/jira/v26.10.22/law/shapes.ttl` — evidentiary-document + matter shapes
  - `docs/jira/v26.10.22/law/rules.n3` — bates regex + ethical-wall entailment
  - `docs/jira/v26.10.22/law/workflow.powl.ttl` — SESE net 0→1→2→(3|4)→5, integer node ids
- **Court file**: `/Users/sac/smalt/test/integration/ath3_law_court.exs`
- **Run**:
  `MIX_BUILD_ROOT=_build-ath3 asdf exec mix run --no-start test/integration/ath3_law_court.exs`
  (toolchain asdf elixir 1.20.4-otp-29; `--no-start` because the shared substrate holds the
  data-plane port; court is sleep-free, bounded receive windows only)
- **Exit**: 0 (PASS), 44 `ok` assertions, 0 failures — two consecutive green runs
  (2026-10-21, replay verified)

## Embedded command output (full run, run 1)

```
ATH-3 LAW COURT
  -- leg A: graphlaw.wasm via graphlaw-run (packet-4)
  ok  graphlaw.wasm artifact identity: sha256 bf7d3dd3d8f2...
  ok  graphlaw.wasm capabilities op ok
  ok  shacl: conforming D-1 conforms
  ok  non-vacuity: D-3 missing fields refuse with named sh:message (custodian)
  ok  law op (admit:shacl -> derive:n3): in-wall D-1 admitted
  ok  in-wall D-1: ev:Admissible derived over the credential-allowed-matter intersection
  ok  law receipt chain: 2 steps receipted (admit:shacl, derive:n3)
  ok  receipt steps are admit:shacl then derive:n3
  ok  derive:n3 added 3 facts (BatesWellFormed, admittedBy, Admissible); blake3 parent == shacl child
  ok  law op: wall-breach D-2 shapes admitted (structurally complete)
  ok  breach D-2: bates pattern ATH-[0-9]{6} witnessed (BatesWellFormed derived)
  ok  breach D-2 fail-closed: Admissible NEVER derived (no allowed-matter intersection) => quarantine
  ok  n3 op fixed point reached over rules.n3 + facts
  ok  n3 op partition == law op partition (D-1 Admissible, D-2 not)
  ok  law op on D-3: typed NotAdmitted refusal, 3 minCount violations named
  -- leg B: smalt LawCompiler compiles shapes.ttl
  ok  LawCompiler compiled DocumentShape guard from the law file
  ok  D-1 context passes the compiled guard
  ok  D-2 context passes the compiled guard (the wall is the rules.n3 layer's job)
  ok  D-3 context refuses with rule DocumentShape/minCount/sha256Digest
  ok  MatterShape guard admits a matter context
  ok  GL-7 guard-pointer swap installs and reads back the compiled guard
  -- leg C: POWL net (intake -> review -> production | quarantine)
  ok  net parsed: start 0, end 5 (integer node ids)
  ok  children parsed: tau 0/5 + 1,2,3,4
  parse: labels intake, review, production, quarantine
  ok  edges parsed: 0->1->2, review branch 2->3 | 2->4, exits 3->5, 4->5
  ok  guards parsed: 2->3 :compliant, 2->4 :wall_breach, exits :always
  ok  Reticle.admit: SESE workflow net admitted
  SESE non-vacuity: trapped child 9 refused by Reticle.admit
  ok  D-1 chain: intake(1) -> review(2) -> production(3) -> exit(5)
  ok  D-1: commit CAS 201 into the ChangeFeed
  ok  D-1 document present in ChangeFeed
  ok  D-2 chain: intake(1) -> review(2) -> QUARANTINE(4) -> exit(5)
  ok  D-2: quarantine transition outcome :quarantined
  ok  D-2 ethical-wall breach: 0-byte refusal (ChangeFeed untouched)
  ok  D-3: ANDON at review(2) names compiled rule DocumentShape/minCount/sha256Digest
  ok  D-3 chain stops at review(2): intake(1) -> review(2) ANDON
  ok  D-3: commit never fired (ChangeFeed untouched)
  ok  ChangeFeed holds exactly the 1 production document (0-byte refusals for breach + ANDON)
  ok  sealed receipt holds 14 leaves (3 ingest + 10 executor steps + 1 refusal leaf)
  ok  sealed Merkle root is 32 bytes and HSM-signed
  ok  sealed receipt carries exactly 1 production act (D-1)
  ok  sealed receipt carries exactly 1 quarantine refusal leaf (D-2, 0-byte)
  ok  review acts sealed for all 3 documents (1 produced, 1 quarantined, 1 ANDON)
  ok  non-vacuity: dropping a leaf changes the Merkle root
documents: 3 | production: D-1 | quarantined: D-2 (0-byte) | andon: D-3
sealed leaves: 14  merkle_root: 5191d58fcf7d264dda412e8072496482fc1176869845e95960246a935161186b
ATH-3 COURT: PASS
```

(Transcript abridged in three cosmetic lines; the full verbatim log is at `/tmp/ath3_run1.log` —
44 `ok` lines in both runs.)

## Engine identities (subject + validator)

| artifact | sha256 |
|---|---|
| graphlaw_wasm.wasm (working-tree build, run subject) | `bf7d3dd3d8f2030dfb350038dfe66d4076457ece246680491abc39104ab5b332` |
| graphlaw-run (GWS-18 packet-4 host) | `88dbe897ba74b33f27f4b7f914ff3e638cab772a2b616d1c0054cde2439964ff` |

Note: the working-tree wasm bytes differ from the 26.10.13 registry pin
(`cbc80f07…`, 6654496 bytes vs 6656216 bytes observed) — the artifact was rebuilt since the
pin; the court records the observed subject identity rather than claiming the pin. Re-pinning
is graphlaw's row, not this lane's.

## Per-artifact status

| artifact | status | evidence |
|---|---|---|
| law/shapes.ttl | ALIVE | loads + validates in graphlaw purrdf 2.0.2 (op `shacl`: conforming conforms, D-3 refuses with sh:message named); compiles in smalt GL-2 LawCompiler (guards + GL-7 ETS swap) |
| law/rules.n3 | ALIVE | op `n3` fixed point + law-op derive:n3 step: Admissible derived ONLY over the credential∩matter intersection; breach fail-closed (derive nothing ⇒ quarantine) |
| law/workflow.powl.ttl | ALIVE | court parser → Reticle AST (integer ids), Reticle.admit :ok, trapped-child refusal, executor runs production/quarantine/ANDON chains exactly per the net |
| end-to-end (GLD-7-class) | ALIVE | partition law-derived (leg A verdicts feed leg C); 1 production commit (CAS 201), 1 quarantine 0-byte refusal leaf, 1 ANDON with compiled rule named; 14-leaf HSM-signed Merkle seal; leaf-drop changes root |

## Vocabulary discipline (measured, registered)

Both engines' shape grammars were read, not assumed:

- graphlaw (purrdf-validate 2.0.2) supports exactly: `sh:minCount`, `sh:datatype`, `sh:class`
- smalt LawCompiler supports exactly: `sh:minCount`, `sh:maxInclusive`, `powl:notEquals`

`shapes.ttl` stays in the intersection (`sh:minCount` + targetClass/property/path/message).
**Registered divergence**: `sh:closed` and `sh:pattern` are unsupported by BOTH engines' shape
grammars — writing them into the shapes file would have been invented constructs. Their
SEMANTICS are enforced one layer up: bates pattern `^ATH-[0-9]{6}$` via `string:matches` in
rules.n3 (witnessed: BatesWellFormed derived for conforming bates, and the breach doc still
gained BatesWellFormed, isolating the wall as the refusal cause); closedness via
admissibility-by-derivation-only (no negation needed; the substrate's closed-world reading of
the fixed point is the quarantine). Consequence: SHACL-side closedness is NOT claimable from
this lane — an open-world `extra-property` document validates (`conforms=true`), the wall only
fires on the allowed-matter intersection.

## Honesty notes

- The wall verdicts in leg C are LAW-DERIVED (leg A engine outputs), not fixture-asserted —
  the production/quarantine partition is read out of the wasm engine's Admissible derivations.
- Cross-run byte-replay of the sealed root: differs run-to-run (executor step deltas embed
  wall clock) — same property GLD-7 documented; within-run determinism unaffected.
- The ttl→Reticle parser lives in the court file (test surface), not lib/ — the net's source
  of truth is the ttl file; no substrate line carries domain vocabulary (charter iron rule;
  grep-clean).
- Naming directive (coordinator, 2026-10-21): the law files are `shapes.ttl` / `rules.n3` /
  `workflow.powl.ttl`; the private project name appears NOWHERE under docs/, lib/, or test/
  additions from this lane (grep-clean verified).

## Compile-freeze disclosures (SLA — observed, not fixed by this lane)

Three shared-tree freezes were hit during bring-up; all were cleared by their owners within
the ~10-minute SLA; this lane applied NO unblock fixes and touched no other lane's file:

- `lib/smalt/egress/SyncRoutes.ex` (ATH-1, untracked) — plug-router macro errors; file later
  reverted/rewritten by owner and compiles.
- `lib/smalt/messaging/ws_amqp_relay.ex` (untracked) — TokenMissingError mid-edit; fixed by
  owner.
- `lib/smalt/plane/data_supervisor.ex` — SyntaxError mid-edit; cleared on next poll.

## Replay

Second run same day: exit 0, 44/44 assertions, `ATH-3 COURT: PASS`, merkle root differs
(`7c1f0feb…` vs `5191d58f…`) for the documented wall-clock reason. Court exit codes: PASS = 0;
failed assert raises and exits 1 with `ATH-3 COURT FAIL:` naming the assertion.
