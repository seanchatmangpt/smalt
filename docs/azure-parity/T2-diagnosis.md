# T2 Diagnosis: TenantFence blob/kv/queue (4 failures)

Standing: PASS

Source log: /tmp/lanelogs/tenant.log (seed 325532, 0/4 passed, 0.1s).
Test file: test/integration/tenant_fence_blob_kv_queue_test.exs

## Single root cause (all 4): the TLS twin is not bound; curl exit 7

`twin/0` (test:290-295) returns `https://127.0.0.1:#{arm_tls_port}`. `fetch_sts_token/3`
(test:342-355) runs `{out, 0} = System.cmd("curl", ...)`; curl exits 7 (connection refused,
empty stdout), so the match fails with `{"", 7}` before any request reaches a handler.

Why nothing listens: lib/smalt/plane/control_supervisor.ex:8-19 (v26.10.31 cordon WO-32)
removed the BEAM's 9443/9444 listeners; `init/1` (line ~38-60) starts no Bandit. The only
https twin start site is data_supervisor.ex:80-95 `egress_tls_child/0`, gated on
`Smalt.TLS.all_planes?()` and bound to `egress_tls_port` (not `arm_tls_port`). tenant.log
1050-1063 shows no TLS/ARM Bandit line in the boot. Test premise rotted (substrate moved).

| test | test line | failing call |
|---|---|---|
| KV secrets | 30 (fails at 40) | authed -> token_for -> fetch_sts_token:355 |
| KV versions-list | 106 (fails at 115) | same chain |
| blob plane | 185 (fails at 192) | blob_authed -> token_for -> fetch_sts_token:355 |
| queue plane | 243 (fails at 251) | same chain |

## Fix for T1 (test-side, premise re-pin; no fence code defect observed)

Replace curl transport with in-process Plug.Test (as blob_parity_test does): mint STS via
`Smalt.ArmGateway.Router` / `Smalt.ArmGateway.Plug.OidcSts` `POST /:tid/oauth2/v2.0/token`
(oidc_sts.ex:294), and send secrets/blob/queue requests through `Smalt.Application.TlsTwinDispatch`
(application.ex:293) or `Smalt.EgressRouter` directly. Fence assertions stay unchanged.
Fence behavior itself is UNVERIFIED until the transport runs.

## Shared with blob.log? No

/tmp/lanelogs/blob.log has 11 failures, all Plug.Test assertions reaching the handler
(e.g. blob_quota_headers_test:50 missing x-ms-request-server-encrypted; blob_parity_test:106
WORM delete 202 not 409; 416/MD5/MissingRequiredHeader cases). Those are blob handler
defects (storage_catch_all.ex / blob/worm.ex, both currently modified by other lanes).
Tenant failures never reach a handler, so the root causes are disjoint.
