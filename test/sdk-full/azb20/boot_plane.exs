# AZB-20 per-plane substrate boot (AZB-20, lane interop).
#
# Mirrors config/runtime.exs semantics exactly (Config.Reader.read!/2 of the
# selected planes' az_prod_<plane>.exs profiles), then applies private-port
# overrides AFTER the profile import so the port single-source flat keys land
# on this lane's private block instead of the canonical ports (another lane's
# substrate holds 9443/9444/8443/5672/5673; never evict another lane).
#
# Run: AZB20_PLANES=control mix run --no-start --no-halt test/sdk-full/azb20/boot_plane.exs

planes_env = System.get_env("AZB20_PLANES", "all")

planes =
  if planes_env == "all" do
    :all
  else
    Enum.map(String.split(planes_env, ",", trim: true), &String.to_atom/1)
  end

Application.put_env(:smalt, :planes, planes) # isolation-court: exempt azb20_boot_script

if planes != :all do
  Enum.each(planes, fn plane ->
    path = Path.join(File.cwd!(), "config/env/az_prod_#{plane}.exs")

    for {app, kw} <- Config.Reader.read!(path, env: :test),
        {k, v} <- kw do
      Application.put_env(app, k, v)
    end
  end)
end

# Private port block (checked free before boot by run.mjs). Applied after the
# profile import so these win over any flat port key a profile pins.
for {k, v} <- [
      arm_port: 39443,
      arm_tls_port: 39444,
      egress_port: 39445,
      amqp_port: 39472,
      event_hubs_port: 39473,
      mcp_port: 39475
    ] do
  Application.put_env(:smalt, k, v)
end

Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:39472") # isolation-court: exempt azb20_boot_script

# Shared SAS key so EXTERNAL-attach probes compute matching SAS signatures.
Application.put_env(:smalt, :sb_shared_key, System.get_env("AZB20_SB_KEY")) # isolation-court: exempt azb20_boot_script

Application.put_env(:smalt, :auth_mode, :enforce) # isolation-court: exempt azb20_boot_script

{:ok, _} = Application.ensure_all_started(:smalt)

IO.puts("AZB20_BOOT_OK planes=#{inspect(planes)}")

Process.sleep(:infinity)
