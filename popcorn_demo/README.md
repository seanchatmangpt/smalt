# popcorn_demo — smalt's pure-decision slice on Popcorn (Elixir in WASM)

Minimal working slice: smalt's pure layers compiled to BEAM bytecode and run
inside a real browser on the Popcorn WASM BEAM (OTP/BEAM compiled to WebAssembly).

## What runs in-browser (ALIVE, receipted)

- `Smalt.CosmosSql` — parse + evaluate (WHERE/ORDER BY/LIMIT, params)
- `Smalt.SbRules` — Service Bus SQL rule filter compile + match
- `Smalt.Registry` — admitted resource types + api-version lattice

Witness: `scripts/browser_smoke.mjs` (headless Chromium, COOP/COEP server)
prints `SMOKE_RECEIPT: cosmos_sql=OK(...); sb_rule=OK(...); registry=OK(...)`.

## What stays host-side forever (typed BLOCKED, per Popcorn limits)

- Bandit/Plug HTTP servers — browsers allow no raw sockets (`:gen_tcp`/`:gen_udp`
  unsupported; HTTP only via `Popcorn.Fetch` through browser fetch())
- wasmex — dynamic NIF loading unsupported
- ETS/DETS-backed `Smalt.Store` — ETS works on the wasm BEAM, but the shared
  Smalt.Store GenServer surface depends on Smalt.Amqp/ArmGateway modules not
  in the slice; DETS file persistence has no browser filesystem
- AMQP/EH wire servers, :ssl/public_key servers — same socket restriction
- ex4pm path dep — not in slice

## Chicago testbed charter (canonical contract: `docs/TESTBED.md`)

popcorn_demo is smalt's Chicago-school testbed: real collaborators (the live
substrate on 127.0.0.1:9443/8443), no mocks, loud skips, non-vacuous gates.
`docs/TESTBED.md` (repo root) is the single canonical home for the live
loopback leg table, the exit-code contract for `node scripts/browser_smoke.mjs`,
skip-reason labels, the no-sleep law, and the one named double exception
(`Popcorn.Fetch` is browser-only; host uses real `:httpc`, never a mock).
Witness receipts live in `popcorn_demo/receipts/` (standing line + embedded
command output; output-less receipts are SUSPECT per `receipt_index.py`).

## Toolchain (pinned by the packager, exact-match enforced)

- Erlang/OTP 29.0.6 (must equal the runtime's OTP; `unsupported_otp` otherwise)
- Elixir 1.20.4-otp-29
- Popcorn hex 0.4.0-next.7 (hex ships the `core` runtime only; crypto variant
  needs the npm package, so `config :popcorn, runtime_variant: :core`)
- Beware `~/.erlmcp/otp-28.3.1/bin` shadowing `erl` on PATH — put the asdf
  OTP bin dir FIRST.

## Commands

```sh
export PATH="$HOME/.asdf/installs/erlang/29.0.6/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
mix deps.get
mix compile
mix test                      # host-side smoke, same toolchain
mix popcorn.cook --out-dir public/out
node scripts/browser_smoke.mjs   # in-browser ALIVE witness (exit 0)

# ERRC status / lane-lease cleanup / receipt standings (repo root or popcorn_demo/)
just popcorn-errc-status          # file inventory + present lane build roots
just popcorn-lane-clean           # lane build roots, dry-run default; -y deletes
just popcorn-receipts             # newest 5 receipts' standing lines
```

Toolchain law: host walks run 1.20.3-otp-28; cook stays 29.0.6 (see
`docs/TESTBED.md` "Toolchain law (host-side live walks)").

## Live loopback leg (witnessed)

- live= — the ARM auth-path walk (`live.ex`): GET /metadata/endpoints,
  GET /tenants (parse first tenantId), POST /{tid}/oauth2/v2.0/token
  (form-encoded client_credentials), then a Bearer-authed
  GET /subscriptions?api-version=2022-12-01. Control plane 9443, CORS `*`,
  preflight OPTIONS is auth-exempt (the browser never sends credentials on
  the OPTIONS hop, so an auth-gated preflight would break every cross-origin
  request before any real request fires). Fragments: `live=OK(...)`,
  `live=FAIL(step:reason)`, `live=SKIP(substrate-down)` on connection-refused
  (host: `econnrefused`; browser: the fetch "Failed to fetch" family — same
  skip class). Substrate preflight: `9>&- just substrate-up`.
- queue= — Queue put/get round trip via
  `popcorn_demo/lib/popcorn_demo/live_queue.ex` against the real data-plane
  REST face (127.0.0.1:8443), STS token from 9443, `content-type:
  application/xml` pin.
- Topic pub/sub (topic=), Event Hubs publish (eh=), Event Grid publish (eg=)
  and local delivery (egd=) — messaging legs via `live_topic.ex`, `live_eh.ex`,
  `live_eg.ex`, `live_egd.ex`.
- Cosmos docs (matrix=), blob put/get (blob=), containers walk (containers=),
  TLS twin walk (tls=), queue (queue=) — data-plane legs via `live_matrix.ex`,
  `live_blob.ex`, `live_containers.ex`, `live_tls.ex`.
- ARM walks: rules (rules=), resource graph (rg=), parameters (param=),
  policy (policy=), lifecycle (lifecycle=), DNS (dns=), template export
  (export=) — via `live_rules.ex`, `live_rg.ex`, `live_param.ex`,
  `live_policy.ex`, `live_lifecycle.ex`, `live_dns.ex`, `live_export.ex`.
- Key Vault: secrets (kv=) and key ops (keyops=) via `live_kv.ex`,
  `live_keyops.ex`; App Configuration (appconfig=) via `live_appconfig.ex`.
- Governance/concurrency: ETag CAS (cas=), resource tags (tags=), reconcile
  (reconcile=), in-browser SCVD (scvd=), MCP surface (mcp=), certs (certs=),
  APIM (apim=) — via `live_cas.ex`, `live_tags.ex`, `live_reconcile.ex`,
  `live_scvd.ex`, `live_mcp.ex`, `live_certs.ex`, `live_apim.ex`.
- Container Registry (`live_acr.ex`) is a typed UNSUPPORTED loud skip
  (`{:unsupported, :acr_face_absent}`) — no ACR face exists in smalt; never a
  faked pass. Full charter table: `docs/TESTBED.md`.

Every leg is named only after its module was verified on disk
(`ls popcorn_demo/lib/popcorn_demo/`, 2026-10-20).

One-command gate (from the repo root):

```sh
just popcorn-court   # preflight -> cook -> browser witness -> fail on any non-zero
```

Witness harness (from `popcorn_demo/`):

```sh
bash scripts/receipt_testbed.sh   # substrate preflight -> host legs -> browser witness
                                  # -> standing-line receipt in popcorn_demo/receipts/
```

Exit codes for `node scripts/browser_smoke.mjs`: canonical table lives in
`docs/TESTBED.md` (short form: 0 = `live=OK`, 1 = `FAIL`, 3 = loud `SKIP`).
`SMOKE_ALLOW_OFFLINE=1` downgrades a `live=SKIP` run to exit 0 (loud — the
SKIP fragments stay printed in the receipt); a `live=FAIL` (or any `=FAIL`
while `live=OK`) still exits 1 under `SMOKE_ALLOW_OFFLINE=1`.

## SCVD browser gate (SCVD-T16)

After the smoke's exit-code computation, `scripts/browser_smoke.mjs` runs a
fail-closed gate over the `scvd=` fragment of `SMOKE_RECEIPT`. The fragment
format is `scvd=(OK|SKIP|FAIL)(...)` whose body must carry a positive
`t16:<n>ms` wall, e.g.
`scvd=OK(t16:5.295ms,p99:569us;t256:70.389ms,...)`.

Typed exit-1 reasons:

- `SCVD-FRAGMENT-MISSING` — no `scvd=` in the receipt
- `SCVD-FRAGMENT-MALFORMED` — fragment not `scvd=(OK|SKIP|FAIL)(...)` or no
  positive `t16:<n>ms` wall in the body
- `SCVD-BASELINE-MISSING` — `tmp/bench/scvd-wasm-vs-host.jsonl` absent
- `SCVD-DEGRADED` — `scvd=SKIP/FAIL(...)`, or the t16 wall exceeds 3x the
  rolling-best t16 (minimum across all baseline rows carrying
  `scvd=OK(t16:` in their `wasm_fragment`)

Exit-3 supremacy: the substrate-down path is computed first and preserved
(`finalExit = exitCode === 3 ? 3 : Math.max(exitCode, gate)`), so the gate
never upgrades a loud SKIP to a pass. With no comparable baseline rows the
gate passes through as `SCVD-OK ... (nothing to compare)` rather than
inventing a bound. Non-vacuity: the gate was witnessed flipping to
`SCVD-DEGRADED` exit 1 under a tolerance-perturbed run (receipt
`popcorn_demo/receipts/20261021T110000Z-t16-scvd-gate.md`, standing ALIVE).
