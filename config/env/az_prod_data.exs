import Config

# Data plane profile (AZB-06 spec, seeded by AZB-04).
# Imported by config/runtime.exs only when the data plane is selected
# (SMALT_PLANES=data or config :smalt, :planes, [:data]).
#
# Port single-source (AZB-04): the data-plane listener port is the flat key
# :egress_port. The :cosmos / :blob_storage profiles carry NO port key.

config :smalt, :egress_port, 8443
config :smalt, :cosmos, endpoint: "https://localhost:8443", max_ru_limit: :unbounded
config :smalt, :blob_storage, persistence: :dets_mirrored, sync_interval_ms: 0

# AZB-10: cross-plane peer discovery by config — loopback only, zero egress.
config :smalt, :peers,
  control: "https://127.0.0.1:9443",
  identity: "https://127.0.0.1:9444",
  integration: "sb://127.0.0.1:5672"
