# BK-15 — In-browser SKIP legs census + first Transport.Fetch ports

**Standing:** PARTIAL_ALIVE
Context: solo
Date: 2026-10-21

## What ran (real wire, in-browser wasm BEAM, live substrate)

- Substrate was UP throughout (9443 ARM / 8443 data / 9545 MCP probed; never restarted).
- Cook (runtime toolchain 29.0.6 / 1.20.4-otp-29): `mix popcorn.cook --out-dir public/out` — PASS (`Cooked 8 applications`), twice.
- Browser smoke (`popcorn_demo/scripts/browser_smoke.mjs`, headless Chromium) run twice after the ports:
  - `policy=OK(5-faces-1-defs)` — FLIPPED from `SKIP(wasm-transport)`.
  - `queue=FAIL(create-queue:{:fetch, "TypeError: Failed to fetch ... missing CORS response header"})`
  - `mcp=SKIP(mcp-down: {:fetch, ... missing CORS ...})`
  - `dns=UNSUPPORTED(recordset-A:RouteNotFound-404-zone-deleted-clean)` — full walk rode Fetch end-to-end (RG PUT, zone PUT, vNetLink PUT/GET, delete, 404); the remaining verdict is the leg's by-design typed face-absence, not transport.
- Host mix test (1.20.3-otp-28): `Result: 190 passed, 3 skipped` — 0 failed. (First run of the pair had 34 failures on the busy shared beam; clean rerun green — the witnessed busy-beam load-flake class, not a regression from these ports.)
- Wire evidence — data-plane CORS is route-scoped (curl preflights, embedded verbatim):
  - `OPTIONS /secrets/probe-bk15?api-version=7.4` → **204**, `access-control-allow-origin: *`, `allow-methods: GET,POST,PUT,PATCH,DELETE,OPTIONS`, `allow-headers: authorization,content-type` (kv=OK precedent confirmed at the wire).
  - `OPTIONS /popcorn/q-bk15?restype=queue` → **403**, zero access-control headers.
  - `OPTIONS http://127.0.0.1:9545/` → **404**, zero access-control headers (MCP plane serves no CORS at all).

## Ports landed (popcorn_demo only; smalt lib/ untouched)

kv=OK precedent (dispatch `PopcornDemo.Transport.Fetch` when `Popcorn.JS.available?()`, else `Transport.Httpc`) applied to four Httpc-hardcoded legs:

| leg | file | change |
|---|---|---|
| queue | `popcorn_demo/lib/popcorn_demo/live_queue.ex` | `request/1` now Fetch-aware (kv-style); req maps normalized with default `:headers` |
| mcp | `popcorn_demo/lib/popcorn_demo/live_mcp.ex` | 3 call sites + new `request/1`/`browser?/0` helpers (kv-style) |
| policy | `popcorn_demo/lib/popcorn_demo/live_policy.ex` | `req/3` pipe swapped to Fetch-aware dispatch + `browser?/0` |
| dns | `popcorn_demo/lib/popcorn_demo/live_dns.ex` | `req/3` pipe swapped to Fetch-aware dispatch + `browser?/0`; moduledoc transport law updated |

## 15-leg census (baseline: popcorn_demo/receipts/20261021T234535Z-witness-all.md — 16 OK / 15 SKIP / 0 FAIL)

| # | leg | baseline verdict | status | blocker / evidence |
|---|-----|------------------|--------|--------------------|
| 1 | policy | `SKIP(wasm-transport: :httpc undefined)` | **PORTED-OK** | `policy=OK(5-faces-1-defs)` witnessed twice on the live wire via Fetch |
| 2 | dns | `SKIP(wasm-transport: :httpc undefined)` | **PORTED-OK** (transport) | full walk rode Fetch end-to-end; verdict is the leg's by-design typed `UNSUPPORTED(recordset-A face-absent)` — transport blocker gone, wire walk witnessed |
| 3 | mcp | `SKIP(wasm-transport: :httpc undefined)` | **PENDING-DISPATCH** | port landed; MCP plane 9545 serves no CORS headers (curl OPTIONS → 404, no allow-origin) — substrate-side fix required |
| 4 | queue | `SKIP(wasm-transport: :httpc undefined)` | **PENDING-DISPATCH** | port landed; data-plane CORS is route-scoped — queue paths get preflight **403** while `/secrets` gets **204** (wire evidence above); substrate-side fix required |
| 5 | blob | `SKIP(cors-preflight-403:create-container)` | **PENDING-DISPATCH** | same route-scoped data-plane CORS gap (create-container preflight 403); no port needed, walk is already Fetch-routed |
| 6 | keyops | `SKIP(wasm-transport: :gen_tcp client)` | **PENDING-DISPATCH** | raw `:gen_tcp` HTTP/1.1 client would ride Fetch mechanically, but faces the same data-plane CORS 403; port rides behind the CORS fix |
| 7 | certs | `SKIP(wasm-transport: :public_key.pem_encode/1 undefined)` | **TYPED-PERMANENT** | walk itself calls `:public_key` to PEM-encode locally — not a transport gap; needs walk redesign to take the PEM from the wire |
| 8 | reconcile | `SKIP(wasm-transport: :crypto.hash/2 undefined)` | **TYPED-PERMANENT** | walk itself calls `:crypto.hash` for a checksum — not a transport gap |
| 9 | eg | `SKIP(wasm-transport:publish)` | **TYPED-PERMANENT** | publish is AMQP framing over a raw socket — fetch() cannot carry it |
| 10 | topic | `SKIP(wasm-transport: :httpc undefined)` | **TYPED-PERMANENT** | leg needs the AMQP socket (`:gen_tcp` to 5672/5673) for the topic walk itself; its ARM half alone cannot carry the leg |
| 11 | eh | `SKIP(eh-plane-down(5673 :eprotonosupport))` | **TYPED-PERMANENT** | AMQP plane not booted on this substrate profile — transport-orthogonal |
| 12 | egd | `SKIP(kd101-airgap:local-delivery-unimplemented)` | **TYPED-PERMANENT** | by-design airgap refusal (kd101), transport-orthogonal |
| 13 | acr | `SKIP(face-absent::acr_face_absent)` | **TYPED-PERMANENT** | by-design typed face-absence — transport-orthogonal |
| 14 | apim | `SKIP(wasm-transport: :httpc undefined)` | **TYPED-PERMANENT** | the apim walk's designed verdict is face-absence (PUT refused by ontology enforcement); even Fetch-routed it stays a typed SKIP by design |
| 15 | tls | `SKIP(ca-missing: .smalt/tls/ca-cert.pem)` | **TYPED-PERMANENT** | fix is substrate cert seeding, not a transport gap — fetch() cannot read local files |

Row-counting note: the 15 baseline SKIPs are exactly acr, apim, blob, certs, dns, eg, egd, eh, keyops, mcp, policy, queue, reconcile, tls, topic — all 15 rows above, one per leg, every baseline leg accounted for.
---

## BK-15b re-witness (2026-10-22) — appendix, history above unchanged

Receipt: `docs/jira/v26.10.21/receipts/bk15b-skip-rewitness.md`.
**Standing:** PARTIAL_ALIVE. `Context: solo`. Substrate pid 48942 (fresh boot of
landed BK-21 code, never restarted during the witness). Cooked 3x with the
pinned 29.0.6/1.20.4-otp-29 toolchain; browser smoke 3 runs.

| # | leg | BK-15 status | BK-15b status | evidence |
|---|-----|--------------|---------------|----------|
| 3 | mcp | PENDING-DISPATCH | **OK(32-tools) — FLIPPED** | rode Transport.Fetch end-to-end (root shape + tools/list + tools/call), 3/3 smoke runs |
| 4 | queue | PENDING-DISPATCH | **FAIL(actual-request CORS)** | BK-21 preflight face witnessed 204 on the wire; the actual PUT create-queue response carries no `access-control-allow-origin` → browser blocks the actual response |
| 5 | blob | PENDING-DISPATCH | **SKIP — mislabelled; blocker narrowed** | w6av surface exists and works (PUT ?restype=service&comp=properties → 202; preflight → 200 with rule face); remaining blocker = the same actual-response allow-origin gap as queue (w6ay else-branch registers Expose-Headers only) |
| 6 | keyops | PENDING-DISPATCH | **OK(ES256:verified) — FLIPPED** | full walk via Fetch (health → KV 401 challenge → STS → EC create 200 → ES256 sign/verify valid + tampered false), 2/2 runs; BK-46's Fetch port + precomputed digests; BK-15b disclosed GET-body unblock in `request/1` |
| — | certs | TYPED-PERMANENT | **REGRESSION → FAIL(deleted-get: missing CORS response header)** | concurrent lane's fetch port; same allow-origin residual class; owner = certs-port lane |

Single remaining substrate gap (typed): actual (non-preflight) data-plane
responses outside the KV CORSPlug pipeline — queue paths (BK-21 arm answers
OPTIONS only) and blob paths (w6ay else-branch) — carry no
`access-control-allow-origin`. Close condition: extend w6ay's actual-request
branch + BK-21's queue arm to register allow-origin on matching-origin
actual responses; queue and blob then flip on the next re-witness with no
demo-side edit (live_blob.ex's own close condition predicts this).
