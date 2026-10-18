defmodule Smalt.DataPlane.KeyVaultActionsTest do
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.KeyVaultActions
  alias Smalt.Store

  setup do
    # v26.10.18: canonical resilient shared-Store setup. The previous
    # lens-4 hand-roll (unlinked GenServer.start + clear) is retired into
    # SmaltTest.Store.resilient_clear/1 — same unlink-safety contract
    # (Lifecycle restores the SUPERVISED Store child, tables survive test
    # exits), one audited implementation for the dead-table retry window.
    :ok = SmaltTest.Store.resilient_clear()
    :ok
  end

  defp put_key(name, kty \\ "RSA-HSM", policy \\ nil) do
    record = %{
      "kid" => "https://smalt.local:8443/keys/#{name}",
      "key" => %{"kid" => "https://smalt.local:8443/keys/#{name}", "kty" => kty},
      "attributes" => %{"enabled" => true, "created" => 0},
      "release_policy" => policy
    }

    Store.put(:smalt_vault_keys, name, record)
    name
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
  defp b64_decode!(s), do: Base.url_decode64!(s, padding: false)

  defp assert_op_not_allowed({:error, 403, %{"error" => %{"code" => "OperationNotAllowed"}}}),
    do: :ok

  # ---------------------------------------------------------------------------
  # RSA-OAEP-256 encrypt / decrypt
  # ---------------------------------------------------------------------------

  describe "encrypt/decrypt RSA-OAEP-256" do
    test "round-trip" do
      put_key("rsa-enc")
      plain = :crypto.strong_rand_bytes(32)

      assert {:ok, 200, %{"value" => ct, "kid" => kid}} =
               KeyVaultActions.encrypt("rsa-enc", %{
                 "alg" => "RSA-OAEP-256",
                 "value" => b64(plain)
               })

      assert is_binary(ct)
      assert kid == "https://smalt.local:8443/keys/rsa-enc"

      assert {:ok, 200, %{"value" => pt}} =
               KeyVaultActions.decrypt("rsa-enc", %{"alg" => "RSA-OAEP-256", "value" => ct})

      assert b64_decode!(pt) == plain
    end

    test "same plaintext twice -> different ciphertexts, both decrypt" do
      put_key("rsa-rand")
      plain = :crypto.strong_rand_bytes(16)

      {:ok, 200, %{"value" => ct1}} =
        KeyVaultActions.encrypt("rsa-rand", %{"alg" => "RSA-OAEP-256", "value" => b64(plain)})

      {:ok, 200, %{"value" => ct2}} =
        KeyVaultActions.encrypt("rsa-rand", %{"alg" => "RSA-OAEP-256", "value" => b64(plain)})

      refute ct1 == ct2

      assert {:ok, 200, %{"value" => p1}} =
               KeyVaultActions.decrypt("rsa-rand", %{"alg" => "RSA-OAEP-256", "value" => ct1})

      assert {:ok, 200, %{"value" => p2}} =
               KeyVaultActions.decrypt("rsa-rand", %{"alg" => "RSA-OAEP-256", "value" => ct2})

      assert b64_decode!(p1) == plain
      assert b64_decode!(p2) == plain
    end

    test "keypair is deterministic per key name: cached in the Store row" do
      put_key("rsa-cache")
      plain = "same bytes"

      {:ok, 200, %{"value" => ct}} =
        KeyVaultActions.encrypt("rsa-cache", %{"alg" => "RSA-OAEP-256", "value" => b64(plain)})

      assert {:ok, record} = Store.get(:smalt_vault_keys, "rsa-cache")
      der = record["key_material"]
      assert is_binary(der)

      # A second process (or call) reuses the cached material: ciphertext
      # produced before still decrypts with the same key.
      assert {:ok, 200, %{"value" => pt}} =
               KeyVaultActions.decrypt("rsa-cache", %{"alg" => "RSA-OAEP-256", "value" => ct})

      assert b64_decode!(pt) == plain
      assert {:ok, same_record} = Store.get(:smalt_vault_keys, "rsa-cache")
      assert same_record["key_material"] == der
    end

    test "wrong-key ciphertext fails decrypt with 400" do
      put_key("rsa-a")
      put_key("rsa-b")

      {:ok, 200, %{"value" => ct}} =
        KeyVaultActions.encrypt("rsa-b", %{"alg" => "RSA-OAEP-256", "value" => b64("secret")})

      assert {:error, 400, %{"error" => %{"code" => "InvalidValue"}}} =
               KeyVaultActions.decrypt("rsa-a", %{"alg" => "RSA-OAEP-256", "value" => ct})
    end
  end

  # ---------------------------------------------------------------------------
  # A256GCM encrypt / decrypt (oct keys)
  # ---------------------------------------------------------------------------

  describe "encrypt/decrypt A256GCM (oct)" do
    test "round-trip" do
      put_key("oct-enc", "oct")
      plain = :crypto.strong_rand_bytes(48)

      assert {:ok, 200, %{"value" => ct, "iv" => iv, "tag" => tag}} =
               KeyVaultActions.encrypt("oct-enc", %{"alg" => "A256GCM", "value" => b64(plain)})

      assert {:ok, 200, %{"value" => pt}} =
               KeyVaultActions.decrypt("oct-enc", %{
                 "alg" => "A256GCM",
                 "value" => ct,
                 "iv" => iv,
                 "tag" => tag
               })

      assert b64_decode!(pt) == plain
    end

    test "same plaintext twice -> different ciphertexts, both decrypt" do
      put_key("oct-rand", "oct")
      plain = :crypto.strong_rand_bytes(24)

      {:ok, 200, e1} =
        KeyVaultActions.encrypt("oct-rand", %{"alg" => "A256GCM", "value" => b64(plain)})

      {:ok, 200, e2} =
        KeyVaultActions.encrypt("oct-rand", %{"alg" => "A256GCM", "value" => b64(plain)})

      refute e1["value"] == e2["value"]

      for env <- [e1, e2] do
        assert {:ok, 200, %{"value" => pt}} =
                 KeyVaultActions.decrypt("oct-rand", Map.merge(%{"alg" => "A256GCM"}, env))

        assert b64_decode!(pt) == plain
      end
    end

    test "tampered tag fails decrypt with 400" do
      put_key("oct-tamper", "oct")

      {:ok, 200, env} =
        KeyVaultActions.encrypt("oct-tamper", %{"alg" => "A256GCM", "value" => b64("x")})

      bad = %{env | "tag" => b64(:crypto.strong_rand_bytes(16))}

      assert {:error, 400, %{"error" => %{"code" => "InvalidValue"}}} =
               KeyVaultActions.decrypt("oct-tamper", Map.merge(%{"alg" => "A256GCM"}, bad))
    end
  end

  # ---------------------------------------------------------------------------
  # Sign / verify
  # ---------------------------------------------------------------------------

  describe "sign/verify RS256 + PS256" do
    test "RS256 round-trip" do
      put_key("rsa-sign")
      data = :crypto.strong_rand_bytes(64)

      assert {:ok, 200, %{"value" => sig}} =
               KeyVaultActions.sign("rsa-sign", %{"alg" => "RS256", "value" => b64(data)})

      assert {:ok, 200, %{"value" => true}} =
               KeyVaultActions.verify("rsa-sign", %{
                 "alg" => "RS256",
                 "value" => b64(data),
                 "signature" => sig
               })
    end

    test "PS256 round-trip" do
      put_key("ps-sign")
      data = "pss payload"

      {:ok, 200, %{"value" => sig}} =
        KeyVaultActions.sign("ps-sign", %{"alg" => "PS256", "value" => b64(data)})

      assert {:ok, 200, %{"value" => true}} =
               KeyVaultActions.verify("ps-sign", %{
                 "alg" => "PS256",
                 "value" => b64(data),
                 "signature" => sig
               })
    end

    test "tampered payload verifies invalid (200, valid: false)" do
      put_key("rsa-v")

      {:ok, 200, %{"value" => sig}} =
        KeyVaultActions.sign("rsa-v", %{"alg" => "RS256", "value" => b64("real")})

      assert {:ok, 200, %{"value" => false}} =
               KeyVaultActions.verify("rsa-v", %{
                 "alg" => "RS256",
                 "value" => b64("forged"),
                 "signature" => sig
               })

      assert {:ok, 200, %{"value" => false}} =
               KeyVaultActions.verify("rsa-v", %{
                 "alg" => "RS256",
                 "value" => b64("real"),
                 "signature" => b64(:crypto.strong_rand_bytes(256))
               })
    end

    test "PS256 signature does not verify as RS256" do
      put_key("alg-mix")

      {:ok, 200, %{"value" => sig}} =
        KeyVaultActions.sign("alg-mix", %{"alg" => "PS256", "value" => b64("m")})

      assert {:ok, 200, %{"value" => false}} =
               KeyVaultActions.verify("alg-mix", %{
                 "alg" => "RS256",
                 "value" => b64("m"),
                 "signature" => sig
               })
    end

    test "sign on oct key is 400 InvalidAlgorithm" do
      put_key("oct-sign", "oct")

      assert {:error, 400, %{"error" => %{"code" => "InvalidAlgorithm"}}} =
               KeyVaultActions.sign("oct-sign", %{"alg" => "RS256", "value" => b64("x")})
    end
  end

  # ---------------------------------------------------------------------------
  # wrapKey / unwrapKey
  # ---------------------------------------------------------------------------

  describe "wrapKey/unwrapKey" do
    test "RSA wrap/unwrap round-trip" do
      put_key("rsa-wrap")
      cek = :crypto.strong_rand_bytes(32)

      assert {:ok, 200, %{"value" => wrapped}} =
               KeyVaultActions.wrap_key("rsa-wrap", %{
                 "alg" => "RSA-OAEP-256",
                 "value" => b64(cek)
               })

      assert {:ok, 200, %{"value" => unwrapped}} =
               KeyVaultActions.unwrap_key("rsa-wrap", %{
                 "alg" => "RSA-OAEP-256",
                 "value" => wrapped
               })

      assert b64_decode!(unwrapped) == cek
    end

    test "oct wrap/unwrap round-trip" do
      put_key("oct-wrap", "oct")
      cek = :crypto.strong_rand_bytes(32)

      {:ok, 200, wrapped} =
        KeyVaultActions.wrap_key("oct-wrap", %{"alg" => "A256GCM", "value" => b64(cek)})

      assert {:ok, 200, %{"value" => unwrapped}} =
               KeyVaultActions.unwrap_key("oct-wrap", Map.merge(%{"alg" => "A256GCM"}, wrapped))

      assert b64_decode!(unwrapped) == cek
    end
  end

  # ---------------------------------------------------------------------------
  # Release policy gate
  # ---------------------------------------------------------------------------

  describe "release policy gate" do
    test "missing policy allows all default operations" do
      put_key("open")

      assert {:ok, 200, _} =
               KeyVaultActions.encrypt("open", %{"alg" => "RSA-OAEP-256", "value" => b64("x")})

      assert {:ok, 200, _} =
               KeyVaultActions.sign("open", %{"alg" => "RS256", "value" => b64("x")})
    end

    test "operation absent from allowed_operations -> 400 OperationNotAllowed" do
      put_key("locked", "RSA-HSM", %{"allowed_operations" => ["sign", "verify"]})

      assert_op_not_allowed(
        KeyVaultActions.encrypt("locked", %{"alg" => "RSA-OAEP-256", "value" => b64("x")})
      )

      assert_op_not_allowed(
        KeyVaultActions.decrypt("locked", %{"alg" => "RSA-OAEP-256", "value" => b64("x")})
      )

      assert {:ok, 200, %{"value" => sig}} =
               KeyVaultActions.sign("locked", %{"alg" => "RS256", "value" => b64("x")})

      assert {:ok, 200, %{"value" => true}} =
               KeyVaultActions.verify("locked", %{
                 "alg" => "RS256",
                 "value" => b64("x"),
                 "signature" => sig
               })
    end

    test "camelize allowedOperations is honored" do
      put_key("camel", "RSA-HSM", %{"allowedOperations" => ["encrypt"]})

      assert {:ok, 200, _} =
               KeyVaultActions.encrypt("camel", %{"alg" => "RSA-OAEP-256", "value" => b64("x")})

      assert_op_not_allowed(
        KeyVaultActions.sign("camel", %{"alg" => "RS256", "value" => b64("x")})
      )
    end

    test "empty policy list falls back to defaults" do
      put_key("empty-policy", "RSA-HSM", %{})

      assert {:ok, 200, _} =
               KeyVaultActions.encrypt("empty-policy", %{
                 "alg" => "RSA-OAEP-256",
                 "value" => b64("x")
               })
    end
  end

  # ---------------------------------------------------------------------------
  # Unknown keys / bad parameters
  # ---------------------------------------------------------------------------

  describe "errors" do
    test "unknown key -> 404 KeyNotFound" do
      assert {:error, 404, %{"error" => %{"code" => "KeyNotFound"}}} =
               KeyVaultActions.encrypt("ghost", %{"alg" => "RSA-OAEP-256", "value" => b64("x")})

      assert {:error, 404, %{"error" => %{"code" => "KeyNotFound"}}} =
               KeyVaultActions.list_versions("ghost")
    end

    test "invalid base64 value -> 400 InvalidValue" do
      put_key("b64")

      assert {:error, 400, %{"error" => %{"code" => "InvalidValue"}}} =
               KeyVaultActions.encrypt("b64", %{"alg" => "RSA-OAEP-256", "value" => "!!not-b64!!"})
    end

    test "missing value -> 400 InvalidParameter" do
      put_key("nvals")

      assert {:error, 400, %{"error" => %{"code" => "InvalidParameter"}}} =
               KeyVaultActions.encrypt("nvals", %{"alg" => "RSA-OAEP-256"})
    end

    test "alg mismatched to key type -> 400 InvalidAlgorithm" do
      put_key("mismatch")
      put_key("oct-mismatch", "oct")

      assert {:error, 400, %{"error" => %{"code" => "InvalidAlgorithm"}}} =
               KeyVaultActions.encrypt("oct-mismatch", %{
                 "alg" => "RSA-OAEP-256",
                 "value" => b64("x")
               })

      assert {:error, 400, %{"error" => %{"code" => "InvalidAlgorithm"}}} =
               KeyVaultActions.encrypt("mismatch", %{"alg" => "A256GCM", "value" => b64("x")})
    end

    test "unknown alg -> 400 InvalidAlgorithm" do
      put_key("bad-alg")

      assert {:error, 400, %{"error" => %{"code" => "InvalidAlgorithm"}}} =
               KeyVaultActions.encrypt("bad-alg", %{"alg" => "RSA1_5", "value" => b64("x")})
    end
  end

  # ---------------------------------------------------------------------------
  # List keys / list versions
  # ---------------------------------------------------------------------------

  describe "listing" do
    test "list_keys returns all stored keys in key order, without key_material" do
      put_key("k-b")
      put_key("k-a")
      put_key("rsa-list")
      plain = "leak check"

      {:ok, 200, _} =
        KeyVaultActions.encrypt("rsa-list", %{"alg" => "RSA-OAEP-256", "value" => b64(plain)})

      {:ok, 200, %{"value" => keys}} = KeyVaultActions.list_keys()

      names =
        keys |> Enum.map(&(&1["kid"] |> String.split("/keys/") |> List.last())) |> Enum.sort()

      assert names == Enum.sort(["k-a", "k-b", "rsa-list"])

      # private material never leaves the vault
      Enum.each(keys, fn k -> refute Map.has_key?(k, "key_material") end)
    end

    test "list_versions returns the current version" do
      put_key("v-key")
      {:ok, 200, %{"value" => [version]}} = KeyVaultActions.list_versions("v-key")
      assert version["kid"] == "https://smalt.local:8443/keys/v-key"
    end
  end

  # ---------------------------------------------------------------------------
  # Secure Key Release (SKR): derived, per-key, attestation-bound material
  # ---------------------------------------------------------------------------

  describe "secure key release" do
    import Plug.Test

    alias Smalt.DataPlane.SKR
    alias Smalt.Security.Attestation

    setup do
      m1 = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

      # v26.10.18: canonical save/restore — the previous unconditional
      # delete_env on_exit destroyed a pre-existing baseline set by a sibling.
      :ok = SmaltTest.Env.put_restored(maa_measurement_baseline: [m1])

      {:ok, m1: m1}
    end

    defp attest_token do
      {:ok, token, _claims} = Attestation.attest_enclave(%{"measurement" => m1()})
      token
    end

    # kept in the process dictionary is overkill; re-read the baseline env
    defp m1, do: Application.get_env(:smalt, :maa_measurement_baseline) |> List.first()

    defp release_conn(token) do
      conn(:post, "/keys/x/release")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    end

    defp put_skr_key(name, policy) do
      put_key(name, "RSA-HSM", policy)
    end

    test "two different keys release different material" do
      put_skr_key("skr-a", %{"authority" => "smalt-test"})
      put_skr_key("skr-b", %{"authority" => "smalt-test"})
      token = attest_token()

      assert {:ok, 200, v1} = SKR.release("skr-a", release_conn(token))
      assert {:ok, 200, v2} = SKR.release("skr-b", release_conn(attest_token()))

      assert v1["status"] == "Released" and v2["status"] == "Released"
      assert is_binary(v1["value"]) and byte_size(b64_decode!(v1["value"])) == 32
      refute v1["value"] == v2["value"]
      assert v1["kid"] != v2["kid"]
    end

    test "same key + policy releases deterministic (replayable) material" do
      put_skr_key("skr-det", %{"authority" => "smalt-test"})

      assert {:ok, 200, v1} = SKR.release("skr-det", release_conn(attest_token()))
      assert {:ok, 200, v2} = SKR.release("skr-det", release_conn(attest_token()))

      assert v1["value"] == v2["value"]
      # each release still advances the per-key material version
      assert v2["keyMaterialVersion"] == v1["keyMaterialVersion"] + 1
    end

    test "material is bound to the policy hash" do
      put_skr_key("skr-pol", %{"authority" => "smalt-test", "use" => "sign"})

      assert {:ok, 200, v1} = SKR.release("skr-pol", release_conn(attest_token()))

      # same policy re-created: identical material and policyHash
      put_skr_key("skr-pol-2", %{"authority" => "smalt-test", "use" => "sign"})
      assert {:ok, 200, v2} = SKR.release("skr-pol-2", release_conn(attest_token()))
      assert v1["policyHash"] == v2["policyHash"]
      # salt (key name) still differs
      refute v1["value"] == v2["value"]

      # different policy: different policyHash AND different material for the
      # SAME key name
      put_skr_key("skr-pol", %{"authority" => "smalt-test", "use" => "encrypt"})
      assert {:ok, 200, v3} = SKR.release("skr-pol", release_conn(attest_token()))
      refute v3["policyHash"] == v1["policyHash"]
      refute v3["value"] == v1["value"]
    end

    test "jti single-use: replayed attestation token -> 403 TokenReplay" do
      put_skr_key("skr-jti", %{"authority" => "smalt-test"})
      token = attest_token()

      assert {:ok, 200, _} = SKR.release("skr-jti", release_conn(token))

      assert {:error, 403, %{"error" => %{"code" => "TokenReplay"}}} =
               SKR.release("skr-jti", release_conn(token))

      # a fresh token (fresh jti) still releases
      assert {:ok, 200, _} = SKR.release("skr-jti", release_conn(attest_token()))
    end

    test "tampered token still refused with 403 UnauthorizedAttestation" do
      put_skr_key("skr-tamper", %{"authority" => "smalt-test"})
      token = attest_token()
      [h, _p, s] = String.split(token, ".")

      forged_claims =
        token
        |> token_claims()
        |> Map.put("x-ms-compliance-status", "azure-uncompliant-attacker")
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      assert {:error, 403, %{"error" => %{"code" => "UnauthorizedAttestation"}}} =
               SKR.release("skr-tamper", release_conn(h <> "." <> forged_claims <> "." <> s))
    end

    test "key without release policy -> 400 KeyNotExportable; unknown -> 404" do
      put_key("skr-nopolicy", "RSA-HSM", nil)
      token = attest_token()

      assert {:error, 400, %{"error" => %{"code" => "KeyNotExportable"}}} =
               SKR.release("skr-nopolicy", release_conn(token))

      assert {:error, 404, %{"error" => %{"code" => "KeyNotFound"}}} =
               SKR.release("skr-ghost", release_conn(token))
    end

    test "recipient JWK in token claims releases RSA-OAEP-256-wrapped material" do
      put_skr_key("skr-recipient", %{"authority" => "smalt-test"})

      # build the recipient-bearing token by signing claims directly
      recipient_priv = :public_key.generate_key({:rsa, 2048, 65537})
      n = elem(recipient_priv, 2)
      e = elem(recipient_priv, 3)

      claims =
        Map.merge(base_claims(), %{
          "skr_recipient_jwk" => %{
            "kty" => "RSA",
            "n" => Base.url_encode64(:binary.encode_unsigned(n), padding: false),
            "e" => Base.url_encode64(:binary.encode_unsigned(e), padding: false)
          }
        })

      wrapped_token = Smalt.Security.ReceiptSigner.sign(claims)

      assert {:ok, 200, %{"transport" => "RSA-OAEP-256", "value" => value}} =
               SKR.release("skr-recipient", release_conn(wrapped_token))

      plain =
        :public_key.decrypt_private(b64_decode!(value), recipient_priv, [
          {:rsa_padding, :rsa_pkcs1_oaep_padding},
          {:rsa_oaep_md, :sha256}
        ])

      assert byte_size(plain) == 32

      # deterministic: same material under the same key + policy decrypts equal
      # across releases only if the jti is fresh but derivation unchanged
      assert {:ok, 200, %{"value" => value2}} =
               SKR.release("skr-recipient", release_conn(attest_token()))

      assert b64_decode!(value2) == plain
    end

    test "HKDF-SHA256 derivation matches RFC 5869 test vectors" do
      # RFC 5869 Appendix B vectors for SHA-256: A.1 (TC1) and A.3 (TC3, empty salt+info)
      ikm = String.duplicate(<<0x0B>>, 22)
      salt = Base.decode16!("000102030405060708090A0B0C")
      info = Base.decode16!("F0F1F2F3F4F5F6F7F8F9")

      okm1 =
        SKR.hkdf_sha256(ikm, salt, info, 42)

      assert Base.encode16(okm1, case: :upper) ==
               "3CB25F25FAACD57A90434F64D0362F2A2D2D0A90CF1A5A4C5DB02D56ECC4C5BF34007208D5B887185865"

      okm3 = SKR.hkdf_sha256(ikm, "", "", 42)

      assert Base.encode16(okm3, case: :upper) ==
               "8DA4E775A563C18F715F802A063C5A31B8A11F5C5EE1879EC3454E5F3C738D2D9D201395FAA4B61A96C8"
    end

    test "jti replay race: concurrent releases of one token -> exactly one release" do
      put_skr_key("skr-jti-race", %{"authority" => "smalt-test"})
      token = attest_token()

      results =
        1..12
        |> Enum.map(fn _ ->
          Task.async(fn -> SKR.release("skr-jti-race", release_conn(token)) end)
        end)
        |> Task.await_many(30_000)

      assert Enum.count(results, &match?({:ok, 200, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, 403, _}, &1)) == 11

      # every refusal is the replay code, not a different failure
      assert Enum.all?(results, fn
               {:error, 403, %{"error" => %{"code" => "TokenReplay"}}} -> true
               {:ok, 200, _} -> true
               _ -> false
             end)
    end

    test "jti is single-use globally, not per key" do
      put_skr_key("skr-jti-x", %{"authority" => "smalt-test"})
      put_skr_key("skr-jti-y", %{"authority" => "smalt-test"})
      token = attest_token()

      assert {:ok, 200, _} = SKR.release("skr-jti-x", release_conn(token))

      # same token (same jti) against a different key is still a replay
      assert {:error, 403, %{"error" => %{"code" => "TokenReplay"}}} =
               SKR.release("skr-jti-y", release_conn(token))
    end

    test "expired token never releases, even with a fresh jti" do
      put_skr_key("skr-exp", %{"authority" => "smalt-test"})

      claims =
        base_claims()
        |> Map.put("exp", System.system_time(:second) - 1)

      assert {:error, 403, %{"error" => %{"code" => "UnauthorizedAttestation"}}} =
               SKR.release("skr-exp", release_conn(Smalt.Security.ReceiptSigner.sign(claims)))

      # the expired token's jti was never consumed: a valid token re-using it
      # is not a replay (freshness is enforced by exp before jti consumption)
      good = base_claims() |> Map.put("jti", claims["x-ms-runtime"]["jti"])
      good = %{good | "x-ms-runtime" => %{"jti" => claims["x-ms-runtime"]["jti"]}}

      assert {:ok, 200, _} =
               SKR.release("skr-exp", release_conn(Smalt.Security.ReceiptSigner.sign(good)))
    end

    test "failed release (malformed recipient JWK) burns neither jti nor keyMaterialVersion" do
      put_skr_key("skr-fail", %{"authority" => "smalt-test"})

      # baseline version from a clean release
      assert {:ok, 200, %{"keyMaterialVersion" => v0}} =
               SKR.release("skr-fail", release_conn(attest_token()))

      # malformed recipient JWK: wrap fails AFTER jti check in the old flow
      bad_claims =
        base_claims()
        |> Map.put("skr_recipient_jwk", %{"kty" => "oct", "k" => "not-an-rsa-key"})

      assert {:error, 400, %{"error" => %{"code" => "InvalidParameter"}}} =
               SKR.release("skr-fail", release_conn(sign_claims(bad_claims)))

      # the same token (same jti) now releases fine: the nonce was NOT burned
      # by the failed attempt, and no version was consumed by it either
      good_claims = Map.put(bad_claims, "skr_recipient_jwk", nil)
      good_claims = Map.delete(good_claims, "skr_recipient_jwk")

      assert {:ok, 200, %{"keyMaterialVersion" => v1}} =
               SKR.release("skr-fail", release_conn(sign_claims(good_claims)))

      assert v1 == v0 + 1
    end

    defp sign_claims(claims), do: Smalt.Security.ReceiptSigner.sign(claims)

    defp token_claims(token) do
      [_, p, _] = String.split(token, ".")

      p
      |> Base.url_decode64!(padding: false)
      |> Jason.decode!()
    end

    defp base_claims do
      now = System.system_time(:second)

      %{
        "x-ms-compliance-status" => "azure-compliant-cvm",
        "x-ms-runtime" => %{"jti" => System.unique_integer([:positive]) |> to_string()},
        "iat" => now,
        "exp" => now + 7200
      }
    end
  end

  # ---------------------------------------------------------------------------
  # R14 repairs (lane A4 defects 1-3)
  # ---------------------------------------------------------------------------

  describe "R14 versioned-key semantics" do
    test "unknown version -> 404 KeyNotFound, never a bare-name fallback" do
      put_key("r14-phantom")
      plain = :crypto.strong_rand_bytes(16)

      assert {:error, 404, %{"error" => %{"code" => "KeyNotFound"}}} =
               KeyVaultActions.encrypt(
                 "r14-phantom",
                 %{"alg" => "RSA-OAEP-256", "value" => b64(plain)},
                 "v999"
               )

      assert {:error, 404, %{"error" => %{"code" => "KeyNotFound"}}} =
               KeyVaultActions.decrypt(
                 "r14-phantom",
                 %{"alg" => "RSA-OAEP-256", "value" => b64(plain)},
                 "v999"
               )
    end

    test "versioned crypto op does not surface a duplicate key in list_keys" do
      put_key("r14-dup")

      # A versioned op on a fabricated version 404s and must not materialize
      # any row (phantom-version defect). A REAL version row must stay hidden
      # from list_keys even after its material is generated.
      assert {:error, 404, _} =
               KeyVaultActions.encrypt(
                 "r14-dup",
                 %{"alg" => "RSA-OAEP-256", "value" => b64("x")},
                 "v999"
               )

      {:ok, 200, %{"value" => keys}} = KeyVaultActions.list_keys()
      assert length(keys) == 1
      assert hd(keys)["kid"] == "https://smalt.local:8443/keys/r14-dup"

      # Simulate a real create-route version row (no key_material yet), then
      # run a versioned op so ensure_rsa materializes it.
      version_record = %{
        "kid" => "https://smalt.local:8443/keys/r14-dup/v1",
        "key" => %{"kid" => "https://smalt.local:8443/keys/r14-dup/v1", "kty" => "RSA-HSM"},
        "attributes" => %{"enabled" => true}
      }

      Store.put(:smalt_vault_keys, {"r14-dup", "v1"}, version_record)

      assert {:ok, 200, _} =
               KeyVaultActions.encrypt(
                 "r14-dup",
                 %{"alg" => "RSA-OAEP-256", "value" => b64("x")},
                 "v1"
               )

      {:ok, 200, %{"value" => keys}} = KeyVaultActions.list_keys()
      assert length(keys) == 1
    end

    test "oct versions derive distinct material; bare name keeps legacy derivation" do
      put_key("r14-oct", "oct-HSM")

      assert KeyVaultActions.derive_oct_key("r14-oct") ==
               KeyVaultActions.derive_oct_key("r14-oct", nil)

      assert KeyVaultActions.derive_oct_key("r14-oct") ==
               :crypto.hash(:sha256, "smalt-vault-derived:r14-oct")

      refute KeyVaultActions.derive_oct_key("r14-oct") ==
               KeyVaultActions.derive_oct_key("r14-oct", "v1")

      refute KeyVaultActions.derive_oct_key("r14-oct", "v1") ==
               KeyVaultActions.derive_oct_key("r14-oct", "v2")

      # Round-trip through a versioned oct op uses the version-bound material.
      # A versioned op requires an existing {name, version} row (create route
      # contract), so provision it first.
      Store.put(:smalt_vault_keys, {"r14-oct", "v1"}, %{
        "kid" => "https://smalt.local:8443/keys/r14-oct/v1",
        "key" => %{"kid" => "https://smalt.local:8443/keys/r14-oct/v1", "kty" => "oct-HSM"},
        "attributes" => %{"enabled" => true}
      })

      plain = :crypto.strong_rand_bytes(16)

      {:ok, 200, %{"value" => ct, "iv" => iv, "tag" => tag}} =
        KeyVaultActions.encrypt("r14-oct", %{"alg" => "A256GCM", "value" => b64(plain)}, "v1")

      assert {:error, 400, _} =
               KeyVaultActions.decrypt("r14-oct", %{
                 "alg" => "A256GCM",
                 "value" => ct,
                 "iv" => iv,
                 "tag" => tag
               })

      # Decrypting under the SAME version succeeds.
      assert {:ok, 200, %{"value" => pt}} =
               KeyVaultActions.decrypt(
                 "r14-oct",
                 %{"alg" => "A256GCM", "value" => ct, "iv" => iv, "tag" => tag},
                 "v1"
               )

      assert b64_decode!(pt) == plain
    end

    test "colon-in-name cannot collide with a version separator (R138/W5-6)" do
      # Victim: oct key "w5a" with a versioned encrypt under "V".
      put_key("w5a", "oct")
      plain = :crypto.strong_rand_bytes(16)

      Store.put(:smalt_vault_keys, {"w5a", "V"}, %{
        "kid" => "https://smalt.local:8443/keys/w5a/V",
        "key" => %{"kid" => "https://smalt.local:8443/keys/w5a/V", "kty" => "oct"},
        "attributes" => %{"enabled" => true}
      })

      {:ok, 200, %{"value" => ct, "iv" => iv, "tag" => tag}} =
        KeyVaultActions.encrypt("w5a", %{"alg" => "A256GCM", "value" => b64(plain)}, "V")

      # Attacker key literally named "w5a:V" — its bare derivation must now
      # differ from derive_oct_key("w5a", "V") (length-prefix kills the
      # separator collision).
      refute KeyVaultActions.derive_oct_key("w5a:V") == KeyVaultActions.derive_oct_key("w5a", "V")

      # Cross-decrypt under the attacker key name fails: "w5a:V" is an
      # unrelated key that does not exist, so the gate is 404 KeyNotFound —
      # the separator collision is structurally impossible post-fix, so the
      # wrong-material decrypt path is unreachable.
      assert {:error, 404, %{"error" => %{"code" => "KeyNotFound"}}} =
               KeyVaultActions.decrypt("w5a:V", %{
                 "alg" => "A256GCM",
                 "value" => ct,
                 "iv" => iv,
                 "tag" => tag
               })

      # Legit versioned decrypt still round-trips.
      assert {:ok, 200, %{"value" => pt}} =
               KeyVaultActions.decrypt(
                 "w5a",
                 %{"alg" => "A256GCM", "value" => ct, "iv" => iv, "tag" => tag},
                 "V"
               )

      assert b64_decode!(pt) == plain
    end

    test "empty allowed_operations is deny-all; camelCase honored in gate" do
      put_key("r138-deny", "oct", %{"allowed_operations" => []})

      assert {:error, 403, %{"error" => %{"code" => "OperationNotAllowed"}}} =
               KeyVaultActions.encrypt("r138-deny", %{"alg" => "A256GCM", "value" => b64("x")})

      assert {:error, 403, %{"error" => %{"code" => "OperationNotAllowed"}}} =
               KeyVaultActions.decrypt("r138-deny", %{"alg" => "A256GCM", "value" => b64("x")})

      put_key("r138-camel", "oct", %{"allowedOperations" => ["encrypt"]})

      assert {:error, 403, _} =
               KeyVaultActions.decrypt("r138-camel", %{"alg" => "A256GCM", "value" => b64("x")})
    end

    test "recover restores live version rows: versioned fetch returns the material (R24/A3-D1)" do
      name = "r24-recover"
      put_key(name)

      # Create-route contract: bare-name row carries the versions list; the
      # {name, version} row holds the material once materialized.
      {:ok, record} = Store.get(:smalt_vault_keys, name)
      Store.put(:smalt_vault_keys, name, Map.put(record, "versions", ["v1"]))

      Store.put(:smalt_vault_keys, {name, "v1"}, %{
        "kid" => "https://smalt.local:8443/keys/#{name}/v1",
        "key" => %{"kid" => "https://smalt.local:8443/keys/#{name}/v1", "kty" => "RSA-HSM"},
        "attributes" => %{"enabled" => true}
      })

      # Materialize the version row's RSA DER so delete captures real material.
      plain = :crypto.strong_rand_bytes(16)

      assert {:ok, 200, %{"value" => ct}} =
               KeyVaultActions.encrypt(
                 name,
                 %{"alg" => "RSA-OAEP-256", "value" => b64(plain)},
                 "v1"
               )

      # Soft delete, then recover.
      assert {:ok, 200, _} = KeyVaultActions.delete_key(name)

      assert {:error, 404, _} =
               KeyVaultActions.encrypt(
                 name,
                 %{"alg" => "RSA-OAEP-256", "value" => b64(plain)},
                 "v1"
               )

      assert {:ok, 200, _} = KeyVaultActions.recover_deleted_key(name)

      # The versioned fetch path must find the restored {name, "v1"} row and
      # its cached material — pre-fix (R4/D1) this 404s because recover never
      # re-put the live version rows.
      assert {:ok, 200, %{"value" => pt}} =
               KeyVaultActions.decrypt(name, %{"alg" => "RSA-OAEP-256", "value" => ct}, "v1")

      assert b64_decode!(pt) == plain

      # list_versions after recover is non-empty.
      assert {:ok, 200, %{"value" => versions}} = KeyVaultActions.list_versions(name)
      refute versions == []
    end

    test "release-policy denial is 403 Forbidden (real Azure status)" do
      put_key("r14-policy", "RSA-HSM", %{"allowed_operations" => ["encrypt"]})

      assert {:error, 403, %{"error" => %{"code" => "OperationNotAllowed"}}} =
               KeyVaultActions.sign("r14-policy", %{"alg" => "RS256", "value" => b64("x")})
    end
  end
end
