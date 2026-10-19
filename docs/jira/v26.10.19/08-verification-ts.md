# V261019-08 — verification/ts: external official-SDK suite (5 workflows), TypeScript

- **Release:** v26.10.19
- **Files owned (new tree):** `verification/ts/` — `package.json`, `tsconfig.json`, `harness/{substrate,credential,poll,assert,enum}.ts`, `wf1-wf5/` (one dir per workflow), `run.mjs`
- **Status at open:** does not exist. Lift source is the deleted `test/sdk-full/ts-run.mjs` + `ts-reality.test.mjs` (content extracted per WO-07 §0 before `git rm`).

## 1. Layout

```
verification/ts/
  package.json          # real @azure deps, lockfile committed
  tsconfig.json
  run.mjs               # orchestrator: boot → run workflows → teardown, ts-run.mjs exit contract
  harness/
    substrate.ts        # lifted ts-run.mjs boot: port preflight, boot eval, TCP poll, PG teardown, watchdog
    credential.ts       # STS client_credentials + SAS signing + DevCa TLS (NODE_EXTRA_CA_CERTS)
    poll.ts             # deadline-bounded polling (POLL_DEADLINE_MS = 90_000 shape from ts-run.mjs:34,123-137)
    assert.ts           # wire-shape assertions + fail-closed exit mapping
    enum.ts             # surface enums (see §3)
  wf1..wf5/
    wfN.test.mjs        # one workflow per file, runnable under `node --test`
```

Workflow set (five, mirroring the former `test/sdk-full/` coverage breadth, minus eventgrid):
1. **wf1 — Messaging (Service Bus / Event Hubs)**: `@azure/service-bus` + `@azure/event-hubs` — SAS from shared key, send/receive/lock-renew on the AMQP ports (lift of `ts-reality.test.mjs` which imports `@azure/service-bus`, `@azure/event-hubs`).
2. **wf2 — Storage (blob)**: `@azure/storage-blob` SharedKey conn-string flow, account `smaltacct`.
3. **wf3 — Data (Cosmos)**: `@azure/cosmos` master-key signing, any 64-hex key in MIX_ENV=test anonymous mode.
4. **wf4 — Management (ARM)**: `@azure/arm-resources` + `@azure/identity` client_credentials over the ARM gateway; LRO polling via `@azure/core-lro` (already a transitive dep in the old `package-lock.json`).
5. **wf5 — Secrets/Keys (Key Vault)**: `@azure/keyvault-keys` + `@azure/keyvault-secrets` with the dev-CA challenge witness pattern (former `kv_challenge_witness.mjs`).

## 2. Dependency rules

- Allowed: `@azure/service-bus`, `@azure/event-hubs`, `@azure/storage-blob`, `@azure/cosmos`, `@azure/arm-resources`, `@azure/identity`, `@azure/keyvault-keys`, `@azure/keyvault-secrets`, `@azure/core-*` (transitive pins only), `@azure/logger`.
- **No `@azure/eventgrid`** — excluded by operator decision (the old `test/sdk-full/package.json` and `eventgrid.probe.mjs` carried it; the fresh face does not re-admit it; EG coverage belongs to the WO-2 G3 engine work, not this suite).
- Real npm install, real SDKs, real auth flows — no mocks, no stub servers, same bar as `ts-run.mjs` header comment ("Real npm installs, real SDKs, real auth flows").

## 3. Surface enums

`harness/enum.ts` exports exactly three verdicts, applied per check and rolled up per workflow:

- `GREEN` — SDK call completed with the wire shape real Azure produces; assertion passed against the live substrate.
- `REGISTERED-DIVERGENCE` — SDK call completed but the emulator's shape differs from real-Azure semantics in a way that is **named in a registered divergence table** (carried from `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`; the test asserts the registered shape and marks the row REGISTERED-DIVERGENCE, it does not silently pass). An unregistered divergence is NOT this verdict — it is a failure.
- `MISSING` — the surface the SDK targets is absent on the emulator (route not mounted, comp not implemented — the WO-6 peek/clear class). Asserted as a typed absence (e.g. 404 RouteNotReady face), never skipped.

Rollup: a workflow run is GREEN only if every check is GREEN or REGISTERED-DIVERGENCE with the row cited; MISSING rows are reported per-run and must map to open GAP/work-order tokens.

## 4. No fixed sleeps

- All readiness/ordering waits go through `harness/poll.ts`: deadline-bounded condition polling (the `ts-run.mjs` TCP poll and the conftest D3 poll-exit pattern are the two sanctioned shapes).
- Blanket rule mirrors the v26.10.14 exemplar F3 court bar ("no sleeps", `docs/jira/v26.10.14/04-event-hubs.md` F3): no `setTimeout`-as-wait in workflow bodies. The only setTimeout uses permitted are in `run.mjs`/`substrate.ts` teardown escalation (SIGTERM→deadline→SIGKILL), matching `ts-run.mjs:89-103`.
- CI-determinism: the former `cosmos_test.exs:2039-2070` 5-second-cap restart poll flake class (v26.10.14 exemplar 07 item 3) is the anti-pattern; every poll has a deadline ≥ the CI budget and exits on condition, not on a counted sleep.

## 5. Required-test / falsifier

- Each workflow carries at least one check that must be **red against a substrate missing its plane** (e.g. wf4 against a substrate booted without the ARM port open → poll deadline → exit 2, not a silent pass).
- Verdict table printed per run: `wfN: GREEN (12 checks, 2 registered-divergence [KD-…, KD-…]) | MISSING: peek-messages (→ WO-6)`.

**Acceptance criteria:**
- [ ] `cd verification/ts && npm ci && node run.mjs` boots its own substrate, runs wf1–wf5, exits per the 0/1/2/3/124 contract.
- [ ] `grep -r "eventgrid" verification/ts/package.json package-lock.json` → 0 hits.
- [ ] `grep -rn "setTimeout" verification/ts/wf*/` → 0 hits (teardown escalation confined to harness/).
- [ ] Every REGISTERED-DIVERGENCE row cites a KNOWN_DIVERGENCES.md token; an injected unregistered divergence flips the run to exit 1.
- [ ] `git ls-files test/` contains no sdk-full survivors (WO-07 falsifier holds); `ts-run.mjs` machinery lives only in `verification/ts/harness/substrate.ts`.
