defmodule Smalt.Security.Lens6CrashClassTest do
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.SKR
  alias Smalt.Security.ReceiptSigner
  alias Smalt.Store

  @compliance "azure-compliant-cvm"

  # lens-6 cycle-4 court: total-function sweep round 2. A structurally valid
  # RSA recipient JWK with an unusable key (1-byte modulus, degenerate e)
  # raised out of :public_key.encrypt_public, escaping the SKR release
  # boundary. The guard converts it to the same typed 400 InvalidParameter
  # envelope as a malformed JWK. Courts pin: typed refusal, no state burn,
  # release path still usable after the refusal.
  describe "lens-6 SKR wrap crash-class: hostile recipient JWK refuses typed" do
    test "degenerate RSA modulus -> typed 400, no state burn, path usable" do
      Store.put(:smalt_vault_keys, "l6-wrap", %{
        "kid" => "k-l6",
        "release_policy" => %{"authority" => "smalt-test"}
      })

      jti = "l6-jti-a-#{System.unique_integer([:positive])}"

      hostile_token =
        ReceiptSigner.sign(%{
          "x-ms-compliance-status" => @compliance,
          "x-ms-runtime" => %{"jti" => jti},
          "skr_recipient_jwk" => %{"kty" => "RSA", "n" => "AQ", "e" => "AQAB"},
          "iat" => 1_000_000_000,
          "exp" => 2_000_000_000
        })

      assert {:error, 400, %{"error" => %{"code" => "InvalidParameter"}}} =
               release("l6-wrap", hostile_token)

      # Conservation: the failed wrap burns neither jti nor keyMaterialVersion.
      assert :error = Store.get(:smalt_vault_keys, "skr-version:l6-wrap")
      assert :error = Store.get(:smalt_attestation_baseline, "skr-jti:" <> jti)

      # Release path still usable after the refusal.
      good_token = ReceiptSigner.sign(good_claims("l6-jti-ok"))
      assert {:ok, 200, %{"status" => "Released"}} = release("l6-wrap", good_token)
    end

    test "degenerate exponent e=1 -> typed 400" do
      Store.put(:smalt_vault_keys, "l6-wrap2", %{
        "kid" => "k-l6b",
        "release_policy" => %{"authority" => "smalt-test"}
      })

      hostile_token =
        ReceiptSigner.sign(%{
          "x-ms-compliance-status" => @compliance,
          "x-ms-runtime" => %{"jti" => "l6-jti-b"},
          "skr_recipient_jwk" => %{"kty" => "RSA", "n" => "AQAB", "e" => "AQ"},
          "iat" => 1_000_000_000,
          "exp" => 2_000_000_000
        })

      assert {:error, 400, %{"error" => %{"code" => "InvalidParameter"}}} =
               release("l6-wrap2", hostile_token)

      assert :error = Store.get(:smalt_vault_keys, "skr-version:l6-wrap2")
    end
  end

  defp release(name, token) do
    conn =
      :post
      |> Plug.Test.conn("/keys/#{name}/release")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)

    SKR.release(name, conn)
  end

  defp good_claims(jti) do
    now = System.system_time(:second)

    %{
      "x-ms-compliance-status" => @compliance,
      "x-ms-runtime" => %{"jti" => jti},
      "iat" => now,
      "exp" => now + 7200
    }
  end
end