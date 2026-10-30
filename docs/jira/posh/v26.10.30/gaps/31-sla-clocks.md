# 31 SLA Clocks: posh-court runner contract for GAP09 G1

Status: PARTIAL (design lane; no runner code landed, no court executed this
session — every citation is a real file read this session).

Subjects:

- charter: `~/smalt/docs/jira/posh/v26.10.30/dfcharter/andon.md` §4/§6
- gap register: `~/smalt/docs/jira/posh/v26.10.30/gaps/09-courts-matrix.md`
  §3 G1 (SLA clocks are prose) + G3 (SLA-less refusal falsifier)
- implementation target: `~/smalt/justfile.d/58-posh.just` (531 lines;
  `posh-court` at :268, exit contract 0/1/3 at :17)
- consumer witness repo: `/Users/sac/cai/courtroom-platform-az` (HEAD 31c58e9)

## 1. Runner contract: `run_with_sla` helper in 58-posh.just

Charter §4 is directly implementable: per-gate-child hard timeout; expiry =
SIGKILL + RED + receipt `outcome:"timeout"` carrying `sla_ms`/`elapsed_ms`;
SLA-less gate = runner refusal exit 2. Preferred form: one bash helper, not
per-recipe `timeout N` prefixes — one implementation, one receipt emitter,
O(1) drift surface.

```bash
# run_with_sla <gate-name> <sla_seconds> <cmd...>
# Exit: child's exit verbatim, except 124 (SLA expiry) -> 1 RED.
# Refusal: empty sla_seconds -> exit 2, child never spawned.
run_with_sla() {
  local gate="$1" sla="$2"; shift 2
  if [ -z "$sla" ]; then
    echo "[SLA-REFUSE] gate '$gate' registered without an SLA clock — runner refuses (exit 2)" >&2
    return 2
  fi
  local t0 rc ms outcome
  t0=$(date +%s%N)
  timeout -k 2 "$sla" "$@"; rc=$?
  ms=$(( ($(date +%s%N) - t0) / 1000000 ))
  outcome=pass
  [ "$rc" -eq 124 ] && outcome=timeout
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && outcome=fail
  # Andon JSONL receipt (andon.md §5 fields); append, never overwrite.
  printf '{"gate":"%s","outcome":"%s","exit":%d,"elapsed_ms":%d,"sla_ms":%d,"ts":"%s"}\n' \
    "$gate" "$outcome" "$rc" "$ms" $((sla * 1000)) "$(date -u +%FT%TZ)" \
    >> tmp/posh/andon.jsonl
  if [ "$rc" -eq 124 ]; then
    echo "[SLA-RED] $gate exceeded ${sla}s — killed, RED (timeout counts as fail)" >&2
    return 1
  fi
  return "$rc"
}
```

Notes:

- macOS: `timeout` is GNU coreutils (`brew install coreutils` → `gtimeout`).
  Resolve once at recipe top: `TO=$(command -v timeout || command -v gtimeout)`
  and invoke `"$TO"`. Fail-closed if neither exists (a clock that cannot be
  set is an SLA-less gate → refusal, same exit-2 path).
- `-k 2` makes the charter's "SIGKILL the child" mechanical, not
  TERM-and-hope.
- Exit contract extends posh-court's typed ladder (0/1/3) with charter
  exit 2 = refusal. Stage blocks change from `if just posh-vet` to
  `if run_with_sla vet 10 just posh-vet`. The stage-1/5 SKIP path (rc 3)
  passes through verbatim — the helper only rewrites 124→1.
- `tmp/posh/andon.jsonl` is the G3/R3 close artifact (JSONL receipts never
  produced today).

## 2. Stage→SLA mapping (8 implemented stages + pre-stage onto 4 charter gates)

Charter has 4 gates (Build<60s, Test<40s, Lint<10s, Invariant<5s); posh-court
implements 8 counted stages plus an uncounted load-bearing pre-stage. Stages
not in a charter class get explicit rows — registering them is mandatory
because the runner default-refuses any unregistered gate (fail-closed by
design).

### §2.1 Authoritative mapping table

| Stage (58-posh.just) | Recipe body | Charter gate | SLA row (s) | Justification |
|---|---|---|---|---|
| pre kind ladder (:288) | kind-up / kind-images / kind-deploy | new row `infra` | 600 | container/kind ops; charter matrix covers compile/test/lint/invariant classes, not container ops |
| pre posh-build (:316) | `make -C posh build` + provider `go build` | Build | 60 | direct charter Build. Cold Go build cache on first run may breach 60s → first breach is a measurement-debt signal, not a court defect |
| stage 1 vet (:330) | `golangci-lint run ./...` × 2 trees | Lint | 10 | charter Lint. Cold golangci-lint over two Go trees realistically 10–60s; 10s is plausible only warm-cache. First RED = measurement debt |
| stage 2 alloc-test (:342) | `go test -race ./...` over posh/ | Test | 40 | direct charter Test |
| stage 3 static (:349) | `go vet ./...` over provider dir | Lint | 10 | warm-cache by construction — pre-stage build (:316) runs earlier in the ladder, so the Go build cache is warm when stage 3 fires; warm go vet is seconds |
| stage 4 fence (:356) | `go test -race` egress+config | Test | 40 | subset of stage 2's package surface, bounded by the same Test gate |
| stage 5 wire (:363) | STS mint + 4 asserts, each curl `--max-time 5` | new row `wire` | 30 | integration-class; no charter gate fits. Each call hard-bounded at 5s → structural worst case ~25s; 30s headroom |
| stages 6+7 apply + zero-drift (:375, :399) | tf init/apply/plan/destroy + residue GETs | new row `e2e` | 300 (shared) | E2E-class; charter matrix has no E2E gate. One 300s budget across the ordered apply→plan→destroy→residue lifecycle pair |
| stage 8 mutation (:430) | `go test -race -run` tamper legs | Test | 40 | Test-class. NOT Invariant 5s — "mutation" in the name refers to non-vacuity, not gate class; -race overhead alone would false-RED at 5s |

## 3. SLA-less refusal (charter exit 2, fail-closed)

Two refusal legs, both fail-closed:

1. **Empty SLA arg**: `run_with_sla ghost-stage "" just posh-status` →
   `[SLA-REFUSE]`, exit 2, child never spawned.
2. **Unregistered gate name**: the §2.1 table is the case table; any stage
   invoked through the runner whose name has no row → default-refuse exit 2.
   This closes G3's named falsifier ("register a gate without an SLA clock →
   runner refuses exit 2").

The pre-stage kind ladder and the wire/e2e rows prove the refusal is not a
straitjacket: stages outside the charter matrix get explicit rows rather than
silent passage — an unregistered stage is a bug, loudly.

## 4. Measurement debt (estimated, not measured)

Stage wall-times were **estimated from recipe bodies**, not timed. Running
`just posh-court` for real timing is not cheap: its standing receipt
(`receipts/posh-court/posh-court-green.json`, per GAP09 R1) is FAIL 0/8 — the
kind node disk preflight REDs the whole ladder at the pre-stage, so no
end-to-end timing exists to sample. Closure: after `just kind-prune` (R1's
close), the first witnessed green run should execute under the SLA runner so
`tmp/posh/andon.jsonl` acquires its first real `elapsed_ms` column; the §2.1
suspect rows (posh-build 60s cold, stage-1 vet 10s cold) are then confirmed or
re-baselined from receipts, not prose. Until then every SLA number in §2.1 is
an estimate.

## 5. Sleep(999) control mutation (SLA-court non-vacuity)

Charter §6 names the mutation; the concrete fixture:

- Add a fixture recipe `posh-court-sla-test` in 58-posh.just that sources
  `run_with_sla` and runs two legs:
  1. **Control (GREEN leg)**: `run_with_sla sla-fixture 5 true` → must exit 0
     and append an `outcome:"pass"` receipt row.
  2. **Mutation (RED leg)**: `run_with_sla sla-fixture-sleep 5 sleep 999` →
     must be killed at ~5s, emit `[SLA-RED]`, exit 1, and append
     `outcome:"timeout"` with `elapsed_ms` in a bounded band around 5000ms
     (accept 4000–12000ms: scheduler slack plus the `-k 2` grace, still
     three orders below 999s).
- The fixture FAILS unless BOTH legs hold: a sleep(999) that passes, is not
  killed, or kills without a typed `timeout` receipt row each flip the
  fixture RED. Non-vacuity mirror: a runner whose clock is absent or
  inert (e.g. `timeout` shimmed to `true`) fails leg 2 loudly — a court
  that cannot flip is FAIL.
- Cost: ~7s per fixture run (5s mutation + control). Cheap enough to wire as
  a standing leg; do not gate it behind the full posh-court ladder.
- Restore discipline: the fixture writes only to `tmp/posh/andon.jsonl` and
  spawns no persistent state — no shim-court restore machinery needed; the
  mutation lives entirely inside the fixture invocation.

## 6. Falsifier proposal (executable)

`just posh-court-sla-test` (new recipe, 58-posh.just):

```just
# posh-court-sla-test — SLA-clock non-vacuity fixture (GAP09 G1 close leg).
[no-cd]
posh-court-sla-test:
    #!/usr/bin/env bash
    set -uo pipefail
    cd {{POSHROOT}}
    # ... define run_with_sla (shared source with posh-court) ...
    run_with_sla sla-fixture 5 true \
      || { echo "[SLA-TEST-FAIL] control leg exited nonzero" >&2; exit 1; }
    if run_with_sla sla-fixture-sleep 5 sleep 999; then
      echo "[SLA-TEST-FAIL] sleep(999) PASSED under a 5s clock — SLA clock inert, court vacuous" >&2
      exit 1
    fi
    grep -q '"gate":"sla-fixture-sleep","outcome":"timeout"' tmp/posh/andon.jsonl \
      || { echo "[SLA-TEST-FAIL] no timeout receipt row — clock killed but did not receipt" >&2; exit 1; }
    echo "[SLA-TEST] PASS: control green, sleep(999) RED + timeout receipt — SLA clock non-vacuous"
```

Plus the refusal leg (exit 2):
`run_with_sla ghost-stage "" true` must exit 2 with `[SLA-REFUSE]`.

## 7. Status line

PARTIAL — runner contract specified (`run_with_sla` + §2.1 mapping + refusal
legs + sleep(999) fixture); implementation target named
(`~/smalt/justfile.d/58-posh.just`); nothing landed in smalt this lane, no
court executed, all wall-times estimated with the debt recorded in §4.
GAP09 G1 remains open until the fixture recipe exits 0 and a witnessed
`posh-court` run under the runner produces the first `andon.jsonl` rows.
