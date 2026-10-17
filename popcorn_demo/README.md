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
