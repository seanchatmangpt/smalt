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
  graphlaw_engine: nil

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

if config_env() == :test do
  import_config "test.exs"
end
