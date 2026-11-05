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

  test "ROUNDTRIP ARM: BLOCKED-HONEST (L3 server role not landed)" do
    # The server face is typed UNSUPPORTED in the wrapper; the court
    # asserts that law rather than faking a loopback pass.
    assert {:error, {:quic_refusal, {:unsupported, :server_role_not_in_nif_surface}}} =
             Quic.serve(0, [])

    IO.puts(
      "[BLOCKED-HONEST] roundtrip loopback (serve->accept->stream_open->send->recv->" <>
        "Frame re-parse byte-identity; ALPN-drop and wrong-CA mutations) requires the " <>
        "cgap server-role NIF surface - cited dependency: cgap lane L3, aq_quic.rs " <>
        "server job variants, not landed when this court ran."
    )
  end

  defp sha256(path) do
    {out, 0} = System.cmd("shasum", ["-a", "256", path])
    out |> String.split() |> hd()
  end

end
