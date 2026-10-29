# KD-173R: closes KD-172 — the `sb:` audience wildcard at
# lib/smalt/messaging/amqp/sas_verifier.ex:192 accepted ANY `sb://<host>`
# audience with full namespace rights. The match is now host-scoped to the
# configured endpoint host (loopback endpoints additionally accept any
# loopback audience host, so real SDKs minting from a loopback
# connection-string namespace still verify).
#
# Court (Chicago: real SasVerifier, real HMAC sign+verify with the real
# runtime dev key, no mocks):
#   1. foreign sb:// host   -> typed 401 INVALID_LOCAL_SAS  (the KD-172 hole)
#   2. loopback sb:// audience -> {:ok, claims}             (real SDK shape)
#   3. foreign non-sb scheme  -> typed 401                 (existing control)
defmodule Smalt.Internal.KD173RAudienceScopeCourtTest do
  use ExUnit.Case, async: false

  alias Smalt.Amqp.SasVerifier

  @endpoint %SasVerifier.Audience{scheme: "sb", host: "127.0.0.1", port: 5672}

  setup do
    :persistent_term.erase({SasVerifier, :dev_key})
    :ok
  end

  defp mint(sr) do
    key = SasVerifier.shared_key()
    se = System.system_time(:second) + 3_600
    sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{sr}\n#{se}"))

    "SharedAccessSignature sr=#{sr}&sig=#{sig}&se=#{se}&skn=RootManageSharedAccessKey"
  end

  test "foreign sb:// audience host is refused with typed 401" do
    for sr <- ["sb://foreign-namespace.evil.example/path", "sb://attacker.example"] do
      assert {:error, {401, "INVALID_LOCAL_SAS"}} = SasVerifier.verify(mint(sr), @endpoint)
    end
  end

  test "legit loopback sb:// audiences still verify" do
    for sr <- [
          "sb://127.0.0.1:5672",
          "sb://127.0.0.1:5672/sbkey-floor-queue",
          "sb://localhost:5672/q",
          "sb://localhost/q"
        ] do
      assert {:ok, %{audience: ^sr}} = SasVerifier.verify(mint(sr), @endpoint)
    end
  end

  test "127.*-prefixed domains refuse typed 401 (BK-AMPSKEP F1 repair)" do
    for sr <- ["sb://127.evil.example", "sb://127.0.0.1.evil.example"] do
      assert {:error, {401, "INVALID_LOCAL_SAS"}} = SasVerifier.verify(mint(sr), @endpoint)
    end
  end

  test "127/8 dotted-quad literals beyond 127.0.0.1 still verify (loopback posture)" do
    sr = "sb://127.1.2.3:9999"
    assert {:ok, %{audience: ^sr}} = SasVerifier.verify(mint(sr), @endpoint)
  end

  test "endpoint-host-exact audience verifies against a binary endpoint config" do
    assert {:ok, %{audience: "sb://127.0.0.1:5672/q"}} =
             SasVerifier.verify(mint("sb://127.0.0.1:5672/q"), SasVerifier.endpoint())
  end

  test "foreign non-sb scheme remains refused (control, KD-172 witness row 4)" do
    sr = "amqps://127.0.0.1:5672"
    assert {:error, {401, "INVALID_LOCAL_SAS"}} = SasVerifier.verify(mint(sr), @endpoint)
  end
end
