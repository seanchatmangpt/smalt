# Gap 09 — Court/Gate Coverage Matrix (POSHT wave v26.10.30)

Lane 9 of 12, read-mostly. Scope: every court/gate that exists across smalt
and posh, what it claims to protect (mapped to `dfcharter/verify.md` rungs
and `dfcharter/andon.md` gates: BUILD/TEST/LINT/INVARIANT), and the gap
class: `gate-missing` / `vacuity-missing` / `run-missing`.

Evidence style: every status is re-read from disk this session
(2026-10-30). Paths are smalt-root relative; smalt root
`/Users/sac/smalt`.

## 1. What exists on disk (inventory)

### smalt composite court

- `just court` (justfile:220-221): `doctor test-offline tf-plan-smoke
  bench-check mutation-court census invariant-gates naming-sweep
  verification-gates` — exit 1 loudly if a leg is retired.
- `scripts/mutation_court.py` via `just mutation-court` — exit 0
  non-vacuous / 1 vacuous / 2 BLOCKED (justfile:152-156).
- `scripts/invariant_gates.py` via `just invariant-gates` — 6 fail-closed
  gates, fresh receipts `tmp/invariant-gates/*.json` (justfile:162-163).
- `scripts/naming_sweep.sh` via `just naming-sweep` (justfile:173).
- `justfile.d/18-shim-court.just` — `just shim-court <name>` reusable
  harness; ~50 court scripts under `scripts/shim_court/*_court.sh` with
  paired witnesses (`lib.sh` shim protocol: baseline→before→shim→after→
  restore byte-exact fail-closed). Sleep-gate non-vacuity:
  `justfile.d/29-sleep.just` (`sleep-gate-court`) + ext
  `33-sleep-gate-ext.just` (4 legs; TS/PY legs are loud TODOs).
- `justfile.d/57-tf-provider.just`: `provider-court-elixir` — Elixir
  spike court, self-declared "NOT the GA admission path"; `provider-court`
  is a DEPRECATED alias pointing at it. GA court is `posh-court`.
- `adapters/terraform-provider-smalt/scripts/provider_court.sh` — 8-stage
  provider court (build → tfrc → fmt/init/validate → plan → apply →
  falsifier STS + destroy + residue-0 → zero-drift re-plan → receipt
  `scripts/receipts/provider-court-2026-10-30.md`). Run-once receipt
  dated 2026-10-30. NOT re-runnable post-tombstone (corrected 2026-10-30,
  lane 50): the Elixir spike tree was archived to
  `tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz`,
  so `just provider-court-elixir` (justfile.d/57-tf-provider.just) now
  exits 4 loudly (`[TF-ARCHIVED]`, mix.exs absent) before the ladder
  starts — the run-once receipt stands, the court cannot flip again. A
  real re-runnable stub for 57 is landing with lane 51; until then treat
  this row as run-once receipt only, spike not GA.

### POSH (Go membrane + Go provider)

- `justfile.d/58-posh.just`: `posh-court` — pre-stage (kind
  boot/health/build/install) + 8 counted stages: 1 vet, 2 alloc-test
  (-race), 3 go vet over provider, 4 fence (egress+config -race), 5
  smalt-wire (STS mint + wire asserts + X-Smalt-Receipt-Turnstile header
  assert), 6 tf apply, 7 zero-drift (plan -detailed-exitcode==0 →
  destroy → residue GETs), 8 mutation non-vacuity (`go test -run
  'TestHTTPEnvelopeOverTCPListener|TestVerifyTurnstile'`). Typed exits
  0/1/3, `[POSH-*]` lines. Standalones: posh-vet / posh-alloc-test /
  posh-build / posh-fence-test / posh-smalt-wire / posh-install.
- `scripts/posh_mutation_court.py` (`just posh-mutation-court`) — POSH-006
  non-vacuity: positive fixtures pass, tampered receipt/invalid frame
  length refused; exit 0/1.
- `scripts/posh_coverage.py` (`just posh-coverage`) — coverage compiler
  deriving provider surface inventory, asserting zero silent gaps
  (POSH-009); flip receipts `receipts/parity/posh009-*.json`.
- Andon driver: `posh/internal/andon/` (machine.go, state.go,
  receipt.go, andon_test.go) + `posh/cmd/andon/main.go` +
  `just posh-andon` (help only) + `just posh-doctor`/`posh-doctor-fix`
  (Autonomous System Physician, TPS Andon + 5-Whys).
- Go provider live tests: `adapters/terraform-provider-smalt/internal/
  provider/live_test.go`, `live_f4_test.go` — guarded by
  `TFPOSHT_LIVE=1`, real collaborators, real state assertions.
- Elixir provider courts: `test/` integration courts on the BEAM spike
  (via 57-tf-provider.just); archived spike path, superseded by the Go
  court (58).

### Claims with no gate (design-only claims)

- `dfcharter/verify.md` §3 posh-court 8-stage table (substrate/binary/
  fmt-validate/plan/apply/residue/drift/receipt) — the on-disk
  `posh-court` implements a *different* 8 stages (vet/alloc-test/
  static/fence/wire/apply/drift+residue/mutation). Stage table in the
  charter is a claim with no matching gate.
- DPMO 500-run campaign (verify.md §6), MSA, SPC control plan
  (verify.md §7) — verify.md status line says PLANNED; no script, no
  receipt ledger.
- SHACL negative courts: `ggen-marketplace/packs/posh/shapes/ingress.ttl`
  exists; no consumer found (grep over posh/, scripts/, justfile.d/
  returns only unrelated hits) — shapes with no court that reads them.
- Andon receipts: andon.md §5 specifies `tmp/posh/andon.jsonl` JSONL
  receipts; the driver code exists but no recipe runs it against a real
  gate child and no `tmp/posh/andon.jsonl` is produced by any court leg.
- `posh-doctor` (ASP) — recipe exists, no receipt found, not a court leg.

## 2. Coverage matrix

Columns: gate/court → what it claims to protect → andon/verify rung →
non-vacuity mutation → last receipt/standing.

| Gate / court | Claims to protect | Rung / andon gate | Non-vacuity mutation | Receipt evidence (re-read 2026-10-30) | Standing |
|---|---|---|---|---|---|
| `just court` composite (smalt) | whole-repo admission | full ladder | mutation-court + census | runs as one typed chain; legs individually receipted | PARTIAL_ALIVE |
| `just mutation-court` | 422/400 validator gate non-vacuous | INVARIANT | self (is the mutation court) | exit 0/1/2 convention | ALIVE |
| `just invariant-gates` (6 gates) | fail-closed invariants, fresh receipts | INVARIANT | not proven per-gate | `tmp/invariant-gates/*.json` fresh per run | PARTIAL_ALIVE |
| `just naming-sweep` | tracked-file pattern law | LINT-class | no mutation proving it flips | — | PARTIAL_ALIVE |
| `just sleep-gate` + `sleep-gate-court` | no unclassified sleep | TEST discipline | 4-leg court incl. VACUOUS-GATE self-check | TS/PY legs missing (loud TODO, 33-sleep-gate-ext.just:19) | ALIVE (4 legs) |
| `just shim-court <name>` + ~50 scripts | per-defect non-vacuity | TEST/INVARIANT | self (is the protocol) | receipts via `just receipts` | ALIVE |
| `provider-court-elixir` (57) | Elixir spike provider E2E | E2E (spike) | none — no mutation leg | receipt `provider-court-2026-10-30.md`, run-once | ARCHIVED-SPIKE, run-missing |
| `posh-court` (58) | GA admission ladder, POSH-006 | E2E ladder | stage 8 mutation legs (tamper-reject) | `receipts/posh-court/posh-court-green.json` standing FAIL 0/8 (kind disk preflight), attempts=2 | PARTIAL_ALIVE (never exited 0 witnessed) |
| `posh-mutation-court` | POSH-006 gate non-vacuity | INVARIANT | self | `receipts/mutation/turnstile-flip.json` | ALIVE |
| `posh-coverage` | zero silent provider divergences (POSH-009) | INVARIANT | flip receipts `posh009-coverage-gate-flip.json` | green + flip receipts on disk | ALIVE |
| andon driver (`posh/internal/andon`) | GREEN/YELLOW/RED + N=2 hysteresis, latch | all gates (composite) | andon_test.go (unit) | no JSONL receipt produced by any recipe | PARTIAL_ALIVE (code ALIVE, wiring run-missing) |
| Go provider TFPOSHT_LIVE tests | live provider resource lifecycle | E2E | real collaborators (not a mutation) | env-guarded; run on demand only | PARTIAL_ALIVE (run-missing: no recipe wraps TFPOSHT_LIVE=1) |
| Elixir provider courts (test/) | spike provider behavior | Unit/Integration | conventional tests | superseded; GA path is 58 | ARCHIVED |
| SLA timeouts (andon.md §4: 60/40/10/5s) | gate cannot hang past SLA | all gates | §6 SLA control mutation specified | no runner code implementing SLA clocks | gate-missing |
| SHACL negative courts (ingress.ttl shapes) | route graph well-formedness | INVARIANT | specified (orphan route flip) | shapes on disk, zero consumers | gate-missing |
| DPMO 500-run campaign (verify.md §6) | 6σ-compile tollgate | Tollgate | n/a (is itself a falsifier corpus) | verify.md status: PLANNED; no ledger | claim-with-no-gate |
| MSA / SPC control plan (verify.md §7) | post-tollgate control | Control plan | n/a | PLANNED | claim-with-no-gate |
| verify.md §3 stage table (substrate/binary/fmt/plan/apply/residue/drift/receipt) | charter court spec | E2E | specified per stage (§5) | on-disk posh-court implements different 8 stages | drift: claim ≠ gate |

## 3. Gaps (typed)

### gate-missing

- G1. **SLA clocks are prose.** andon.md §4 requires `timeout <sla>` on
  every gate child plus the §6 SLA control mutation; no runner
  implements it. Close: a posh gate runner that sets per-toolchain
  timeouts and emits `outcome:"timeout"` receipts; mutation = insert
  `sleep(999)` into a driver → timeout RED.
- G2. **SHACL shapes with no court.** `packs/posh/shapes/ingress.ttl`
  has no consumer. Close: SPARQL/SHACL gate driver under
  `invariant_gates.py` contract reading the shapes, plus the §5 orphan
  route mutation flipping it.
- G3. **Andon composite is not wired.** The driver
  (`posh/internal/andon`) implements the state machine (GREEN/YELLOW/
  RED, latch, N=2) and has unit tests but no recipe executes it over
  real gate children or writes `tmp/posh/andon.jsonl`. Close:
  `posh-court` (or a `posh-gates` recipe) drives the four gates through
  the andon driver and appends JSONL receipts; falsifier = register a
  gate without an SLA clock → runner refuses exit 2.
- G4. **verify.md §3 stage table vs on-disk court drift.** The charter
  court spec (substrate/binary/fmt/plan/apply/residue/drift/receipt)
  does not match the implemented 8 stages. Close: amend verify.md §3 to
  name the implemented stages, or add the missing stages (fmt/validate
  is covered by posh-vet; "receipt stage" as specified does not exist in
  58-posh.just).

### vacuity-missing

- V1. **invariant-gates have no per-gate mutation legs.** 6 gates run
  fail-closed with fresh receipts, but no court proves each flips. Close:
  shim-court leg per gate (orphan-node fixture flips the SPARQL gate).
- V1b. **naming-sweep has no mutation court.** Close: insert a pattern
  hit into a fixture tree; sweep must REFUSE; restore byte-exact.
- V2. **sleep-gate TS/PY legs.** `33-sleep-gate-ext.just:19` — existing
  4-leg court covers 4 languages; TS/PY shim-court legs do not exist
  (loud TODO). Close: land the two legs or keep the loud refusal.
- V3. **provider-court-elixir has no non-vacuity leg.** Close: accept as
  archived spike (no close) or add a drift/residue mutation leg.

### run-missing

- R1. **posh-court has never exited 0.** Standing receipt
  `receipts/posh-court/posh-court-green.json` = FAIL 0/8, root cause
  kind node disk preflight (host /var/lib/containerd pressure). Close:
  `just kind-prune` / host disk remediation, then a witnessed
  `just posh-court` exit 0 receipt. This is the single highest-value
  run: it gates E2E standing for the whole POSH ladder.
- R2. **TFPOSHT_LIVE tests have no recipe and no receipt.** Close:
  `just posh-live` recipe wrapping `TFPOSHT_LIVE=1 go test ./internal/
  provider/...` against the kind substrate, receipt under
  `receipts/posh-court/`.
- R3. **Andon JSONL receipts never produced.** Close: subsumed by G3.
- R4. **500-run DPMO campaign, MSA, SPC — PLANNED.** verify.md declares
  these; no ledger exists. Close per verify.md: 500 stratified runs,
  probe-receipt ledger, DPMO 0.00 + C_pk ≥ 2.00, then hand-off. Not a
  defect — a declared-planned tollgate; do not let it silently read as
  done.

## 4. Status line

- smalt court infrastructure (`just court` legs, shim-courts,
  mutation-court, sleep-gate): **ALIVE** — recipes and courts on disk,
  receipts current, non-vacuity protocol enforced.
- posh court ladder (`posh-court` 8 stages): **PARTIAL_ALIVE** — code
  and typed exits on disk; standing receipt is FAIL 0/8 (kind disk
  preflight); never witnessed exit 0.
- posh auxiliary courts (posh-mutation-court, posh-coverage): **ALIVE**
  — flip receipts on disk.
- andon driver: **PARTIAL_ALIVE** — code + unit tests ALIVE, pipeline
  wiring and JSONL receipts run-missing.
- SLA clocks, SHACL ingress gate, DPMO/MSA/SPC campaign: **BLOCKED /
  PLANNED** — claims without gates or runs.
