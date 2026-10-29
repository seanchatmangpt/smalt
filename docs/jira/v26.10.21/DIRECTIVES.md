# Standing Charter: Cross-Language Falsification (operator directive, 2026-10-21)

Standing: **ALIVE** (charter landed; instances accrue receipt-gated)
Context: solo · Date: 2026-10-21 · Repo: /Users/sac/smalt
Owner: milestone-doc lane; instances owned by their landing lanes
(ECOURT first). Charter text is standing; instance standing lives in the
instance's own receipt.

This charter is a standing directive, not a wave artifact: it binds every
future window until the operator revokes it. It lives beside the
validation board (`VALIDATION.md`) and the KD register
(`KNOWN_DIVERGENCES.md` → canonical
`../v26.10.14/KNOWN_DIVERGENCES.md`).

## 1. The Erlang-court mandate

**Primary wire courts are written in pure Erlang, not Elixir.**

- Location: `test/courts/court_*.erl` (directory does not exist yet;
  ECOURT is landing the first instance — landing, not landed).
- Zero Elixir helpers: no `.exs` harness, no Elixir test framework, no
  `SmaltTest.*` — the court compiles and runs as plain Erlang against the
  substrate's compiled beams. Raw sockets and raw bit-syntax assertions
  only; no borrowed serializer for the subject under test.
- Mandate scope: wire surfaces (AMQP frame codec, AMQP10 frame decoder,
  primitive/CBS encodings, and successors). An Elixir court may still
  exist alongside, but the *primary* court — the one whose receipt flips
  standing — is the Erlang one.
- First instance: ECOURT lane, `test/courts/court_*.erl` against the
  AMQP surface. Its receipt names its exact subject, commands, exits,
  and standing; until that receipt lands, the mandate itself is landed
  as charter but unexercised (PARTIAL_ALIVE at the instance level).

## 2. Differential promotion rule for `smalt_amqp10_*`

The pure-Erlang AMQP10 path promotes over the Elixir hot wire path only
by clearing all four gates. Promotion flips the hot wire path — the
Elixir implementation is relegated to routing/telemetry/UI and is not
deleted, it is demoted.

**Gate 1 — wire parity.** Byte-level parity with the incumbent path on
the real wire surface, including regression of the 7 wire KDs named in
the canonical register (`../v26.10.14/KNOWN_DIVERGENCES.md`; the
wire-compat pinions: SASL ANONYMOUS only, sasl-outcome descriptor 0x44,
attach top-level ≤14 with locale fields omitted, .NET-GUID lock-token
byte reordering, EH fixed partitions `["0","1"]`) and a leg against the
real `@azure/service-bus` SDK. A real-SDK leg is a real-SDK leg: zero
skips, loud SKIP is not pass.

**Gate 2 — throughput: beat 268.3 reds/frame.** The promotion
denominator named by the operator is **268.3 reds/frame**; the Erlang
candidate must beat it, not match it. On-disk context: the only landed
reds/frame measurement in this window is impl13's frame bench
(`receipts/impl13-jit-2912.md`): **254.3 reds/frame** on 29.1.2, 254.3
on 28.3.1, over one 1582-byte Service-Bus-dialect transfer frame — the
268.3 denominator is the named promotion bar the candidate must beat,
measured under the identical bench shape (impl13's harness: pure module
calls, best-of-5 rounds, 3 runs) under the pinned 29.1.2 toolchain
(`popcorn_demo/.tool-versions`, IMPL-9). If a landed IMPL-17 receipt
re-baselines the number, the register of truth is the receipt on disk,
not this charter's prose.

**Gate 3 — memory: 0-word heap delta.** The candidate's hot decode loop
must show a 0-word caller-heap delta under the same tracing shape used
by `receipts/impl1-process-iterator.md` (iterator caller-heap delta
0 words vs 514,605 for the materializing path). Heap-delta court runs
on the pinned toolchain; a delta > 0 fails the gate.

**Gate 4 — teardown: < 15 µs.** Process teardown (connection/session/
link teardown round trip on the real listener) under 15 µs per link,
min-of-N, pinned toolchain.

**Promotion semantics.** Clearing all four gates flips the hot wire
path to the Erlang candidate; Elixir retains routing, telemetry, and
UI surfaces. A wire-compat break at any point after promotion re-types
the promoted path **QUARANTINED** (typed standing, not prose): the
candidate is demoted back, the falsifier that broke it is named in the
KD register, and the Elixir path is restored as the hot path. A
wire-compat break before promotion is an ordinary gate failure — no
QUARANTINED type, the candidate simply has not cleared Gate 1.

## 3. Shared-illusion rationale

Same-language courts mirror the SUT's blind spots. An Elixir court
against an Elixir codec shares its serializer idioms, its pattern-match
laziness, its byte-order assumptions, and its test-framework scaffolding
— a bug baked into the idiom is invisible to the court that speaks the
idiom. A pure-Erlang court shares only the wire: it asserts on raw
bytes over a raw socket, so the only thing it can confirm is the thing
that crosses the process boundary. This is the cross-language analogue
of the shim-court non-vacuity law (a gate that cannot flip is the
failure) and of the Chicago discipline (assert on real state, real
collaborators): the real collaborator here is the wire itself, read
with a different lens.

## 4. Receipt requirements

- Every instance receipt: doc path, exact subject, commands, exits,
  standing line, and `Context:` field (v26.10.17 law).
- Charter flips (mandate revoked/amended, gate thresholds changed) are
  operator acts, receipted in this file by the milestone-doc lane.
- `just docs-dod-check` applies: every receipt path named here must
  exist on disk.

## TTV ledger (operator Pareto list, 2026-10-21) — whitepaper §6 threats neutralization

| WO | Item | Files | Owner | Dispatch | Receipt |
|---|---|---|---|---|whitepaper |
| TTV-1 (D1) | Clamp wire atom minting (cosmos_sql.ex:766, fuzz gate atom_count delta ≡ 0) | lib/smalt/cosmos_sql.ex | JA-R3 (in-flight) | tick 19:0x | ja-r3-ja16-defect-fixes.md |
| TTV-2 (D2) | CA-file load failures observable (typed error + Logger) | lib/smalt/auth/x_arr_cert.ex | JA-R3 (in-flight) | tick 19:0x | ja-r3-ja16-defect-fixes.md |
| TTV-3 (D3) | Quota fallback → typed backpressure + telemetry | lib/smalt/messaging/eh_throttle.ex | JA-R3 (in-flight) | receipt | ja-r3-ja16-defect-fixes.md |
| TTV-4 | Wire JournalReader boot-replay into Smalt.Store init; gate = kill under flight, zero committed-key loss | lib/smalt/store.ex, lib/smalt/storage/journal_reader.ex | TTV-4 lane | QUEUED | pending |
| TTV-5 | Partition Smalt.Store (table-level striping, heir+give-away, adopt-then-replay) | lib/smalt/store.ex, store/heir.ex, store/partition.ex | TTV-5 lane (landed) | tick ~22:00 | ttv5-store-partitioning.md ALIVE |
| TTV-6 | Re-baseline release cold-boot gate (defer non-critical trees OR re-type ceiling 500ms→2000ms per measured 1,906ms; operator decision defaulting to measured-ceiling re-type with falsifier named) | t47-release-boot-gate.md + charter line in DIRECTIVES.md | ttv6 lane | 2026-10-21 | ttv6-cold-boot-gate.md — CLOSED: ceiling re-typed 500→2,000ms (operator-defaulted), falsifier named |
| TTV-7 | Formalize reductions-first reporting standard for sub-10µs benches (47.24 reds/step primary; wall-clock tail = scheduler artifact) | docs/jira/v26.10.21/BENCH-ERLANG.md + gl9 receipt addendum | QUEUED | — | pending |
| TTV-8 | Type hot-upgrade Explicitly-Unsupported/Crash-Only-Preferred in release charter; note 64MiB = host-layer boundary in WASM-SANDBOX-SPEC §1 | docs/jira/v26.10.21/receipts/ja14-release-handling.md (exists, ALIVE), WASM-SANDBOX-SPEC §1 | QUEUED | — | pending |

## Release & upgrade charter (TTV-8, operator directive, 2026-10-21)

Standing: **ALIVE** (charter) · Context: solo

- **Hot-code upgrade is Explicitly Unsupported.** Crash-only
  stop→rebuild→restart is the preferred upgrade path. Evidence:
  `receipts/ja14-release-handling.md` (zero `.appup`/`.relup`/
  `code_change` across the release surface ×34);
  `receipts/ja12-hot-reload-court.md` proves the hot-reload mechanism
  works when wanted, but this charter does not commit to it as a
  supported path.
- **ML-KEM preference durability**: the post-quantum group preference
  (`[:x25519mlkem768, ...]` on tlsv1.3) is a standing release property —
  `receipts/imp14-mlkem-flip.md` (PARTIAL_ALIVE).

Every receipt path named here must exist on disk (`just docs-dod-check`).

## Release cold-boot budget (TTV-6, operator directive, 2026-10-21)

Standing: **ALIVE** (charter) · Context: solo

- **Ceiling re-typed: 500 ms → 2,000 ms** for release cold
  boot-to-all-listeners (production builds, quiet machine). This is an
  **operator-defaulted measured-ceiling re-type** per the charter law
  above (§4: charter/gate-threshold changes are operator acts, receipted
  here). Evidence: `receipts/t47-release-boot-gate.md` (best quiet
  cold boot 1,906 ms — 3.8x the old ceiling; the residual floor is
  erts/beam boot + code load of the compressed beam set, not mix) and
  `receipts/ttv6-cold-boot-gate.md` (HEAD re-measurement confirming
  FAIL vs 500 ms; loaded-machine cold walls 9.5-19 s are load-bound,
  not the baseline).
- **Falsifier (re-opens the gate)**: a quiet-machine cold boot past
  4,000 ms (2x the new ceiling), or a warm stop→start cycle exceeding
  cold-boot × 1.5 (i.e. > 3,000 ms against the 2,000 ms baseline).
  Load-bound runs (other lanes' beams resident) are excluded from the
  baseline and from falsifier firing — the same load-flake residual
  class typed in BK-1.
- **Warm-restart defect stands**: `bin/smalt restart` (`System.restart/0`)
  reproducibly fails to rebind listeners — typed defect in
  `receipts/t47-release-boot-gate.md`, re-witnessed in
  `receipts/ttv6-cold-boot-gate.md` (rebind_ok=0). Warm recovery is
  stop→start only until the defect closes.
