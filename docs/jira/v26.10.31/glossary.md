# posh Glossary (v26.10.31 copy)

Copied from `posh/v26.10.30/glossary.md` (consolidation lane 8/15, 2026-10-30);
the original stays untouched in v26.10.30. The bilingual table below is the
dialect-#1 sub-glossary (per `posh/v26.10.31/gaps/15-doc-migration-plan.md`
Tier A row).

## Neutral-core glossary (v26.10.31)

Vendor-neutral terms of the smalt-core membrane. Each entry cites its source
gap or charter anchor.

| Term | Definition | Source |
|---|---|---|
| **Port In** | The membrane's dialect-facing ingress: an insulated, fail-closed validation and bounding lane (ring-buffer intake, admission before any state transition). Absorbs untrusted shock; crashes the isolated actor on invariant failure (Andon RED). | `posh/v26.10.30/dfcharter/triz.md:25-27,59-60,70` |
| **Starboard Out** | The membrane's smalt-core-facing egress: unhindered laminar outbound flow at raw wire speed over zero-copy binary membranes. | `posh/v26.10.30/dfcharter/triz.md:25-27,59-60` |
| **Turnstile + receipt** | Mutation fence: a delta passes only with a receipt header `X-Smalt-Receipt-Turnstile` carrying the 32-byte/64-hex BLAKE3 digest `BLAKE3(op ‖ ts_ns ‖ payload_body)` (3-input — the 4-input `(delta ‖ node_id ‖ …)` dispatch premise was corrected; see the M14 header note in `gaps/INDEX.md`). | `posh/v26.10.31/gaps/14-turnstile-neutrality.md:20-26,52-54`; header `X-Smalt-Receipt-Turnstile` per `posh/v26.10.31/gaps/11-harness-coupling.md:31` |
| **Dialect #0** | The Entra-shaped STS wire face (identity/Entra STS) — the token-issuance dialect. | `posh/v26.10.31/00-unification-dialect-decision.md`; verdict per `posh/v26.10.31/gaps/01-sts-migration.md` |
| **Dialect #1** | The Azure ARM face (the azurerm swap), kept byte-identical; reclassified from native semantics to a vendor shim living in posh. | `posh/v26.10.31/00-unification-dialect-decision.md` (Decision + law 1) |
| **Dialect-n** | The growth path: further vendor translation layers (first non-Azure consumer: Stripe or Datadog per charter consumer list), each mapping into smalt-core; dialects live and die in posh. | `posh/v26.10.31/00-unification-dialect-decision.md` (additive path; law 1) |
| **Neutral core** | smalt-core: a vendor-neutral public-cloud ontology (prior art first: OASIS TOSCA node types + DMTF CIMI) serving as the ontology-gated admission layer ABOVE existing registry families; smalt never grows a per-vendor face. Landed artifact: `posh/v26.10.31/smalt-core.ttl`. | `posh/v26.10.31/00-unification-dialect-decision.md`; `posh/v26.10.31/smalt-core.ttl` |
| **Membrane** | The peripheral posh boundary (charter §1/§3 Rule 1): Port In on one side, Starboard Out on the other, dialect faces and turnstiles embedded; posh stays stateless and disposable (SPAF Rule 1). Code-side realization: `MembraneOp` + the generated op registry. | `posh/v26.10.30/charter-master.md §1/§3`; `glossary.md` rows 8/12; decision-record law 4 |
| **GraphLaw admission** | Ontology-gated admission mechanics (carries over unchanged): new faces close via ontology ttl + regen; GraphLaw refuses ad-hoc routes; `registry.ex` is generated, never hand-edited. Forbidden to migrate out of core (F1). | `posh/v26.10.31/00-unification-dialect-decision.md` (law 2, carries-over); `posh/v26.10.31/gaps/17-what-must-not-migrate.md` (F1) |
| **Compat pin** | Registry-pinning split into two pin loads: CORE pin (`compat-pin-core.ttl`, smalt repo root, substrate-owned) vs AZURERM-DIALECT pin (`adapters/terraform-provider-smalt/compat-pin.ttl`); one binary, two checks (`compat_pin_check.py --core-pin / --dialect-pin`). | `posh/v26.10.31/gaps/12-compat-pin-split.md` |
| **Andon** | Signal register (BUILD/TEST/LINT/INVARIANT carrying GREEN/YELLOW/RED) raised at Port In on invariant failure: signal RED, crash the isolated actor, stop the line. In v26.10.30 realized as a 7-stage DoD ladder (`posh/cmd/andon`), standalone — not a court stage. | `posh/v26.10.30/dfcharter/andon.md`; `charter-master.md §6`; `posh/v26.10.30/dfcharter/triz.md:70`; divergence register row 3 |
| **Invariant gate** | The SPARQL-over-ingress/egress-graphs court (100% routes terminate in turnstiles, 0 orphan nodes, SHACL closure, receipt rule per route; SLA <5s). Nearest realized mechanism: grep-count guard + `posh_coverage.py` — right shape, wrong mechanism; landing via lanes 40/44; design in gaps/27. | `glossary.md` rows 4 and "Missing-artifact register"; `posh/v26.10.30/gaps/27-invariant-gate-design.md` |
| **Dev overlay** | The Gemini-delta work: operator-confirmed Explore-mode agent work written concurrently into `posh/` (uncommitted, volatile — re-stat before consuming), audited and dispositioned in gaps 71–76. | `posh/v26.10.30/gaps/71-gemini-inventory.md`; consolidated in `v26.10.31/gaps/GEMINI-DOSSIER.md` |

---

# posh Glossary — Charter Terms vs Code Names

Landed from `gaps/19-vocabulary-drift.md` §1 (lane 52, 2026-10-30). This is
the glossary home file that gap 19's close condition proposed; the gap record
remains the authority on its own anchors.

Standing note: the charter INVARIANT-gate artifacts are landing via lanes
40/44 — rows below marked MISSING may close there.

## Bilingual glossary

| # | Charter term | Code artifact (file:line, verified 2026-10-30) | Divergence note |
|---|---|---|---|
| 1 | **Port In** | `lib/smalt/posh/port.ex` (module `Smalt.Posh.Port`, BEAM Port wrapper for the posh Go binary); ring buffer `lib/smalt/posh/ingress/ring_buffer.ex`; admission `lib/smalt/posh/ingress/admission.ex:76` (`validate_task/4`) | Name drift. Charter "Port In" = the intake ring buffer itself (zero-allocation SPSC); the artifact named `Port` is the OS-process port wrapper, and "Port" is additionally the OTP `Port` primitive — one word, three referents. The charter's intake semantics live in `ingress/`, not `port.ex`. |
| 2 | **Starboard Out** | No artifact. Nearest: `lib/smalt/posh/egress/` (`settlement.ex`, `event_log.ex`, `supervisor.ex`) | NO artifact named Starboard exists anywhere in-tree. Charter "Starboard Out" = zero-copy egress conduit (Refc Binary / writev). Name drift only — charter §5 FMEA row "Egress Delivery (Starboard)" confirms the mapping to `egress/`. |
| 3 | **Andon gates (BUILD / TEST / LINT / INVARIANT; GREEN / YELLOW / RED)** | Charter `charter-master.md` §6; elaboration `dfcharter/andon.md`; driver `posh/cmd/andon/main.go` + `posh/internal/andon`; staged court `justfile.d/58-posh.just` (7 named stages + uncounted pre-stage, lines 4–14 and 266–279); receipt chain default `posh/var/andon.jsonl` (main.go:13–15) | Diverges in shape: charter names a 4-gate matrix with per-gate SLA clocks (<60s/<40s/<10s/<5s); posh-court is a 7-stage DoD ladder (vet, alloc-test, build+static, fence, smalt-wire, tf apply, zero-drift) whose stage names and count match none of the charter's four gates. The andon driver is standalone (`just posh-andon`, 58-posh.just:525–531), not a court stage. GREEN/YELLOW/RED, composite MAX, hysteresis N=2, and typed exits 0/1/2/3 are faithfully typed in `andon.md` §1–2 and main.go. |
| 4 | **INVARIANT gate = SPARQL over ingress/ + egress/ graphs** (100% routes terminate in turnstiles, 0 orphan nodes, SHACL closure, receipt rule per route) | NONE in-tree. Nearest real artifacts: `scripts/posh_coverage.py` (POSH-009 coverage compiler, exit 0/1) and the non-vacuity individual-count guard `grep -h 'a posh:IngressRoute'` at `justfile.d/58-posh.just:97–103` | Semantic divergence, the largest in this register: the charter INVARIANT gate is a SPARQL ASK/SELECT court over the route graphs; no runtime SPARQL engine exists in-tree. What actually runs is (a) a syntactic grep-count stand-in for the route census and (b) the coverage compiler, which inventories the TF provider surface, not the route graph. Both are fail-closed exit-code gates — the right *shape*, the wrong *mechanism*. |
| 5 | **DPMO / C_pk / Sigma** | None. Defined only in `dfcharter/dpmo.md` §1 (O = R × 4; R via SPARQL COUNT over `posh:Route` individuals) and charter-master §7 | No artifact computes DPMO in-tree. The charter's denominator R (route count) is only approximated by the same 58-posh.just:97 grep-count — a syntactic stand-in for the specified SPARQL COUNT, so any future DPMO number computed from the grep would not be receipt-backed per dpmo.md §1.1's own law. |
| 6 | **CTQ / VOC flowdown** | None. `dfcharter/` only (charter-master §3 table, `define.md`, `measure.md`) | Charter-only vocabulary; no code anchor expected. Not a defect — a DfLSS charter term, not a runtime concept. |
| 7 | **Tollgate (DMADV phase reviews)** | None in code. `charter-master.md` §4 ("Tollgate Gate Review" per phase), `dfcharter/raci-signoff.md` ("Final Tollgate Sign-Off") | "tollgate" appears nowhere outside dfcharter/. Charter-only. |
| 8 | **Turnstile (BEAM sense)** | `lib/smalt/posh/turnstile.ex:25` — `admit/5`, typed `{:ok, …} / {:refused, term()}`; moduledoc "no unreceipted delta passes"; admission then `Egress.Settlement.settle/4` into a 32-byte receipt | Faithful to charter sense (type-enforced, signed receipt token required before state transition). Divergence (per gap 04): not yet enforced on any BEAM production call path — the fence exists, the wiring does not. |
| 9 | **Turnstile (Go sense)** | `posh/internal/armclient/client.go` (`VerifyTurnstile`); `MembraneOp.TurnstileReceipt` field at `posh/internal/adapter/generated_dispatcher.go:18`; wire assert `X-Smalt-Receipt-Turnstile` header check at `justfile.d/58-posh.just:257–264` | Same charter term, second code realization: receipt verification at the ARM client + HTTP header enforcement. Two implementations (BEAM + Go) of one charter concept — the N-implementations-drift risk applies; they currently agree on the 32-byte receipt contract. |
| 10 | **admission** | BEAM: `lib/smalt/posh/ingress/admission.ex:76` (`validate_task/4`, let-it-crash task admission). Go: dispatcher allowlist — an op absent from `generatedOps` is refused (`generated_dispatcher.go:19–24`) | Charter uses "admission" for payload intake validation (D_admission in dpmo.md §1.2). In-tree it denotes two distinct mechanisms: payload shape/crash validation (BEAM `Admission`) and op-allowlist membership (Go dispatcher). Related but not identical; the glossary keeps them separate senses under one charter word. |
| 11 | **Turtle route individuals (`arm.request`, `arm-get`, `echo`, `telemetry`)** | `ggen-marketplace/packs/posh/examples/posh_instance.ttl:35–44` (`posh:routeArmRequest`, `posh:routeArmGet`, telemetry route; shapes at :24–31); op-registry strings `posh/internal/adapter/generated_ops_arm_request.go:6`, `generated_ops_arm_get.go:6`, `generated_ops_echo.go:6`; BEAM projections `lib/smalt/posh/pipeline/arm.request.ex`, `arm-get.ex`, `echo.ex` | Mapping is exact: each route individual's `posh:membraneOp "arm.request"` / `"arm-get"` string matches the `generatedOps` registry key and the BEAM pipeline module name. Note: the instance A-box shows arm.request, arm-get, telemetry — echo exists as a generated op + BEAM pipeline module but is not an IngressRoute individual in the instance file. Divergence (gap 04): the BEAM pipeline projections are dead code on the production call path. |
| 12 | **MembraneOp** | `posh/internal/adapter/generated_dispatcher.go:15` (`type MembraneOp struct`); per-op registrations `generated_ops_*.go:6`; registry-as-allowlist ("an op absent from it is refused", dispatcher :19–24) | Faithful. The charter never names MembraneOp; it is the code-side realization of charter §1/§3-Rule-1 "peripheral membrane". No semantic drift. |

## Terms used with TWO or more meanings in-tree

| Term | Meaning A | Meaning B | Meaning C |
|---|---|---|---|
| **gate** | just recipe / court stage: `just posh-court`'s 7 stages (`justfile.d/58-posh.just`), `just invariant-gates` → `scripts/invariant_gates.py`, schema-parity gate (`resource_resource_group.go:13` comment, `server.go:101`) | andon signal: one of BUILD/TEST/LINT/INVARIANT carrying GREEN/YELLOW/RED (`posh/cmd/andon/main.go:32`, `dfcharter/andon.md`) | TF-provider-internal validation colloquialism: "registry gate admits 2023-07-01" (`resource_resource_group.go:13`), "schema-parity gate" (`server.go:101`) — release-engineering usage, unrelated to the andon register |
| **Port** | charter Port In (intake ring buffer) | `lib/smalt/posh/port.ex` (OS-process port wrapper) | OTP `Port` primitive the module wraps |
| **turnstile** | charter turnstile: type-enforced signed-receipt state transition (BEAM `turnstile.ex`) | Go receipt verification + HTTP header (`VerifyTurnstile`, `X-Smalt-Receipt-Turnstile`) | charter §5 FMEA "Type-Enforced Turnstile" — a compile-time requirement ("required to compile") that neither implementation enforces at compile time; both enforce at runtime |
| **admission** | payload intake validation (`Ingress.Admission.validate_task/4`) | op-allowlist membership in the Go dispatcher | charter D_admission defect dimension (both false-admit and false-reject count) |
| **coverage** | TF provider surface coverage compiler (`scripts/posh_coverage.py`, POSH-009) | test coverage band (TEST gate, charter §6: ≥85% branch GREEN / 80–84.9% YELLOW / <80% RED) | unrelated meanings sharing one word |

## Missing-artifact register

| Charter term | Required artifact per charter | Status |
|---|---|---|
| INVARIANT gate SPARQL | SPARQL ASK/SELECT court over route graphs, SLA <5s | MISSING — nearest: grep-count guard + coverage compiler; landing via lanes 40/44 |
| DPMO computation | O = R×4, receipt-backed R | MISSING — no computer exists |
| Starboard Out | named egress conduit | MISSING as a name; `egress/` carries the semantics |
| Andon as court stage | charter §6 gates wired into the pipeline | MISSING — andon driver is standalone (confirmed by gap 04) |

## See Also

`gaps/19-vocabulary-drift.md` · `dfcharter/` · `charter-master.md`
