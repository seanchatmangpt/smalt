# GAP-05: Egress Fence Disposition — Single-Homing per Language Runtime

Milestone: v26.10.31 · Lane 5 of 17 · 2026-10-30

## Claim under disposition

The egress fence is already posh-side: `internal/egress` (runtime fence) +
`internal/poshvet` (go/analysis multichecker failing unfenced dials — Gemini's, per
gaps/71) + the posh.yaml allowlist graph law (fail-closed ceiling, `egress_allowlist:
[]` default-deny). The migration completes the fence's single-home **per language
runtime**; it is not a move.

Confirmed with one refinement: single-homing is per-language, and each language's
fence is at a different standing.

## Component inventory (all paths /Users/sac/smalt unless noted)

| Component | Path | Standing |
|---|---|---|
| Runtime fence (Go) | `posh/internal/egress/egress.go` | ALIVE (read; builds via vet run below) |
| Static analyzer (Go) | `posh/cmd/poshvet/main.go` → multichecker(ConvTSlice, FencedNet, OpTurnstile, Budget) | ALIVE — ran 2026-10-30, exits 1 on 7 findings |
| Allowlist ceiling | `posh/posh.yaml` `egress_allowlist: []` (default-deny; missing/empty file = boot refusal) | ALIVE (read) |
| Static gate (TS) | courtroom-platform-az `scripts/hermetic_guard.sh` | ALIVE — ran, PASS, exit 0 |
| BEAM-side egress fence | — | ABSENT (see §1) |

## 1. smalt BEAM-side egress assumptions

`Smalt.EgressRouter` (`lib/smalt/egress_router.ex`) is a ROUTER, not an egress
control: it is the inbound Plug pipeline on :8443 serving the Azure emulator data
planes (Cosmos/KV/Sentinel/Purview/...). The `egress` in its name is the Azure
"egress plane" naming (traffic egressing the membrane to consumers), not outbound
network control. No fence semantics there.

Outbound dials in `lib/smalt` (unfenced, by inspection):
- `lib/smalt/webpubsub/events.ex:101` — `:httpc.request(:post, ...)` webhook
  delivery, unfenced (no host allowlist, no IMDS tripwire).
- `lib/smalt/data_plane/apim_gateway.ex:602-680` — Finch (when loaded) /
  :httpc backend-forwarding leg, unfenced outbound TCP; this is by design (the
  emulator forwards to a configured backend) but it is a real outbound dial with
  no allowlist.
- All other `:ssl` mentions in `lib/` are inbound TLS listen paths (tls.ex), not
  outbound.

Conclusion: BEAM-side has NO egress fence. If the migration's fence single-homing
is per-runtime, BEAM is the missing home. The hermetic_guard.sh host-literal gate
(TS repo) does not cover it, and poshvet cannot (different module tree, different
language).

## 2. courtroom harness static gates vs poshvet: complement, not duplicate

`scripts/hermetic_guard.sh` (courtroom-platform-az, HRN-009/NFR-HERMETIC-01) is a
grep-class host-literal classifier over TS/JS app source (`apps/web/src`,
`apps/api/src`, test harness) with three typed classes: LEGAL-FIXTURE,
LEGAL-REDIRECT, VIOLATION. It checks *host literals in TS source*, not dialer
construction.

poshvet's FencedNetAnalyzer checks *dialer/client construction in Go AST*
(POSHVET-002 on `net.Dialer` without Control, raw `http.Client` without fenced
transport, `http.DefaultClient`/`DefaultTransport`, direct `http.Get`-family
calls; exempts `internal/egress` and `_test.go`). Different language, different
AST, different subject. No duplication — complementary per-language gates.

## 3. Per-runtime single-homing disposition

| Runtime | Fence home | Standing |
|---|---|---|
| Go (posh) | `posh/internal/egress` runtime + `poshvet` static, ceiling posh.yaml | PARTIAL — analyzer ALIVE, 7 live violations in-tree (below) |
| TS (courtroom platform) | `scripts/hermetic_guard.sh` | ALIVE (PASS exit 0, 2026-10-30) TS-side |
| BEAM (smalt lib) | none | MISSING — outbound `:httpc`/Finch sites unfenced |

### poshvet coverage: run receipt (2026-go-vet)

Ran `go build ./cmd/poshvet && go vet -vettool ./...` from `/Users/sac/smalt/posh`:
exit 1 with 7 POSHVET-002 findings. Raw output (verbatim):

```
internal/doctor/doctor.go:401:14: POSHVET-002: raw http.Client constructed without fenced Transport and CheckRedirect; use egress.NewFencedClient(cfg, timeout)
internal/doctor/kube_healer.go:64:15: POSHVET-002: raw http.Client constructed without fenced Transport and CheckRedirect; use egress.NewFencedClient(cfg, timeout)
internal/pgo/collector.go:191:13: POSHVET-002: raw http.Client constructed without fenced Transport and CheckRedirect; use egress.NewFencedClient(cfg, timeout)
internal/armclient/client.go:79:8: POSHVET-002: use of unfenced http.DefaultClient violates POSH-008 fail-closed egress; use egress.NewFencedClient
internal/telemetry/otlp/exporter.go:187:13: POSHVET-002: raw http.Client constructed without fenced Transport and CheckRedirect; use egress.NewFencedClient(cfg, timeout)
internal/replay/replay.go:304:16: POSHVET-002: raw http.Client constructed without fenced Transport and CheckRedirect; use egress.NewFencedClient(cfg, timeout)
internal/chaos/chaos.go:210:10: POSHVET-002: use of unfenced http.DefaultTransport violates POSH-008 fail-closed egress; use egress.NewFencedTransport
```

### poshvet coverage: all posh packages, tui/wasm/dev included

poshvet is a multichecker over `go vet -vettool ./...` from the posh module root —
`./...` covers every package in the module, internal/tui, internal/wasm,
internal/dev included (all analyzed; tui/wasm/dev produced zero findings). The
analyzer also compiled and analyzed the wasm package (no net usage in
`internal/wasm/*.go` — verified by grep: no `http`/`Dial` matches outside tests).

## wazero engine unguarded status

`internal/wasm/engine.go` uses wazero v1.12.0 (pure-Go, WASI snapshot preview1
host imports instantiated). The posh wasm package itself imports no net/http or
net package — posh-side Go code behind the engine is net-clean. But the WASI host
module set instantiated (`wasi_snapshot_preview1.MustInstantiate`) gives guest
modules stdio/env/clock/cargs; wazero's WASI preview1 does not expose sockets, so
guests have no dial surface today — unguarded but surface-free. Gap: this is a
wazero default, not a fence. A future `wasisocket`-style host function or a guest
making syscalls wazero later grants networking would dial without any allowlist or
wasm/fence wiring, with no analyzer rule (fencednet only sees Go AST, not guest
binaries). Named as the third open class after §1 (BEAM absent) and the 7
unfenced Go client sites.

## Status line

- Runtime fence (Go): PARTIAL_ALIVE — builds and enforces when wired; 7 unfenced client sites in-tree.
- poshvet: ALIVE — ran 2026-10-30, 7 findings, exit 1 (findings are the fence working, not the fence failing; the sites are the gap).
- hermetic_guard.sh: ALIVE — PASS exit 0, 1 LEGAL-FIXTURE + 1 LEGAL-REDIRECT correctly classified.
- BEAM-side egress fence: MISSING (webpubsub `:httpc` webhook + apim_gateway Finch/:httpc forward leg, unfenced outbound).
- wazero: UNGUARDED-BUT-SURFACE-FREE (WASI preview1 grants no sockets today; no analyzer rule for guest modules).
