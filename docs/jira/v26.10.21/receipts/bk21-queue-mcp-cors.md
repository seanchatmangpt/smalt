# BK-21: Queue + MCP CORS gap closed (typed substrate transport fix)

**Standing:** **ALIVE** — witnessed on a live private substrate over real wire.

`Context: solo`

## Scope

Closes the typed substrate CORS gap blocking BK-15's PENDING-DISPATCH legs.
Unblocks rows 3 (mcp), 4 (queue), 6 (keyops) of
`docs/jira/v26.10.21/receipts/bk15-skip-fetch-census.md`. BK-15's PENDING
legs are now unblocked for re-witness; their flips stay receipt-gated —
BK-15's follow-up re-runs them and flips per its own gates. Row 5 (blob) is
NOT unblocked by this fix — see Residuals.

## Surfaces (lib/smalt only)

- `lib/smalt/egress_router.ex` — `egress_cors/2` restructured as a cond:
  queue-shaped preflights divert from the blob rule-based branch to the KV
  CORSPlug face. New: `queue_mcp_cors/1`, `queue_preflight?/1`,
  `queue_plane_shape?/1`, public `loopback_origin?/1`.
- `lib/smalt/mcp/router.ex` — new `:mcp_cors` plug (after HealthPlug):
  loopback-Origin requests get the identical CORSPlug face
  (`egress_cors_origins`/`egress_cors_headers` config — matching KV);
  non-loopback Origin → 403, no allow headers; no Origin → untouched.

Root cause (queue leg): the queue REST namespace (`/popcorn/...`, no plane
prefix) fell into `blob_plane_path?/1` → w6ay rule-based CORS → preflight
403 (blob account "popcorn" has no stored `<Cors>` rules). The MCP plane
had no CORS face at all (`OPTIONS /` → 404).

Loopback posture preserved: the server bind is loopback-only (unchanged),
and the new faces add a loopback-origin gate — a non-loopback Origin
refuses 403 with no allow headers. No-Origin requests pass through
untouched (CORSPlug semantics; never fabricate a CORS face for a
non-browser request). KV's pinned face (KD-15) and the blob rule-based
branch (w6ay) are untouched.

Note: `lib/smalt/mcp/router.ex` carried an unrelated in-flight deletion by
another lane (`defp actuation_verb?/1` dead clause, ~line 582); my edits
are disjoint (plug-list region). Disclosed per the compile-freeze
disclosure law.

## Method

The shared substrate (8443/9545) was UP serving other lanes — restarting it
is a global transition, not a lane's to make. Witnessed on a dedicated
private beam (testbed pattern from `justfile.d/22-native.just`): lock fd
closed on spawn, `MIX_BUILD_ROOT=_build-bk21`, private ports 29455-29460
(witnesses ran on egress 29458 / mcp 29460), `:auth_mode, :anonymous`
(preflights are auth-exempt; keeps witnesses auth-orthogonal). Harness:
`tmp/bk21/bk21_boot.exs` (tmp/ is scratch, uncommitted).

## Commands + exits (all exit 0)

### BEFORE (shared substrate, ports 8443/9545)

```
$ curl -s -i -X OPTIONS "http://127.0.0.1:8443/popcorn/q-test?restype=queue" \
    -H "Origin: http://localhost:3000" -H "Access-Control-Request-Method: GET"
HTTP/1.1 403 Forbidden
content-length: 0

$ curl -s -i -X OPTIONS "http://127.0.0.1:8443/secrets/probe" \
    -H "Origin: http://localhost:3000" -H "Access-Control-Request-Method: GET"
HTTP/1.1 204 No Content
access-control-allow-credentials: true
access-control-allow-origin: *
access-control-expose-headers:
access-control-max-age: 1728000
access-control-allow-headers:
access-control-allow-methods: GET,POST,PUT,PATCH,DELETE,OPTIONS

$ curl -s -i -X OPTIONS "http://127.0.0.1:9545/"
HTTP/1.1 404 Not Found
{"error":"not found"}
```

### AFTER (private beam, egress 29458 / mcp 29460)

```
$ curl -s -i -X OPTIONS "http://127.0.0.1:29458/popcorn/q-test?restype=queue" \
    -H "Origin: http://localhost:3000" -H "Access-Control-Request-Method: GET"
HTTP/1.1 204 No Content
access-control-allow-credentials: true
access-control-allow-origin: *
access-control-expose-headers:
access-control-max-age: 1728000
access-control-allow-headers:
access-control-allow-methods: GET,POST,PUT,PATCH,DELETE,OPTIONS

$ curl -s -o /dev/null -w "%{http_code}\n" -X OPTIONS \
    "http://127.0.0.1:29458/popcorn?comp=list&restype=queue" \
    -H "Origin: http://localhost:3000" -H "Access-Control-Request-Method: GET"
204

$ curl -s -i -X OPTIONS "http://127.0.0.1:29460/" \
    -H "Origin: http://127.0.0.1:5173" -H "Access-Control-Request-Method: POST"
HTTP/1.1 204 No Content
access-control-allow-credentials: true
access-control-allow-origin: *
access-control-expose-headers:
access-control-max-age: 1728000
access-control-allow-headers:
access-control-allow-methods: GET,POST,PUT,PATCH,DELETE,OPTIONS

# negative legs
$ curl -s -o /dev/null -w "%{http_code}\n" -X OPTIONS \
    "http://127.0.0.1:29458/popcorn/q-test?restype=queue" \
    -H "Origin: http://evil.example.com" -H "Access-Control-Request-Method: GET"
403

$ curl -s -o /dev/null -w "%{http_code}\n" -X OPTIONS "http://127.0.0.1:29460/" \
    -H "Origin: http://evil.example.com" -H "Access-Control-Request-Method: POST"
403

$ curl -s -o /dev/null -w "%{http_code}\n" -X OPTIONS \
    "http://127.0.0.1:29458/popcorn/q-test?restype=queue"
404

# pinned faces unchanged
$ curl -s -o /dev/null -w "%{http_code}\n" -X OPTIONS \
    "http://127.0.0.1:29458/secrets/probe" -H "Origin: http://localhost:3000" \
    -H "Access-Control-Request-Method: GET"
204

$ curl -s -o /dev/null -w "%{http_code}\n" -X OPTIONS \
    "http://127.0.0.1:29458/acct/cont/b" -H "Origin: http://localhost:3000" \
    -H "Access-Control-Request-Method: PUT"
403

# real queue lifecycle end-to-end after the CORS arm
$ curl -s -o /dev/null -w "%{http_code}\n" -X PUT \
    "http://127.0.0.1:29458/popcorn/q-test?restype=queue"
201
$ curl -s -o /dev/null -w "%{http_code}\n" \
    "http://127.0.0.1:29458/popcorn?comp=list&restype=queue"
200
```

## Regression gate

```
$ MIX_BUILD_ROOT=_build-bk21 mix test test/integration/{cors_headers_knob,healthz_cors,queue_message_ct,t27lq_list_queues_feed}_test.exs
Finished in 0.2 seconds
Result: 19 passed, 0 failures  (exit 0)
```

No MCP test file exists in the tree (removed with the v26.10.19 reset per
CLAUDE.md; successor verification/ts SDK probes pending V261019-08) — the
MCP face is witnessed at the wire only.

## Residuals

- BK-15 row 5 (blob, create-container preflight 403): this is the w6ay
  rule-based branch — real-Azure parity (no `<Cors>` rules seeded → 403 per
  real Azure). Not a gap in this fix; BK-15's blob re-witness can either
  seed rules via Set Blob Service Properties or re-classify the leg as
  rule-gated by design.
- Shared substrate still runs pre-fix code; the next substrate restart
  (coordinator-owned transition) picks it up.

## Standing

ALIVE — all primary legs 204 with the exact KV header face, negative legs
403 with no allow headers, pinned faces unchanged (kv 204, blob 403), real
queue lifecycle (PUT 201 / list 200) after the arm, 19/19 regression tests
pass on the lane build root.
