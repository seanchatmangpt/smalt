# Receipt: BK-SUB2 — FD-1 shared-substrate remount: ALREADY CLOSED (premise rot), goal state re-witnessed

- **Date**: 2026-10-22
- **Lane**: BK-SUB2 (substrate ops)
- **Standing**: ALIVE (FD-1 goal state holds on the live wire; no bounce performed — typed deviation)
- **Context**: solo
- **Subject**: shared substrate beam pid 76687 (ports 9443/9444/5672/5673/9545, canonical `_build/dev`), MCP face on 9545

## Typed deviation: the staleness premise was stale

Dispatch order said: confirm tools/list == 32, then bounce. Observed instead:

```
$ curl -s http://127.0.0.1:9545/ -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
→ count: 37   (wave-6 cosmos.ttl.effective present)
```

The beam is NOT the stale one FD-1 described. Timeline evidence:

```
descriptor mtime : Oct 22 05:01  (lib/smalt/mcp/generated/mcp_descriptor.ex)
beam boot (76687): Thu Oct 22 05:19:34 2026   (ps lstart)
```

The beam booted 18 minutes AFTER the descriptor regen landed. pid 76687 is
exactly the substrate BK-SUBTLS stood up (its receipt names "Substrate UP,
pid 76687, canonical _build/dev, lock fd closed") — the FD-1 repair was
already executed by that remount. A second lock-managed bounce would be a
disruptive transition against an already-converged state with an
unwitnessable 32→37 flip (the falsifier cannot fire), so the bounce was
not performed. FD-1 in `bkmcpskep-mcp-audit.md` is closed by this evidence.

## Goal-state verification (live wire, all embedded output)

MCP face (9545, plain http JSON-RPC — lsof before-evidence):

```
$ lsof -nP -iTCP:9443 -iTCP:9545 -sTCP:LISTEN
COMMAND    PID   USER   FD ... TCP 127.0.0.1:9443 (LISTEN)   beam.smp 76687
COMMAND    PID   USER   FD ... TCP 127.0.0.1:9545 (LISTEN)   beam.smp 76687
```

- tools/list: **37 tools**, includes wave-6 `cosmos.ttl.effective`.
- tools/call `cosmos.ttl.effective` with no args → typed `INVALID_PARAMS`
  ("requires db and coll") — dispatched, not TOOL_NOT_FOUND (the exact
  FD-1 failure mode is absent).
- tools/call `cosmos.ttl.effective {db:"bksub2probe",coll:"c"}` →
  `isError:false`, `{"coll":"c","db":"bksub2probe","effective_ttl":"off"}`
  — the wave-6 probe answers materially.

Standard health set:

```
9444 TLS h2 GET        → 401
9444 STS POST (form)   → 200   (default tenant oauth2 token endpoint)
9443 /metadata/endpoints → 200  (plain h1 — see residual)
9443 other paths       → 401   (served, authenticated surface)
```

## Typed-orphan law: no kills, no conflicts

Only one beam holds the substrate ports (76687, both 9443 and 9545 in the
lsof above) — single canonical substrate, lock FREE per `just
substrate-status`. Zero port conflicts, therefore zero tree-aware verdicts
or kills were required. Other beams observed in the census are lane test
harnesses on ephemeral ports, the OTP-28 erlmcp processes outside this
repo's port set, and wasm stub runners — none hold substrate ports.

## Residual (typed, non-blocking)

- In this boot 9443 serves **plain http/h1** (401/200); TLS h2 to 9443
  resets (000). Consistent with the BK-SUBTLS residual note (8443/8444
  cleartext by boot config); the ARM TLS twin is 9444, which is TLS h2
  healthy. Not a defect, noted so the next lane doesn't re-diagnose it.
- FD-2 correction chain (BK-MCPSHA) untouched by this lane; already
  resolved per `bkmcpsha-sha-fix.md`.

## Replay

```bash
curl -s http://127.0.0.1:9545/ -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | \
  python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["tools"]))'
curl -s http://127.0.0.1:9545/ -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"cosmos.ttl.effective","arguments":{"db":"bksub2probe","coll":"c"}}}'
curl -s --http2 --cacert .smalt/tls/ca-cert.pem -o /dev/null -w '%{http_code}\n' https://127.0.0.1:9444/
curl -s --http2 --cacert .smalt/tls/ca-cert.pem -o /dev/null -w '%{http_code}\n' -X POST \
  https://127.0.0.1:9444/default/oauth2/v2.0/token -d 'grant_type=client_credentials&client_id=x&client_secret=y&scope=x'
curl -s --http1.1 -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9443/metadata/endpoints
just substrate-status
```
