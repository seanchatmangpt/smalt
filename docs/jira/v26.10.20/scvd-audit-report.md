# scvd-audit-report — SCVD final audit (v26.10.20)

Standing: **ALIVE** (every claim below cites an on-disk artifact `ls`-verified
before citation; every command in the evidence appendix was executed in this
session with the exit code shown, or is quoted verbatim from the cited
receipt). Author: milestone-doc lane S15. Immutable audit report for the PRD's
"Final Receipt Emission". No GAP tokens minted; no KD rows touched.

## 1. Tier table — host BEAM subject

Subject: host BEAM (OTP 28, JIT), `PopcornDemo.Concurrency`
(`popcorn_demo/lib/popcorn_demo/concurrency.ex`), deterministic smalt-layer
verification walk, fresh-VM cold runs, median of 3 per rung.
Source: `popcorn_demo/BENCH_SCVD.md` + `popcorn_demo/bench/scvd.jsonl`
(46 rows on disk, re-counted at authoring: 46/46 clean, zero error rows,
zero breaches, zero `environment_skip`).

PRD tier targets: Tier1 <500 ms / <16 MB, Tier2 <750 ms / <24 MB,
Tier3 <1200 ms / <32 MB. Basis: worst observed rung of the PRD tier set
(N=256, median-of-3). Memory = ramp-attributable increment over the ~65 MB
cold-VM baseline (the cold footprint is host-runtime overhead, present before
and after any ramp — same before/after; the divergence vs absolute VM
footprint is typed in `BENCH_SCVD.md`, not hidden).

| tier | target | measured (worst rung N=256) | verdict |
|---|---|---|---|
| Tier 1 | <500 ms / <16 MB | 6.02 ms / +1.2 MB increment | PASS (83x / 13x margin) |
| Tier 2 | <750 ms / <24 MB | 6.02 ms / +1.2 MB increment | PASS (124x / 20x margin) |
| Tier 3 | <1200 ms / <32 MB | 6.02 ms / +1.2 MB increment | PASS (199x / 26x margin) |

These verdicts qualify the HOST BEAM subject only. The in-browser (wasm BEAM)
subject is a different subject and is never conflated with it (see §3).

## 2. Threshold Wall — LOCATED at N=512

Source: `popcorn_demo/BENCH_SCVD.md` (S2 rungs <=256 + S14-A2 extension rungs
512-4096), rows on disk in `popcorn_demo/bench/scvd.jsonl`
(3 fresh-VM runs per rung, `timeout 120` fence per run).

Median sequential wall (ms): 1: 2.41, 2: 3.20, 4: 2.80, 8: 2.80, 16: 2.75,
32: 3.03, 64: 5.08, 128: 5.13, 256: 6.02, 512: 13.88, 1024: 36.11,
2048: 76.52, 4096: 293.60 (verified=4096, breaches=0).

Doubling ratios vs the 2.00x linear expectation: 1->2: 1.33x, 2->4: 0.88x,
4->8: 1.00x, 8->16: 0.98x, 16->32: 1.10x, 32->64: 1.68x (jitter-class),
64->128: 1.01x, 128->256: 1.17x, **256->512: 2.31x, 512->1024: 2.60x,
1024->2048: 2.12x, 2048->4096: 3.84x**.

Verdict (typed): the flat regime ends at N=256; **the scaling wall is
LOCATED at N=512** (first rung where every subsequent doubling exceeds
2.00x). It is super-linear growth, not a hard boundary — no rung timed out
(worst 297.3 ms vs the 120 s fence) and the VM refused nothing; verified=N
and breaches=0 through 4096 at 293.6 ms median. The hard boundary (timeout or
VM refusal) is OPEN at N>4096 — untested, not refuted.

Per-actor memory (S14-A2 extension rows): processes KB medians
18,050 (512) -> 18,707 (1024) -> 19,586 (2048) -> 24,764 (4096); near-linear
~0.7-0.9 KB/actor through 2048, then a ~5.2 MB processes jump at 4096
(~4.6x the old-rate expectation). **The per-actor memory constant breaks past
2048** — measured, not extrapolated (S14-A2 rows in `BENCH_SCVD.md`).

## 3. In-browser subject (wasm BEAM) — never conflated with the host

Source: `docs/jira/v26.10.20/receipts/scvd-browser-ramp-witness.md` (S14-A,
3 witnessed runs, all exit 0, cooked bundle, headless Chromium
chrome-headless-shell 156.0.8078.4) + the S9 memory section of
`popcorn_demo/BENCH_SCVD.md`.

| check | measured | verdict |
|---|---|---|
| ramp(256) wall, in-browser | 64.034 / 64.984 / 65.185 ms | PASS (<1200 ms Tier-3 target, ~18x margin) |
| ramp(256) leg law | all 256 actors verified, zero breaches, every run | PASS |
| contention(128) | `w8/l120/committed8` (8 winners / 120 losers / 8 committed), deterministic, every run | PASS |
| main-thread JS heap | 10,000,000/10,000,000 B (~9.5 MiB) vs 32 MiB budget | PASS, quantized-class (3.4x margin) |

Host-vs-browser divergence is measured on both sides, not narrated: host t256
~3.3 ms (JIT, same bundle) vs wasm t256 ~65 ms — 20x, well inside budget.
The BEAM wasm worker heap and `WebAssembly.Memory` committed size are
**UNMEASURABLE-(exposed-surface)**: no exposed API reaches them
(`performance.memory` absent in the worker; `measureUserAgentSpecificMemory`
SecurityError in the headless shell despite `crossOriginIsolated=true`; no
Popcorn/Module wasm-memory handle on any global). The 64 MiB static
`WebAssembly.Memory` reservation (`beam.mjs` initial:1024 pages) is virtual
address space, not committed heap — REFUTED on reservation only. Close
condition for the worker-heap verdict is typed in `BENCH_SCVD.md` (S9).

## 4. Contention — deterministic through the measured rungs

Source: `popcorn_demo/BENCH_SCVD.md` contention table (S1's rows, jsonl on
disk) + `popcorn_demo/receipts/v261020-s1-concurrency-ramp.md`
(S1 engine receipt, ALIVE) + the in-browser c128 fragment above.

| N | winners (verified) | committed_rows | vm_wall ms (r1/r2/r3) |
|---:|---|---|---|
| 32 | 8/8/8 | 8/8/8 | 0.7 / 1.2 / 0.8 |
| 128 | 8/8/8 | 8/8/8 | 1.2 / 1.1 / 1.1 |

Exactly one winner per key at every run; deterministic-final assertion never
fired `not_deterministic`. Losers are typed CAS losers (atomic ETS
`insert_new` claim, conditional update to `:committed`); in-browser c128
carries the same shape (`w8/l120/committed8`). Determinism witnessed at every
measured rung up to and including 128 actors concurrent (and 256-actor ramps
with zero breaches); beyond the measured rungs nothing is claimed.

## 5. Zero-egress — static + runtime gate, both flip directions witnessed

Source: `popcorn_demo/scripts/egress_gate.sh` (on disk, fail-closed; exit 0
PASS / 1 EGRESS_GATE_REFUSED / 2 usage / 3 RAMP_ABSENT loud). Session
re-witness (this lane, real runs — see appendix A5-A8):

- Full gate (static + runtime): **PASS, exit 0** — stage 1 static scan clean
  over `popcorn_demo/lib` + `popcorn_demo/public`; stage 2 ramp(64)
  verified=64, breaches=0, pgid-scoped lsof sampler saw 0 non-loopback
  remote sockets.
- Flip direction 1 (URI-DNS): a foreign URL literal in a scratch root is
  **REFUSED, exit 1** (`EGRESS_GATE_REFUSED[URI_DNS]`).
- Flip direction 2 (IP-LITERAL): a non-loopback dotted-quad literal is
  **REFUSED, exit 1** (`EGRESS_GATE_REFUSED[IP_LITERAL]`).
- Static PASS direction: a loopback-URL-only scratch root passes static
  stage, exit 0.

A gate that cannot flip is vacuous; both refusal classes are witnessed
flipping in this session. The runtime stage additionally refuses
fail-closed on ramp-timeout, missing ramp row, verified==0, breaches>0, or
any non-loopback socket observed during verified work (gate source, on disk).

## 6. Standing vocabulary — applied, not narrated

- **Every dollar/economic claim: UNSUPPORTED.** Per
  `docs/jira/v26.10.20/scvd-ledger.md` §3: no dollar figure is asserted,
  implied, or inherited from any receipt in this report; no prose valuation
  (cost model, ROI, $/run) exists on disk. A claim flips only by citing a
  receipt whose embedded output contains the measured number.
- **Subjects never conflated**: host BEAM (OTP 28 JIT) and browser wasm BEAM
  verdicts are reported in separate tables (§1 vs §3) with separate margins
  (6.02 ms vs 64-65 ms at t256), each tied to its own subject line.
- **Open boundaries typed**:
  - Threshold Wall: super-linear scaling wall LOCATED at N=512; hard
    boundary OPEN at N>4096 (untested, not refuted).
  - Worker-heap memory: UNMEASURABLE-(exposed-surface), with a typed close
    condition (Popcorn/harness exposing `WebAssembly.Memory` buffer size or
    CDP `Performance.getMetrics` on the worker target).
  - Contention: deterministic at the measured rungs (<=128 concurrent);
    no claim beyond them.
- Disclosures carried from sources: the S2 session incident (unguarded
  `receive` hang, killed stale beams, `timeout 120` fence added —
  `BENCH_SCVD.md`); the S9 row-delivery race in `browser_smoke.mjs` (1-of-3
  console-row delivery, disclosed not edited — `BENCH_SCVD.md` S9); the
  pre-existing in-wasm `kv` TCP SKIP (session-neutral across receipts).

## 7. Evidence appendix — exact command + exit per claim

| # | claim | command | exit | source |
|---|---|---|---|---|
| A1 | tier table, ramp medians, wall ratios | rows in `popcorn_demo/bench/scvd.jsonl` via `popcorn_demo/scripts/bench_scvd.sh`; 46 rows re-counted in-session (`wc -l` = 46) | 0 | `popcorn_demo/BENCH_SCVD.md` |
| A2 | 4096 rung: verified=4096, 293.6 ms median | `bench_scvd.sh` fresh-VM runs, 3x per rung under `timeout 120` | 0 | `BENCH_SCVD.md` ramp table |
| A3 | per-actor memory break past 2048 | S14-A2 extension rows (jsonl on disk) | 0 | `BENCH_SCVD.md` S14-A2 |
| A4 | in-browser ramp(256)/contention(128)/heap | `node scripts/browser_smoke.mjs` x3 (S14-A) | 0 x3 | `docs/jira/v26.10.20/receipts/scvd-browser-ramp-witness.md` |
| A5 | egress full PASS | `bash popcorn_demo/scripts/egress_gate.sh` | 0 | this session (output quoted below) |
| A6 | egress flip: URI-DNS | `bash popcorn_demo/scripts/egress_gate.sh --static /tmp/eg-flip` (foreign URL fixture) | 1 | this session |
| A7 | egress flip: IP-LITERAL | `bash popcorn_demo/scripts/egress_gate.sh --static /tmp/eg-flip` (203.0.113.9 fixture) | 1 | this session |
| A8 | egress static PASS direction | `bash popcorn_demo/scripts/egress_gate.sh --static /tmp/eg-pass` (loopback-only fixture) | 0 | this session |
| A9 | S1 engine receipt | `MIX_BUILD_ROOT=_build-s1 mix compile --warnings-as-errors` + gate legs | 0 | `popcorn_demo/receipts/v261020-s1-concurrency-ramp.md` |
| A10 | standing law for $ claims | `ls docs/jira/v26.10.20/scvd-ledger.md` | 0 | `scvd-ledger.md` §3 |

A5 verbatim output:

```
egress_gate stage1: static scan PASS over /Users/sac/smalt/popcorn_demo/lib + /Users/sac/smalt/popcorn_demo/public (URI-DNS / URI-HOSTVAR / IP-LITERAL / DNS-NAME; allowlist classes a-c)
egress_gate stage2: ramp row verified>0 + breaches=0; pgid-scoped sampler saw 0 non-loopback remote sockets
s1_ramp: %{
  n: 64,
  verified: 64,
  breaches: 0,
  p50_us: 7705,
  p99_us: 7756,
  reductions_total: 200506,
  wall_ms: 8.598
}
EGRESS_GATE_PASS (static+runtime)
```

A6 verbatim refusal: `EGRESS_GATE_REFUSED[URI_DNS]: non-loopback URL literal
outside the documented allowlist (...)` at
`/tmp/eg-flip/lib/bad.ex:1:https://evil.example.net/api`.
A7 verbatim refusal: `EGRESS_GATE_REFUSED[IP_LITERAL]: non-loopback IP
address literal` at `/tmp/eg-flip/lib/badip.ex:1:203.0.113.9`.

## See Also

- `docs/jira/v26.10.20/scvd-ledger.md` — PRD-to-reality ledger + standing law
- `popcorn_demo/BENCH_SCVD.md` — host bench summary + S9 memory section
- `popcorn_demo/bench/scvd.jsonl` — 46 raw rows
- `docs/jira/v26.10.20/receipts/scvd-browser-ramp-witness.md` — in-browser legs
- `popcorn_demo/receipts/v261020-s1-concurrency-ramp.md` — S1 engine receipt
- `docs/jira/v26.10.20/_LANES.md` — lane partition (this lane: S15)
