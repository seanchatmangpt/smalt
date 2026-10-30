# Andon Signal Protocol — POSH Operational Spec

Elaborates `charter-master.md` §6 (authoritative). The SLA matrix and the
composite MAX rule are fixed there; this spec adds state machines, halt
semantics, enforcement anchors, receipt schema, and falsifiers. It never
contradicts the charter.

## 1. Signal State Machine

Each gate is a two-variable machine: an **observed outcome** (from the gate
run) and a **published signal** (what the pipeline sees).

- `GREEN`: gate passed within SLA. Proceed.
- `YELLOW`: actionable-warning band. Proceed, but the signal carries
  forward: the composite is strict MAX over the ordered signals
  `GREEN < YELLOW < RED`, so one YELLOW anywhere demotes the composite to
  YELLOW, and a YELLOW composite blocks deploy-lane promotion (§2).
- `RED`: arrest. A RED composite halts the line instantly (§2).

### Transitions

```text
outcome pass, within SLA        : any state -> GREEN (publish)
outcome warn band, within SLA   : any state -> YELLOW (publish)
outcome fail/timeout, or arrest : any state -> RED (publish, latched)
no state change warranted       : hold current signal
```

### Latch and hysteresis (what demotes YELLOW back to GREEN)

RED is **latched** for the subject's lifetime. RED clears only via a
subsequent gate run over a **changed subject** (new content SHA for the
gate's input set). Rerunning the same subject that went RED cannot clear
it: rerun-after-RED on an unchanged SHA is itself a RED event of the same
failure class. This is the POSH anti-vacuity law — a gate clearable by
rerun is a gate that cannot fail.

YELLOW demotes back to GREEN only when all three hold:

1. **Changed subject**: new input SHA for the gate's input set.
2. **Full GREEN-band run**: outcome meets the pass criteria of §3.
3. **N=2 hysteresis**: 2 consecutive GREEN runs over *distinct* subject
   SHAs. A single GREEN over a new SHA does not demote; the signal holds
   YELLOW until the second distinct-SHA GREEN lands.

With N=2, one flaky GREEN cannot clear a warning band. RED never
hysteresis-demotes; it clears only via the changed-subject + full-GREEN
path above.

## 2. Halt-the-Line Semantics

Exactly what a RED arrests, by surface:

| Arrest surface | Trigger | Arrest action | Notified |
|---|---|---|---|
| Local build | Gate RED, dev time | Chain aborts; later recipes never run | Operator; receipt |
| CI pipeline | Gate RED in CI | Job fails; later stages unscheduled | PR author, branch owner |
| Deploy lane | Composite YELLOW/RED | Promotion refused, non-zero exit | Lane owner; receipt |
| Merge gate | Composite RED pre-merge | PR cannot merge (check-run fail) | PR author; receipt |

Scope law: an arrest is **lane-local**. A RED composite does not arrest
unrelated lanes on the same canonical checkout — isolation per the
same-checkout-fanout law.

Composite semantics (charter §6, verbatim constraint):

- Composite = `MAX(GREEN, YELLOW, RED, ...)` across the four gates.
- RED composite: HALT pipeline.
- YELLOW composite: proceed, signal carried on the receipt; deploy-lane
  promotion still refused.
- GREEN composite: PROCEED to deploy.

### Typed exit codes (smalt convention)

The composite publisher exits with exactly one of:

- `0` — composite GREEN, proceed.
- `1` — composite RED (or any RED), halt.
- `3` — loud-skip: the gate did not run. Always paired with a stdout line
  `[SKIP] <gate> <reason>` and a receipt line with `outcome:"skip"`.
  A skip is loud, never a faked pass (testing-chicago-style shim-court
  discipline).
- `2` — BLOCKED: infra failure or compile-abort. Follows the smalt
  `mutation-court` convention (`justfile:152`: exit 0 non-vacuous / 1
  vacuous / 2 BLOCKED).

Compile-abort classification law: a Test-gate compile abort is typed
`blocked` (exit 2), never counted as test failures — per the smalt census
law in `justfile.d/28-test-budget.just` (compile-abort ≠ failure count).
The Andon runner reads the census class and emits `blocked`, never `fail`.

## 3. Per-Gate Enforcement Mechanics

### Build Gate — SLA < 60 s

- `mix compile --warnings-as-errors` — Elixir. Warning-band demotes to
  YELLOW per charter ("Compiler warnings present" = YELLOW); errors RED.
- `go build` + `go vet` — POSH Go peripheral shims (HashiCorp plugin
  protocol v6). A vet finding is YELLOW; a build error RED.
- `cargo build --release --locked` with `RUSTFLAGS="-D warnings"` — the
  `#![no_std]` BLAKE3 SIMD Merkle kernel. The kernel gets no warning band:
  any warning is RED (charter pass criterion is "0 compiler warnings";
  RPN 120 -> 10 type-enforced turnstile control).
- POSH adds: `just posh-build` chaining the three toolchains, each child
  under `timeout 60` (§4); first non-zero child aborts the chain; the
  per-toolchain SLA clock starts at child spawn.

### Test Gate — SLA < 40 s

- `mix test` with branch coverage. Bands (charter): 100% pass and >= 85%
  branch coverage GREEN; 80-84.9% YELLOW; any failure or < 80% RED.
- POSH adds: a coverage-band evaluator parsing `mix test --cover` output.
- POSH reuses: the smalt test-budget census law
  (`justfile.d/28-test-budget.just`) for compile-abort -> `blocked`
  classification.

### Lint Gate — SLA < 10 s

- `mix credo --strict` — Elixir.
- `golangci-lint run` — Go.
- `cargo clippy -- -D warnings` — Rust kernel; kernel clippy warning is
  RED (no formatting-only YELLOW band for the kernel).
- Charter bands: 0 errors and 0 stylistic warnings GREEN; formatting-only
  warnings YELLOW; any critical lint error RED.
- POSH adds: `just posh-lint` chain recipe with `timeout 10` per
  toolchain.

### Invariant Gate — SLA < 5 s

- SPARQL ASK/SELECT verification over the `ingress/` and `egress/` graphs:
  100% routes terminate in turnstiles, 0 orphan nodes, SHACL shapes close,
  a receipt rule present per route. RED on orphan route, broken SHACL
  shape, or missing receipt rule.
- Real smalt anchors (existing, on disk):
  - `just invariant-gates` -> `scripts/invariant_gates.py` — runner for
    six fail-closed invariant gates, fresh JSON receipts under
    `tmp/invariant-gates/`. POSH adds the ingress/egress SPARQL checks as
    new gate drivers under the same runner contract (fail-closed, fresh
    receipts per gate).
  - `just naming-sweep` -> `scripts/naming_sweep.sh` — tracked-file
    pattern greps; POSH adds the ingress/egress naming law to its pattern
    list and applies the sweep to Andon receipt content at write time.
  - `just sleep-gate` / `just sleep-gate-court`
    (`justfile.d/29-sleep.just`, `justfile.d/33-sleep-gate-ext.just`) —
    the Andon runner code itself is subject to the no-sleep gate: the
    runner polls gate child processes with bounded deadlines, never
    sleeps; an unclassified-sleep insert into the runner must REFUSE via
    the `sleep-gate-court` non-vacuity court.
  - `just mutation-court` (`justfile:151-156`,
    `scripts/mutation_court.py`) — proves a gate non-vacuous by
    real-restore mutation; exit 0 / 1 / 2 convention (§2). POSH
    falsifiers (§6) run as mutation-court-class courts.
  - `just shim-court <name>` (`justfile.d/18-shim-court.just`) — POSH
    mutation falsifiers run in the shim-court protocol: baseline ->
    before -> shim -> after -> restore, byte-exact restore, fail-closed.

## 4. SLA Timeouts

From the charter matrix (authoritative): BUILD < 60 s, TEST < 40 s,
LINT < 10 s, INVARIANT < 5 s.

Timeout is RED, not silent pass — a gate that cannot fail is vacuous.

- The runner sets a hard `timeout <sla>` on every gate child process. On
  expiry: SIGKILL the child, publish RED, receipt
  `outcome:"timeout"` with `sla_ms` and `elapsed_ms`.
- A gate registered without an SLA clock is not run: the runner refuses
  (exit 2, loud `[SKIP]`-class line `missing SLA clock`). Fail-closed.
- The SLA clock has its own falsifier (§6, control mutation).

## 5. Andon Receipts (JSONL)

Every signal change writes one JSONL line to `tmp/posh/andon.jsonl`.
Schema, one line:

```json
{"ts": "2026-10-30T12:00:00Z", "subject_sha256": "<sha256>",
 "gate": "build", "prev_signal": "GREEN", "signal": "GREEN",
 "outcome": "pass", "exit": 0, "elapsed_ms": 1240,
 "sla_ms": 60000, "hysteresis_count": 0,
 "composite": "GREEN", "arrested": false, "skip_reason": null}
```

Field rules:

- `ts` — RFC3339 UTC.
- `subject_sha256` — sha256 over the gate's ordered input set
  (gate-specific manifest: source files + config + runner version).
- `gate` — one of `build|test|lint|invariant`.
- `prev_signal` — read from the last receipt line for that gate in the
  state store, never from session memory. Receipts are the register of
  truth.
- `outcome` — one of `pass|warn|fail|timeout|skip|blocked`.
- `exit` — typed exit code per §2 (`0|1|2|3`).
- `composite` — MAX over the four gate signals for this subject run.
- `arrested` — true iff composite RED and an arrest surface fired.
- `skip_reason` — non-null iff `outcome:"skip"`.
- No PHI, no secrets in receipt lines; the naming-sweep pattern class
  applies to receipt content at write time.

## 6. Falsifiers (Non-Vacuity Courts)

A gate is non-vacuous iff a real mutation flips it to RED with a real
restore (shim-court protocol, byte-exact restore check, fail-closed). A
court that cannot flip is FAIL; a skip is loud. One falsifier minimum per
gate:

- **Build**: insert a `.ex` file with a warning (unused variable) into the
  subject tree. Expected YELLOW (Elixir/Go warning band). Insert the same
  class of warning into the `no_std` kernel: expected RED. A build gate
  that stays GREEN under the warning mutation is vacuous.
- **Test**: delete a test file. Expected RED (coverage band demotes /
  pass-rate surface changes). A test gate that stays GREEN when a test is
  deleted is vacuous.
- **Lint**: insert a violation (module missing `@moduledoc` under credo
  strict, or an unlocked clippy lint). Gate must flip RED.
- **Invariant**: add an orphan route node (route with no terminating
  turnstile) to a fixture `ingress/` graph. Gate must flip RED.
- **SLA control mutation (all gates)**: insert a `sleep(999)` /
  blocking-read mutation into a gate driver; the SLA clock must flip it
  RED with `outcome:"timeout"`. Same court class as `sleep-gate-court`.
- **Runner falsifier**: register a gate with no SLA clock; the runner must
  refuse with exit 2 and a loud line.

## Status

- Charter: `charter-master.md` §6 is authoritative; this spec elaborates
  it without contradiction (SLA values and MAX composite inherited
  verbatim).
- This spec: WRITTEN (`andon.md`, v26.10.30). UNVERIFIED as to any POSH
  implementation — POSH gate code does not exist yet; this is a design
  spec, not an execution receipt.
- Existing smalt anchors verified on disk this session:
  `justfile.d/29-sleep.just` (sleep-gate, sleep-gate-court),
  `justfile.d/33-sleep-gate-ext.just`, `justfile.d/28-test-budget.just`,
  `justfile.d/18-shim-court.just`, `scripts/invariant_gates.py`,
  `scripts/naming_sweep.sh`, `scripts/mutation_court.py`, smalt
  `justfile:151-174` (mutation-court, invariant-gates, naming-sweep
  recipes).
