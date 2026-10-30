# 43 SLA Runner Landing (GAP09 G1, closes the run_with_sla half of gaps/31)

Status: ALIVE (fixture green + timeout receipt on disk this session; posh-court
elapsed_ms collection is debt — see §5).

Subjects:

- spec: smalt `docs/jira/posh/v26.10.30/gaps/31-sla-clocks.md` (§1/§2/§3/§5/§6)
- landed: smalt `scripts/posh_sla.sh` (new) + smalt `justfile.d/58-posh.just`
- consumer witness repo: /Users/sac/cai/courtroom-platform-az (HEAD 31c58e9)

## 1. What landed

- `~/smalt/scripts/posh_sla.sh` — canonical `run_with_sla` runner + `sla_for`
  registry. One implementation, one receipt emitter, sourced by both recipes
  (just shebang recipes are separate processes; a function cannot be shared
  in-file, so the body lives in the sourced file — this is the single
  implementation G31 §1 demanded, physically in scripts/ not inline).
- `justfile.d/58-posh.just`:
  - `posh-court` sources the runner and wraps every counted stage + the two
    load-bearing pre-stage legs (kind ladder, posh-build) in run_with_sla:
    infra=600 (kind ladder), build=60, vet=10, the §2.1 table verbatim
    (alloc-test=40, static=10, fence=40, wire=30, e2e=300, mutation=40).
  - Stage 6/7 tf legs wrapped under the `e2e` row (300s each leg; the spec's
    "shared 300s budget" is landed as per-leg 300s — per-leg is the landed
    semantics, noted as a deviation below).
  - Default-refuse: `sla_for` returns empty for unregistered names →
    `[SLA-REFUSE]` exit 2, child never spawned; missing timeout/gtimeout
    binary → same refusal path (fail-closed). rc-3 SKIP passthrough intact
    (helper rewrites only 124→1).
  - New recipe `posh-court-sla-test` (G31 §6, extended): refusal leg
    (`run_with_sla ghost-stage "" true` → exit 2) + control leg (true under
    5s must pass with a pass receipt) + mutation leg (sleep 999 must be
    killed RED with `outcome:"timeout"`, elapsed_ms in the 4000–12000 band).
- macOS fix vs spec: G31's helper used `date +%s%N` (GNU-only; BSD date emits
  literal "N"). Landed helper uses python3 epoch-ms. `timeout` resolved via
  `command -v timeout || command -v gtimeout`; both present at
  /opt/homebrew/bin on this host.

## 2. Gates — real output

- `just --evaluate` (smalt Justfile): exit 0.
- `just posh-court-sla-test`: exit 0, 6.3s wall. Witnessed output:
  `[SLA-TEST] PASS refusal leg` / control / mutation at 5039ms.
- Timeout receipt on disk (real cat):
  `~/smalt/tmp/posh/andon.jsonl`:
  `{"gate":"sla-fixture-sleep","outcome":"timeout","exit":124,"elapsed_ms":5039,"sla_ms":5000,"ts":"2026-10-30T20:13:11Z"}`
  (+ `sla-fixture` pass row, elapsed_ms 40).

## 3. ALIVE claim

ALIVE for the fixture: posh-court-sla-test exit 0 with the sleep-999 RED
witnessed and the `outcome:"timeout"` receipt row on disk. First real
elapsed_ms collection happened (fixture legs: 40ms pass, 5039ms timeout).

## 4. Deviations from G31, disclosed

- Helper body physically in `scripts/posh_sla.sh` (sourced), not inline in
  58-posh.just — needed for single-implementation sharing across two recipes;
  the registry + runner + receipt format are exactly §1's contract.
- e2e 300s is per-leg, not a shared budget across stages 6+7.
- Fixture adds the refusal leg inside the recipe (G31 proposed it as a
  separate falsifier line), so one recipe proves all three properties.
- macOS-portable timing (python3) replaces `date +%s%N`.

## 5. Debt

- posh-court under the runner: NOT executed this lane. Two posh-court runs
  from other lanes were mid-run on the shared checkout (pids 17577, 17844)
  and the substrate anchor was down; running a third would collide. Debt:
  first witnessed posh-court run under run_with_sla still owes the
  andon.jsonl infra/build/vet/... stage rows + real cold/warm elapsed_ms for
  the suspect §2.1 rows (build 60s cold, vet 10s cold). Fixture rows exist;
  court rows are the remaining G31 §4 measurement debt.
- `just posh-court-sla-test` appends to tmp/posh/andon.jsonl (append-only by
  design); posh-clean removes it with tmp/posh.
