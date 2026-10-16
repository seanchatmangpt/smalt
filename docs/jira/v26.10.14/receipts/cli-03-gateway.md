# Receipt: CLI-03 wire-gateway core (smalt-cli)

- Date: 2026-10-15
- Lane: CLI-3 (independent)
- Subject: `/Users/sac/smalt/smalt-cli/` (canonical checkout, no worktree)
- Scope: `smalt_cli/gateway/{__init__,sts,proxy,interceptor,__main__}.py`, `smalt_cli/test_gateway.py`

## Delivered

- `gateway/sts.py` — `LocalSTS`: client_credentials-shaped HS256 JWT issuer,
  stdlib only (hmac/hashlib/base64), claims iss/aud/tid/oid/nbf/exp
  configurable; `decode()` with signature + exp/nbf verification;
  `client_credentials()` token-response shape. Zero network calls.
- `gateway/proxy.py` — `GatewayProxy`: http.server (ThreadingHTTPServer,
  no asyncio) reverse proxy forwarding Azure SDK HTTP to the smalt substrate
  from `SMALT_SUBSTRATE_URL` (default `http://127.0.0.1:8080`); strips
  hop-by-hop headers both directions; rewrites Host; loopback-only egress
  gate (`_enforce_loopback`) refuses non-127.0.0.1 substrates at construction.
- `gateway/interceptor.py` — ADR-PY-003 zero-actuation middleware:
  POST/PUT/PATCH/DELETE -> typed 403 envelope
  (`type: smalt.gateway.mutation_refused`, `error.code: MutationRefused`);
  ledger callback seam swallows ledger failures (refusal never blocked).
- `gateway/__main__.py` — `python -m smalt_cli.gateway` serves
  127.0.0.1:18443, SIGINT/SIGTERM clean shutdown.

Not re-implemented: blob/cosmos/AMQP surfaces (owned by the smalt emulator;
gateway is policy + redirect only).

## Verification (real output)

`python3 -m pytest smalt_cli/test_gateway.py -v` — **14 passed in 2.63s**:

```
STSTests::test_bad_signature_rejected_and_expiry_enforced PASSED
STSTests::test_claims_shape_and_configurability PASSED
STSTests::test_client_credentials_response_shape PASSED
STSTests::test_token_header_and_signature_verify PASSED
InterceptorTests::test_all_mutation_verbs_refused PASSED
InterceptorTests::test_envelope_shape_helper PASSED
InterceptorTests::test_get_passes_through PASSED
InterceptorTests::test_ledger_failure_does_not_block_refusal PASSED
InterceptorTests::test_put_refused_with_typed_403 PASSED
ProxyTests::test_default_substrate_is_loopback PASSED
ProxyTests::test_http_server_handler_end_to_end PASSED
ProxyTests::test_mutation_never_reaches_substrate PASSED
ProxyTests::test_round_trip_get_through_proxy_core PASSED
ProxyTests::test_zero_egress_non_loopback_substrate_refused PASSED
```

`python -m smalt_cli.gateway` smoke: binds `127.0.0.1:18443`, prints
`smalt gateway: 127.0.0.1:18443 -> http://127.0.0.1:1`, serves until signal
(exit 124 under timeout = clean long-run, killed by harness timeout).

## Zero-egress enforcement in tests

All live HTTP in `test_gateway.py` targets `ThreadingHTTPServer` stubs bound
to `127.0.0.1` (port 0 = OS-assigned); the proxy constructor itself raises
`ValueError` for non-loopback substrates (`test_zero_egress_non_loopback_substrate_refused`).
No test performs external network I/O.

## Standing

ALIVE (exact subject: all 5 modules + tests on disk at
`/Users/sac/smalt/smalt-cli/smalt_cli/gateway/`, suite passing as of
2026-10-15). No commits made, per lane contract.
