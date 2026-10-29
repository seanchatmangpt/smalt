# BK-40 — SKIP-audit: adversarial re-typing of the 9 TYPED-PERMANENT legs + jsonl SKIP census

**Standing:** PARTIAL_ALIVE
Context: solo
Date: 2026-10-22

## Method

Every BK-15 TYPED-PERMANENT reason (docs/jira/v26.10.21/receipts/bk15-skip-fetch-census.md)
was tested against the actual walk code (`popcorn_demo/lib/popcorn_demo/live_*.ex`) and,
where a wire claim was load-bearing, against the live substrate. The kv=OK precedent
(most transport blockers flip) held: **5 of 9 re-typed PENDING-DISPATCH, only 4 survive as
confirmed permanent.**

## Per-leg verdict table (the 9 TYPED-PERMANENT)

| leg | BK-15 typed reason | verdict | mechanism / fix path |
|---|---|---|---|
| certs | walk calls `:public_key.pem_encode/1` locally | **RE-TYPED-PENDING-DISPATCH** | `pem_encode` is pure PEM **framing** (header + base64), not crypto. The call site (live_certs.ex:213) merely VALIDATES wire-delivered DER (`Base.decode64` of `cer`). Fix: assert DER structurally — binary pattern-match the SEQUENCE tag `0x30` + length — or hand-roll PEM framing (string concat + `Base.encode64`). Zero `:public_key` needed. |
| reconcile | walk calls `:crypto.hash/2` for a checksum | **RE-TYPED-PENDING-DISPATCH** | `:crypto.hash` lives in `Reconcile.consistency_hash/0` (reconcile.ex:124), computed eagerly inside `reconcile/2`'s return map — and `grep hash live_reconcile.ex` = **zero hits**: the walk never asserts on it. Fix: pure-BEAM consistency face (`:erlang.phash2` over the sorted tuples — deterministic in wasm) or lazy hash field. |
| eg | "publish is AMQP framing over a raw socket — fetch() cannot carry it" | **RE-TYPED-PENDING-DISPATCH** | BK-15's reason is **contradicted by the code**: eg publish is `POST /topics/<t>/events` over HTTP (live_eg.ex:175-201), already Fetch-routed via `req/1` (Fetch dispatch landed in BK-15). Wire-verified this session: `OPTIONS /topics/pegl3/events` → **403, zero access-control headers** — the same route-scoped data-plane CORS gap as queue/blob. Fix = substrate CORS route fix, shared lane. |
| topic | walk needs the AMQP socket (`:gen_tcp` to 5672) | **RE-TYPED-PENDING-DISPATCH** (compound) | True that the topic walk is SASL-AMQP over raw `:gen_tcp` (live_topic.ex:276). Fix path exists (real-Azure SB parity: AMQP-over-WebSocket on 443): substrate-side WS upgrade listener relaying frames to 5672, client via Popcorn JS interop `WebSocket`. Second face: SAS HMAC (`:crypto.mac`, live_topic.ex:97) — fixed-payload constant precedent (keyops) or host-side mint at cook time. |
| eh | AMQP plane not booted on this profile — "transport-orthogonal" | **RE-TYPED-PENDING-DISPATCH** | Two refutations: (1) the SKIP string itself embeds the fix ("run `9>&- just substrate-up`"); (2) **measured this session: 5672 AND 5673 are UP**. Residual blocker is wasm raw-TCP (same as topic) → same AMQP-over-WS relay lane. Plane precondition is already green. |
| egd | kd101 airgap: local-delivery unimplemented | **CONFIRMED-PERMANENT** | Mechanism: kd101 typed airgap refusal — local delivery deliberately unimplemented by design; not a transport gap; no substrate or client change under discussion removes the typed refusal. |
| acr | face-absent `acr_face_absent` | **CONFIRMED-PERMANENT** | Mechanism: by-design typed face-absence — the surface deliberately exposes no ACR face; transport-orthogonal. |
| apim | designed verdict is face-absence (PUT refused by ontology enforcement) | **CONFIRMED-PERMANENT** | Mechanism: ontology enforcement refuses the PUT by design; even fully Fetch-routed the leg's designed verdict stays a typed SKIP (dns analogue witnessed in BK-15). |
| tls | ca-missing; "fix is substrate cert seeding, not a transport gap" | **CONFIRMED-PERMANENT** | Mechanism: the leg's designed assertion is BEAM-side chain verification (raw `:ssl` socket, `verify: :verify_peer`, `cacertfile`, `pkix_verify_hostname_match_fun`; live_tls.ex:80-135). The wasm BEAM has no `:ssl` NIF; `fetch()` does TLS in the browser against the OS trust store — pinning the self-signed smalt CA requires OS trust mutation (`security add-trusted-cert`), outside a zero-mutation witness scope. The ca-missing face is incidental (CA exists on disk now); the underlying blocker is not. |

**Score: 4 CONFIRMED-PERMANENT (egd, acr, apim, tls) / 5 RE-TYPED-PENDING-DISPATCH (certs,
reconcile, eg, topic, eh).**

## jsonl SKIP census

`grep -h SKIP tmp/*.jsonl | sort -u` — the tmp root jsonls (affidavit-seal-bench, burn-soak
20261018/19 series, f16L4-adm series, spc-history) contain **zero SKIP strings**. Two files
carry SKIP state:

| file | SKIP string | classification |
|---|---|---|
| tmp/bench/spc-watch2.jsonl | `verdict: SKIP, reason: load_gate_never_opened` (gate requires 1-min load < 8; measured 33.32 / 37.45 / 40.30 across 3 checks 18:38–18:50Z) | **PENDING-DISPATCH** — environmental load gate, transport-orthogonal; fix is `just quiesce` + re-run under quiesced load (the court-x2 quiet-check precedent). Not permanent. |
| tmp/bench/ctq4-memory.jsonl | `smoke_receipt: "... SKIP legs typed wasm-transport/cors"` | **REFERENCE-ONLY** — not a leg verdict; restates the popcorn witness-all classification (below). |

## popcorn_demo receipts census (witness-all series, incl. baseline 20261021T234535Z)

Distinct SKIP strings, one per leg, classified:

| SKIP string (distinct) | legs | classification |
|---|---|---|
| `wasm-transport: :httpc undefined` | apim, dns, mcp, policy, queue, topic | see BK-15: policy/dns FLIPPED OK; mcp/queue PENDING-DISPATCH (CORS); apim confirmed permanent above; topic re-typed above |
| `wasm-transport: :gen_tcp client` / `{:tcp_connect, :eprotonosupport}` | keyops, (eh face) | keyops PENDING-DISPATCH (BK-15); note BK-40 adds: live_keyops.ex:279 `:crypto.hash` is a second, unregistered blocker — fixed-payload → constant-digest precedent applies |
| `cors-preflight-403:create-container` | blob | PENDING-DISPATCH (CORS route fix, shared with queue + now eg) |
| `wasm-transport:publish` | eg | re-typed above — actually the CORS 403 face |
| `wasm-transport: :public_key.pem_encode/1 undefined` | certs | re-typed above |
| `wasm-transport: :crypto.hash/2 undefined` | reconcile | re-typed above |
| `eh-plane-down(5673-connect-:eprotonosupport)` | eh | re-typed above (plane now measured up) |
| `kd101-airgap:local-delivery-unimplemented` | egd | CONFIRMED-PERMANENT |
| `face-absent::acr_face_absent` | acr | CONFIRMED-PERMANENT |
| `ca-missing: .smalt/tls/ca-cert.pem` | tls | CONFIRMED-PERMANENT (on the underlying :ssl-in-wasm mechanism) |

## Fix lanes surfaced (for dispatch)

1. **CORS route-scoping lane** (substrate): extend data-plane preflight 204 to
   `/topics/*/events` (eg), queue paths, `create-container` (blob) — same shape as the
   `/secrets` 204. Flips eg, queue, blob, mcp(9545 CORS) legs. Highest flip-count lane.
2. **Walk-restructure lane**: certs (structural DER assert), reconcile (`:erlang.phash2`
   consistency face), keyops (constant digest). No substrate change needed.
3. **AMQP-over-WebSocket relay lane**: eg/topic/eh SASL-AMQP over WS upgrade on the
   integration plane; real-Azure SB parity precedent. Plus topic SAS-HMAC constant-token.
4. `spc-watch2` load-gate re-run under `just quiesce`.
