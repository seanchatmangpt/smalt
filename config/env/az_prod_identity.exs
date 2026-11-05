import Config

# Identity plane profile (AZB-08 spec, seeded by AZB-04).
# Imported by config/runtime.exs only when the identity plane is selected
# (SMALT_PLANES=identity or config :smalt, :planes, [:identity]).

config :smalt, :keyvault, api_version: "7.4", challenge_mode: :strict_bearer
config :smalt, :sts, token_ttl_seconds: 3600, pki_envelope: :pqc_hybrid

# AZB-10: cross-plane peer discovery by config — loopback only, zero egress.
# The identity peer endpoint is the pinned spec value (TICKETS.md AZB-10).
config :smalt, :peers,
  control: "https://127.0.0.1:9443",
  identity: "https://127.0.0.1:9444",
  data: "https://127.0.0.1:8443",
  integration: "sb://127.0.0.1:5672"
