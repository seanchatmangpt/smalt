# 14 — Boundary Annex: What Must NOT Migrate (Forbidden List, Accretion Test, Tripwires)

Status: PARTIAL_ALIVE — consolidation annex; every load-bearing claim cites its
source file and is NOT restated in full here. Enumeration is normative-as-written
(PARTIAL per source); enforcement is not wired (T1 partial poshvet, T2–T5 PLANNED).

Sources (as-of their own receipts, read 2026-10-30):
- Primary: `/Users/sac/smalt/docs/jira/posh/v26.10.31/gaps/17-what-must-not-migrate.md`
  (M17, the negative-space lane)
- Worked example: `/Users/sac/smalt/docs/jira/posh/v26.10.31/gaps/06-wasm-disposition.md`
  (M6, wazero KILL with named inheritance)
- "What stays" anchor: `/Users/sac/smalt/docs/jira/posh/v26.10.31/gaps/14-turnstile-neutrality.md`
  (M14, provider-neutral turnstile boundary statement)
- Governing contract: `/Users/sac/smalt/docs/jira/posh/v26.10.30/dfcharter/charter-master.md`
  §2 (SPAF Rules 1–3) + `docs/jira/posh/v26.10.31/gaps/00-unification-dialect-decision.md`
  (laws 1–4)

Where gaps/01–16 classify what moves into posh, this annex is the normative
complement: the assets whose migration is a charter violation, the four-predicate
test for detecting accretion, and the tripwires that make refusal mechanical.

## A. The Forbidden List (F1–F8)

Normative table lives at M17 §"The Forbidden List" — cite by row, do not restate.
Summary register (each row = SOVEREIGN asset → governing rule → violation class):

| Row | SOVEREIGN asset (smalt surface) | Forbidding rule |
|---|---|---|
| F1 | GraphLaw admission + ontology ttl (`lib/smalt/graphlaw*`) | Charter BEAM invariant / law 2 — dialects are admitted, they do not admit |
| F2 | Turnstile / receipt settlement + event log (`lib/smalt/posh/turnstile.ex`, `egress/{settlement,event_log}.ex`) | Receipt law R=receipt(A); settlement stays sovereign-side |
| F2b | The one pinned exception: `posh/internal/receipt/` pure-Go BLAKE3 kernel — KEEP only while byte-identical to the Elixir lane and authority-free | Gaps/06 inheritance clause |
| F3 | Store/ETS state + supervision trees (`lib/smalt/application.ex`) | SPAF Rule 1 (Go stateless) + law 4 ("stops being a shim") |
| F4 | ggen projection discipline + Turtle ontologies (`lib/smalt/registry.ex` DO-NOT-EDIT header) | Law 2 — the graph IS the allowlist; projection is one-directional |
| F5 | Courts / receipts discipline (posh-court gate, affidavit courts) | Verification sovereignty — a posh-self-court is tautological, zero bits |
| F6 | registry.ex generation path (`mix smalt.gen` + ggen_igniter.sync) | Law 2 — the generator path stays sovereign; second projection identity without a C20 court |
| F7 | Ingress/egress turnstile supervision (`lib/smalt/posh/supervisor.ex`, `egress_router.ex`) | BEAM invariant — supervision trees are BEAM-native (no-sleep-testing law 2) |
| F8 | Harness substrate-state assertions (`apps/web/test/harness/**`) | Chicago discipline — harness verifies smalt at 127.0.0.1:9443/8443 only, never posh internals |

Full why-migration-is-a-violation column: M17 table rows F1–F8.

## B. The 4-predicate accretion test

A posh component is accreting sovereignty — and thereby converts itself from shim
to charter violation — if it gains any of (M17 §"The wazero lesson, generalized"):

1. **Arbitrary-byte or by-name loading** of anything executable or schema-like
   without sha256 pin + allowlist + handshake.
2. **A ledger** — persisted settlement/event/receipt state it can read back.
3. **A decision** — it emits pass/fail on *admissibility* (vs translating an
   already-admitted wire shape).
4. **A hand-edited projection** — `posh.yaml` (ceiling) or generated code edited
   instead of regenerating from the graph.

## C. Worked example: M6's wazero KILL

The wave's one SPAF violation (v26.10.30 gaps/04 + gaps/06) was predicate-1
exactly: `posh/internal/wasm` compiled arbitrary bytes by name
(`engine.go:123-143` — no pin, no allowlist, no ABI handshake) and was dead code.
Verdict KILL with named inheritance (gaps/06): admission authority never lives in
posh; BEAM `Affidavit.WasmEngine` remains the sole court-execution substrate;
`internal/receipt/` is the F2b-shaped KEEP (byte-identical kernel, no authority);
host-fn ABI shape and the three Chicago court artifacts carry forward to the
Phase-4 Rust kernel. This is the precedent the 4-predicate test generalizes: any
future candidate failing any predicate gets the same KILL-with-inheritance
treatment, not a migration.

## D. What stays: M14's turnstile boundary statement

The positive-space anchor is M14's normative boundary statement ("The turnstile
receipt law is provider-neutral", cited verbatim-range at
`gaps/14-turnstile-neutrality.md` §Boundary statement): a delta is receipted iff
`BLAKE3(op_utf8 || u64BE(ts_ns) || payload_body)` exists for it (three inputs —
the four-input formula is a false citation, see M14 Violations §1 and the INDEX
digest correction), it carries the `X-Smalt-Receipt-Turnstile` header on the
wire, and the mutation is admitted through the turnstile fence with typed
`AdmissionRefused` refusal settled into the prev-hash-chained event log. No
clause names a provider, resource type, ARM shape, or credential system —
provider identity is lane 1's STS bearer boundary, referenced not duplicated.

That statement is what the forbidden list protects: F2 is the settlement side of
exactly this law, F2b the sole allowed kernel beneath it, F7 its supervision.

## E. Accretion tripwires (T1–T5) — honest statuses

Mechanism table: M17 §"Accretion tripwires". Status register (re-read 2026-10-30):

| Tripwire | Detects | Status |
|---|---|---|
| T1 | F1/F3/F4 — poshvet analyzer pass flagging `os.WriteFile`, embedded KV-store imports, un-pinned schema-like reads | **PARTIAL** — poshvet + `make poshvet-budget` exist; the accretion pass is unextended |
| T2 | F2 — settlement-authority leak (posh-side `settle`/`commit`/`finalize` verbs over `internal/receipt`) | **PLANNED** |
| T2b | F4/F6 — smalt-side inverse gate: hand-edits under DO-NOT-EDIT headers without a regen receipt | **PLANNED** |
| T3 | F1–F7 — charter-conformance gate extending the v26.10.30 gaps/04 law-by-law table, exits 1 on new posh state/admission/ledger ownership | **PLANNED** |
| T4 | F8 — harness address allowlist (9443/8443 + egress ceilings only) | **PLANNED** |
| T5 | F6 — generator-plurality court (C20) for any proposed posh-side projection | **PLANNED** |

Wiring T2/T2b/T3 is the close condition for M17. Non-vacuity law applies to all
six: a tripwire that cannot flip on a real accretion mutation is FAIL
(shim-court non-vacuity).

## Sources

- `/Users/sac/smalt/docs/jira/posh/v26.10.31/gaps/17-what-must-not-migrate.md`
- `/Users/sac/smalt/docs/jira/posh/v26.10.31/gaps/06-wasm-disposition.md`
- `/Users/sac/smalt/docs/jira/posh/v26.10.31/gaps/14-turnstile-neutrality.md`
- `/Users/sac/smalt/docs/jira/posh/v26.10.31/gaps/00-unification-dialect-decision.md`
- `/Users/sac/smalt/docs/jira/posh/v26.10.30/dfcharter/charter-master.md` §2
- `/Users/sac/smalt/docs/jira/v26.10.31/gaps/INDEX.md` (digest-correction banner)

## See Also

- `11-credential-admission-annexes.md` (sibling consolidation annex, same window)
- `10-migration-phases-normative.md` (phases whose scope this annex bounds)
