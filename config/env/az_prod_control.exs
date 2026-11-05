import Config

# Control plane profile (AZB-05 spec, seeded by AZB-04).
# Imported by config/runtime.exs only when the control plane is selected
# (SMALT_PLANES=control or config :smalt, :planes, [:control]).
#
# Port single-source (AZB-04): the control-plane port is the flat key
# :arm_port. The :arm_gateway profile carries NO port key by design.

config :smalt, :arm_port, 9443
config :smalt, :arm_gateway, strict_version_validation: true
config :smalt, :graph_law, enforcement: :fail_closed

# AZB-10: cross-plane peer discovery by config — loopback only, zero egress.
# Ports are the flat single-source keys' own defaults (AZB-04); the peers map
# names PLANES, never ports of its own.
config :smalt, :peers,
  identity: "https://127.0.0.1:9444",
  data: "https://127.0.0.1:8443",
  integration: "sb://127.0.0.1:5672"
