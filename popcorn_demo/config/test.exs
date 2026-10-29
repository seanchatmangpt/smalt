import Config

# LiveReconcileTest is the single writer to :reconcile_store and the
# live-reconcile-* wire docs in the test VM. The Application boot smoke
# runs every live leg (including LiveReconcile.run/0) concurrently with
# ExUnit — a second concurrent writer that produced witnessed drift
# (:converged / typed-conflict outcomes on equal-_v merges). Gate it off
# here; the same surface is exercised directly by the tests themselves.
config :popcorn_demo, :boot_smoke, false
