# 13 Court Andon Ledger — Verification-Evidence Annex

Consolidation lane 13 of 15 (v26.10.31 window). All rows re-read from the
live files 2026-10-30 (as-of timestamps per artifact); nothing cited from
session memory. Canonical andon stream: smalt `posh/var/andon.jsonl`
(27 rows as-of 2026-10-30T21:30Z); SLA fixture + court stage stream: smalt
`tmp/posh/andon.jsonl` (28 rows as-of 2026-10-30T21:30Z).

## Andon chain rows (L41 7-row chain, live jq-equivalent read)

First five rows of `posh/var/andon.jsonl` form the synthetic-court chain
(subject `f0e0a125…97b3`), the RED→latch→clear sequence:

| # | ts (2026-10-30) | gate | prev→signal | outcome | composite | reason (abridged) |
|---|---|---|---|---|---|---|
| 1 | 20:18:55Z | vet | GREEN→RED | fail (exit 2) | RED, arrested | `[POSH-COURT-1]` leg A |
| 2 | 20:18:55Z | terraform-apply | GREEN→GREEN | pass | RED (latched) | synthetic pass leg |
| 3 | 20:19:05Z | vet | RED→RED | pass | RED (latch) | same-SHA rerun (falsifier step 2) |
| 4 | 20:19:05Z | smalt-wire | GREEN→GREEN | skip | GREEN | substrate silent (outcome leg) |
| 5 | 20:19:05Z | vet | RED→GREEN | pass | GREEN (clear) | new subject (falsifier step 3) |

Rows 6–7 (20:28:26Z, preflight, kind ladder exited 1) are the first real
gate rows: RED, `arrested:true`, composite RED. The same preflight RED then
latches across 20:28:26Z→21:23:25Z (12 further rows, all `arrested:true`) —
an arrest window of ~55 minutes on subject `f0e0a125…97b3`.

RED→latch→clear semantics witnessed in the live data: a single RED arrests
(row 1); a GREEN rerun on the SAME subject does not clear (row 3, latch
holds); only a new subject SHA clears (row 5). A synthetic pass leg does not
override the composite (row 2).

## SLA fixture receipt (posh-court-sla-test)

Lane evidence: `docs/jira/posh/v26.10.30/gaps/43-sla-runner-landing.md`
(read 2026-10-30). First timeout receipt row, live from `tmp/posh/andon.jsonl` (fenced literals
below are byte-exact receipt quotes, not wrapped):

```json
{"gate":"sla-fixture-sleep","outcome":"timeout","exit":124,"elapsed_ms":5039,"sla_ms":5000,"ts":"2026-10-30T20:13:11Z"}
```

- Refusal leg: `run_with_sla ghost-stage` → `[SLA-REFUSE]` exit 2 (child
  never spawned; default-refuse on unregistered names, fail-closed).
- RED leg: sleep-999 killed at ~5s SLA — first run 5039ms, repeat runs
  5040/5036/5041/5058/5071/5057ms (all `outcome:"timeout"`, exit 124, in the
  4000–12000ms band G31 §6 specified). Companion pass rows
  `sla-fixture` 33–51ms, exit 0.
- First real gate receipts under the runner: `infra` rows in the same stream,
  including the first SLA-bounded timeout:
  `{"gate":"infra","outcome":"timeout","exit":124,"elapsed_ms":600061,
  "sla_ms":600000,"ts":"2026-10-30T21:23:03Z"}`
  — the 600s infra budget actually fired. Remaining infra rows are real
  `fail` exits 1 with real elapsed_ms (879–490522ms).
- Standing: fixture ALIVE; posh-court end-to-end under `run_with_sla` was
  debt at G43 write time — partially discharged since (real infra stage rows
  now present in the stream).

## First real gate receipts (court flips)

Each entry: evidence artifact — what it witnesses — date — path
(paths smalt-root relative, `docs/jira/` prefix shown in full on first use).

- **coverage gate GREEN** — 15 faces / 6 families vs register: 9 pass +
  6 registered-divergence, 0 silent gaps, exit 0 — 2026-10-30 —
  `docs/jira/posh/v26.10.30/receipts/parity/posh009-coverage-gate-green.json`
- **coverage gate FLIP** — `wire_op:echo` removed from
  `posh/cmd/posh/main.go` → gate FAIL exit 1 (ghost-row detection);
  sha256 restore byte-exact; post-restore exit 0 — 2026-10-30 —
  `…/receipts/parity/posh009-coverage-gate-flip.json`
- **turnstile shim-court flip** — `ReceiptTurnstile` plug commented
  (SHIM-COURT marker) → pinned suite 4-pass → 3-fail (exit 2); restore
  4-pass exit 0, byte-exact — 2026-10-30T11:37:08Z —
  `…/receipts/mutation/turnstile-flip.json`
- **invariant court flip** — `just posh-invariant-court`: orphan-route
  injection → SPARQL gate exit 1 naming `invariant_orphan_route.rq` /
  `routeOrphanInjected`; instance sha256 `fecd2086…644df` unchanged —
  2026-10-30 —
  `…/v26.10.30/gaps/40-invariant-gate-landing.md`
- **compat-pin court** — SPLIT PLAN ONLY (core/dialect/missing-file legs,
  COMPAT-PIN-SKIP exit 3) — not executed; substrate ALIVE via unsplit
  pin — 2026-10-30 — `…/v26.10.31/gaps/12-compat-pin-split.md`

Path prefix: `…/` = `docs/jira/posh/`.

## Harness mutation court (HRN-013)

Receipt: `docs/jira/v26.10.31/harness/v26.10.30/receipts/mutation-court-2026-10-30.md`
(mirror: courtroom repo `docs/jira/nextjs-harness/v26.10.30/receipts/mutation-court-2026-10-30.md`),
header 2026-10-30T21:13:30Z.

- 20 sed mutations on temp copies of `apps/web/test/harness/` suites, vitest
  `-t` filtered to the target TC; 20 ran, 0 loud SKIP.
- Inversion class (the vacuity probe): **14 ran, 14 flipped, 0 survived —
  kill rate 100%** against the >90% target. VERDICT: PASS.
- Strength-degradation rows (relax/delete/weaken): 6 SURVIVED — recorded as
  redundancy, no kill-rate credit either way (M02/M03/M04/M06/M09/M10).
- Coverage boundary disclosed: RED sibling-domain suites excluded from the
  court baseline, not silently absorbed.

## Standing summary (as-of 2026-10-30)

- Andon RED→latch→clear: ALIVE on live rows (5-row synthetic chain + ~55-min
  real preflight arrest window).
- SLA fixture (refusal exit 2 + sleep-999 RED + first real timeout receipts):
  ALIVE.
- Coverage flip, turnstile flip, invariant flip: ALIVE (executed, restored
  byte-exact).
- Compat-pin split court: plan only, UNVERIFIED/NOT EXECUTED.
- Harness mutation court: ALIVE (PASS, 14/14 inversion kill).
