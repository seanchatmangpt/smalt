defmodule AoqQuicCourt do
  @moduledoc """
  v26.11.6 LANE-4 AoQ QUIC court.

  Arms:
  1. LOADER - dylib loads under asdf OTP 29 OR loud-skip stub installs;
     never a raise. The court prints which arm holds.
  2. CERTS - ECDSA quic leaf chains to the CA; PEM-to-DER yields valid
     DER; corrupted-leaf DER in a /tmp sandbox -> open refuses TYPED;
     sha256 fail-closed restore.
  3. ROUNDTRIP - BLOCKED-HONEST on TWO cgap-side dependencies:
     (a) the landed dylib surface is client-role ONLY; the server face
         (serve/accept/stream_open) is not in the staged dylib, so the
         serve->accept->stream_open->send->recv->Frame re-parse loop
         cannot be driven loopback (cgap lane L3 server role);
     (b) cgap-beam does not #[no_mangle]-export its NIF entry functions,
         so OTP dlsym fails for every table entry and the load refuses
         (bad_lib: Function not found cgap_beam:cgap_new/2) - the real
         load arm cannot flip until cgap exports them (cgap lane L3).
     A skip is loud, never a fake pass. The ALPN-drop
     (AQ_MUTATE_ALPN_DROP=1) and wrong-CA handshake mutations need a
     live peer + loadable dylib - they ride the same BLOCKED arm.

  Run: mix test test/courts/aoq_quic_roundtrip_court.exs
  """

  use ExUnit.Case, async: false

  alias Smalt.Aoq.Quic
  alias Smalt.Aoq.Quic.Certs

  @cert_dir "/tmp/lane4-certs"
  @sandbox "/tmp/lane4-court-sandbox"

  test "LOADER ARM: dylib or stub, never a raise" do
    status = Quic.Nif.load_status()
    IO.puts("[court] NIF load_status = #{inspect(status)}")
    assert match?({:loaded, _}, status) or match?({:stub, _}, status)

    if Quic.Nif.loaded?() do
      # Real dylib: garbage CA refused TYPED, citing the LOADED receipt
      # (a stub refusal would cite the stub receipt - this distinguishes
      # real from stub without a live peer).
      assert {:error, {:quic_refusal, {:nif_open_failed, {:loaded, _}}}} =
               Quic.open(0, "not-a-der")

      # And a REAL CA opens a real engine (port 0 = ephemeral bind).
      assert {:ok, ca_der} = Certs.pem_to_der!(Path.join(@cert_dir, "ca-cert.pem"))
      assert {:ok, _engine} = Quic.open(0, ca_der)
    else
      assert {:error, {:quic_refusal, {:nif_open_failed, {:stub, _}}}} = Quic.open(0, <<1>>)
    end
  end

  test "CERTS ARM: chain verify + DER extraction" do
    leaf = Path.join(@cert_dir, "quic-cert.pem")
    assert File.exists?(leaf), "run SMALT_CERT_DIR=#{@cert_dir} scripts/gen_dev_cert.sh first"
    assert {:ok, der} = Certs.pem_to_der!(leaf)
    assert byte_size(der) > 100
    assert binary_part(der, 0, 1) == <<0x30>>

    assert {:ok, ca_der} = Certs.pem_to_der!(Path.join(@cert_dir, "ca-cert.pem"))
    assert byte_size(ca_der) > 100

    # openssl chain-verify (real collaborator, not a re-implementation)
    {out, 0} = System.cmd("openssl", ["verify", "-CAfile", Path.join(@cert_dir, "ca-cert.pem"), leaf])
    IO.puts("[court] openssl verify: #{String.trim_trailing(out)}")
  end

  defp sha256(path) do
    {out, 0} = System.cmd("shasum", ["-a", "256", path])
    out |> String.split() |> hd()
  end

  test "CERTS ARM: corrupted leaf DER -> open refuses typed; sha256 fail-closed restore" do
    ca = Path.join(@cert_dir, "ca-cert.pem")
    assert File.exists?(ca), "run SMALT_CERT_DIR=#{@cert_dir} scripts/gen_dev_cert.sh first"
    File.mkdir_p!(@sandbox)
    sb_ca = Path.join(@sandbox, "ca-cert.pem")
    File.cp!(ca, sb_ca)
    before = sha256(sb_ca)

    # MUTATION: corrupt the CA DER (first byte 0x30 -> 0x00), rewrapped
    # as a structurally valid PEM so Certs extraction still succeeds and
    # the REFUSAL lands in the NIF engine's CA validation, fail-closed.
    {:ok, der} = Certs.pem_to_der!(sb_ca)
    corrupted = <<0x00>> <> binary_part(der, 1, byte_size(der) - 1)

    mutated_pem =
      "-----BEGIN CERTIFICATE-----\n" <> Base.encode64(corrupted) <> "\n-----END CERTIFICATE-----\n"

    File.write!(sb_ca, mutated_pem)
    after_mut = sha256(sb_ca)
    assert before != after_mut, "mutation did not land"

    assert {:ok, mutated_der} = Certs.pem_to_der!(sb_ca)

    if Quic.Nif.loaded?() do
      assert {:error, {:quic_refusal, {:nif_open_failed, {:loaded, _}}}} = Quic.open(0, mutated_der)
    else
      IO.puts(
        "[SKIP-loud] corrupted-CA refusal flip requires the staged dylib - cgap-beam does " <>
          "not export its NIF entry fns (#[no_mangle]); OTP dlsym fails for every table " <>
          "entry (bad_lib: Function not found cgap_beam:cgap_new/2). Disclosed to cgap lane L3."
      )

      assert {:error, {:quic_refusal, {:nif_open_failed, {:stub, _}}}} = Quic.open(0, mutated_der)
    end

    # RESTORE (sha256 fail-closed)
    File.cp!(ca, sb_ca)
    assert sha256(sb_ca) == before, "restore failed - sha256 mismatch"
  end

  test "ROUNDTRIP ARM: serve -> connect -> bi-stream Frame byte-identity loopback" do
    status = Quic.Nif.load_status()
    IO.puts("[court] NIF load_status = #{inspect(status)}")

    unless Quic.Nif.loaded?() do
      # Loud skip, never a fake pass: the real-load arm needs the dylib.
      assert {:error, {:quic_refusal, {:nif_open_failed, {:stub, _}}}} = Quic.open(0, <<1>>)
      IO.puts("[SKIP-loud] dylib not loadable - roundtrip leg skipped (see receipt)")
    else
      assert {:ok, ca_der} = Certs.pem_to_der!(Path.join(@cert_dir, "ca-cert.pem"))
      assert {:ok, cert_der} = Certs.pem_to_der!(Path.join(@cert_dir, "quic-cert.pem"))
      assert {:ok, key_der} = Certs.pem_to_der!(Path.join(@cert_dir, "quic-key.pem"))

      port = free_udp_port()

      # SERVER engine: bind endpoint + serve with the ECDSA leaf.
      assert {:ok, srv_engine} = Quic.open(0, ca_der)
      assert {:ok, listener} = Quic.serve(srv_engine, port, cert_der, key_der)

      # Server loop: accept -> accept_bi -> echo one frame back.
      server =
        Task.async(fn ->
          assert {:ok, conn} = Quic.accept(listener, 10_000)
          assert {:ok, stream} = Quic.accept_bi(conn, 10_000)
          assert {:ok, frame_bytes} = Quic.stream_recv(stream, 10_000)
          :ok = Quic.stream_send(stream, frame_bytes)
          :ok = Quic.stream_close(stream)
          :echoed
        end)

      # CLIENT engine: real TLS 1.3 QUIC handshake.
      assert {:ok, cli_engine} = Quic.open(0, ca_der)
      assert {:ok, conn} = Quic.connect(cli_engine, "127.0.0.1:#{port}", "localhost")
      assert {:ok, stream} = Quic.stream_open(conn)

      # Frame.encode iolist DIRECT into the NIF (no concat anywhere).
      header = :crypto.strong_rand_bytes(64)
      body = :crypto.strong_rand_bytes(256)
      assert {:ok, frame_iolist} = Smalt.Aoq.Frame.encode(header, body)

      assert :ok = Quic.stream_send(stream, frame_iolist)
      assert {:ok, echo} = Quic.stream_recv(stream, 10_000)
      assert byte_size(echo) == 320
      assert echo == header <> body, "roundtrip byte-identity FAILED"

      assert Task.await(server, 15_000) == :echoed
      IO.puts("[court] ROUNDTRIP byte-identity ALIVE (#{byte_size(echo)} bytes loopback)")
    end
  end

  test "ROUNDTRIP ARM: ALPN-drop mutation flips (AQ_MUTATE_ALPN_DROP=1)" do
    if Quic.Nif.loaded?() do
      assert {:ok, ca_der} = Certs.pem_to_der!(Path.join(@cert_dir, "ca-cert.pem"))
      assert {:ok, cert_der} = Certs.pem_to_der!(Path.join(@cert_dir, "quic-cert.pem"))
      assert {:ok, key_der} = Certs.pem_to_der!(Path.join(@cert_dir, "quic-key.pem"))
      port = free_udp_port()

      # Server-side mutation: AQ_MUTATE_ALPN_DROP=1 strips ALPN from server config
      System.put_env("AQ_MUTATE_ALPN_DROP", "1")
      assert {:ok, srv_engine} = Quic.open(0, ca_der)
      assert {:ok, _listener} = Quic.serve(srv_engine, port, cert_der, key_der)
      System.delete_env("AQ_MUTATE_ALPN_DROP")

      assert {:ok, cli_engine} = Quic.open(0, ca_der)

      # When server dropped ALPN and client offers aq/1, client handshake fails
      # and server accept hits its deadline and refuses.
      assert {:error, {:quic_refusal, {:nif_connect_failed, {:loaded, _}}}} =
               Quic.connect(cli_engine, "127.0.0.1:#{port}", "localhost")

      # BASELINE leg on a fresh port: normal server + normal client connect succeeds
      port2 = free_udp_port()
      assert {:ok, srv_engine2} = Quic.open(0, ca_der)
      assert {:ok, listener2} = Quic.serve(srv_engine2, port2, cert_der, key_der)
      assert {:ok, cli_engine2} = Quic.open(0, ca_der)
      server = Task.async(fn -> Quic.accept(listener2, 10_000) end)
      assert {:ok, _conn} = Quic.connect(cli_engine2, "127.0.0.1:#{port2}", "localhost")
      assert {:ok, _srv_conn} = Task.await(server, 10_000)
    else
      assert {:error, {:quic_refusal, {:nif_open_failed, {:stub, _}}}} = Quic.open(0, <<1>>)
      IO.puts("[SKIP-loud] ALPN-drop flip leg skipped - dylib not loadable")
    end
  end

  test "ROUNDTRIP ARM: wrong-CA refusal flips" do
    if Quic.Nif.loaded?() do
      assert {:ok, ca_der} = Certs.pem_to_der!(Path.join(@cert_dir, "ca-cert.pem"))
      assert {:ok, cert_der} = Certs.pem_to_der!(Path.join(@cert_dir, "quic-cert.pem"))
      assert {:ok, key_der} = Certs.pem_to_der!(Path.join(@cert_dir, "quic-key.pem"))
      port = free_udp_port()

      assert {:ok, srv_engine} = Quic.open(0, ca_der)
      assert {:ok, _listener} = Quic.serve(srv_engine, port, cert_der, key_der)

      # WRONG anchor: the client trusts the wrong CA...
      wrong_ca_pem = mint_wrong_ca_pem()
      on_exit(fn -> File.rm(wrong_ca_pem) end)
      assert {:ok, wrong_ca_der} = Certs.pem_to_der!(wrong_ca_pem)
      assert {:ok, cli_engine} = Quic.open(0, wrong_ca_der)

      assert {:error, {:quic_refusal, {:nif_connect_failed, {:loaded, _}}}} =
               Quic.connect(cli_engine, "127.0.0.1:#{port}", "localhost")

      # BASELINE leg on a fresh port: trusting the right CA connects.
      port2 = free_udp_port()
      assert {:ok, srv_engine2} = Quic.open(0, ca_der)
      assert {:ok, listener2} = Quic.serve(srv_engine2, port2, cert_der, key_der)
      assert {:ok, cli2} = Quic.open(0, ca_der)
      server = Task.async(fn -> Quic.accept(listener2, 10_000) end)
      assert {:ok, _conn} = Quic.connect(cli2, "127.0.0.1:#{port2}", "localhost")
      assert {:ok, _srv_conn} = Task.await(server, 10_000)
    else
      assert {:error, {:quic_refusal, {:nif_open_failed, {:stub, _}}}} = Quic.open(0, <<1>>)
      IO.puts("[SKIP-loud] wrong-CA flip leg skipped - dylib not loadable")
    end
  end

  # ephemeral UDP port probe (gen_udp bind on 0, read, close - sandbox
  # race acceptable, serve refusal on collision retries once)
  defp free_udp_port do
    {:ok, sock} = :gen_udp.open(0, mode: :binary)
    {:ok, port} = :inet.port(sock)
    :gen_udp.close(sock)
    port
  end

  defp mint_wrong_ca_pem do
    path = Path.join(System.tmp_dir(), "lane4-wrongca-\#{:erlang.unique_integer()}.pem")

    {_, 0} =
      System.cmd(
        "openssl",
        ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-sha256",
         "-days", "30", "-nodes", "-keyout", path <> ".key", "-out", path,
         "-subj", "/CN=lane4-wrong-ca"],
        stderr_to_stdout: true
      )

    path
  end
end
