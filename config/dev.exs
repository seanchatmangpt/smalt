import Config

# GL28-2: local dev opts in to the GraphLaw admission gate. Enabling here flips
# the gate on, not its trust boundary: engine_digest stays nil (pin unavailable
# = typed refusal) until a real sha256 pin is configured.
config :smalt, :graphlaw_ex_gate, enabled: true
