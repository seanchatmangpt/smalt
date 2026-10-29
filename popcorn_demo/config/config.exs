import Config

# Popcorn packaging: entrypoint app = this app; crypto runtime variant is
# selected automatically because :crypto is an extra_application.
config :popcorn, app: :popcorn_demo

# The hex package ships only the core runtime; the crypto variant comes from
# the npm package. The slice uses no :crypto, so pin core explicitly.
config :popcorn, runtime_variant: :core

# Test-environment overrides (single-writer law for :reconcile_store in the
# test VM; see config/test.exs for the witnessed drift this closes).
if Mix.env() == :test do
  import_config "test.exs"
end
