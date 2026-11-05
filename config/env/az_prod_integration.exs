import Config

# Integration plane profile (AZB-07 spec, seeded by AZB-04).
# Imported by config/runtime.exs only when the integration plane is selected
# (SMALT_PLANES=integration or config :smalt, :planes, [:integration]).
#
# Port single-source (AZB-04): the AMQP/Service Bus endpoint (including its
# port) is the flat key :sb_endpoint. The :amqp / :event_grid profiles carry
# NO port key.

config :smalt, :sb_endpoint, "sb://127.0.0.1:5672"
config :smalt, :amqp, sasl_mechanisms: [:anonymous], max_frame_size: 65536
config :smalt, :event_grid, delivery_mode: :at_least_once

# AZB-10: cross-plane peer discovery by config — loopback only, zero egress.
config :smalt, :peers,
  control: "https://127.0.0.1:9443",
  identity: "https://127.0.0.1:9444",
  data: "https://127.0.0.1:8443"
