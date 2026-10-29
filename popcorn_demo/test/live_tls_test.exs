defmodule PopcornDemo.LiveTlsTest do
  use ExUnit.Case, async: false

  # Chicago-school TLS leg over the REAL smalt substrate TLS twin (9444).
  # No mocks: `run/0` performs a real :ssl peer-verified handshake against
  # the substrate CA and walks the real auth path. A down substrate surfaces
  # as a loud tls=SKIP; a wrong CA surfaces as a typed tls=FAIL — never a
  # fake pass or a verify_none connection.
  alias PopcornDemo.LiveTls

  @ca "/Users/sac/smalt/.smalt/tls/ca-cert.pem"

  # A genuinely unrelated trust anchor: OTP ssl treats an exact-match
  # non-self-signed trust anchor as valid, so the substrate's own leaf
  # (dev-cert.pem) does NOT produce a failure — the negative leg needs a
  # different CA entirely.
  @tmp_dir System.tmp_dir!() |> Path.join("popcorn-live-tls-#{:os.system_time(:millisecond)}")
  @wrong_ca Path.join(@tmp_dir, "wrong-ca.pem")

  setup do
    unless File.regular?(@ca) do
      flunk("SKIP(live-tls): substrate CA missing at " <> @ca)
    end

    on_exit(fn -> File.rm_rf(@tmp_dir) end)
    :ok
  end

  describe "run/0 TLS walk over live substrate twin" do
    @tag :tls_leg
    test "returns OK with n >= 0 subscriptions over a peer-verified TLS walk" do
      clear_ca_env()
      assert {:ok, "https-twin,endpoints,tenants,sts,subscriptions=" <> n} = LiveTls.run()
      assert String.to_integer(n) >= 0
    end
  end

  describe "negative: wrong CA is a typed FAIL, not a silent pass" do
    @tag :tls_leg
    test "unrelated CA fails the handshake with a TLS alert" do
      {:ok, _} = make_wrong_ca()

      set_ca_env(@wrong_ca)
      result = LiveTls.run()
      assert {:fail, "tls:" <> detail} = result
      assert detail =~ ~r/tls_alert|unknown_ca|bad_certificate|certificate/i
    end
  end

  describe "format/1 receipt fragments" do
    test "tls=OK carries the walk detail" do
      assert "tls=OK(https-twin,endpoints,tenants,sts,subscriptions=3)" =
               LiveTls.format({:ok, "https-twin,endpoints,tenants,sts,subscriptions=3"})
    end

    test "tls=SKIP(ca-missing) is loud" do
      assert "tls=SKIP(ca-missing:/nope/ca.pem)" =
               LiveTls.format({:skip, {:ca_missing, "/nope/ca.pem"}})
    end

    test "tls=FAIL carries the alert detail" do
      assert "tls=FAIL(tls:boom)" = LiveTls.format({:fail, "tls:boom"})
    end
  end

  # -- Real collaborators ----------------------------------------------------

  # A real, structurally-valid CA that simply is not the substrate CA —
  # minted with the host openssl (the same toolchain gen_dev_cert.sh uses),
  # never a fake PEM blob. A structurally invalid CA would be a vacuous
  # negative (OTP would just ignore it).
  defp make_wrong_ca do
    File.mkdir_p!(@tmp_dir)

    case System.cmd("openssl", [
           "req",
           "-x509",
           "-newkey",
           "rsa:2048",
           "-keyout",
           Path.join(@tmp_dir, "wrong-key.pem"),
           "-out",
           @wrong_ca,
           "-days",
           "2",
           "-nodes",
           "-subj",
           "/CN=popcorn-wrong-ca"
         ]) do
      {_, 0} ->
        {:ok, @wrong_ca}

      {out, code} ->
        flunk("SKIP(live-tls): could not mint wrong CA (openssl exit #{code}): #{out}")
    end
  end

  defp clear_ca_env do
    System.delete_env("SMALT_TLS_CA")
    System.delete_env("SSL_CERT_FILE")
  end

  defp set_ca_env(path) do
    System.put_env("SMALT_TLS_CA", path)
    System.delete_env("SSL_CERT_FILE")
  end
end
