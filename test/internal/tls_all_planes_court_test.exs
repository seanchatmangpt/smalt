# P14 TLS-everywhere court (item 8, smalt side).
#
# Real Azure is https-only on every plane; today only the 9444 twin speaks TLS
# by default. SMALT_TLS_ALL_PLANES=1 mounts an ADDITIVE https listener on the
# data-plane surface (TlsTwinDispatch plug, :egress_tls_port default 8445)
# alongside plaintext 8443. This court pins:
#
#   1. default OFF — flag unset and app env nil => no extra listener, boot
#      byte-for-byte unchanged (all_planes?/0 false, child list []).
#   2. on-state — flag on => gate true and the same bandit_opts/2 resolution
#      path the 9444 twin rides produces a real :https listener spec (port,
#      certfile/keyfile pair on disk, 1.3+1.2 version pin) — asserted against
#      the actual generated dev cert, not a mock.
#
# Chicago discipline: real cert files, real :ssl parse, no mocks, no sleeps.
defmodule Smalt.Test.Internal.TlsAllPlanesCourtTest do
  use ExUnit.Case, async: false

  test "default OFF: flag unset + app env nil => gate false, no extra listener" do
    prior_env = System.get_env("SMALT_TLS_ALL_PLANES")
    prior_env_tls = System.get_env("SMALT_TLS_ECDSA")
    System.delete_env("SMALT_TLS_ALL_PLANES")
    prior = Application.get_env(:smalt, :tls_all_planes)

    on_exit(fn ->
      if prior_env, do: System.put_env("SMALT_TLS_ALL_PLANES", prior_env)
      if prior_env_tls, do: System.put_env("SMALT_TLS_ECDSA", prior_env_tls)
    end)

    assert prior in [nil, false]
    assert Smalt.TLS.all_planes?() == false

    # The default egress https port is the documented 8445 adjacency (pinned
    # with the key absent; config/test.exs installs a probed-free port).
    prior_port = Application.get_env(:smalt, :egress_tls_port)
    Application.delete_env(:smalt, :egress_tls_port)
    assert Smalt.TLS.egress_tls_port() == 8445
    Application.put_env(:smalt, :egress_tls_port, prior_port)
  after
    Application.delete_env(:smalt, :tls_all_planes)
    System.delete_env("SMALT_TLS_ALL_PLANES")
  end

  test "on-state: gate true and bandit_opts yields a real :https listener spec" do
    prior_env = System.get_env("SMALT_TLS_ALL_PLANES")

    on_exit(fn ->
      if prior_env, do: System.put_env("SMALT_TLS_ALL_PLANES", prior_env)
    end)

    System.delete_env("SMALT_TLS_ALL_PLANES")
    System.put_env("SMALT_TLS_ECDSA", "0")
    Application.put_env(:smalt, :tls_all_planes, true)
    port = Smalt.TLS.egress_tls_port()

    assert Smalt.TLS.all_planes?() == true

    # Same resolution path the 9444 twin rides (bandit_opts/2): the generated
    # dev cert must really exist and parse as a Certificate alongside its key.
    opts = Smalt.TLS.bandit_opts(Smalt.Application.TlsTwinDispatch, port)

    assert opts[:scheme] == :https
    assert opts[:port] == port
    assert opts[:plug] == Smalt.Application.TlsTwinDispatch
    assert opts[:certfile] != nil and opts[:keyfile] != nil

    assert File.regular?(List.to_string(opts[:certfile]))
    assert File.regular?(List.to_string(opts[:keyfile]))

    # The cert material parses as a real X.509 certificate.
    {:ok, pem} = File.read(List.to_string(opts[:certfile]))
    assert [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
    assert match?({:OTPCertificate, _, _, _}, :public_key.pkix_decode_cert(der, :otp))

    # Version pin rides the shared transport_tls_opts seam (1.3 + 1.2 default).
    tls_opts = opts[:thousand_island_options][:transport_options]
    assert :"tlsv1.3" in tls_opts[:versions] and :"tlsv1.2" in tls_opts[:versions]

    # h2 reset-rate parity rides every listener (KD-157).
    assert opts[:http_2_options][:max_reset_stream_rate] == {50_000, 10_000}
  after
    Application.delete_env(:smalt, :tls_all_planes)
    System.delete_env("SMALT_TLS_ALL_PLANES")
    System.delete_env("SMALT_TLS_ECDSA")
  end

  defp test_egress_tls_port do
    case :gen_tcp.listen(0, [:binary, active: false]) do
      {:ok, sock} ->
        {:ok, port} = :inet.port(sock)
        :gen_tcp.close(sock)
        port

      _ ->
        8445
    end
  end
end
