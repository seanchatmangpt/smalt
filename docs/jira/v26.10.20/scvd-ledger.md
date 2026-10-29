# scvd-ledger — SCVD PRD-to-reality ledger (v26.10.20)

Standing: PARTIAL_ALIVE (S1/S2/S3 all landed on disk; standing flips are
receipt-gated). Author: milestone-doc lane S5; refreshed by lane S16
(2026-10-20) against the landed wall. Every path named below was
`ls`/`grep`-verified on disk; nothing is asserted from memory. No GAP
tokens minted; no KD rows touched.

## 1. PRD requirement → on-disk reality map

### EXISTS — typed legs + three-state classification (= PRD outcome classes)

The PRD's outcome classes are realized as the testbed's three-state leg
contract, on disk in two forms:

- Leg receipt house style (`popcorn_demo/lib/popcorn_demo/live_cas.ex`
  moduledoc, shared by every `popcorn_demo/lib/popcorn_demo/live_*.ex`
  leg):
  `{:ok, "cas=OK(...)"}` / `{:skip, "cas=SKIP(substrate-down)"}` /
  `{:error, "cas=FAIL(<step>:<reason>)"}` — OK / loud-SKIP / typed-FAIL.
- Harness-core states (`popcorn_demo/lib/popcorn_demo/concurrency.ex`
  moduledoc): `:verified` / `:environment_skip` / `:invariance_breach`
  ("anything not byte-exact is a breach; the walk never coerces").

`environment_skip` is the SKIP law: an environment gap (wasm runtime
availability, substrate-down) is a typed environment face, never a
verification verdict and never a fake pass. The exit-code contract for
self-booting harnesses (0/1/2/3, SKIP is loud, never a fake pass) is fixed
in `/Users/sac/smalt/CLAUDE.md` §Commands.

### EXISTS — run-unique keying (= PRD zero-lock keying)

`popcorn_demo/lib/popcorn_demo/concurrency.ex` moduledoc: each actor's doc
set is keyed to the actor id (`"actor-<id>-doc-<i>"`, partition `"p<id>"`)
— actors share no mutable state, "isolation is by construction, not by
discipline". Run-uniqueness rides the actor id; the module exports named
test seams (`ramp/1`, `contention/1`, `walk/1`, `contention_actor/4`,
`assert_contention_final/2` — grep-verified against the module's `def`
lines; an earlier revision of this ledger named `expected_walk/1` and
`concurrency_actor/4`, which do not exist).

### EXISTS — receipts = the witness ledger

Two receipt stores, both gated by an index check that flags output-less
receipts SUSPECT:

- Window store: `docs/jira/v26.10.20/receipts/` (119 files at authoring
  time), indexed by `scripts/receipt_index.py`.
- Testbed store: `popcorn_demo/receipts/*.md` (timestamped witnesses, e.g.
  `popcorn_demo/receipts/20261021T013518Z-closure-final.md`, standing
  ALIVE, host legs exit 0, browser leg loud-SKIP), indexed by
  `popcorn_demo/scripts/receipt_index.py`.

A receipt with no embedded command output is SUSPECT; a bench leg with
zero good runs is FAIL, never a silent skip (`popcorn_demo/BENCH_LEGS.md`
fence law).

### EXISTS — transport = the wasm-transport SKIP law

`popcorn_demo/lib/popcorn_demo/transport.ex`: one behaviour, two REAL
implementations, no mocks — `Transport.Fetch` (browser `Popcorn.Fetch`;
on host it returns `{:error, :popcorn_fetch_unavailable}`) and
`Transport.Httpc` (real `:httpc`, hard loopback-only refusal,
`http://127.0.0.1`/`localhost`). The wasm constraint itself is pinned in
`popcorn_demo/README.md` (wasmex dynamic NIF loading unsupported; ETS/DETS
`Smalt.Store` shared tables noted as a wasm-BEAM constraint) — so a leg
that cannot run on a given target returns the typed SKIP face from §1
above; it never fakes a pass and never falls back to a mock.

### LANDED — S1 / S2 / S3

- **S1 — actor fan-out engine**: `popcorn_demo/lib/popcorn_demo/concurrency.ex`.
  `ramp/1` spawns N isolated actors running a deterministic in-memory
  verification walk over three shipped smalt modules (CosmosSql, SbRules,
  Registry); `contention/1` races N actors on one partition via ETS
  `insert_new` CAS. Zero-egress by construction (no `:httpc`, no
  `Popcorn.Fetch`, no sockets).
- **S2 — host-side SCVD bench**: LANDED — `popcorn_demo/scripts/bench_scvd.sh`
  exists on disk, 46 result rows in `popcorn_demo/bench/scvd.jsonl`
  (46/46 clean, zero errors, zero breaches), summary
  `popcorn_demo/BENCH_SCVD.md` (Threshold Wall located at N=512).
- **S3 — egress gate**: LANDED — `popcorn_demo/scripts/egress_gate.sh`
  exists on disk.

## 2. Reconciliation-engine requirement — falsifier spec on real seams

PRD requirement: reconcile staged state via "stage locally, hash, monotonic
conflict resolution on simulated connectivity". Mapping to seams that
ALREADY EXIST on disk — no new machinery proposed; each row names the wire
probe that would witness the property.

### 2a. Stage → hash — CAS leg (optimistic concurrency)

- Seam: `PopcornDemo.LiveCas.run/0`
  (`popcorn_demo/lib/popcorn_demo/live_cas.ex`) — GET real `_etag`, PUT
  with `If-Match: <fresh>` → 200, PUT with the stale etag → 412
  PreconditionFailed; server side is ONE atomic
  `Store.compare_and_swap` inside the Store GenServer
  (`lib/smalt/data_plane/cosmos.ex`). Gate twin:
  `gates/cosmos_etag_cas_gate.py` (verdict must REFUSE a mutated
  observation or it is vacuous).
- Property under falsification: "staging is locally hashed and committed
  only if the staged hash still matches the committed hash."
- Wire probe (witness shape): stage doc v1; GET etag E1; concurrent
  writer commits v2 (etag E2); staged PUT with `If-Match: E1` must 412,
  re-stage against E2 must 200; the committed body is v2 at every
  observation point. Falsified if the stale staged write lands 200 or the
  probe cannot distinguish v1/v2 on the wire (etag-less write must be
  refused or tagged, per `lib/smalt/data_plane/conditional_headers.ex`).

### 2b. Monotonic conflict resolution — blob WORM (immutability)

- Seam: `check_worm` / `worm_blocked?` in
  `lib/smalt/data_plane/blob_storage.ex` — locked containers return
  `409 ContainerLocked` on overwrite (lines 82/113/250 region); gate twin
  `gates/blob_worm_gate.py` (fail-closed, negative-fixture non-vacuity).
- Property: "once a version is admitted, no later writer can rewrite or
  delete it" — monotonicity of the admitted set.
- Wire probe: PUT policy-locked container; PUT blob v1 (200); attempt
  overwrite v2 → 409; attempt DELETE → 409 while the lock window covers
  `now` (per `check_worm(container_meta, now)`); GET still returns v1
  byte-exact. Falsified if any write path reaches the blob after lock
  (the "real Azure permits new-blob writes into locked containers"
  pinion from `~/.claude/rules/testing-chicago-style.md` applies: the
  probe must distinguish append-of-new vs rewrite-of-admitted and pin
  which face the emulator exposes — register row if it diverges).

### 2c. Simulated connectivity — queue redelivery (at-least-once)

- Seam: AMQP delivery header `delivery_count` on the wire
  (`lib/smalt/messaging/amqp/delivery_encoder.ex` builds
  `header: %{delivery_count: n}`; `frame_codec.ex` carries
  `:initial_delivery_count` / `:delivery_count`); invariant driver
  `gates/amqp_invariant_driver.exs`; gate twin
  `gates/queue_capacity_gate.py`.
- Property: "a delivery that is sent-but-not-settled is re-delivered with
  monotonically increasing `delivery_count` — at-least-once, never
  silently dropped."
- Wire probe: send one message; receiver takes the delivery and does NOT
  settle (abandon/no terminal outcome); bounded poll (no sleeps —
  `SmaltTest.AssertEventually` discipline) until redelivery; assert the
  redelivery carries `delivery_count: n+1` and identical payload bytes.
  Falsified if the message is dropped, delivered-zero-times, or
  re-delivered with a non-monotonic count.

### Spec discipline

Each probe above rides an existing gate with a non-vacuity contract: the
gate must exit 1 on the mutated/negative fixture (`gates/common.py`
family). A probe that cannot fail is not a witness. All three properties
compose the reconciliation-engine requirement without inventing new
primitives (dfcm-composition law: compose existing seams, don't reinvent).

## 3. Standing law — economic claims

Every PRD dollar/economic claim is **UNSUPPORTED** until a measured
counterpart exists on disk. The only measured perf counterparts in the
window are the bench jsonl rows (`popcorn_demo/bench/legs.jsonl`,
`popcorn_demo/bench/browser-legs.jsonl`) and their ratio-fenced summaries
(`popcorn_demo/BENCH_LEGS.md`, `popcorn_demo/BENCH_BROWSER.md`,
`popcorn_demo/BENCH_COOK.md`). No prose valuation (cost model, ROI, $/run)
exists anywhere on disk; until one is derived from measured rows, every
PRD economic figure carries standing UNSUPPORTED — never PARTIAL by
narration. A claim flips only by citing a receipt whose embedded output
contains the measured number.

## See Also

- `docs/jira/v26.10.20/PLANNING.md` — window WO table
- `docs/jira/v26.10.20/_LANES.md` — lane partition (this lane: S5)
- `popcorn_demo/README.md` — testbed canonical doc
- `docs/TESTBED.md` — testbed gate inventory

## Azure emulator deep-research (2026-10-21, 100-agent cited run)

Full report: docs/jira/v26.10.20/receipts/azure-emulators-deep-research.md.
Key external validation: Microsoft's first-party emulators (Azurite, SB emulator,
Cosmos vNext) track the same emulator-vs-live divergence classes smalt's KD
register tracks; the Azure SDK guidelines (general-testing-6/8/9) sanction
smalt's offline/version-pinned/differential test shape as guideline-native.
Integration cautions: Azurite port 10000-10002 collision check vs smalt's plan;
SB emulator is .NET-native management (raw HTTP 5300 is the non-native path);
Cosmos vNext has no auth enforcement (smalt :enforce stays the auth-verified
surface).
