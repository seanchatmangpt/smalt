# Gap 04 — posh implementation vs governing charters (law-by-law)

Lane 4, v26.10.30 gap wave. Read-only evaluation; this file is the only write.
Subjects: `/Users/sac/smalt/posh/` (Go membrane) and `/Users/sac/smalt/lib/smalt/posh/` (BEAM client)
against `docs/jira/posh/v26.10.30/dfcharter/charter-master.md` (SPAF contract),
`dfcharter/triz.md`, `dfcharter/design.md`, `requirements-synthesized.md`.

Status line: **PARTIAL** — fences (egress default-deny, turnstile, honest digest naming,
stateless Go) are landed and partially receipted; the posh turnstile is not enforced on any
BEAM production call path, the ggen-rendered BEAM pipeline modules are dead code with a latent
template bug, andon is standalone (not a court stage), and the posh-court gate stands FAIL
(0/8, kind disk preflight).

## 1. SPAF Rule 1 — Go stateless (charter-master §2)

**MET.** Swept `posh/internal` + `posh/cmd` for persistence: no sqlite/bolt/leveldb/badger, no
schedulers, no domain state. The only `os.WriteFile` in non-test Go is
`posh/internal/doctor/doctor.go:441` — a doctor self-heal writing the terraform rc file, not
membrane domain state. Live state is confined to the token-cache/connection-pool class that
design.md §1.2 admits ("rebuildable live state ONLY").

## 2. SPAF Rule 2 — BEAM purity ("never raw cryptographic hashing on actor heaps")

**VIOLATED — as a disclosed v1 trade.** Sites:

- `lib/smalt/posh/blake3.ex` — a full pure-Elixir BLAKE3 (chunk tree + compression function)
  executing on the actor heap. Moduledoc discloses the trade ("No NIF, no hex dependency —
  hermetic by construction").
- `lib/smalt/posh/egress/settlement.ex:41` calls it for every settlement;
  `lib/smalt/posh/egress/event_log.ex:67` runs `:crypto.hash(:sha256, ...)` per log append.
- Go side mirrors the violation in the other direction: `posh/internal/receipt/blake3.go` is a
  pure-Go BLAKE3 — the Tier-2 membrane performing Tier-3's cryptographic settlement itself.

Charter remediation path is the Tier-3 `#![no_std]` kernel (law 9), ABSENT-by-plan in v1, so
heap crypto is the interim reality. Disclosure is honest in both moduledocs and
requirements-synthesized.md:13. Close condition: Phase 4 kernel; nothing closer exists.

## 3. v1 digest honestly named

**MET (exceeded).** requirements-synthesized.md:13 allows v1 to use SHA-256 "honestly named as
such". The implementation shipped real BLAKE3 in both Elixir and Go, named BLAKE3 everywhere
(blake3.ex, settlement.ex digest contract `BLAKE3(op_utf8 || u64BE(ts) || payload_body)`,
blake3.go header quoting the same formula). The one place SHA-256 is used (event-log prev-hash
chaining) is named `:sha256` honestly. No misnaming anywhere.

## 4. Egress allowlist default-deny — where enforced

**MET (Go tier) / PARTIAL (BEAM side).**

- Fail-closed config: `posh/posh.yaml` ships `egress_allowlist: []` with "empty/omitted list
  refuses all egress"; `posh/internal/config/config.go:32-35` (default-deny doc), :78-104
  (validation refusing non-bare-hostname entries).
- Runtime enforcement is layered and real: `posh/internal/adapter/generated_dispatcher.go:47-51`
  (op with no graph-admitted host → REFUSED_EGRESS; graph host must pass
  `egress.AdmitsHost(cfg, host)` against the posh.yaml allowlist);
  `posh/internal/egress/egress.go:135,139,153,176` refuse link-local/IMDS/unspecified IPs,
  un-admitted hosts, and **redirects to un-admitted hosts** (closes the 30x allowlist bypass).
- BEAM side: `lib/smalt/posh/client.ex` (`decode_envelope/1`) decodes `REFUSED_EGRESS` into a
  typed `{:error, {:upstream, %{code: "REFUSED_EGRESS"}}}` — it does NOT pre-check hosts
  locally. This is design-compliant (Tier 2 owns the fence) but leaves a structural bypass:
  nothing prevents a BEAM process from opening its own `:gen_tcp` to an un-admitted host.
  Close condition: state membrane-only-egress as a charter law and enforce (or explicitly
  accept the open bypass).
- Graph/config skew: the instance graph admits only `http://127.0.0.1:9443`
  (`posh/internal/adapter/generated_ops_arm_get.go:10`) while deployed `posh.yaml` ships `[]` —
  any membrane egress op would be REFUSED until they agree. Close condition: posh.yaml in the
  kind lane carries the graph-admitted host.

## 5. Turnstile fence — every admitted delta requires a receipt

**PARTIAL.** The fence exists and is honest, but is not enforced through the posh path.

- Fence constructs: `lib/smalt/posh/turnstile.ex` (validate → settle → 32-byte receipt, typed
  `{:refused, _}`), `lib/smalt/posh/egress/settlement.ex` (BLAKE3 digest contract);
  Go side: `posh/internal/adapter/generated_dispatcher.go:45` refuses ops with no receipt,
  `posh/internal/receipt/blake3.go` computes it.
- **Test-only on the BEAM posh path.** `grep -rn "Smalt.Posh.Turnstile" lib` — the only lib
  callers are the ggen-rendered pipeline modules (`lib/smalt/posh/pipeline/{arm.request,
  arm-get,echo}.ex`), and no module in lib/ or test/ calls `Smalt.Posh.Pipeline.*`. The
  generated pipelines resolve `String.to_atom("Smalt.Posh.Turnstile.TurnstileArm")` — a module
  that does not exist (real module is `Smalt.Posh.Turnstile`, `admit/5`; the generated call
  passes 2 args). Latent fail-closed crash: the first real call raises UndefinedFunctionError.
  This is a template bug (ggen-marketplace/packs/posh/templates/go_…
  — precisely `templates/construct_beam_pipeline` output; fix the TEMPLATE, never the rendered
  output).
- Live fence on the ARM production face is a *different*, hand-written turnstile:
  `lib/smalt/arm_gateway/plug/receipt_turnstile.ex` plugged at
  `lib/smalt/arm_gateway/router.ex:46`, emitting/asserting `X-Smalt-Receipt-Turnstile`,
  asserted fail-closed by `just posh-smalt-wire` (58-posh.just stage 5). So "no unreceipted
  delta" holds on the ARM face, but via a plug outside the posh tree, not via
  `Smalt.Posh.Turnstile`.
- Close conditions: (a) fix the ggen template to reference the real turnstile module/arity or
  generate per-route turnstile adapter modules; (b) wire a Pipeline caller into supervision
  (`lib/smalt/posh/supervisor.ex` does not invoke the pipelines); (c) prove with a court stage.

## 6. ggen synthesis actually projecting

**PARTIAL.** Machinery landed with a non-vacuity gate; the rendered BEAM output is dead code,
and the cross-language receipt contract is unproven.

- Instance A-box: `ggen-marketplace/packs/posh/examples/posh_instance.ttl` exists, imported by
  the pack manifest (`imports = ["examples/posh_instance.ttl"]` in the pack ggen.toml:14).
- Non-vacuity guard: `just posh-generate` (justfile.d/58-posh.just) counts
  `a posh:IngressRoute` individuals across ontology+instance (zero → loud SKIP exit 3,
  KD-POSH-5), runs `ggen sync run --format json`, requires render rows `written+skipped > 0`,
  then copies out to `lib/smalt/posh/pipeline/` + `posh/internal/adapter/` with a
  `MIX_BUILD_ROOT=_build-f12 mix compile` gate.
- Landed renders: 3 Elixir pipeline modules; Go `generated_dispatcher.go` +
  `generated_ops_arm_get.go`. Go render is load-bearing on the membrane path; Elixir render is
  dead code (law 5).
- Cross-language receipt byte-exactness ("must match the Elixir lane byte-for-byte",
  blake3.go header) has NO proving test: official BLAKE3 KATs exist only on the Go side
  (`posh/internal/receipt/blake3_test.go:9`), and `grep -rn Blake3 test/` finds zero Elixir
  tests — blake3.ex's moduledoc claim "verified against the published BLAKE3 known-answer
  vectors" is UNVERIFIED in-repo. Close condition: one Elixir KAT + Elixir-vs-Go
  cross-language digest test.

## 7. Andon: court-wired or standalone

**PARTIAL.** Standalone, not a court stage.

- Real machine: `posh/internal/andon/machine.go` — RED latched for subject lifetime (same-SHA
  rerun cannot clear it), YELLOW→GREEN only after 2 consecutive distinct-SHA GREENs, prev
  signal read from the receipt chain ("the register of truth"), + `posh/cmd/andon/main.go`,
  `just posh-doctor` / `posh-andon` (58-posh.just:517-523).
- Not wired into the court: the 7-stage posh-court ladder has no andon stage; stage outcomes
  are not fed to `internal/andon.Machine.Apply` from any recipe. `just posh-andon` only runs
  `go run ./cmd/andon -help`. Close condition: call the andon evaluator per court stage so
  composite MAX(signals) RED latches across runs.
- Court itself: `docs/jira/posh/v26.10.30/receipts/posh-court/posh-court-green.json` standing
  **FAIL** — 0/8 PASS, failed in kind preflight (containerd disk 14756MB < 20000MB threshold),
  retry and quiet-check disclosed in the receipt. The end-to-end court has never gone green.
- `final-wave-receipt.md:120` marks justfile.d/58-posh.just "untracked" — confirm tracked
  status at integration before citing it as landed capital.

## 8. Sidecar vs port mode

**MET (receipt completeness PARTIAL).**

- Port mode: `lib/smalt/posh/port.ex` (open_port supervision, orphan detection) +
  `test/smalt/posh/posh_port_test.exs` (socket existed→vanished flips supervision, 2/2);
  POSH-005 ticket landing receipt: "LANDED 2026-10-30", with `receipts/measure/` formal
  witness pending.
- Sidecar: `posh/Dockerfile` (distroless static, CGO off, UDS-only, non-root, read-only
  rootfs) + posh-membrane sidecar stanza in `k8s/smalt-backend.yaml`. The ticket falsifier
  (posh sidecar failing healthz must fail pod readiness) has no witnessed run. Close
  condition: run the healthz-failure falsifier on kind + land the measure witness.

## 9. no_std Rust kernel (Tier 3)

**ABSENT — by plan.** No Cargo.toml anywhere under posh/; no Rust in posh/go.mod;
requirements-synthesized.md:13 pins it as Phase 4 ("v1 uses SHA-256 honestly named as such"),
and design.md §1.3 assigns Tier 3 to the DMADV Design phase. ABSENT-BY-PLAN, not a v1 gap; it
remains the remediation path for law 2 (and for the Go tier doing Tier-3 work, blake3.go).

## 10. Summary table

| # | Law | Verdict | Key evidence | Close condition |
|---|---|---|---|---|
| 1 | Go stateless (SPAF R1) | MET | no DB/scheduler in posh/internal+cmd; only doctor.go:441 WriteFile | — |
| 2 | BEAM purity (SPAF R2) | VIOLATED (disclosed v1 trade) | blake3.ex; settlement.ex:41; event_log.ex:67; Go blake3.go | Phase 4 no_std kernel |
| 3 | v1 digest honestly named | MET (exceeded) | real BLAKE3 named BLAKE3 in both tiers; :sha256 named where used | — |
| 4 | Egress default-deny | MET (Go) / PARTIAL (BEAM bypass) | posh.yaml `[]`; config.go:32-104; egress.go:135-176 incl. redirect re-check; client.ex decodes REFUSED_EGRESS only | declare+enforce membrane-only egress; graph/config host agreement |
| 5 | Turnstile receipt fence | PARTIAL | turnstile.ex+settlement.ex; dispatcher.go:45; but Pipeline.* dead code, template references nonexistent `Smalt.Posh.Turnstile.TurnstileArm` (admit/2 vs admit/5) | fix template; wire pipeline caller; court-stage proof |
| 5' | Turnstile on ARM face | MET | router.ex:46 ReceiptTurnstile plug; posh-smalt-wire header assert | — |
| 6 | ggen projecting, written>0 | PARTIAL | instance A-box + KD-POSH-5 row-count guard; renders landed; Elixir render dead code | render called in production path |
| 6' | Cross-lang receipt byte-exactness | ABSENT | KATs only Go-side (blake3_test.go:9); zero Elixir Blake3 tests | Elixir KAT + cross-language digest test |
| 7 | Andon wired into court | PARTIAL | real latch/hysteresis machine; cmd/andon; posh-andon runs -help only; no court stage | feed stage outcomes → Machine.Apply |
| 7' | posh-court green | ABSENT | posh-court-green.json standing FAIL 0/8 (kind disk preflight) | rerun court on freed disk; confirm 58-posh.just tracked |
| 8 | Sidecar + port coverage | MET (receipt PARTIAL) | port.ex + posh_port_test 2/2; distroless Dockerfile + k8s stanza | healthz-fail falsifier run; measure witness |
| 9 | no_std kernel | ABSENT (by plan, Phase 4) | no Cargo.toml under posh/; requirements-synthesized.md:13 | Phase 4 kernel (also remediates #2) |

## 11. Structural findings (non-law)

1. **Template bug — generated pipelines reference a nonexistent turnstile module.** All three
   of `lib/smalt/posh/pipeline/arm.request.ex:31`, `arm-get.ex:31`, `echo.ex:31` emit
   `def turnstile_module, do: "Smalt.Posh.Turnstile.TurnstileArm"` and call
   `turnstile().admit(frame, receipt_iri())` (admit/2). Neither the module nor the arity
   exists (`Smalt.Posh.Turnstile.admit/5`). First invocation fails closed with
   UndefinedFunctionError. Fix the ggen template in ggen-marketplace/packs/posh/templates/,
   never the rendered output.
2. **Graph/config skew**: instance graph admits `http://127.0.0.1:9443`
   (generated_ops_arm_get.go:10); deployed posh.yaml ships `egress_allowlist: []`. Any
   membrane egress run is REFUSED until the kind-lane posh.yaml carries the graph-admitted
   host.
3. **Missing cross-language receipt proof**: blake3.go's header demands byte-for-byte equality
   with the Elixir lane; no test in the repo establishes it (Go KATs only). Highest-value
   close: one test file pinning Elixir `Smalt.Posh.Blake3.digest/1` against the official
   BLAKE3 vectors and against Go `receipt` output for the settlement contract bytes.

## Appendix — verification commands (run 2026-10-30)

- `grep -rn "Smalt.Posh.Turnstile" lib` → only turnstile.ex + 3 pipeline modules.
- `grep -rn "Smalt.Posh.Pipeline" lib test` → zero callers outside the pipeline dir.
- `grep -rn "Blake3" test/ -r` → zero hits (Go-side KATs live in posh/internal/receipt/).
- `grep -rn "sqlite|bolt|leveldb|badger|WriteFile|database|scheduler" posh/internal posh/cmd`
  → single hit doctor.go:441.
- `receipts/posh-court/posh-court-green.json` → standing FAIL, exit 1, 0/8 PASS.
