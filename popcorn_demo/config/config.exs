import Config

# Popcorn packaging: entrypoint app = this app; crypto runtime variant is
# selected automatically because :crypto is an extra_application.
config :popcorn, app: :popcorn_demo

# The hex package ships only the core runtime; the crypto variant comes from
# the npm package. The slice uses no :crypto, so pin core explicitly.
config :popcorn, runtime_variant: :core
