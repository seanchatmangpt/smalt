defmodule Smalt.TrustProfileTest do
  use ExUnit.Case, async: false

  alias Smalt.TrustProfile
  alias Smalt.TrustProfile.Deployment

  describe "CryptoProfile resolution" do
    test "classical is provisioned and real" do
      assert {:ok, p} = TrustProfile.profile(:classical)
      assert p.profile == :classical
      assert p.algorithms == ["RS256"]
      assert p.provisioned == true
      assert p.canonicalization == "JCS-RFC8785-subset"
    end

    test "pqc refuses typed — no faked ML-DSA" do
      assert {:refused, :PQC_NOT_PROVISIONED, msg} = TrustProfile.profile(:pqc)
      assert is_binary(msg) and msg != ""
    end

    test "hybrid refuses typed" do
      assert {:refused, :HYBRID_NOT_PROVISIONED, _} = TrustProfile.profile(:hybrid)
    end

    test "envelope construction under pqc profile refuses typed" do
      assert {:refused, :PQC_NOT_PROVISIONED, _} =
               TrustProfile.new(subject: "x", profile: :pqc)
    end

    test "signing under pqc profile refuses typed" do
      envelope = %TrustProfile{
        version: TrustProfile.envelope_version(),
        algorithm: "ML-DSA-65",
        key_id: "k",
        profile: :pqc,
        policy_epoch: 0,
        revocation_epoch: 0,
        generation: 0,
        nonce: :crypto.strong_rand_bytes(16),
        not_before: 1,
        expires_at: 2,
        subject_digest: :crypto.hash(:sha256, "x"),
        audience: "smalt"
      }

      assert {:refused, :PQC_NOT_PROVISIONED, _} = TrustProfile.sign(envelope)
    end
  end

  describe "classical profile: real RS256 sign/verify over JCS envelope" do
    test "round trip verifies and returns the signed payload" do
      {:ok, env} = TrustProfile.new(subject: "receipt-1", ttl: 60)
      assert {:ok, token} = TrustProfile.sign(env)

      assert {:ok, payload} = TrustProfile.verify(token)
      assert payload["version"] == TrustProfile.envelope_version()
      assert payload["algorithm"] == "RS256"
      assert payload["profile"] == "classical"
      assert payload["subject_digest"] == Base.encode16(:crypto.hash(:sha256, "receipt-1"), case: :lower)
      assert byte_size(payload["nonce"]) == 32
      assert payload["domain_tag"] == TrustProfile.domain_tag()
    end

    test "key_id is the stable fingerprint of the active key" do
      assert TrustProfile.key_id() =~ ~r/^[0-9a-f]{16}$/
      {:ok, env} = TrustProfile.new(subject: "k")
      assert env.key_id == TrustProfile.key_id()
    end

    test "tampered payload fails signature" do
      {:ok, env} = TrustProfile.new(subject: "t")
      {:ok, [h, p, s] = token_parts} = sign_parts(env)

      _ = env
      _ = h
      _ = s

      # flip a char in the payload segment
      [h, p, s] = token_parts
      flipped = if String.starts_with?(p, "eyJ"), do: "e" <> flip(p), else: flip(p)
      tampered = Enum.join([h, flipped, s], ".")

      assert {:error, reason} = TrustProfile.verify(tampered)
      assert reason in [:bad_signature, :invalid_json, :invalid_token, :invalid_base64]
    end

    test "alg-confusion: none and HS256 headers are refused" do
      {:ok, env} = TrustProfile.new(subject: "a")
      {:ok, token} = TrustProfile.sign(env)
      [h, p, s] = String.split(token, ".", parts: 3)

      none_header = Base.url_encode64("{\"alg\":\"none\"}", padding: false)
      hs_header = Base.url_encode64("{\"alg\":\"HS256\"}", padding: false)

      assert {:error, {:bad_alg, "none"}} = TrustProfile.verify(Enum.join([none_header, p, s], "."))
      assert {:error, {:bad_alg, "HS256"}} = TrustProfile.verify(Enum.join([hs_header, p, s], "."))
      _ = h
    end

    test "expired envelope is refused with :expired" do
      {:ok, env} = TrustProfile.new(subject: "e", not_before: now() - 100, ttl: 10)
      {:ok, token} = TrustProfile.sign(env)
      assert {:error, :expired} = TrustProfile.verify(token)
    end

    test "envelope with reversed epochs is refused at sign time" do
      {:ok, env} = TrustProfile.new(subject: "r", not_before: 500, ttl: 0)
      assert {:error, {:malformed_envelope, :bad_epochs}} = TrustProfile.sign(env)
    end
  end

  describe "JCS canonicalization (RFC 8785 subset)" do
    test "sorted keys, ASCII" do
      assert {:ok, "{\"a\":1,\"b\":2,\"c\":{\"x\":true,\"y\":null}}"} =
               TrustProfile.jcs(%{"c" => %{"y" => nil, "x" => true}, "a" => 1, "b" => 2})
    end

    test "arrays keep order, objects sort" do
      assert {:ok, "[3,{\"a\":2,\"b\":1}]"} = TrustProfile.jcs([3, %{"b" => 1, "a" => 2}])
    end

    test "string escaping: C0 controls, shorthand escapes, literals preserved" do
      assert {:ok, "{\"k\":\"a\\u0001b\\tc\\nd\\\\e\\\"f\x{e9}\"}"} =
               TrustProfile.jcs(%{"k" => "a\u0001b\tc\nd\\e\"f\x{e9}"})
    end

    test "UTF-16 code-unit key order: supplementary before BMP-high" do
      # JCS sorts by UTF-16 code units: the high surrogate of U+1F600
      # (0xD83D) is less than U+FFFD, so the supplementary-plane key sorts
      # FIRST even though its code point is larger. Non-ASCII is emitted
      # literally (minimal escaping).
      assert {:ok, j} = TrustProfile.jcs(%{"\u{1F600}" => 1, "\u{FFFD}" => 2})
      assert j == "{\"" <> "\u{1F600}" <> "\":1,\"" <> "\u{FFFD}" <> "\":2}"
    end

    test "numbers: integers within 2^53 emitted, beyond refused typed" do
      assert {:ok, "9007199254740952"} = TrustProfile.jcs(9_007_199_254_740_952)
      assert {:error, {:non_canonical_number, 9_007_199_254_740_953}} =
               TrustProfile.jcs(9_007_199_254_740_953)

      assert {:error, {:non_canonical_number, -9_007_199_254_740_953}} =
               TrustProfile.jcs(-9_007_199_254_740_953)
    end

    test "floats: -0.0 becomes 0, integral floats drop .0" do
      assert {:ok, "0"} = TrustProfile.jcs(-0.0)
      assert {:ok, "1"} = TrustProfile.jcs(1.0)
    end

    test "non-JSON values refused typed" do
      assert {:error, {:bad_json_value, :atom}} = TrustProfile.jcs(:atom)
      assert {:error, {:bad_json_value, {1, 2}}} = TrustProfile.jcs({1, 2})
    end

    test "jcs form equals Jason sorted-key form for envelope-shaped documents" do
      {:ok, env} = TrustProfile.new(subject: "pin")
      {:ok, token} = TrustProfile.sign(env)
      [_h, p64, _s] = String.split(token, ".", parts: 3)
      {:ok, payload_bin} = Base.url_decode64(p64, padding: false)

      assert payload_bin == Jason.encode!(Jason.decode!(payload_bin))
    end

    test "verify recomputes the same canonical bytes: resigning an identical envelope is byte-identical" do
      nonce = :crypto.strong_rand_bytes(16)
      now = now()

      {:ok, t1} =
        TrustProfile.new(subject: "same", nonce: nonce, not_before: now, ttl: 60, generation: 7)
        |> then(fn {:ok, env} -> TrustProfile.sign(env) end)

      {:ok, env} =
        TrustProfile.new(subject: "same", nonce: nonce, not_before: now, ttl: 60, generation: 7)

      {:ok, t1} = TrustProfile.sign(env)
      # identical canonical bytes -> identical deterministic RS256 signature
      {:ok, t2} = TrustProfile.sign(env)

      assert t1 == t2
    end
  end

  describe "Deployment profile tailoring (AAIF closed enum)" do
    test "closed enum: unknown profile refused typed" do
      assert {:refused, [{:unknown_profile, _}]} = Deployment.validate(:hybrid_dev, %{})
      assert Deployment.profiles() == [:loopback_dev, :sovereign_enterprise]
    end

    test "non-map config refused typed" do
      assert {:refused, [{:bad_config, _}]} = Deployment.validate(:loopback_dev, "nope")
    end

    test "loopback_dev admits dev config and names relaxations" do
      cfg = %{auth_mode: :anonymous, tls: false, sb_shared_key: nil}

      assert {:ok, %{profile: :loopback_dev, findings: findings}} =
               Deployment.validate(:loopback_dev, cfg)

      assert Enum.any?(findings, &(&1 =~ "anonymous"))
      assert Enum.any?(findings, &(&1 =~ "plaintext"))
      assert Enum.any?(findings, &(&1 =~ "sb_shared_key absent"))
    end

    test "sovereign_enterprise refuses each hardening gap, typed" do
      assert {:refused, violations} =
               Deployment.validate(:sovereign_enterprise, %{
                 auth_mode: :anonymous,
                 tls: false,
                 sb_shared_key: nil
               })

      reasons = Enum.map(violations, &elem(&1, 0))
      assert :missing_auth_enforce in reasons
      assert :tls_not_enabled in reasons
      assert :sb_shared_key_missing in reasons
    end

    test "sovereign_enterprise refuses :auto TLS (self-signed dev cert)" do
      assert {:refused, violations} =
               Deployment.validate(:sovereign_enterprise, %{
                 auth_mode: :enforce,
                 tls: :auto,
                 sb_shared_key: "secret"
               })

      assert Enum.any?(violations, &match?({:tls_not_enabled, _}, &1))
    end

    test "sovereign_enterprise admits fully hardened config" do
      cfg = %{auth_mode: :enforce, tls: true, sb_shared_key: "secret"}
      assert {:ok, %{profile: :sovereign_enterprise, findings: ["all hardening requirements met"]}} =
               Deployment.validate(:sovereign_enterprise, cfg)
    end

    test "validate/2 is pure: same input, same verdict" do
      cfg = %{auth_mode: :enforce, tls: false, sb_shared_key: "k"}
      assert Deployment.validate(:sovereign_enterprise, cfg) ==
               Deployment.validate(:sovereign_enterprise, cfg)
    end

    test "current_config/0 reflects application environment" do
      old = Application.get_env(:smalt, :auth_mode)
      Application.put_env(:smalt, :auth_mode, :anonymous)

      assert %{auth_mode: :anonymous, tls: tls, sb_shared_key: sk} = Deployment.current_config()
      assert tls in [true, false, :auto]
      assert sk == Application.get_env(:smalt, :sb_shared_key)

      if old, do: Application.put_env(:smalt, :auth_mode, old), else: Application.delete_env(:smalt, :auth_mode)
    end
  end

  ## Helpers

  defp now, do: System.system_time(:second)

  defp sign_parts(env) do
    {:ok, token} = TrustProfile.sign(env)
    {:ok, String.split(token, ".", parts: 3)}
  end

  defp flip(s), do: String.graphemes(s) |> Enum.reverse() |> Enum.join()
end
