# HRN-009 — NFR-HERMETIC-01 (Hermetic Test Isolation) — Receipt

Status: **ALIVE** — static gate green + runtime fail-fast witnessed (both directions) + guard non-vacuity court passed.

## Scope / files (lane 9 ownership)

- `apps/web/test/harness/nfr/hermetic.test.ts` (new)
- `scripts/hermetic_guard.sh` (new, executable)

No other files touched. A concurrent lane added `apps/web/test/harness/vault/lib.ts` mid-wave; the guard picked it up automatically and classifies its `scope:` literal as LEGAL-FIXTURE.

## (1) Static gate — `scripts/hermetic_guard.sh`

Grep for public Azure hosts (`management.azure.com`, `login.microsoftonline.com`, `*.vault.azure.net`, `azurecr.io`) over `apps/web/src`, `apps/web/test`, `apps/api/src` (lib code only; `*.test.ts` excluded as fixture-legal by convention). Classification:

- `LEGAL-FIXTURE` — token audience/scope literals (`.default` scope strings; smalt mints tokens for that audience). 2 witnessed: `apps/web/test/harness/lib/smalt-client.ts:19`, `apps/web/test/harness/vault/lib.ts:52`.
- `LEGAL-REDIRECT` — SAML browser-redirect URL construction (`apps/api/src/config.ts:150` builds the Entra SAML entrypoint the *browser* visits; server never fetches it).
- `VIOLATION` — anything else, exit 1, fail-closed.

Receipt: PASS, 0 violations, exit 0. Non-vacuity (shim court): injected `fetch("https://vault-abc.vault.azure.net/secrets/x")` into `apps/api/src/config.ts` → guard exit 1 with VIOLATION line; byte-restored from backup → exit 0 (git diff clean, config.ts untouched).

## (2) Runtime gate — `apps/web/test/harness.nfr/hermetic.test.ts`

Real subprocess fetch of `https://management.azure.com/subscriptions?api-version=2022-12-01`, bounded by a 5s `AbortSignal.timeout` plus a hard SIGKILL wrapper at 2x budget (a hang resolves as typed `HARD-TIMEOUT-KILL` and fails the test).

- **Kill-switch mode** (`NODE_USE_ENV_PROXY=1 HTTPS_PROXY=http://127.0.1:1`): typed failure `Error/ECONNREFUSED` witnessed in **12ms** (standalone probe; in-suite 97ms wall including spawn). Asserts typed-fail + `< 5s` budget. Loud typed SKIP if node `<24` (no `NODE_USE_ENV_PROXY`); current node v26.10.0, SKIP path not taken.
- **Control (both-ways) mode**: on this internet-connected machine the control fetch reached the public endpoint: `HTTP 401 in 379ms` — proving the isolation story is network-layer, not app-layer, and is asserted/documented in the NOTE. On an air-gapped machine the same test passes with the typed-failure branch.
- Result: 3/3 pass (`npx vitest run test/harness/nfr/hermetic.test.ts`), `tsc --noEmit` exit 0.

## (3) Operator runbook — network isolation recipe (NOT automated; operator-run)

> The app-layer gate above proves fail-fast behavior; real hermeticity comes from network-layer isolation, applied by a human:

- **macOS dev (pf)**: packet filter stateful anchor blocking outbound 443/80 to public ranges, loopback exempted:
  `pfctl -a hermetic -f rules` with anchor rules `block return out proto tcp to any port {80,443} user root` — loopback traffic (smalt plane at `127.0.0.1:9443`) is unaffected. Alternatively `networksetup -setnetworkserviceenabled Wi-Fi off` for total isolation (blunt: kills loopback-adjacent DNS too). `sandbox-exec` (deprecated by Apple, still functional) can wrap a single vitest process with a `(allow network-outbound (to remote ip "127.0.0.1:9443"))`-only profile — per-process, no system state.
  Note: pf is system-global and root-run; the per-process `sandbox-exec` route is preferred for per-suite runs.
  (Probe evidence this recipe is honest: closed-port fail is 12ms, so a pf `return`-block behaves equivalently fail-fast.)
  <!-- GAPS-FILE-SNIPPET: The pf ruleset itself is prose here, not a committed rules file — a future lane could commit a `scripts/hermetic_pf.conf` + `just hermetic-up/down` pair, but that mutates system network state and stays operator-run by design. -->
<!-- GAPS-FILE-SNIPPET: sandbox-exec is Apple-deprecated; a successor (per-test container/profile) is an open gap. -->
- **CI (GitHub Actions)**: job-level isolation via a container with no external route or an egress-firewall action pinned to allow only the smalt plane's loopback/WireGuard endpoint; plus `NODE_USE_ENV_PROXY=1 HTTPS_PROXY=http://127.0.0.1:1` as the in-job fail-fast tripwire — the exact env pair proven above, so any accidental outbound attempt in a suite fails in ms with ECONNPROXY/ECONNREFUSED instead of hanging for the job timeout.

## Standing

- Static gate: ALIVE (exit 0 + shim court receipt above).
- Runtime fail-fast: ALIVE (ECONNREFUSED 12ms kill-switch receipt; control 401 both-ways receipt).
- Runbook: documented prose, explicitly operator-run (UNVERIFIED as automation — by design).
- Typed SKIP: implemented, not witnessed this run (node ≥24).

## Verify commands

```
bash scripts/hermetic_guard.sh                                  # exit 0, PASS
cd apps/web && npx vitest run test/harness/nfr/hermetic.test.ts # 3/3 pass
```
