# AoQ plane profile (L28r, aq-architecture-spec.md §1.3): imported by
# config/runtime.exs ONLY when the :aoq plane is explicitly selected via
# SMALT_PLANES / config :smalt, :planes. Turning the selection on IS the
# AoQ gate permit — the same config :smalt, :aoq, [enabled: true] key the
# Smalt.Plane.DataSupervisor.aoq_child/0 gate reads (default boot without
# the selection stays byte-identical, gate OFF).
import Config

config :smalt, aoq: [enabled: true]
