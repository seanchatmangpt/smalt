defmodule Smalt.R32VerifyScratchTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.DataPlane.KeyVaultActions
  alias Smalt.EgressRouter
  alias Smalt.Store

  @opts EgressRouter.init([])

  setup do
    SmaltTest.Env.put_restored(auth_mode: :anonymous)
    SmaltTest.Store.resilient_setup()
    :ok
  end

  defp put_key(name, kty) do
    Store.put(:smalt_vault_keys, name, %{
      "kid" => "https://smalt.local:8443/keys/#{name}",
      "key" => %{"kid" => "https://smalt.local:8443/keys/#{name}", "kty" => kty},
      "attributes" => %{"enabled" => true, "created" => 0},
      "release_policy" => nil
    })
  end

  defp b64u(bin), do: Base.url_encode64(bin, padding: false)

  defp keyv(post_path, body) do
    conn(:post, post_path, body)
    |> put_req_header("authorization", "Bearer scratch-token")
    |> EgressRouter.call(@opts)
  end

  test "1. oversize RSA encrypt -> 400 InvalidValue envelope, not 500" do
    put_key("r32-big", "RSA-HSM")
    big = :crypto.strong_rand_bytes(300)

    assert {:error, 400, %{"error" => %{"code" => "InvalidValue"}}} =
             KeyVaultActions.encrypt(
               "r32-big",
               %{"value" => b64u(big), "alg" => "RSA-OAEP-256"},
               nil
             )
  end

  test "1b. normal-size RSA encrypt/decrypt still round-trips" do
    put_key("r32-ok", "RSA-HSM")
    plain = :crypto.strong_rand_bytes(100)

    assert {:ok, 200, %{"value" => ct}} =
             KeyVaultActions.encrypt(
               "r32-ok",
               %{"value" => b64u(plain), "alg" => "RSA-OAEP-256"},
               nil
             )

    assert {:ok, 200, %{"value" => pt}} =
             KeyVaultActions.decrypt("r32-ok", %{"value" => ct, "alg" => "RSA-OAEP-256"}, nil)

    assert pt == b64u(plain)
  end

  test "2. decrypt accepts all 4 b64 forms of the same ciphertext" do
    put_key("r32-b64", "RSA-HSM")
    plain = :crypto.strong_rand_bytes(24)

    {:ok, 200, %{"value" => ct}} =
      KeyVaultActions.encrypt("r32-b64", %{"value" => b64u(plain), "alg" => "RSA-OAEP-256"}, nil)

    raw = Base.url_decode64!(ct, padding: false)

    forms = [
      Base.url_encode64(raw, padding: false),
      Base.url_encode64(raw, padding: true),
      Base.encode64(raw, padding: false),
      Base.encode64(raw, padding: true)
    ]

    for form <- forms do
      assert {:ok, 200, %{"value" => pt}} =
               KeyVaultActions.decrypt(
                 "r32-b64",
                 %{"value" => form, "alg" => "RSA-OAEP-256"},
                 nil
               )

      assert pt == b64u(plain)
    end
  end

  test "3. distinct oct keys project distinct JWK k values" do
    c1 = keyv("/keys/r32-oct-a/create", %{"kty" => "oct"})
    c2 = keyv("/keys/r32-oct-b/create", %{"kty" => "oct"})
    assert c1.status == 200 and c2.status == 200

    k1 = Jason.decode!(c1.resp_body)["key"]["k"]
    k2 = Jason.decode!(c2.resp_body)["key"]["k"]

    assert is_binary(k1) and is_binary(k2)
    assert k1 != k2

    assert k1 ==
             Base.url_encode64(Smalt.DataPlane.KeyVaultActions.derive_oct_key("r32-oct-a"),
               padding: false
             )
  end

  test "4. create JWK body carries kty + key_ops; policy intersects key_ops" do
    c = keyv("/keys/r32-rsa/create", %{"kty" => "RSA-HSM"})
    assert c.status == 200
    body = Jason.decode!(c.resp_body)["key"]
    assert body["kty"] == "RSA-HSM"
    assert body["key_ops"] == ["encrypt", "decrypt", "sign", "verify", "wrapKey", "unwrapKey"]

    cp =
      keyv("/keys/r32-rsa-p/create", %{
        "kty" => "oct",
        "release_policy" => %{"allowed_operations" => ["encrypt", "verify"]}
      })

    assert cp.status == 200
    body_p = Jason.decode!(cp.resp_body)["key"]
    assert body_p["key_ops"] == ["encrypt"]
  end
end
