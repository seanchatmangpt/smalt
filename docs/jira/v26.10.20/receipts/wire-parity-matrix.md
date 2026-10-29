# Wire-Parity Matrix — T24WIRE (2026-10-21)

**Standing:** **PARTIAL_ALIVE** (5 SDKs witnessed end-to-end; 1 new witness closed
with 3 server-side fixes; 1 client-bound OPEN divergence)

Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}` (`just bench-machine`)

Context: solo lane. Repo `/Users/sac/smalt` @ main (5b8ec75 + in-flight wave).
Shared substrate on 9443/9444 **never restarted**; the new witness ran on a
private `substrate-ctl` v-block (`v4`, ports 39740-39745), swept down after
(`--mode sweep`).

## SDK end-to-end witness matrix

| SDK | Version | Witness receipt / evidence | Gaps |
|---|---|---|---|
| @azure/cosmos | 4.10.1 | `tmp/bench/scvd-tier1.jsonl` (lane scvd-t1, surface=cosmos, `concurrent_put_get_16legs`, errors=0, verdict PASS, 16 legs × 5 cycles, endpoint :9444) + `scvd-tier2/tier3.jsonl` cosmos-docs ramp (tier3 ramp-512 errors=0) | none open |
| @azure/service-bus | 7.10.0 | `tmp/bench/scvd-sb.jsonl` (lane scvd-t12, `sendrecv-c128`, n=1024, errors=0, standing PASS) + KD-155SDK witness chain | KD-155 (deleteQueue HPE_INVALID_CONSTANT) CLOSED-SIMULATED; KD-153/154 ARM shape-gate rows OPEN |
| @azure/event-hubs | 6.0.4 | `tmp/bench/scvd-eh.jsonl` (lane scvd-t18, `send-c128`, n=512, errors=0, SAS per-host key, hub scvd-t18-hub) | KD-88 OPEN (client-bound: rhea 3.0.5 pre-send pump stall; smalt side cleared by 330-frame decode replay) |
| @azure/storage-blob | 12.34.0 | `tmp/bench/scvd-blob.jsonl` (lane scvd-t12, `putget-c128`, n=512, errors=0, standing PASS) | none open |
| azure-servicebus (Python) | smalt-cli venv | `smalt-cli/tests/test_servicebus.py` (real `azure.servicebus ServiceBusClient/ServiceBusMessage/ServiceBusSubQueue` import + probe suite, `just cli-test`) | same KD-153/155 surface class |
| **@azure/app-configuration** | **1.13.0** | **NEW — this lane**: `verification/ts/appconfig.probe.mjs`, 7/7 cells PASS (jsonl: `tmp/bench/wire-parity.jsonl`), against private v4 substrate running the three fixes below | 3 divergences found AND closed in the same window (see below) |

Not yet witnessed with any SDK: `@azure/keyvault-secrets` JS client (KV secrets
surface has Python-side coverage in `smalt-cli/tests/test_keyvault.py`; the JS
SDK witness is unwitnessed). `@azure/identity` rides the KD-100
instance-discovery loud-SKIP in the harness (`verification/ts/harness/credential.ts`).

## New probe: @azure/app-configuration@1.13.0 — witness ALIVE

Probe: `/Users/sac/smalt/verification/ts/appconfig.probe.mjs`
(unmodified official SDK, `AppConfigurationClient` in AAD/TokenCredential mode
with the harness `SmaltTokenCredential` POSTing the substrate STS — no HMAC
path). Loud-SKIP exit 3 if substrate down; never boots/restarts the shared
substrate. Exit contract 0/1/3.

First run against pre-fix code **hard-failed** (real divergences, not harness
noise): SDK crashed on the sync-token and later cells diverged. Three
server-side closes in `lib/smalt/egress/AppConfigRoutes.ex`:

1. **PUT /kv answered 201 on create; contract is 200** (upsert semantics —
   KD-149's 201 is the `/secrets` 7.4 face, not `/kv`). The generated SDK
   client accepts only 200 and threw `RestError: Unexpected status code: 201`.
   Fixed both PUT branches to unconditional 200; the stale 201 pin at
   `test/integration/kv404_typed_error_test.exs` was premise rot (the KD-149
   201 belongs to /secrets) and is corrected in the same diff.
2. **Sync-token wire shape**: smalt emitted bare `smalt-<ts>`; the SDK's
   `syncTokenPolicy` regex `^([^=]+)=([^;]+);sn=(\d+)$` requires
   `{id}={value};sn={seq}` and hard-crashed on anything else. Fixed
   `kv_sync_token/1` to emit `smalt=<max>;sn=<max>`.
3. **Exact If-None-Match ignored on PUT**: `onlyIfChanged` sends
   `If-None-Match: <etag>`; a match must 412 (RFC 7232) — smalt ignored it and
   answered 200. New cond clause answers typed 412 PreconditionFailed.

Post-fix witness (all against v4 substrate, unmodified SDK):

```
[PASS] set-create — key=wire-parity/appconfig/1792608361158 etag="515AC99B48B…
[PASS] get-roundtrip — value="v1"
[PASS] cas-if-match — value="v2"
[PASS] cas-stale-412 — status=412 name=RestError
[PASS] cas-if-none-match-412 — status=412
[PASS] list-key-filter — count=1
[PASS] delete-404 — status=404
SUMMARY pass=7 fail=0 total=7
exit=0
```

Result row: `tmp/bench/wire-parity.jsonl`
`{"lane":"wire-parity","surface":"app-configuration","op":"sdk-e2e-6cell","n":7,"errors":0,"verdict":"PASS","sdk":"@azure/app-configuration@1.13.0",...}`

## Verification ladder

- `MIX_BUILD_ROOT=_build-lane24 mix test test/integration/kv404_typed_error_test.exs test/integration/kd_conformance_test.exs` →
  **7 tests, 0 failures** (KD-149 /secrets 201 leg untouched and passing).
- Full-tree compile in lane build root: clean after the concurrent powl2 lane
  landed (two windows where `lib/smalt/powl2/*` was mid-edit — no lane edit of
  powl2 by this lane; SLA unblock was NOT needed, the owning lane fixed it).
- v4 substrate health 200, identity_verified=1 before the witness run.

## Honest-failure ledger

- First probe run FAILED (201 divergence). Runs 2 and 3 FAILED (sync-token
  crash, delete-cell probe bug). All are receipted above; the final 7/7 PASS
  postdates every fix. One row in `tmp/bench/wire-parity.jsonl` (PASS only —
  the failing runs crashed before emit; their output is quoted here verbatim).
- No errors outstanding.

## Handoff to kd-registrar (not minted by this lane)

Three closed-this-window divergences above are candidates for KD rows (201
status face, sync-token shape, If-None-Match PUT precondition) — all with wire
witness pre/post, flip receipt-gated. KD-88/KD-153/154/155/156 rows untouched.
