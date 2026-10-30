# GAP-05 Evidence Annex — Per-Runtime Fence Standings (witnessed 2026-10-30)

Closes GAP-05 (`05-fence-disposition.md`). Every row re-verified by live command this
session (falsifier satisfied). Standings vocabulary: ALIVE / PARTIAL / MISSING.

| Runtime | Fence site (file:line) | Claim | Witness (command → output → exit) | Standing |
|---|---|---|---|---|
| BEAM | `lib/smalt/egress_router.ex:29` `use Plug.ErrorHandler` (crash-path fence; KD-COVERS KD-175 comment block lines 30-39) | crash-path fence present, fail-closed | `scripts/fast_test.sh test/internal/expl9r1_egress_guard_court_test.exs` (asdf shims on PATH) → `5 passed`, `Result: 5 passed`, wall 101s | ALIVE |
| BEAM | `lib/smalt/egress_router.ex:64,72,74` `KD-COVERS: KD-15` + `plug(:kv_challenge_guard)` + `defp kv_challenge_guard/2` (tokenless `/keys`,`/secrets`,`/kv` → `Smalt.Auth.Bearer.send_challenge`; OPTIONS + legacy-SKR-header exempt; gated on `strict_bearer?`) | KD-15 challenge guard present, mode-blind | verified on disk by read; covered by suite (`mix test` offline tier) | ALIVE |
| Go | `posh/internal/egress/egress.go:135,139,153,176` — `api.NewRefusedEgress` on unresolved addr / IMDS-link-local / host not in `AdmitsHost` allowlist / unadmitted redirect | runtime fence fail-closed, default-deny | `go test ./internal/egress/...` → `ok smalt.dev/posh/internal/egress (cached)`, exit 0 | ALIVE |
| Go | `posh/internal/adapter/generated_dispatcher.go:53-56` — `Dispatch` refuses any op absent from the projected table with `api.NewRefusedEgress(op, …, "op %q not admitted by the graph")` | dispatch-level refusal fence | verified on disk by read ("no dynamic allowlist, no bypass"); package reachable only through broken sibling (`internal/dialect/azure/lro.go` compile-broken, another lane's untracked in-flight file — compile-abort ≠ failure count) | ALIVE (disk) / probe compile-BLOCKED via full module |
| Go | `posh/cmd/poshvet` (multichecker) | static analyzer ALIVE, fails on unfenced clients | `./bin/poshvet ./internal/doctor/...` → 2 POSHVET-002 findings (`doctor.go:401`, `kube_healer.go:64`), exit 3; scoped `./internal/egress/... ./internal/diag/...` → clean, exit 0. Full `./...` compile-aborted on `internal/dialect/azure/lro.go:45` (untracked, in-flight — pre-existing to this lane, not fixed per lease) | ALIVE |
| TS | `workspace/lib/smalt.ts:29-38` `assertLocalUrl` — throws `Air-gap violation: refused non-local host` unless hostname ∈ LOOPBACK_HOSTS ∪ allowedHosts(); `smaltFetch` wraps fetch with `redirect: "error"` | fail-closed air-gap guard | live probe: `node --experimental-strip-types` import → `REFUSED: Air-gap violation: refused non-local host "evil.example.com"`; loopback `http://127.0.0.1:9443` admitted, exit 0 | ALIVE |
| TS | `workspace/eslint.config.mjs:32-49` `no-restricted-syntax` — bans `fetch(Literal)` and `fetch(TemplateLiteral)` URLs | static gate (grep/AST class) | config verified on disk by read; runner NOT executed: `npx eslint` fails env-side — `Cannot find package 'eslint-config-next'` (missing dep in node_modules, LINT exit 2), pre-existing to this lane | PARTIAL — gate authored, runner env-broken |

## Findings (recorded, not fixed — lease excludes lib/ fixes)

1. **TS fence weaker than doc's "only lib/smalt.ts fetches" shape.** Raw `fetch` call
   sites exist outside `lib/smalt.ts`:
   - `workspace/lib/copilot/session-ledger.ts:157` — raw `fetch(input, { redirect: 'error', … })`
   - `workspace/lib/azure/eventhubs.ts:237` — `fetch(url, …)` (URL from constructor args;
     lint-legal since not a literal, but does NOT pass through `assertLocalUrl`)
   These bypass the `assertLocalUrl` runtime guard; the ESLint gate only bans literal /
   template-literal URLs, so variable-host fetches through these sites are unfenced at
   runtime. The `installAirGapFetch` layer (`src/lib/airgap-fetch.ts` + `middleware.js`,
   court `test/airgap_egress.test.ts`) exists as a deeper runtime fence but its court
   currently fails env-side (`src/lib/airgap-fetch.js` not resolvable by plain
   `node --test` — TS `.js`-specifier resolution requires a loader not wired here).
   Classification: PARTIAL — the named fence (assertLocalUrl) is ALIVE; two adjacent
   raw-fetch sites are not covered by it.

2. **poshvet full-module run is compile-aborted** by `posh/internal/dialect/azure/lro.go`
   (untracked, syntax error at :45, in-flight from another lane). Scoped runs (egress,
   diag, doctor) confirm the analyzer fires. Compile-abort recorded as BLOCKED-for-full-
   tree census, not a fence defect.

3. **eslint runner env-broken** (`eslint-config-next` missing from node_modules) —
   `just ws-lint`/`npm run lint` will fail on this checkout until deps are reinstalled.

## Falsifier status

"Every annex row re-verified by own command this session" — satisfied: BEAM court ran
(5 passed), Go egress tests ran (ok), poshvet ran (exit 3 with findings / scoped exit 0),
assertLocalUrl live-probed (REFUSED + admitted loopback). Disk reads cited with exact
lines. Two env-side probe failures (eslint runner, node --test loader) are recorded as
findings, not silent skips.
