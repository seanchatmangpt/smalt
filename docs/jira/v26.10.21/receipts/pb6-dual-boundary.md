# PB-6: Dual-Boundary Settlement Walk (wire vs native, per-step boundary tax)

**Standing:** **ALIVE** (single full run, 0 errors on both legs, artifacts on disk)

Date: 2026-10-21 · Lane: PB-6 (bench, OTP-29)

Context: solo (in-process native leg + private-substrate wire leg; no shared-substrate contact)

## What ran

The SAME 5-step settlement walk (lease → validate → CAS → seal → observe)
executed through BOTH boundaries with per-step wall decomposition:

- **Wire leg**: real `@azure/cosmos` 4.10.1 SDK (ESM build from
  `verification/ts/node_modules`) against a private substrate's **TLS twin**
  (`https://localhost:39174`, repo dev certs from `.smalt/tls/`, node trust via
  `NODE_EXTRA_CA_CERTS`). Per-step timing = client `performance.now()`
  timestamps around each SDK call. N=300 iterations (+20 warmup), 0 errors.
- **Native leg**: `Smalt.POWL2.ChangeFeed` in-process (ETS CAS store +
  zero-lease CDC feed), same step-for-step shape, per-step `:timer.tc`.
  N=5000 iterations (+200 warmup), 0 errors.

Step mapping (identical semantics on both legs):

| step | wire (@azure/cosmos) | native (ChangeFeed) |
|---|---|---|
| 1-lease | `items.create` → 201 + `_etag` | `put_item` → `{:ok, 201, etag}` |
| 2-validate | `item.read`, assert etag == lease etag | `etag/3`, pattern-match == lease etag |
| 3-cas | `item.replace {ifMatch: leaseEtag}` | `put_item if_match: lease_etag` |
| 4-seal | `item.replace {ifMatch: casEtag}` (seal body) | `put_item if_match: cas_etag` (seal body) |
| 5-observe | `item.read`, assert `state == "seal"` | drain CDC until seal etag visible (bounded 5s deadline) |

## Measured boundary tax (replaces the asserted 800 µs-vs-50 µs table)

Machine (`just bench-machine`, ambient default toolchain):
`{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
**But the lane itself ran pinned to OTP-29/Elixir 1.20.4** (asdf
`erlang/29.1.2` + `elixir/1.20.4-otp-29`, build root `_build-pb6`); the
in-process machine spec recorded in every jsonl row reads
`{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.20.4","otp":"29","darwin":"26.2"}`.

| step | wire p50 (ms) | wire p95 | native p50 (ms) | native p95 | tax p50 (ms) | ratio |
|---|---|---|---|---|---|---|
| 1-lease | 0.790 | 1.186 | 0.081 | 0.204 | +0.708 | 9.7x |
| 2-validate | 0.644 | 0.972 | 0.398 | 0.858 | +0.246 | 1.6x |
| 3-cas | 0.733 | 1.131 | 0.058 | 0.097 | +0.675 | 12.6x |
| 4-seal | 0.733 | 1.083 | 0.415 | 0.778 | +0.318 | 1.8x |
| 5-observe | 0.645 | 0.982 | 2.275 | 15.851 | **−1.630** | 0.3x |

Result file: `/Users/sac/smalt/tmp/bench/pb6-dual-boundary.jsonl` (5 rows,
fields: step, wire_ms, wire_p95_ms, native_ms, native_p95_ms, tax_ms,
tax_ratio, n_wire, n_native, errors, machine). Per-step leg stats:
`/Users/sac/smalt/tmp/bench/pb6-wire-steps.json`.

## Honest decomposition notes

1. **The wire leg includes real TLS + HTTP machinery the native leg
   deliberately excludes** — TCP+TLS handshake amortized over keep-alive,
   HTTP/1.1 request framing, Azure master-key header signing, JSON
   encode/decode, SDK pipeline middleware. Both legs are real products for
   different migration postures: the wire numbers are what a real Azure SDK
   client experiences; the native numbers are the in-process POWL ceiling.
   They are not apples-to-apples and are not presented as such — the tax
   column is the *measured cost of the boundary*, per step.
2. **Protocol note**: the TLS twin itself serves HTTP/2 (witnessed:
   `curl --http2 -I https://localhost:39174/dbs` → `HTTP/2 404`), but
   `@azure/cosmos` 4.10.1 negotiates **HTTP/1.1 over TLS** on this leg (node
   https agent ALPN). The "HTTP/2" boundary claim holds for the twin, not for
   this SDK's requests.
3. **Step-5 channel asymmetry**: the wire leg observes settlement by
   read-your-write point read; the native leg observes via the **CDC change
   feed drain** (batch delivery to a subscriber, includes mailbox/scheduler
   latency and a 1 ms poll step — annotated `after 0` + 1 ms bounded re-loop).
   The negative tax at step 5 says: the change-feed delivery path is slower
   than a wire round trip at p50. Read-back via `etag/3` (the native
   validate path) would sit at ~µs; the feed is the honest native
   observability product, so it is the one measured.
4. **Native validate/seal inflation (0.4 ms)**: `gen_statem` calls share the
   server with the CDC drain loop; at 5000 walks the drain work lands between
   the calls. This is real contention, not noise — the native leg is
   measured under its own feed's write amplification.
5. **Enforce-mode divergence found (NOT registered as KD by this lane)**: on
   an enforce-mode private substrate the full STS→bearer→user→permission→
   resource-token flow works over raw HTTP (all 201/200, token minted), but
   `@azure/cosmos` 4.10.1 percent-encodes its `Authorization` header
   (`type%3Dresource%26ver%3D1.0%26sig%3D...` per
   `dist/esm/auth.js:getAuthorizationTokenUsingResourceTokens`), while
   `Smalt.Auth.Bearer.resource_token_header?/1` matches the raw
   `type=resource&` prefix only → typed 401 `MissingBearerToken`. The wire
   leg therefore rode anonymous auth mode (b3-lane pattern) with master-key
   signing; the enforce resource-token SDK leg is a candidate KD row for the
   registrar.
6. **Pre-existing shared-substrate defect witnessed**: the shared substrate
   on `:9444` (beam pid 85369, v13 block) returns **empty-body 500** on
   `POST /dbs/{db}/users` and `POST .../permissions` (both `:9444` and
   `:8443`), while the same routes on a fresh private substrate return 201.
   Pre-existing, not session-introduced; the lane booted its own substrate
   rather than evicting or mutating the shared one.

## Replay

```bash
export PATH=/Users/sac/.asdf/installs/erlang/29.1.2/bin:/Users/sac/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH
cd /Users/sac/smalt
# 1. private TLS substrate (ports 39170..39175, MIX_ENV=test, _build-pb6):
SMALT_TLS_CERTFILE=$PWD/.smalt/tls/dev-cert.pem SMALT_TLS_KEYFILE=$PWD/.smalt/tls/dev-key.pem \
  MIX_BUILD_ROOT=_build-pb6 MIX_ENV=test mix run --no-start -e '
Application.put_env(:smalt, :arm_port, 39170); Application.put_env(:smalt, :egress_port, 39171);
Application.put_env(:smalt, :amqp_port, 39172); Application.put_env(:smalt, :event_hubs_port, 39173);
Application.put_env(:smalt, :arm_tls_port, 39174); Application.put_env(:smalt, :mcp_port, 39175);
{:ok,_}=Application.ensure_all_started(:smalt); Process.sleep(:infinity)' &
# 2. the walk (native leg in-process + node wire leg child):
MIX_BUILD_ROOT=_build-pb6 MIX_ENV=test mix run --no-start scripts/bench/pb6_dual_boundary.exs
```

Scripts: `/Users/sac/smalt/scripts/bench/pb6_dual_boundary.exs` (underscore),
`/Users/sac/smalt/scripts/bench/pb6_wire_leg.mjs`. Result jsonl (hyphen):
`/Users/sac/smalt/tmp/bench/pb6-dual-boundary.jsonl`.

## Reproduction (2026-10-21 backfill)

Fresh re-run skipped (wire leg needs a private substrate + node SDK child — not a cheap replay).
Output lives in the cited artifact `tmp/bench/pb6-dual-boundary.jsonl`; integrity re-checked:

```text
$ python3 -c "import json; rows=[json.loads(l) for l in open('/Users/sac/smalt/tmp/bench/pb6-dual-boundary.jsonl')]; print('rows:',len(rows),'errors:',sum(r.get('errors',0) for r in rows))"
rows: 5 errors: 0
exit 0
```
