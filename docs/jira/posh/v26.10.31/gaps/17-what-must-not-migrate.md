# GAP-17: What Must NOT Migrate — smalt-SOVEREIGN Assets (negative-space lane)

Lane 17 of 17, unification-dialect migration. Companion to
`00-unification-dialect-decision.md` (laws 1–4) and `gaps/01` (sovereign-vs-dialect
classification method). Where gaps/01–16 classify what moves into posh, this file is
the normative complement: the assets that are charter violations to move, each with
the governing rule, the wazero generalization, and a detection tripwire.

Status line: **PARTIAL** — enumeration and tripwires are written from receipts read
this session (00-decision, gaps/01, gaps/06, gaps/04-posh-vs-charter v26.10.30,
charter-master §2, `lib/smalt/registry.ex` header). Wired 2026-10-30 (gap lane M17):
`scripts/must_not_migrate_gate.py` + `just tripwire-gate`
(`justfile.d/61-tripwire.just`) enforce F1 (GraphLaw admission defmodules outside
`lib/smalt/graphlaw_ex/`, `lib/smalt/graphlaw/`, `lib/smalt/affidavit/`,
`priv/ontologies/`), F2 (turnstile/settlement/event-log logic in
`lib/smalt/arm_gateway/` — non-delegating owners and `Smalt.Posh.*` namespace
claims outside `lib/smalt/posh/` are refused), and F2b (BLAKE3 kernel
`posh/internal/receipt/blake3.go` pinned byte-identical, sha256
`5f2e3944…b9641`, pinned 2026-10-30). Extended 2026-10-30 (wave-2 gap lane):
T1 (posh-Go store/ledger imports: sqlite/bolt/badger/leveldb/pebble/
database/sql — import-line matched so prose mentions do not false-positive;
plus un-pinned `.ttl` reads in posh Go), T3's mechanical core (persisted
ledger/settlement/state file writes from posh Go, string-literal paths), and
T5's mechanical core (posh Go writing `.go` sources — a second projection
identity). T3's arm_gateway delegation clause is realized by the F2
non-delegating-owner detector. T4 is NOT MECHANICAL YET: its subject
(`apps/web/test/harness`) does not exist in this tree — a detector over an
absent subject is vacuous by construction; recorded here and in the gate
docstring. Fail-closed; non-vacuity via /tmp scratch-copy self-check
(injected F1/F2/F2b/T1/T3/T5 mutations each refused, restored tree clean,
repo never mutated). Every SOVEREIGN row cites a live smalt surface.

## The Forbidden List (normative)

| # | SOVEREIGN asset | Live surface (smalt) | Governing rule | Why migration is a charter violation |
|---|---|---|---|---|
| F1 | **GraphLaw admission + ontology ttl** | `lib/smalt/graphlaw*`, admission ttl sources; law 2 of 00-decision | Charter BEAM invariant / law 2: dialects are *admitted*, they do not admit | posh admitting routes would be dialect #N claiming admission authority. Witnessed failure mode: `internal/wasm` compiled arbitrary bytes by name (gaps/06: engine.go:123-143, no pin, no allowlist) |
| F2 | **Turnstile / receipt settlement + event log** | `lib/smalt/posh/turnstile.ex`, `lib/smalt/posh/egress/{settlement,event_log}.ex`; the gaps/14 boundary | Receipt law: R=receipt(A); every state transition settles on the sovereign side | A posh-owned settlement ledger is a second implementation of the receipt calculus (O(N²) drift); gap 04 already flags heap-crypto as a disclosed v1 trade — not an authority to relocate |
| F2b | **The one allowed exception, pinned** | `posh/internal/receipt/` pure-Go BLAKE3 kernel, KEEP per gaps/06 inheritance clause | Gaps/06 inheritance clause | The kernel is allowed *because* it is byte-identical to the Elixir lane (`R = BLAKE3(op‖ts‖body)`) and holds no authority — it computes receipts, it does not settle them. Any drift from byte-identity, or any settlement decision inside posh, converts it to F2 territory |
| F3 | **Store/ETS state + supervision trees** | `lib/smalt/application.ex`, supervision trees, ETS-owned state | SPAF Rule 1 (Go stateless, charter-master §2) + BEAM invariant | State in posh = the shim owns domain state → "stops being a shim" (law 4). 67 GB orphaned lane build roots witnessed what posh-owned state does to the fleet (same-checkout-fanout cleanup law) |
| F4 | **ggen projection discipline + Turtle ontologies** | `lib/smalt/registry.ex` ("DO NOT EDIT — regenerate with `mix smalt.gen`"; projected from smalt-substrate-pack) | Law 2: registry.ex is generated, never hand-edited; the graph IS the allowlist | A hand-edited posh registry is exactly the arbitrary-byte admission poshvet exists to reject; the graph is the admission source, projection is one-directional graph→code |
| F5 | **Courts / receipts discipline** | `docs/jira/posh/*/dfcharter/*`, posh-court gate, affidavit courts | smalt's verification sovereignty; chicago-style real-collaborator law | If posh courts its own changes, the court verifies the court — tautological-test class, zero bits. Courts live where authority lives: BEAM/smalt |
| F6 | **registry.ex generation path** | `mix smalt.gen` + ggen_igniter.sync from smalt-substrate-pack | Law 2 (admission via ontology ttl + regen) | Same class as F4: the *generator path* (not just the artifact) must stay sovereign; a posh-side generator is a second projection identity without a generator-plurality court (C20) |
| F7 | **Ingress/egress turnstile supervision** | `lib/smalt/posh/supervisor.ex`, `egress_router.ex` | BEAM invariant: BEAM actors orchestrate supervision + turnstile routing | A Go-owned supervisor re-implements supervision badly (no-sleep-testing law 2: "supervision owns retries"); supervision trees are BEAM-native state machinery |
| F8 | **Harness substrate-state assertions** | `apps/web/test/harness/**` (lane 4 receipt: real HTTP vs smalt plane, zero mocks) | Chicago discipline: harness verifies smalt, not posh | A harness asserting posh's internal state verifies the shim's model, not the substrate — London-class, banned by default; substrate assertions point at 127.0.0.1:9443/8443 only |

## The wazero lesson, generalized

The one SPAF violation found all wave (v26.10.30, gaps/04 + gaps/06): `posh/internal/wasm`
was a Go-side engine that compiled **arbitrary bytes by name** — no sha256 pin, no
import allowlist, no ABI handshake — and was dead code besides. KILLED in gaps/06 with
named inheritance (receipt kernel KEEP, ABI shape → Phase-4 Rust kernel, Chicago test
pattern → kernel court).

Generalization (the tripwire predicate): **any posh component that owns state or
admission stops being a shim.** Concretely, a component is accreting sovereignty if it
gains any of:

1. **Arbitrary-byte or by-name loading** of anything executable or schema-like without
   sha256 pin + allowlist + handshake.
2. **A ledger** — persisted settlement/event/receipt state it can read back.
3. **A decision** — it emits pass/fail on *admissibility* (vs translating an already-
   admitted wire shape).
4. **A hand-edited projection** — `posh.yaml` (ceiling) or generated code edited
   instead of regenerating from the graph.

## Accretion tripwires (T2 + the smalt-side inverse of T2b wired 2026-10-30 via `scripts/must_not_migrate_gate.py`)

| Tripwire | Mechanism | Detects |
|---|---|---|
| T1 | poshvet analyzer pass: flag `os.WriteFile`, sqlite/bolt/leveldb/badger imports, `embed`/`os.ReadFile` of schema-like files without adjacent sha256 pin | F1/F3/F4 — state or schema ownership |
| T2 | grep gate on posh imports: deny `internal/receipt` consumers that *decide* rather than compute (settlement verbs: `settle`, `commit`, `finalize` on posh side) | F2 — settlement authority leak |
| T2b | grep gate on smalt side (inverse): deny hand-edits under generated headers ("DO NOT EDIT") without a regen receipt | F4/F6 — hand-edited projection |
| T3 | charter-conformance court: extend the v26.10.30 gaps/04 law-by-law table into a permanent gate that exits 1 on any new posh package owning state/admission/ledgers | F1–F7 — accretion generally; a gate that never refuses is VACUOUS |
| T4 | harness address allowlist: harness tests may assert only smalt plane surfaces (9443/8443) and posh egress ceilings; posh internal state is not an assertable surface | F8 — harness drift toward London |
| T5 | generator-plurality court (C20): posh-side projection, if ever proposed, must double-compile against frozen ggen and agree byte-identically | F6 — second projection identity |

T1 partially exists (poshvet + `make poshvet-budget`); T2 (posh-side settlement
verbs) and the smalt-side F1/F2 detection are wired in
`scripts/must_not_migrate_gate.py`; T3 remains the close condition for full
accretion coverage. A tripwire that cannot flip (never refuses a real accretion
mutation) is FAIL per shim-court non-vacuity law — the wired gate runs its
scratch-copy self-check on every invocation.

## Status line

- **ALIVE**: enumeration read from live receipts this session (00-decision laws 1-4,
  gaps/01, gaps/06, gaps/04 v26.10.30, charter-master §2, registry.ex header,
  posh Makefile poshvet targets).
- **ALIVE**: tripwire gate wired 2026-10-30 — `scripts/must_not_migrate_gate.py`
  (`just tripwire-gate`, `justfile.d/61-tripwire.just`); F1/F2/F2b enforced with
  a scratch-copy non-vacuity self-check; live tree clean at wiring time.
- **ALIVE**: T1/T3/T5 mechanical cores extended 2026-10-30 (wave-2 gap lane) —
  gate exit 0 with every detector red-before-green self-checked on /tmp
  scratch copies (F1, F2, F2b, T1 store-import, T1 un-pinned .ttl read, T3
  ledger write, T5 projection write; restored tree clean). Live tree clean.
- **NOT MECHANICAL YET**: T4 (harness address allowlist) — subject
  `apps/web/test/harness` absent in this tree; a detector over an absent
  subject is vacuous by construction (loudly recorded in the gate docstring,
  not silently skipped).
- **PARTIAL overall**: F1/F2/F2b fully enforced; T1/T3/T5 mechanical cores
  enforced (full charter-court breadth of T3 and the C20 double-compile
  behind T5 remain open); T4 blocked on harness subject existing; F3–F8
  enforcement beyond the wired predicates is not.

## See Also

- `00-unification-dialect-decision.md` (laws 1–4)
- `gaps/01-sts-migration.md` (sovereign-vs-dialect classification, positive space)
- `gaps/06-wasm-disposition.md` (the wazero lesson, KILL verdict + inheritance)
- `v26.10.30/gaps/04-posh-vs-charter.md` (SPAF law-by-law audit, the wave's one violation)
- `v26.10.30/dfcharter/charter-master.md` §2 (SPAF contract)
