# i29-e2e-fresh — E2E tier fresh run on post-0009df3 (v26.10.18)

Standing: PARTIAL_ALIVE (4 scenarios ALIVE, 4 REAL FAILURES on the pinned tree, 2 environment-BLOCKED)
Context: solo(e2e tier, post-0009df3 tree; canonical checkout concurrently held by other lanes' in-flight `lib/` edits — s4/s6/s8 verdicts plus failure reproductions were pinned on a pristine `git archive` of 0009df3 via `just wt-scratch`, deps symlinked, compiled clean, MIX_BUILD_ROOT=_build-scratch)

## Scope finding

`test/e2e/` is NOT an ExUnit scope: `mix test test/e2e/` refuses the path
(`Paths given to "mix test" did not match any directory/file: test/e2e/`, exit 1;
the dir holds shell/node/python harnesses, one lone `checkpoint_chain.exs` mix-run
script). The tier is the 10 per-scenario runners `test/e2e/s*/run.sh`
(s1 uses `scenario.sh`), each self-booting its own substrate on private ports with
the exit contract 0 pass / 1 test failure / 2 substrate-never-up / 3 harness failure.

## Verdict table (pinned 0009df3 content unless noted)

| scenario | exit | verdict |
|---|---|---|
| s1_iac_chain | 1 | **BLOCKED-ENV**: preflight `port 9443 free` FAIL — `ssh` tunnel pid 61023 holds 9443/8443/5672; tf_smoke never attempted |
| s2_byok | 1 | **FAIL** — 2 pass / 7 fail (reproduced on pristine scratch) |
| s3_pipeline | 3 | **BLOCKED-ENV**: "ports 9443/8443 still occupied after 120s" (same tunnel) |
| s4_oauth_negatives | 0 | **PASS** — 5/5 + 2/2 both phases (scratch; canonical exit 2 was cross-lane boot contention, see disclosures) |
| s5_sessions | 1 | **FAIL** — 3 pass / 3 fail (reproduced on pristine scratch) |
| s6_checkpoints | 0 | **PASS** — `EXACTLY_ONCE_OK`, zero_double_processing (canonical AND scratch) |
| s7_worm | 1 | **BLOCKED-ENV**: suite dies on egress 8443 `UND_ERR_SOCKET other side closed` (tunnel); verdict is exit 1 not 3 |
| s8_cosmos_race | 0 | **PASS** — 8/8 steps PASS incl. CAS race "exactly-one-200-and-seven-412" (canonical AND scratch) |
| s9_lro_chain | 1 | **FAIL** — real assertion (reproduced on pristine scratch) |
| s10_attest_adversary | 1 | **FAIL** — 3 pass / 6 fail (reproduced on pristine scratch) |


**Tally: 3 PASS / 4 FAIL / 3 BLOCKED-ENV.**

## Real failures (verbatim, all reproduced on pristine 0009df3 scratch)

### s9 — storageAccount DELETE returns 202, harness pins 200

```
[ROW] storageAccount-delete: status=202 envelope={"delayMs":0,"endTime":null,"id":"/subscriptions/00000000-0000-0000-0000-000000000000/operations/0567ba6f1abcffe566619963","resourceId":".../s9-lro-rg/providers/Microsoft.Storage/storageAccounts/s9stmveu..."}
✖ s9 (6) DELETE storageAccount -> GET 404, operation record queryable (8.908125ms)
  AssertionError [ERR_ASSERTION]: storageAccount DELETE status 202
  202 !== 200
      at test/e2e/s9_lro_chain/lro_chain.test.mjs:296:10
```

### s5 — session redelivery order + deadletter wrong

```
✖ probe 3: acceptSession trial-A — order, renew, abandon x3 deadletters (42.8ms)
  AssertionError [ERR_ASSERTION]: SESSION_ORDER_REQUIRED (m3 redelivery)
  'm4' !== 'm3'
✖ probe 5: deadletter subqueue carries m3 with MaxDeliveryCountExceeded
  AssertionError: deadlettered message is m3 — undefined !== 'm3'
✖ probe 6: queue drained — session peek returns nothing
ℹ pass 3 / fail 3
```

### s2 — BYOK create/release surface 401s

```
✖ STEP 2 create CMK ... got 401: {"error":{"code":"AuthenticationFailed","message":"MissingBearerToken"}}
✖ STEP 4b ... got 401: {"error":{"code":"AuthenticationFailed","message":"NoSigningSecretConfigured"}}
✖ STEP 4c release ... got 401: {"error":{"code":"AuthenticationFailed":"NoSigningSecretConfigured"}}
ℹ pass 2 / fail 7
```

### s10 — attest passes, KV key-create 401s

```
[PASS] M0.baseline-registered ... 1.unknown-measurement ... 2.malformed-measurement
[FAIL] attack_3_tampered_payload_release_403: key create s10-tamper-key status 401:
  {"error":{"code":"AuthenticationFailed","message":"MissingBearerToken"}}
[FAIL] attack_4_token_replay / 5 / 6 / 7 / 8 — same 401 MissingBearerToken
court.summary: 3 pass / 0 known-gap / 6 fail
CONTROL-OK: attest refused with substrate down (port 38443)
```

## Blocked-environment detail

Default-plane ports 9443/8443/5672 are held for the whole window (22:13–23:13 PDT)
by an `ssh` listener, pid 61023 (`ssh ... *:9443 (LISTEN)`), not owned by this lane;
per the port law it was not evicted. s1's preflight, s3's 120s wait, and s7's
mid-suite socket-close all trace to that holder. These three need a window with
9443/8443 free (or their port-pin overrides made configurable) to run.

## Environment setup performed (not tree edits)

- `npm install` in `test/sdk-full/` (170 pkgs) and `test/sdk-smoke/`
  (@azure/cosmos, @azure/event-hubs, @azure/service-bus; node_modules were absent).
- Pristine scratch: `just wt-scratch 0009df3` → `/tmp/smalt-scratch-0009df3.wvb84X`,
  `deps`/`.smalt` symlinked, `MIX_ENV=test MIX_BUILD_ROOT=_build-scratch mix compile`
  exit 0, s8 `.venv` created.
- **Stray artifact (cleanup denied in-session)**: an npm misfire from repo-root cwd
  created untracked `/Users/sac/smalt/package.json` + `/Users/sac/smalt/node_modules/`.
  Both are untracked (package.json is `??`), node_modules gitignored. Removal was
  permission-denied; coordinator should `rm` them — they are NOT part of any lane's diff.

## Disclosures

- Canonical-checkout runs of s2/s4 (22:15–22:19) failed with substrate-boot
  `Smalt.Store {:already_started, ...}` — concurrent lanes' in-flight edits to
  `lib/smalt/store_tables.ex`, `lib/smalt/plane/integration_supervisor.ex`,
  `lib/smalt/enclave/state.ex`, `lib/smalt/messaging/amqp/{connection,sweeper}.ex`
  were live at run time (cross-lane, disclosed per same-checkout-fanout #6).
  All failure verdicts above were therefore re-pinned on the pristine 0009df3
  scratch; s4 flipped to PASS there, s2/s5/s9/s10 reproduced.
- I killed one beam (pid 38965) — verified before killing to be this lane's own
  orphaned scratch-s9 substrate (held only s9's private ports 18443/19443/19444/15672/15673),
  re-parented to init after run.sh killed only the mix wrapper.
- s2 harness does not set `:sts_signing_secret` yet asserts Bearer-authenticated
  KV; under config/test.exs `auth_mode: :anonymous` the 401s suggest the
  enforce-path refusal fires anyway — root cause NOT diagnosed here; the
  reproduction on pristine scratch is the receipt's claim.

## Verification ladder status

- [x] scope probe: `mix test test/e2e/` exit 1 (path not an ExUnit scope) — embedded above
- [x] canonical first pass: s6=0, s8=0; s2=2→(rerun)1, s3=3, s4=2, s5=3→1, s7=1, s9=1, s10=1, s1=1
- [x] pristine-scratch re-pin: s2=1, s4=0, s5=1, s6=0, s8=0, s9=1, s10=1
- [x] scratch compile exit 0; every verdict in the table traced to an embedded output
- [ ] s1/s3/s7 — BLOCKED on tunnel-held 9443/8443/5672; no verdict claimed
