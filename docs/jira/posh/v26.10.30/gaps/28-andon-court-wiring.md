# 28 Andon-Court Wiring: posh-court Must Emit Gate Results to the Andon Driver

Status: PARTIAL — spec complete; wiring unimplemented. Driver ALIVE (unit tests +
real end-to-end smoke this session); court-side emission does not exist
(`posh/var/` absent on disk; `just posh-andon` prints help only — witnessed).
No executable falsifier has run yet (§6 is the proposal, UNVERIFIED).

## Subjects

- consumer: `/Users/sac/cai/courtroom-platform-az` (this repo, HEAD 31c58e9)
- substrate: `/Users/sac/smalt` (posh module + justfile.d/58-posh.just)
- driver: `/Users/sac/smalt/posh/cmd/andon/main.go` (module `smalt.dev/posh`)
- machine: `/Users/sac/smalt/posh/internal/andon/{machine,receipt,state}.go`
- recipe: `/Users/sac/smalt/justfile.d/58-posh.just` (`posh-court` at 269-445,
  `posh-andon` at 526-531)

## 1. Observed state (all re-read from disk this session, 2026-10-30)

- `just posh-andon` → prints flag usage only; `go run ./cmd/andon -help` makes
  the flag package exit 2. It is a help stub, not a court feed.
- `/Users/sac/smalt/posh/var/andon.jsonl` does not exist (`ls posh/var` →
  "No such file or directory"). No real court run has ever produced it.
- Driver unit tests: `go test -race ./internal/andon/` → `ok ... 1.608s`.
- Real driver smoke (single invocation, 3 stdin lines, temp receipts path):
  RED → same-SHA pass → new-SHA pass printed composite RED, `arrested:true`,
  final rc=1, and wrote 3 receipts with `subject_sha256` bound per line. The
  chain is the register of truth on disk; this is the behavior the court feed
  must preserve.

## 2. Registered divergence: batched-run stale prev_signal

`Machine.Run` (machine.go:198-230) applies ALL gates first and appends receipts
only at the end, and `Apply` reads `LastGate` from the chain at apply time.
Within ONE driver invocation, a repeated gate name reads a stale prev (the
pre-invocation chain). Witnessed in the §1 smoke: the same-SHA green rerun got
per-gate `signal:"GREEN"` (not latched RED) because all three Applies saw the
empty chain; only the composite MAX kept the run arrested. The latch itself is
sound ACROSS invocations (unit test `TestGreenToRedToLatchedRerun` proves the
same-SHA rerun holds RED when runs go through separate `Run` calls — which is
the court case: one invocation per court run).

Wiring law derived from this: **emit each gate name at most once per court
invocation** (stage retries must re-invoke the driver, not re-emit into the
same stdin batch), and rely on invocation-to-invocation chain state for the
latch. Do not "fix" by appending mid-Run without re-reading the chain.

## 3. Gate-result shape (stdin JSONL, one line per counted stage)

Exact shape the driver already parses (main.go:31-37):

    {"gate":"<name>","pass":<bool>,"sla_met":<bool>,"subject_sha":"<40-hex>","reason":"<text>"}

Mapping (main.go:71-77): `!pass` → outcome `fail`; `pass && !sla_met` →
`timeout`; else `pass`. The driver has NO skip channel — a SKIPped stage must
not be emitted as pass (that would fabricate GREEN). Required driver delta
(one field): accept an optional `"skip":true` (or explicit `"outcome":"skip"`)
mapping to `OutcomeSkip`, which `stateForOutcome` already treats as hold —
until that lands, a SKIPped stage emits NO line for its gate and the court
log carries the typed `[POSH-COURT-n] SKIP` line as the witness.

Gate names (9, pre-stage + 8 tally stages — pre-stage is load-bearing but
uncounted in tally; it gets a gate row anyway):

| gate | source line (58-posh.just) |
|---|---|
| `preflight` | kind ladder + metadata anchor poll (289-313) |
| `build` | posh-build + posh-install pre-stage (316-327) |
| `vet` | stage 1 (331) |
| `alloc-test` | stage 2 (343) |
| `static` | stage 3 (350) |
| `fence` | stage 4 (357) |
| `smalt-wire` | stage 5 (364) |
| `terraform-apply` | stage 6 (387-397) |
| `zero-drift` | stage 7 (402-428) |
| `mutation-nonvacuity` | stage 8 (435-441) |

`subject_sha` = `git rev-parse HEAD` of smalt, captured ONCE at court start
(line ~278) and exported; every line in one invocation carries the same value
(the latch binds the RED to that SHA).

`reason` = the existing `[POSH-COURT-*]` message text, verbatim — the andon
chain then carries the same prose the console did, so jq queries reconstruct
the court narrative.

## 4. Recipe change (justfile.d/58-posh.just, posh-court body)

Accumulator + finisher inside the existing shebang recipe:

    subject_sha="$(git rev-parse HEAD)"   # once, before pre-stage
    results="tmp/posh/gate-results.jsonl"
    mkdir -p tmp/posh; : > "$results"     # truncate per court run

    emit() {  # emit <gate> <pass|fail|timeout> <reason>
      printf '{"gate":"%s","pass":%s,"sla_met":%s,"subject_sha":"%s","reason":"%s"}\n' \
        "$1" "$([ "$2" = fail ] && echo false || echo true)" \
        "$([ "$2" = timeout ] && echo false || echo true)" \
        "$subject_sha" "$3" | python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read())))' >> "$results"
    }

    finish() {  # compose court rc with andon rc; ALWAYS runs andon
      local court_rc="$1"
      if [ -s "$results" ]; then
        (cd posh && go run ./cmd/andon -receipts posh/var/andon.jsonl \
           < "../$results") || { 
          arc=$?
          if [ "$arc" = 1 ]; then
            echo "[POSH-COURT] ANDON RED — line halted (latched on $subject_sha)"
            court_rc=1
          elif [ "$arc" = 2 ]; then
            echo "[POSH-COURT] ANDON BLOCKED (driver/infra error rc=2)"
            court_rc=1
          fi
        }
      fi
      exit "$court_rc"
    }

Mechanical changes to the stage bodies, no logic change:

1. Every `pass=$((pass+1)); stage n "PASS ..."` line gains
   `emit <gate> pass "<msg>"`.
2. Every FAIL branch (`stage n "FAIL ..."; tally; exit 1`) becomes
   `stage n "FAIL ..."; emit <gate> fail "<msg>"; tally; finish 1`.
3. Every SKIP branch emits nothing for that gate (§3 skip law) and falls
   through unchanged.
4. The two exit points (`exit 0` at 445, `exit 1` at 296/312/319/326 via
   FAIL branches) route through `finish`.

Receipts land at `posh/var/andon.jsonl` (driver default, cwd `posh/`):
gitignored, swept by neither `make clean` nor `just posh-clean` — durable
across court hygiene, which is the point of a latch register.

## 5. Exit-code composition

- Court's own tally rc ANDs with the andon composite: `finish` takes
  `court_rc` and demotes to 1 on andon 1 (RED) or 2 (BLOCKED). andon 0
  (GREEN/YELLOW) never upgrades a failing court — AND, not OR.
- andon BLOCKED (2) is infra, not a signal: it must not be able to mask a
  GREEN court as pass-through, so it also maps to court exit 1 with the typed
  `[POSH-COURT] ANDON BLOCKED` line.

## 6. Latch evidence trail + falsifier (PROPOSED, UNVERIFIED)

Evidence law: a RED from a stage failure must appear in
`posh/var/andon.jsonl` as a row with `outcome:"fail"`, `signal:"RED"`,
`arrested:true`, and `subject_sha256 == <court HEAD>`; a green rerun at the
same HEAD must leave the composite RED (latch); only a new HEAD + GREEN run
clears. Witness queries:

    # the RED row for a subject
    jq -e 'select(.gate=="terraform-apply" and .outcome=="fail"
      and .signal=="RED" and .arrested==true and .subject_sha256=="'$SHA'")' \
      posh/var/andon.jsonl

    # the latch: any later same-SHA row must never be composite GREEN
    jq -e 'select(.subject_sha256=="'$SHA'" and .composite!="RED")' \
      posh/var/andon.jsonl   # must print NOTHING after a RED at that SHA

    # clear: first row at the new SHA is composite GREEN
    jq -e 'select(.subject_sha256=="'$SHA2'" and .composite=="GREEN")' \
      posh/var/andon.jsonl

Executable falsifier (end-to-end, in smalt; drives the REAL driver, real
chain file — no mocks; the RED is forced at stage 6, the deepest fail-closed
stage):

    #!/usr/bin/env bash
    set -euo pipefail
    cd /Users/sac/smalt
    chain=posh/var/andon.jsonl
    SHA=$(git rev-parse HEAD)
    # 1. force a stage-6 RED (backend-stripped apply is guard-refusable):
    #    run posh-court with the example root's guard tripped, expect exit 1
    #    and a RED row at $SHA
    just posh-court && { echo "expected RED, got green"; exit 1; } || rc=$?
    [ "${rc:-0}" = 1 ] || { echo "court exit $rc, want 1"; exit 1; }
    jq -e --arg s "$SHA" 'select(.gate=="terraform-apply" and .outcome=="fail"
      and .signal=="RED" and .arrested==true and .subject_sha256==$s)' $chain >/dev/null
    # 2. same-SHA green rerun — court tally green is IMPOSSIBLE while latched,
    #    so rerun the driver directly with a passing line at the same SHA:
    printf '{"gate":"terraform-apply","pass":true,"sla_met":true,"subject_sha":"%s","reason":"rerun"}\n' "$SHA" \
      | (cd posh && go run ./cmd/andon -receipts posh/var/andon.jsonl) \
      && { echo "same-SHA rerun exited 0 — LATCH BROKEN"; exit 1; } || true
    jq -e --arg s "$SHA" 'select(.subject_sha256==$s and .composite!="RED")' $chain | grep -q . \
      && { echo "non-RED row at latched SHA"; exit 1; } || true
    # 3. new-SHA green clears:
    SHA2=$(printf '%s0' "${SHA%0}")  # any changed sha; in real use, next commit
    printf '{"gate":"terraform-apply","pass":true,"sla_met":true,"subject_sha":"%s","reason":"new subject"}\n' "$SHA2" \
      | (cd posh && go run ./cmd/andon -receipts posh/var/andon.jsonl)
    jq -e --arg s "$SHA2" 'select(.subject_sha256==$s and .composite=="GREEN")' $chain >/dev/null
    echo "FALSIFIER PASS: RED latched at $SHA, rerun held, cleared at $SHA2"

(Step 1's real form needs the wiring of §4 landed; until then step 1
degrades to a direct driver feed with `pass:false` — the §1 smoke is that
degraded run, already passing. The falsifier is non-vacuous because step 1
requires the court to actually exit 1 and step 2 requires the rerun to exit
nonzero; a wiring that fakes the feed fails step 1's court-exit assert.)

## 7. Status

| cell | standing |
|---|---|
| andon driver (machine + JSONL chain) | ALIVE — `go test -race ./internal/andon/` ok 1.608s; 3-line smoke rc=1, 3 receipts on disk |
| driver skip channel | MISSING — stdin shape has no skip; wiring needs the §3 driver delta |
| posh-court emission (§4) | UNVERIFIED — specified, not landed |
| `posh/var/andon.jsonl` from a real court | BLOCKED — absent on disk; requires §4 |
| latch cross-invocation | ALIVE — `TestGreenToRedToLatchedRerun` |
| latch within one batched invocation | REGISTERED DIVERGENCE — §2 stale-prev; emit-once law |
| falsifier (§6) | UNVERIFIED — proposal; step-1 degraded form witnessed |
