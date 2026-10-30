# Verify (DfLSS Phase 5)

Parent: charter-master.md (POSH v26.10.30). Goal: validate performance,
execute the verification ladder, operationalize the Andon Signal Protocol.
Tollgate: measured 0 DPMO across 500 qualification runs; formal sign-off.

## 1. Verification Ladder Mapped to CTQs

Cheapest high-information rung first. Every rung names its exact command,
expected exit, and the CTQ (charter §3) it proves. A rung that exits other
than its expected code is a failure of that CTQ — re-derive, never re-run
without a new hypothesis.

### Ladder table

| Rung | Command | Exit |
|---|---|---|
| Unit | `mix test test/posh/unit --trace` | 0 |
| Unit kernel | `cargo test -p posh-blake3-kernel --features std` | 0 |
| Integration | `mix test test/posh/integration` | 0 |
| Lint | `just posh-lint` (credo, golangci-lint, clippy) | 0 |
| Invariant | `just posh-invariants` (SPARQL ingress/ + egress/) | 0 |
| E2E | `just posh-court` (kind @ 127.0.0.1:9443) | 0 |
| Chaos | `just posh-chaos` (sink kill mid-burst, netem) | 0 |
| Stress | `just posh-stress` (burst, 10 min sustained) | 0 |
| Benchmark | `just posh-bench` (Benchee + criterion) | 0 |
| Report | `just posh-court && just posh-report` | 0 |

### Rung → CTQ mapping

- **Unit (BEAM)**: Receipt Non-Repudiation — BLAKE3 32-byte token on
  every state transition; SPAF boundary types hold per module (Go/BEAM/
  Rust invariants, charter §2).
- **Unit (kernel)**: Receipt Non-Repudiation — SIMD quarter-round
  correctness against reference vectors.
- **Integration**: Intake Ingress Jitter groundwork — SPSC ring + Starboard
  fail-closed NVMe spool state; Zero-PHI shape of Gold egress records.
- **Lint/Static**: Schema Parity — AST diff of HCL attributes vs generated
  provider schema (charter FMEA row 2 Poka-Yoke).
- **Invariant**: Schema Parity — 100% of routes terminate in turnstiles,
  0 orphan nodes, no missing receipt rule.
- **E2E**: Schema Parity & CLI Compatibility — dev_overrides exit 0;
  receipt committed per transition across the full membrane.
- **Chaos**: Intake Jitter < 10 µs and frame drop 0.000% with the egress
  sink down; Starboard fails closed to local spool.
- **Stress**: Max GC pause p99.99 ≤ 1.0 ms; zero refc binary duplication.
- **Benchmark**: 75% CPU-per-message reduction vs symmetric baseline
  (charter §1.2), against MEASURE-phase baseline numbers.
- **Machine report**: all of the above rendered as a machine-readable
  court verdict; probe receipts are the register of truth.

Ladder invariant: no rung is skipped silently. A degraded environment
makes the skip LOUD (`[SKIP] <reason>` in the court report), never a pass.

## 2. Chicago-School State-Based Integration Suite

Real collaborators only — real ring buffer, real kind API, real NVMe
spool path, real BLAKE3 kernel. No `unittest.mock`/`Mock()`/`patch`/
mockall; a hand-written real interface implementation is not a mock.

Design rules:

- Assert final observable state, never call counts. After a burst of N
  frames with the egress sink stopped: assert the spool holds exactly N
  receipts with valid BLAKE3 digests and zero lost frames — not "the
  sink client was called K times".
- One named double exception: the downstream cloud sink cannot run in
  process; use a real local HTTP fixture on a loopback port (simple
  fake, stated here), not an interaction-recording mock.
- Structural sync over sleeps: ring state owned by the producing
  GenServer is asserted via `GenServer.call`; async convergence via
  bounded polls on observables (`SmaltTest.AssertEventually`).
  Zero `Process.sleep` in test/ — enforced by `just sleep-gate` with
  `just sleep-gate-court` non-vacuity.
- Coverage bar per Andon TEST gate: GREEN ≥ 85% branch, YELLOW
  80–84.9%, RED < 80% or any failure.

Suites (`test/posh/integration/`):

- `port_in_backpressure_test.exs`: fill the ring to capacity with the
  sink stopped; assert drop rate 0.000% and spool occupancy equals
  frames offered.
- `starboard_settlement_test.exs`: settle K transactions; assert each
  carries a 32-byte receipt verifying against the Merkle root.
- `phi_harbor_test.exs`: run Gold egress against the HIPAA Safe Harbor
  field list; assert 0 matches across all emitted records.
- `spaf_boundary_test.exs`: cross-tier contract — BEAM never hashes on
  its heap (kernel-issued receipts only); the Go shim holds zero
  persisted state between plugin sessions (provider state dir empty
  after teardown).

## 3. Cleanroom Execution on kind: `just posh-court`

> SUPERSEDED 2026-10-30 by `justfile.d/58-posh.just` (`posh-court`): the
> original stage table (substrate/binary/fmt/plan/apply/residue/drift/
> receipt, spec'd against `terraform-provider-smalt/scripts/provider_court.sh`,
> the archived Elixir spike) drifted from what was implemented. Original
> intent — an 8-stage fail-closed cleanroom ladder on the kind substrate at
> `http://127.0.0.1:9443`, any stage failure halting the ladder, composite
> Andon signal = MAX(stage signals) per charter §6 — is preserved below.

The IMPLEMENTED ladder (`just posh-court`, justfile.d/58-posh.just; GAP9
G4 close) is 8 counted stages plus an uncounted load-bearing pre-stage,
exit contract 0 green / 1 FAIL / 3 SKIP with typed `[POSH-*]` lines:

| Stage | Runs | GREEN | SKIP (exit 3) | RED (exit 1) |
|---|---|---|---|---|
| pre (uncounted) | kind boot (`kind-up`/`kind-images`/`kind-deploy`), bounded 60x1s poll on the metadata anchor (9443), `posh-build` + `posh-install` (transient dev_overrides rc) | all green | — | any pre-stage leg fails |
| 1 vet | `golangci-lint run ./...` over posh/ + provider dir | 0 findings | golangci-lint or a `.golangci.yml` missing | findings |
| 2 alloc-test | `go test -race ./...` over posh/ | 0 | — | test failure |
| 3 static | `go vet ./...` over provider dir | 0 | — | vet failure |
| 4 fence | `go test -race ./internal/egress/... ./internal/config/...` | 0 | — | test failure |
| 5 smalt-wire | STS bearer mint + resourcegroup/containerApps wire asserts + `X-Smalt-Receipt-Turnstile` header assert | all asserts pass | substrate not answering | assert fails |
| 6 tf apply | `terraform init && apply -auto-approve` on the byte-identical example root | exit 0 | example root not landed (stage 7 co-skips) | apply failure |
| 7 zero-drift | `plan -detailed-exitcode` (0 required pre-destroy) → `destroy` → STS-minted residue GETs (resourcegroups + containerApps must be empty) | plan 0, zero residue | — | drift (exit 2), destroy failure, or any residue |
| 8 mutation non-vacuity | `go test -race -run 'TestHTTPEnvelopeOverTCPListener\|TestVerifyTurnstile' ./internal/server/ ./internal/receipt/` | tamper-reject legs green | — | receipt verification regressed |

Andon mapping: the original per-stage gate mapping (stages → BUILD/
LINT/INVARIANT/receipt gates) is superseded with the table; the
implemented ladder reports typed `[POSH-COURT-N] PASS/SKIP/FAIL` lines
and tallies `$pass/8 PASS, $skip SKIP, $fail FAIL`. The Andon driver
(`posh/internal/andon`) is implemented but not yet wired as a court
stage — see `gaps/09-courts-matrix.md` G3.

## 4. Zero-Drift Verification + Residue Falsifier

Procedure after destroy:

1. `terraform plan -detailed-exitcode -out /tmp/posh_drift.tfplan`
2. Require exit code **0** (no diff, no drift). Exit 1 = error (RED).
   Exit 2 = drift detected — real infrastructure state does not match
   config (RED, INVARIANT gate). Never interpret exit 2 as success.
3. Residue falsifier: with credentials minted fresh via STS (never the
   apply-role credentials — proves no residual access path is being
   misread), GET every namespace the apply wrote. Expected: empty /
   404-class. Any surviving object is residue → RED; the destroy was
   not a lawful cleanup transition.
4. Both results append to the stage-8 court receipt; a receipt without
   the residue GET transcript fails receipt validation.

## 5. Non-Vacuity Mutations (Shim-Court Protocol)

A court that cannot flip is FAIL; a skip is loud. Run via `with_shim`:
BASELINE (sha256) → BEFORE (old outcome) → SHIM (marked `SHIM-COURT`) →
AFTER (new outcome) → RESTORE (byte-exact sha256, fail-closed). For
each gate, the injected defect that MUST flip it:

- **BUILD**: inject a compile error in one module → RED (exit ≠ 0).
- **BUILD warning band**: introduce only a compiler warning → YELLOW,
  not halt.
- **TEST**: delete one Chicago assertion so a test passes vacuously →
  RED via coverage drop or census detects the weakened assert.
- **LINT**: introduce a critical clippy/credo error → RED.
- **INVARIANT**: orphan one route in the .ttl (remove its turnstile
  terminal) → SPARQL invariant query returns the orphan → RED.
- **INVARIANT**: delete a receipt rule from the egress/ graph → RED.
- **Court stage 7**: mutate applied infra out-of-band (patch a kind
  resource) → zero-drift plan exits 2 → RED.
- **Court stage 6**: leave one object behind on the destroy path →
  residue GET non-empty → RED.
- **Court stage 1**: stop the kind port-forward → substrate poll fails,
  ladder halts fail-closed → RED.
- **Sleep gate**: insert an unclassified `Process.sleep` in test/ →
  `just sleep-gate` REFUSES; a gate that accepts it exits 1 as
  VACUOUS GATE.
- **Receipt**: drop one of the 5 receipt fields → validation fails,
  stage 8 RED.

Self-check: the harness corrupts a restore on a real temp copy to prove
restore-detection is not vacuous. `[SKIP] <reason>` lines are counted
in the machine report; an unmotivated skip fails the report.

## 6. 500-Run Qualification Campaign (0 DPMO at Compile Turnstile)

Target (charter §7): 0 defects at the compile-time turnstile —
DPMO 0.00, C_pk ≥ 2.00.

- Opportunity model: O = R × 4 per unit (Syntax, Authentication,
  Transformation, Cryptographic Proof), per charter §7.
- Subject: the compile turnstile — `mix compile` + `go build` +
  `cargo build --no-std` + the AST parity diff — across the generated
  topology corpus.
- Sampling: R = 500 units, stratified:
  - 200 canonical topology regenerations,
  - 150 mutated but valid .ttl graphs,
  - 100 replays of previously-refuted topologies,
  - 50 randomized attribute-order/schema permutations.
  Every run synthesizes fresh; no run reuses a prior artifact.
- Pass criterion: D_total = 0 across 500 × 4 = 2000 defect
  opportunities → DPMO = 0.00; C_pk computed from per-run turnstile
  duration and defect counts against charter targets.
- A single compile defect: D_total = 1 → DPMO = (1 / 2000) × 1e6 =
  **500 DPMO**. The 6σ-compile claim is falsified, the tollgate
  verdict is not 0 DPMO, sign-off is blocked. Fix forward, then re-run
  the full campaign — no partial re-credit for the 499 passing runs.
- Every run appends a probe receipt; the tally is re-read from the
  receipt ledger at sign-off time, never from memory.

## 7. Control Plan Hand-Off

SPC charts (post-tollgate, ongoing):

- Compile turnstile defect count: p/np-chart, target 0; any single
  defect = special-cause signal → stop-the-line (Andon RED).
- Gate SLAs (Build < 60 s, Test < 40 s, Lint < 10 s, Invariant < 5 s):
  X-bar/R per gate; Western Electric rule 1 (1 point beyond 3σ) or
  rule 2 (2 of 3 beyond 2σ, same side) = out-of-control signal.
- Runtime CTQs (jitter, GC p99.99, drop rate): I-MR charts against the
  LSL/USL in charter §3.

Reaction plan (react → assess → contain → diagnose → correct → verify):

| Signal | Reaction | Fix verified by | Owner |
|---|---|---|---|
| Compile defect | HALT, quarantine output | 500-run re-run, DPMO 0.00 | Quality Lead (A/R) |
| Gate SLA drift | YELLOW; RED on 2nd | 20-run window in control | BEAM Eng (R) |
| Zero-drift exit 2 | HALT deploy; reconcile | plan exit 0, residue empty | Go Spec (R), Arch (A) |
| Residue found | HALT; destroy not lawful | STS GET empty | Quality Lead (A/R) |
| Runtime CTQ breach | HALT shift, revert to GREEN | chaos + stress GREEN | BEAM Eng (R), Arch (A) |
| Vacuous gate | exit 1, court retracted | shim flips, restore exact | Quality Lead (A/R) |

Ownership (charter §8): Andon Gates & DfLSS Verification — A/R = Quality/
Compliance Lead; Final Tollgate Sign-Off — R = Quality Lead, A = Project
Sponsor. The control plan transfers to that owner at tollgate; SPC charts
render in `just posh-report` output from that point forward.

## Status

PLANNED — doc authored this session; rungs, court, and campaign not yet
executed on a live kind substrate. ALIVE requires `just posh-court`
exit 0 plus the 500-run receipt ledger on disk.
