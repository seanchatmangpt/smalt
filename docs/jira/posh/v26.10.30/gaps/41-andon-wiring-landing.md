# 41 Andon Wiring Landing (G28)

Status: ALIVE (witnessed this session, 2026-10-30). Driver outcome channel,
court-side emission wiring, and a real `posh/var/andon.jsonl` with RED →
latch → clear rows all executed against the real driver and real chain file.
Full `just posh-court` did NOT run end to end (kind/ARM stages; pre-stage
held by lane 38) — court-level falsifier step 1 ("a real court run exits 1
through finish()") remains UNVERIFIED until a real court runs.

Subjects (lane note: the G28 work surface is /Users/sac/smalt —
courtroom-platform-az has no posh tree; this is the lane report file):

- driver: /Users/sac/smalt/posh/cmd/andon/main.go
- machine: /Users/sac/smalt/posh/internal/andon/{machine,state}.go
- recipe: /Users/sac/smalt/justfile.d/58-posh.just (posh-court body,
  wiring block at ~line 289)
- chain: /Users/sac/smalt/posh/var/andon.jsonl (real, 7 rows)

## 1. What landed

1. Driver outcome channel (G28 §3 delta), posh/cmd/andon/main.go:
   explicit `"outcome"` field on stdin gate lines; accepted values
   pass|warn|fail|timeout|skip|blocked; unknown value → typed driver
   error, exit 2. Explicit outcome wins over pass/sla_met; missing
   outcome keeps the legacy derivation (`!pass`→fail,
   `pass&&!sla_met`→timeout, else pass) — backward compatible.
   skip/blocked HOLD the current signal and still receipt (real machine
   run inside the tests: skip-after-RED holds RED receipted;
   blocked-on-fresh-gate stays GREEN receipted).
2. Court wiring, justfile.d/58-posh.just posh-court body, single
   wiring block (~lines 289-357) + mechanical emit calls at every
   stage branch:
   - `subject_sha="$(git rev-parse HEAD)"` once at court start; every
     emitted row carries it (latch binds RED to that SHA).
   - `results=tmp/posh/gate-results.jsonl`, truncated per run.
   - `emit <gate> <pass|fail> <reason>` — appends the driver stdin
     shape via env-var-passed python3 (quoting-safe). SKIP branches
     emit NOTHING for their gate (no fabricated GREEN; the typed
     [POSH-COURT-n] SKIP console line is the witness).
   - `finish <court_rc>` — pipes the results file through the real
     driver and exits; court rc ANDs with andon rc (RED/BLOCKED → 1;
     andon GREEN never upgrades a failing court).
   - All stage FAIL branches route `emit <gate> fail …; finish 1`;
     the green tail is `tally; echo ALIVE; finish 0`.
   - Emit-once law (G28 §2) encoded in the recipe comment: each gate
     name at most once per invocation; retries re-invoke the court.
   - G28 falsifier queries use repo-root-relative `posh/var/andon.jsonl`;
     witnessed that `(cd posh && go run ./cmd/andon -receipts
     posh/var/andon.jsonl)` (G28 §4 literal) lands at
     posh/posh/var/ — fixed to `-receipts var/andon.jsonl` from the
     posh cwd (chain path unchanged, posh/var/andon.jsonl).
3. Emit-once law: documented in the recipe wiring block (see §2 audit
   below).
4. First real chain: posh/var/andon.jsonl — 7 real rows (2 from the
   synthetic court legs + 5 from falsifier legs), including an
   `outcome:"skip"` row through the real driver.

## 2. Witness receipts (all commands + exits this session)

Driver tests (new outcome tests included):

    cd /Users/sac/smalt/posh
    go test -race -count=1 ./internal/andon/ ./cmd/andon/
    → ok smalt.dev/posh/internal/andon 1.742s
    → ok smalt.dev/posh/cmd/andon      1.299s   (exit 0, twice run)

just gate:

    just --evaluate → exit 0 (EVAL_OK, re-run after every recipe edit)
    bash -n on the extracted posh-court body → BASH_SYNTAX_OK

Synthetic court through the REAL recipe emit/finish block (functions
extracted verbatim from the recipe by sed and sourced; 2 gates fed):

    rows=2
    vet fail -> RED (prev GREEN, hysteresis 0)
    terraform-apply pass -> GREEN (prev GREEN, hysteresis 0)
    composite RED → finish rc=1, "[POSH-COURT] ANDON RED — line halted
    (latched on f0e0a12575c38f07e37a40ed58f4e448086c97b3)"
    → posh/var/andon.jsonl written with 2 receipts
    (subject_sha256 bound, arrested:true)

Falsifier legs (direct driver feeds, real chain file):

    latch:    same-SHA pass rerun  → rc 1, "vet pass -> RED (prev RED)"
    skip:     outcome:"skip" feed  → rc 0, holds GREEN, receipted
    clear:    distinct SHA + pass  → rc 0, "vet pass -> GREEN (prev RED)"

jq witnesses on /Users/sac/smalt/posh/var/andon.jsonl:

    RED row:    jq -e 'select(.gate=="vet" and .outcome=="fail" and
                .signal=="RED" and .arrested==true and
                .subject_sha256==$SHA)' → RED_ROW_OK
    latch:      select(same SHA, gate vet, .composite!="RED") → NO rows
                (jq -e rc 1 = PASS; latch held)
    clear row:  select($SHA2 and .composite=="GREEN") → CLEAR_OK
    skip row:   outcome=="skip", signal GREEN, arrested:false — on disk
    emit-once:  jq uniq -c audit → only repeat is the intentional
                falsifier fail+latch legs (two separate driver
                invocations at the same SHA, one line each — the legal
                latch pattern; no gate repeats within one invocation)

## 3. Disclosed concurrent-lane note (same-checkout fan-out)

justfile.d/58-posh.just was being edited concurrently by lane 31
(SLA clocks: run_with_sla, scripts/posh_sla.sh, tally /9 PASS, new
stage 0 invariant gate) while this lane landed. This lane's wiring was
applied on top of that base (rebased mid-session after an edit
collision was refused) and wired the new stage 0 as gate `invariant`
plus the G28 gate table. Both lanes' content is present in the current
file (witnessed by grep at final gate run: wiring block at line 289,
34 emit call sites, `-receipts var/andon.jsonl` at line 320).

## 4. Standing table

| cell | standing |
|---|---|
| driver outcome channel (skip/blocked hold, receipted) | ALIVE — unit + machine tests exit 0 |
| legacy pass/sla_met derivation (backward compat) | ALIVE — unit-tested all 3 shapes |
| recipe emit/finish wiring | ALIVE — synthetic court through verbatim-extracted functions wrote 2 real receipts, rc 1, typed ANDON RED line |
| emit-once law | ALIVE — encoded in recipe + audited by jq uniq -c (no intra-invocation repeat) |
| real posh/var/andon.jsonl | ALIVE — 7 rows incl. RED/latch/clear/skip |
| RED→latch→clear falsifier (§6 steps 2-3 + degraded step 1) | ALIVE — every leg flipped rc and jq output |
| full posh-court end-to-end through finish() | UNVERIFIED — kind/ARM stages; pre-stage held by lane 38 |
| full-court falsifier step 1 (real court exit 1) | UNVERIFIED — next real court run closes it |
| receipts-path divergence in G28 §4 | FIXED — `-receipts posh/var/andon.jsonl` from posh cwd landed at posh/posh/var/; wired as `-receipts var/andon.jsonl` |
