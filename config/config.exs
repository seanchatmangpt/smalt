import Config

# Required by ash >= 3.36 transformer (disclosed minimal fix: pre-existing
# compile failure blocked all tests; codepoints matches Elixir-side validation).
config :ash, default_string_length_count: :codepoints

# Lane defaults (egress router lane).
config :smalt,
  blob_catch_all_hosts: [],
  skr_allow_legacy_header: false,
  maa_measurement_baseline: [],
  kv_master_secret: nil,
  receipt_signing_key: nil,
  lro_delay_ms: 0,
  graphlaw_engine: nil,
  # Latency-realism lane: OFF by default (no added latency anywhere).
  # Turn on per config.exs comment in Smalt.Egress.LatencyPlug moduledoc.
  # AZURE-FIDELITY lane 18: when armed, the ARM control plane additionally gets
  # built-in per-route-class profiles (deployments 250/800, graph 60/150,
  # cost 150/400 ms p50/p99); explicit `:planes` entries override, e.g.
  #   config :smalt, :latency,
  #     planes: %{"deployments" => [p50_ms: 300, p99_ms: 900],
  #               "graph" => [p50_ms: 50, p99_ms: 150],
  #               "cost" => [p50_ms: 150, p99_ms: 400]}
  latency: :off

# WASM sandbox runtime (WASM-1/GWS-18). Stub mode is the default: the packet-4
# stub runner priv/wasm/stub_runner.exs answers every eval envelope. The real
# graphlaw wasm module is a CONFIG-ONLY swap: set :wasm_runner_path to the
# graphlaw-run binary (graphlaw repo, built with --features runner) — the
# worker speaks the same packet-4 frames and the same exit-86 memory-wall /
# fault-mode contract. Leave :wasm_binary_path unset (that selects wasmtime
# raw-abi mode instead).
# config :smalt, :wasm_runner_path, "/Users/sac/graphlaw/target/release/graphlaw-run"

# GL28-2: GraphLaw admission gate (host-side config schema). Precedence follows
# GraphlawEx.WasmConfig.expected_sha256/1 (graphlaw repo,
# graphlaw_ex/lib/graphlaw_ex/wasm_config.ex:146): an explicit override wins;
# the default is fail-closed — a nil engine_digest is "pin unavailable", which
# the gate REFUSES, never reads as "unpinned".
config :smalt, :graphlaw_ex_gate,
  # Opt-in. No prod config enables the gate: prod stays host-owned (the
  # STS-bearer egress path is unchanged while the gate is off).
  enabled: false,
  # Pinned sha256 of the vendored graphlaw wasm. nil = pin unavailable = refuse
  # (mirrors WasmConfig.pinned_sha256/0 collapsing manifest defects to nil).
  engine_digest: nil,
  # Backpressure bound on queued gate requests (WasmConfig default max_queue).
  max_queue: 64,
  # Any gate defect answers a typed refusal, never a degrade to the host path.
  fail_closed: true

# Bearer auth (lane: s4-oauth-negatives). :enforce (default/prod) requires a
# valid STS-signed Bearer on every non-exempt route; :anonymous is the explicit
# opt-out. Audiences may be widened via :token_audiences.
config :smalt, :auth_mode, :enforce
config :smalt, :token_audiences, ["https://management.azure.com"]

# TLS on the Bandit egress (8443) and ARM (9443) listeners (lane: tls).
# :auto (default at runtime) generates a self-signed dev cert into tmp/;
# production users set explicit cert/key paths and their own certs.
config :smalt, :tls, :auto
config :smalt, :tls_certfile, nil
config :smalt, :tls_keyfile, nil

# Ports (defaults mirrored from Smalt.Application for visibility).
config :smalt, :arm_port, 9443
config :smalt, :egress_port, 8443

# Service Bus CBS auth (lane: sas-config). Endpoint scopes SAS token audiences
# in SasVerifier/CbsRouter; :sb_shared_key set to a >=32-byte binary pins the
# HMAC key (nil = generated dev key cached in :persistent_term, for tests/dev).
config :smalt, :sb_endpoint, "sb://127.0.0.1:5672"
config :smalt, :sb_shared_key, nil

# Plane selection (AZB-04): SMALT_PLANES (comma list) or explicit list;
# default :all boots exactly today's child list (no env-profile import).
# Parsing + validation (invalid_plane refusal) happen at runtime-config time
# in config/runtime.exs via Smalt.Planes.resolve/0.
config :smalt, :planes, :all

# MOONSHOT lane 9 (throttling realism): per-plane token-bucket throttle on the
# egress router. DEFAULT-OFF — rate/burst nil (or missing) means unlimited;
# the plug short-circuits before any bucket math. Enable via config or the
# SMALT_THROTTLE_RATE / SMALT_THROTTLE_BURST env vars (rate tokens/sec,
# burst = bucket size). Exhaustion answers the real-Azure 429 face for the
# request's plane (storage XML / cosmos / EventHubs ServerBusy) with
# retry-after. Tests inject a deterministic clock via
# `config :smalt, :throttle_clock, Mod` (Mod.now_ms/0).
config :smalt, :throttle, rate: nil, burst: nil
config :smalt, :throttle_clock, nil

# AZURE-FIDELITY lane 8 + G2 gap-closure: Marketplace SaaS fulfillment face
# (/saas/*) on the egress router. DEFAULT-ON as of 2026-10-25 (config flip) —
# an explicit `enabled: false` still leaves every conn falling through to the
# pre-lane routing (byte-identical wire; Gate 5 of the court proves it). When enabled:
#   * `publisher_token` — required Bearer secret per request (nil = open,
#     loopback-only discipline)
#   * `tokens` — map of x-ms-marketplace-token => purchase record
#     (id / subscriptionName / publisherId / offerId / planId / quantity)
config :smalt, :marketplace_saas, enabled: true,
  # D1 lane (athena differential D1): dev-default purchase record, default-on
  # like the rest of the dev posture. The athena wire runner sends the minted
  # STS bearer (the transport Auth.Bearer plug validates it — publisher_token
  # MUST stay nil: one Authorization header, two verifiers, a literal
  # "dev-publisher" bearer is unreachable over the real wire) plus
  # x-ms-marketplace-token: dev-mp-token (env MARKETPLACE_DEV_TOKEN).
  publisher_token: nil,
  tokens: %{
    "dev-mp-token" => %{
      "id" => "af-sub-1",
      "subscriptionName" => "smalt-dev-subscription",
      "publisherId" => "smalt-dev-publisher",
      "offerId" => "smalt-dev-offer",
      "planId" => "free",
      "quantity" => 1
    }
  }

# JA-15 gap G5: Logger.metadata correlation ids were invisible under the
# default formatter (metadata list empty by default). Minimal config-level
# fix: the default formatter renders the correlation id on every log line.
config :logger, :default_formatter,
  format: "$time $level[$metadata] $message\n",
  metadata: [:correlation_id]

if config_env() == :dev do
  import_config "dev.exs"
end

if config_env() == :test do
  import_config "test.exs"
end
