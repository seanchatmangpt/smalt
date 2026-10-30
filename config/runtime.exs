import Config

# Runtime plane selection (AZB-04). Evaluated by releases AND `mix run`/`mix
# test` (Mix evaluates runtime.exs during app.start, post-compile — so
# Smalt.Planes is available here, unlike config/config.exs which is evaluated
# pre-compile).

planes = Smalt.Planes.resolve()

config :smalt, :planes, planes

# Each config/env/az_prod_<plane>.exs is imported ONLY when its plane is
# explicitly selected. `:all` (the default) imports NOTHING — default boot
# stays byte-identical to pre-AZB-04 (AZB-04 falsifier).
#
# import_config/1 is not enabled in runtime.exs, so the profiles are read via
# Config.Reader and merged with config/2 (same semantics: keyword merge into
# :smalt).
case planes do
  :all ->
    :ok

  planes when is_list(planes) ->
    Enum.each(planes, fn plane ->
      path = Path.join(__DIR__, "env/az_prod_#{plane}.exs")

      for {app, kw} <- Config.Reader.read!(path, env: config_env()) do
        config(app, kw)
      end
    end)
end

# KIND-E2E unblock (2026-10-30, lane verification fix, disclosed): the plane
# supervisors read the APP env :bind_all_interfaces (default false -> loopback
# bind) but nothing mapped the SMALT_BIND_ALL_INTERFACES env contract to it —
# in kind the ARM front door (9443) bound 127.0.0.1, kubelet probes failed,
# and the pod SIGTERMed ~31s after a clean boot (witnessed smalt-backend-0).
# Runtime mapping: env set -> flag on; unset -> nil (default boot unchanged).
if System.get_env("SMALT_BIND_ALL_INTERFACES") in ["1", "true"] do
  config :smalt, :bind_all_interfaces, true
end
