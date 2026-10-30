# Gap 19 — Vocabulary Drift: Charter Terms vs Code Names

Lane 19, v26.10.30 gap wave. Read-mostly; this file is the only write.
Subjects: `docs/jira/posh/v26.10.30/dfcharter/charter-master.md` (charter terms),
`lib/smalt/posh/` (BEAM), `posh/` (Go membrane), `posh/cmd/andon`,
`justfile.d/58-posh.just`, `ggen-marketplace/packs/posh/` (Turtle), `scripts/`.

Status line: **PARTIAL** — every charter term below has at least one on-disk
anchor (file:line verified this session), but four charter terms have no code
artifact at all, the charter INVARIANT gate's SPARQL has no runtime artifact,
and "gate" is used with three distinct in-tree meanings.

## 1. Bilingual glossary

| # | Charter term | Code artifact (file:line, verified this session) | Divergence note |
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

## 2. Terms used with TWO or more meanings in-tree

| Term | Meaning A | Meaning B | Meaning C |
|---|---|---|---|
| **gate** | just recipe / court stage: `just posh-court`'s 7 stages (`justfile.d/58-posh.just`), `just invariant-gates` → `scripts/invariant_gates.py`, schema-parity gate (`resource_resource_group.go:13` comment, `server.go:101`) | andon signal: one of BUILD/TEST/LINT/INVARIANT carrying GREEN/YELLOW/RED (`posh/cmd/andon/main.go:32`, `dfcharter/andon.md`) | TF-provider-internal validation colloquialism: "registry gate admits 2023-07-01" (`resource_resource_group.go:13`), "schema-parity gate" (`server.go:101`) — release-engineering usage, unrelated to the andon register |
| **Port** | charter Port In (intake ring buffer) | `lib/smalt/posh/port.ex` (OS-process port wrapper) | OTP `Port` primitive the module wraps |
| **turnstile** | charter turnstile: type-enforced signed-receipt state transition (BEAM `turnstile.ex`) | Go receipt verification + HTTP header (`VerifyTurnstile`, `X-Smalt-Receipt-Turnstile`) | charter §5 FMEA "Type-Enforced Turnstile" — a compile-time requirement ("required to compile") that neither implementation enforces at compile time; both enforce at runtime |
| **admission** | payload intake validation (`Ingress.Admission.validate_task/4`) | op-allowlist membership in the Go dispatcher | charter D_admission defect dimension (both false-admit and false-reject count) |
| **coverage** | TF provider surface coverage compiler (`scripts/posh_coverage.py`, POSH-009) | test coverage band (TEST gate, charter §6: ≥85% branch GREEN / 80–84.9% YELLOW / <80% RED) | unrelated meanings sharing one word |

## 3. Missing-artifact register

| Charter term | Required artifact per charter | Status |
|---|---|---|
| INVARIANT gate SPARQL | SPARQL ASK/SELECT court over route graphs, SLA <5s | MISSING — nearest: grep-count guard + coverage compiler |
| DPMO computation | O = R×4, receipt-backed R | MISSING — no computer exists |
| Starboard Out | named egress conduit | MISSING as a name; `egress/` carries the semantics |
| Andon as court stage | charter §6 gates wired into the pipeline | MISSING — andon driver is standalone (confirmed by gap 04) |

## 4. Close condition

Glossary lands at `docs/jira/posh/v26.10.30/glossary.md` (proposal path). This
file is the gap record; the glossary home file does not exist yet.

**Status: PARTIAL** — glossary content complete and receipt-anchored (this
file); glossary home file NOT LANDED (lane charter scoped ONE file:
gaps/19-vocabulary-drift.md, so the landing at glossary.md is left to the
coordinator per the close-condition proposal).
