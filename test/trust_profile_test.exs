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

    test "sign/1 on hand-built struct with hostile profile field refuses typed, never raises (lens-8 cycle-3 pin)" do
      for prof <- ["str", :infinity, nil, [], 0, %{}, :weird_profile] do
        env = %TrustProfile{
          version: TrustProfile.envelope_version(),
          algorithm: "RS256",
          key_id: "k",
          profile: prof,
          policy_epoch: 0,
          revocation_epoch: 0,
          generation: 0,
          nonce: :crypto.strong_rand_bytes(16),
          not_before: 1,
          expires_at: 2,
          subject_digest: "d"
        }

        assert {:refused, :UNKNOWN_PROFILE, msg} = TrustProfile.sign(env)
        assert is_binary(msg) and msg != ""
      end
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

      assert payload["subject_digest"] ==
               Base.encode16(:crypto.hash(:sha256, "receipt-1"), case: :lower)

      assert byte_size(payload["nonce"]) == 32
      assert payload["domain_tag"] == TrustProfile.domain_tag()
    end

    test "key_id is the stable fingerprint of the active key" do
      assert TrustProfile.key_id() =~ ~r/^[0-9a-f]{16}$/
      {:ok, env} = TrustProfile.new(subject: "k")
      assert env.key_id == TrustProfile.key_id()
    end

    test "garbage tokens refuse with typed reasons" do
      for junk <- ["", "a.b", "a.b.c.d", "!!!.???.###", "x." <> String.duplicate("A", 40)] do
        assert {:error, _typed_reason} = TrustProfile.verify(junk)
      end
    end

    test "new/1 without :subject raises ArgumentError (pinned contract)" do
      assert_raise ArgumentError, ~r/:subject/, fn ->
        TrustProfile.new(ttl: 60)
      end
    end

    test "new/1 refuses malformed opts typed instead of crashing" do
      assert {:error, {:malformed_envelope, :bad_opts}} =
               TrustProfile.new(subject: "x", ttl: "60")

      assert {:error, {:malformed_envelope, :bad_opts}} = TrustProfile.new(subject: "x", ttl: 0)
      assert {:error, {:malformed_envelope, :bad_opts}} = TrustProfile.new(subject: 42)
      assert {:error, {:malformed_envelope, :bad_opts}} = TrustProfile.new(subject: "x", nonce: 7)

      assert {:error, {:malformed_envelope, :bad_opts}} =
               TrustProfile.new(subject: "x", policy_epoch: -1)

      assert {:error, {:malformed_envelope, :bad_opts}} =
               TrustProfile.new(subject: "x", key_id: :atom)
    end

    test "new/1 admits valid typed opts" do
      assert {:ok, %TrustProfile{} = env} =
               TrustProfile.new(
                 subject: "ok",
                 ttl: 60,
                 policy_epoch: 3,
                 revocation_epoch: 1,
                 generation: 2,
                 nonce: :crypto.strong_rand_bytes(16),
                 key_id: "kid",
                 audience: "other"
               )

      assert env.expires_at == env.not_before + 60
      assert env.audience == "other"
    end

    test "jcs: map with non-binary key refused typed" do
      assert {:error, {:bad_json_value, _}} = TrustProfile.jcs(%{1 => "a"})
      assert {:error, {:bad_json_value, _}} = TrustProfile.jcs(%{%{} => 1})
    end

    test "jcs: invalid UTF-8 binaries refused typed (lossy byte-drop + canonicalization-collision pin, lens-9)" do
      for v <- [<<0xFF>>, <<0xC3>>, "ok" <> <<0xFF>>, <<0xED, 0xA0, 0x80>>, <<0xC0, 0x80>>] do
        assert {:error, {:bad_json_value, ^v}} = TrustProfile.jcs(v)
        # keys are fenced identically to values
        assert {:error, {:bad_json_value, _}} = TrustProfile.jcs(%{<<0xFF>> => 1})
      end
    end

    test "sign/1: hostile audience (invalid UTF-8) refuses in-spec as bad_fields, not a jcs leak (lens-9)" do
      {:ok, env} = TrustProfile.new(subject: "utf8-audience")

      assert {:error, {:malformed_envelope, :bad_fields}} =
               TrustProfile.sign(%{env | audience: "ok" <> <<0xFF>>})
    end

    test "sign/1: hostile key_id (invalid UTF-8) refuses in-spec as bad_fields, not a crash" do
      {:ok, env} = TrustProfile.new(subject: "utf8-key-id")

      assert {:error, {:malformed_envelope, :bad_fields}} =
               TrustProfile.sign(%{env | key_id: "k" <> <<0xFF>>})
    end

    test "sign/1: unknown profile refuses typed as {:refused, :UNKNOWN_PROFILE, msg}" do
      {:ok, env} = TrustProfile.new(subject: "bogus-profile")
      assert {:refused, :UNKNOWN_PROFILE, msg} = TrustProfile.sign(%{env | profile: :bogus})
      assert is_binary(msg) and msg != ""
    end

    test "alg-confusion: none and HS256 headers are refused" do
      {:ok, env} = TrustProfile.new(subject: "a")
      {:ok, token} = TrustProfile.sign(env)
      [_h, p, s] = String.split(token, ".", parts: 3)

      none_header = Base.url_encode64("{\"alg\":\"none\"}", padding: false)
      hs_header = Base.url_encode64("{\"alg\":\"HS256\"}", padding: false)

      assert {:error, {:bad_alg, "none"}} =
               TrustProfile.verify(Enum.join([none_header, p, s], "."))

      assert {:error, {:bad_alg, "HS256"}} =
               TrustProfile.verify(Enum.join([hs_header, p, s], "."))
    end

    test "tampered signature segment fails with exactly :bad_signature" do
      {:ok, env} = TrustProfile.new(subject: "sig-tamper")
      {:ok, token} = TrustProfile.sign(env)
      [h, p, s] = String.split(token, ".", parts: 3)

      # flip one char inside the signature b64, keep header+payload intact
      {:ok, sig} = Base.url_decode64(s, padding: false)
      <<a::size(8), rest::binary>> = sig

      corrupted_sig =
        Base.url_encode64(<<Bitwise.bxor(a, 1)::size(8), rest::binary>>, padding: false)

      assert {:error, :bad_signature} = TrustProfile.verify(Enum.join([h, p, corrupted_sig], "."))
    end

    test "tampered header (kid swap) fails signature — header is inside the signed bytes" do
      {:ok, env} = TrustProfile.new(subject: "kid-tamper")
      {:ok, token} = TrustProfile.sign(env)
      [_h, p, s] = String.split(token, ".", parts: 3)

      other_kid_header =
        Base.url_encode64(
          Jason.encode!(%{"alg" => "RS256", "typ" => "ctp-envelope-v1", "kid" => "rogue"}),
          padding: false
        )

      assert {:error, :bad_signature} =
               TrustProfile.verify(Enum.join([other_kid_header, p, s], "."))
    end

    test "tampered payload field (audience swap) fails signature" do
      {:ok, env} = TrustProfile.new(subject: "aud-tamper", audience: "smalt")
      {:ok, token} = TrustProfile.sign(env)
      [h, p, s] = String.split(token, ".", parts: 3)
      {:ok, payload_bin} = Base.url_decode64(p, padding: false)

      forged =
        payload_bin
        |> Jason.decode!()
        |> Map.put("audience", "evil")
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      assert {:error, :bad_signature} = TrustProfile.verify(Enum.join([h, forged, s], "."))
    end

    test "not-yet-valid envelope is refused with :not_yet_valid" do
      {:ok, env} = TrustProfile.new(subject: "future", not_before: now() + 100, ttl: 60)
      {:ok, token} = TrustProfile.sign(env)
      assert {:error, :not_yet_valid} = TrustProfile.verify(token)
    end

    test "signing under hybrid profile refuses typed (sign/2 path)" do
      envelope = %TrustProfile{
        version: TrustProfile.envelope_version(),
        algorithm: "ML-DSA-65",
        key_id: "k",
        profile: :hybrid,
        policy_epoch: 0,
        revocation_epoch: 0,
        generation: 0,
        nonce: :crypto.strong_rand_bytes(16),
        not_before: 1,
        expires_at: 2,
        subject_digest: :crypto.hash(:sha256, "x"),
        audience: "smalt"
      }

      assert {:refused, :HYBRID_NOT_PROVISIONED, msg} = TrustProfile.sign(envelope)
      assert is_binary(msg) and msg != ""
    end

    test "envelope payload and header field closure (pack gate 020 parity)" do
      {:ok, env} = TrustProfile.new(subject: "closure")
      {:ok, token} = TrustProfile.sign(env)
      [h64, p64, _s] = String.split(token, ".", parts: 3)

      [header, payload] =
        Enum.map([h64, p64], &(&1 |> Base.url_decode64!(padding: false) |> Jason.decode!()))

      assert MapSet.new(Map.keys(payload)) ==
               MapSet.new(
                 ~w(version algorithm key_id profile policy_epoch revocation_epoch
                             generation nonce not_before expires_at subject_digest audience domain_tag)
               )

      assert MapSet.new(Map.keys(header)) == MapSet.new(["alg", "typ", "kid"])
      assert header["typ"] == TrustProfile.envelope_version()
    end

    test "epoch boundary: not_before == expires_at is refused at sign" do
      env = %TrustProfile{
        version: TrustProfile.envelope_version(),
        algorithm: "RS256",
        key_id: "k",
        profile: :classical,
        policy_epoch: 0,
        revocation_epoch: 0,
        generation: 0,
        nonce: :crypto.strong_rand_bytes(16),
        not_before: 500,
        expires_at: 500,
        subject_digest: :crypto.hash(:sha256, "b"),
        audience: "smalt"
      }

      assert {:error, {:malformed_envelope, :bad_epochs}} = TrustProfile.sign(env)
    end

    test "ttl: 0 and negative ttl refused at new/1 (typed)" do
      assert {:error, {:malformed_envelope, :bad_opts}} = TrustProfile.new(subject: "b", ttl: 0)
      assert {:error, {:malformed_envelope, :bad_opts}} = TrustProfile.new(subject: "b", ttl: -5)
    end

    test "payload pinning: rogue profile field cannot ride on a real signature" do
      # The private key is not exportable through the API, so a payload
      # claiming profile "pqc" cannot be given a valid active-key signature.
      # What IS testable: the pinning fence sits behind the signature check
      # (defense-in-depth ordering) and a signature-level rejection fires first.
      {:ok, env} = TrustProfile.new(subject: "pin-forge")
      {:ok, token} = TrustProfile.sign(env)
      [h, p, s] = String.split(token, ".", parts: 3)
      {:ok, payload_bin} = Base.url_decode64(p, padding: false)

      bogus =
        Base.url_encode64(Jason.encode!(Map.put(Jason.decode!(payload_bin), "profile", "pqc")),
          padding: false
        )

      assert {:error, :bad_signature} = TrustProfile.verify(Enum.join([h, bogus, s], "."))
    end

    test "rotation fence: token from a retired key is refused :unknown_key_id (active fingerprint law)" do
      key_ref = {Smalt.TrustProfile, :keypair}
      original = :persistent_term.get(key_ref, :missing)

      retired_token =
        (fn ->
           {:ok, env} = TrustProfile.new(subject: "rotation")
           {:ok, token} = TrustProfile.sign(env)
           token
         end).()

      # swap in a fresh keypair (the rotation)
      new_priv = :public_key.generate_key({:rsa, 2048, 65_537})

      new_pub =
        :public_key.der_encode(
          :RSAPublicKey,
          {:RSAPublicKey, new_priv |> elem(2), new_priv |> elem(3)}
        )

      new_pub = :public_key.der_decode(:RSAPublicKey, new_pub)
      :persistent_term.put(key_ref, {new_priv, new_pub})

      try do
        # the retired token no longer names the active fingerprint
        assert {:error, :unknown_key_id} = TrustProfile.verify(retired_token)

        # a token signed under the new key verifies end-to-end
        {:ok, env} = TrustProfile.new(subject: "rotation-new")
        {:ok, token} = TrustProfile.sign(env)
        assert {:ok, payload} = TrustProfile.verify(token)
        assert payload["key_id"] == TrustProfile.key_id()
      after
        if original == :missing,
          do: :persistent_term.erase(key_ref),
          else: :persistent_term.put(key_ref, original)
      end
    end

    test "field-closure boundary fuzz: sign refuses wrong-typed struct fields, typed" do
      base = fn overrides ->
        %TrustProfile{
          version: TrustProfile.envelope_version(),
          algorithm: "RS256",
          key_id: "k",
          profile: :classical,
          policy_epoch: 0,
          revocation_epoch: 0,
          generation: 0,
          nonce: :crypto.strong_rand_bytes(16),
          not_before: now() - 1,
          expires_at: now() + 60,
          subject_digest: :crypto.hash(:sha256, "x"),
          audience: "smalt"
        }
        |> struct(overrides)
      end

      # every string field attacked with non-binary, every epoch field with
      # non-integer / negative — each must refuse typed, none may sign
      for overrides <- [
            %{version: 1},
            %{algorithm: nil},
            %{key_id: :atom},
            %{nonce: 1234},
            %{audience: %{}},
            %{subject_digest: 12_345},
            %{policy_epoch: "0"},
            %{policy_epoch: -1},
            %{revocation_epoch: "0"},
            %{generation: 1.5},
            %{not_before: "now"},
            %{expires_at: nil}
          ] do
        assert {:error, {:malformed_envelope, :bad_fields}} = TrustProfile.sign(base.(overrides))
      end
    end

    test "verify/1 has no struct path: hand-built envelopes are typed-invalid, not signed (symmetry pin)" do
      # sign/1 got a struct fence in cycle-21; verify/1's contract is token-string
      # only — a struct (or any non-binary) hits the catch-all typed refusal and
      # can never enter the crypto pipeline. This pin makes the asymmetry a law:
      # structs are manufacture-side only.
      struct_env = %TrustProfile{
        version: TrustProfile.envelope_version(),
        algorithm: "RS256",
        key_id: "k",
        profile: :classical,
        policy_epoch: 0,
        revocation_epoch: 0,
        generation: 0,
        nonce: :crypto.strong_rand_bytes(16),
        not_before: 1,
        expires_at: 2,
        subject_digest: :crypto.hash(:sha256, "x"),
        audience: "smalt"
      }

      assert {:error, :invalid_token} = TrustProfile.verify(struct_env)
      assert {:error, :invalid_token} = TrustProfile.verify(nil)
      assert {:error, :invalid_token} = TrustProfile.verify(42)
    end

    test "private key material never reaches the emitted surface" do
      {:ok, env} = TrustProfile.new(subject: "leak")
      {:ok, token} = TrustProfile.sign(env)

      # emitted surface: JWS token, envelope inspect, key fingerprint, verdict maps
      surfaces = [
        token,
        inspect(env),
        inspect(TrustProfile.key_id()),
        TrustProfile.key_id(),
        elem(TrustProfile.jcs(%{"tok" => token}), 1)
      ]

      {priv, _pub} = :persistent_term.get({Smalt.TrustProfile, :keypair})
      # :RSAPrivateKey fields: version, n, e, d, prime1, prime2, exp1, exp2, coefficient
      secrets = [elem(priv, 4), elem(priv, 5), elem(priv, 6), elem(priv, 8)]

      for secret_int <- secrets,
          raw = :binary.encode_unsigned(secret_int),
          byte_size(raw) > 16,
          # every rendering a leak could take: raw bytes, decimal, hex, base64
          rep <- [
            raw,
            Integer.to_string(secret_int),
            Base.encode16(raw, case: :lower),
            Base.encode16(raw, case: :upper),
            Base.encode64(raw)
          ],
          chunk_size <- [16, 24] do
        windows =
          for <<win::binary-size(chunk_size)-unit(8) <- rep>> do
            win
          end

        for win <- Enum.take_every(windows, 5),
            surface <- surfaces do
          assert :binary.match(win, surface) == :nomatch,
                 "private key material leaked into emitted surface"
        end
      end

      # the fingerprint IS the only key-derived material on the surface, and it is public
      assert TrustProfile.key_id() =~ ~r/^[0-9a-f]{16}$/
    end

    test "expired envelope is refused with :expired" do
      {:ok, env} = TrustProfile.new(subject: "e", not_before: now() - 100, ttl: 10)
      {:ok, token} = TrustProfile.sign(env)
      assert {:error, :expired} = TrustProfile.verify(token)
    end

    test "envelope with reversed epochs is refused at sign time" do
      env = %TrustProfile{
        version: TrustProfile.envelope_version(),
        algorithm: "RS256",
        key_id: "k",
        profile: :classical,
        policy_epoch: 0,
        revocation_epoch: 0,
        generation: 0,
        nonce: :crypto.strong_rand_bytes(16),
        not_before: 500,
        expires_at: 400,
        subject_digest: :crypto.hash(:sha256, "r"),
        audience: "smalt"
      }

      assert {:error, {:malformed_envelope, :bad_epochs}} = TrustProfile.sign(env)
    end
  end

  describe "cross-surface isolation vs Smalt.Security.ReceiptSigner (lens-2)" do
    test "TP envelope JWS does not verify under ReceiptSigner.verify/1 (distinct keys)" do
      # Neither app-env key configured: each module generates and caches its own
      # random 2048-bit key, so the cryptographic isolation is real, not accidental.
      refute Application.get_env(:smalt, :receipt_signing_key)
      {:ok, env} = TrustProfile.new(subject: "isolation")
      assert {:ok, tp_token} = TrustProfile.sign(env)
      assert {:error, _} = Smalt.Security.ReceiptSigner.verify(tp_token)
    end

    test "ReceiptSigner claims JWS does not verify under TrustProfile.verify/1 (distinct keys)" do
      refute Application.get_env(:smalt, :receipt_signing_key)
      token = Smalt.Security.ReceiptSigner.sign(%{"sub" => "ledger", "exp" => now() + 600})
      assert {:error, :unknown_key_id} = TrustProfile.verify(token)
    end

    test "even SHARED key material does not cross domains: RS token refused structurally by TP" do
      # Force both modules onto the same keypair via the shared app-env key.
      # Isolation must hold by domain structure, not by key coincidence.
      tp_ref = {Smalt.TrustProfile, :keypair}
      rs_ref = {Smalt.Security.ReceiptSigner, :keypair}
      tp_orig = :persistent_term.get(tp_ref, :missing)
      rs_orig = :persistent_term.get(rs_ref, :missing)
      app_env_orig = Application.get_env(:smalt, :receipt_signing_key)

      priv = :public_key.generate_key({:rsa, 2048, 65_537})

      pub =
        priv
        |> then(&:public_key.der_encode(:RSAPublicKey, {:RSAPublicKey, elem(&1, 2), elem(&1, 3)}))

      pub = :public_key.der_decode(:RSAPublicKey, pub)

      pem_pair = %{
        private: :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, priv)]),
        public: :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPublicKey, pub)])
      }

      :persistent_term.erase(tp_ref)
      :persistent_term.erase(rs_ref)
      SmaltTest.Env.put_restored(receipt_signing_key: pem_pair)

      try do
        # ReceiptSigner signs plain claims; TrustProfile.verify refuses it even
        # though the key is identical — the payload has no TP key_id/profile/version.
        rs_token = Smalt.Security.ReceiptSigner.sign(%{"sub" => "ledger", "exp" => now() + 600})
        assert {:error, :unknown_key_id} = TrustProfile.verify(rs_token)

        # The reverse direction (lens-3 cycle-2 re-pin, ledger lane landed its
        # typ fence mid-cycle): a validly-signed TP token is now ALSO refused
        # by ReceiptSigner — typ != the RS token type. The lens-2 asymmetric
        # boundary (RS had no domain check) is CLOSED: isolation holds by
        # domain structure in BOTH directions under shared key material.
        {:ok, env} = TrustProfile.new(subject: "shared")
        {:ok, tp_token} = TrustProfile.sign(env)

        assert {:error, {:bad_typ, "ctp-envelope-v1"}} =
                 Smalt.Security.ReceiptSigner.verify(tp_token)
      after
        if app_env_orig == nil,
          do: Application.delete_env(:smalt, :receipt_signing_key),
          else: Application.put_env(:smalt, :receipt_signing_key, app_env_orig)

        if tp_orig == :missing,
          do: :persistent_term.erase(tp_ref),
          else: :persistent_term.put(tp_ref, tp_orig)

        if rs_orig == :missing,
          do: :persistent_term.erase(rs_ref),
          else: :persistent_term.put(rs_ref, rs_orig)
      end
    end
  end

  describe "JCS canonicalization (RFC 8785 subset)" do
    test "sorted keys, ASCII" do
      assert {:ok, "{\"a\":1,\"b\":2,\"c\":{\"x\":true,\"y\":null}}"} =
               TrustProfile.jcs(%{"c" => %{"y" => nil, "x" => true}, "a" => 1, "b" => 2})
    end

    test "combining-mark escape law: quote/backslash + combining mark keeps its escape (codepoint, not grapheme, iteration)" do
      # Lens-2 cycle-3 production defect: grapheme clustering merged a quote or
      # backslash with a following combining mark; the catch-all emitted the
      # cluster RAW, dropping a required escape and yielding invalid JSON.
      assert {:ok, ~s("a\\"̀")} = TrustProfile.jcs("a\"" <> "̀")
      assert {:ok, ~s("a\\\\̀")} = TrustProfile.jcs("a\\" <> "̀")
      # the emitted forms must round-trip to the original string
      for s <- ["a\"" <> "̀", "a\\" <> "̀", "\"̀", "\\̀"] do
        {:ok, j} = TrustProfile.jcs(s)
        assert Jason.decode!(j) == s
      end
    end

    test "UTF-16 key sort: BMP/astral boundary and prefix chains (adversarial key orders)" do
      # RFC 8785 §3.2.3 orders by UTF-16 code units, so U+10000 (leading
      # surrogate 0xD800) sorts BEFORE U+FFFF (single unit 0xFFFF); plain
      # code-point order would reverse them. Verified against the JS oracle:
      # ["￿","\u{10000}"].sort() -> ["𐀀","￿"].
      assert {:ok, j} =
               TrustProfile.jcs(%{
                 "\uFFFF" => 1,
                 "\u{10000}" => 2,
                 "a" => 3,
                 "aa" => 4,
                 "\u00E1" => 5
               })

      pos = fn s -> :binary.match(j, s) |> elem(0) end

      assert pos.("\"a\"") < pos.("\"aa\"")
      assert pos.("\"aa\"") < pos.("\"\u00E1\"")
      assert pos.("\"\u00E1\"") < pos.("\"\u{10000}\"")
      assert pos.("\"\u{10000}\"") < pos.("\"\uFFFF\"")
    end

    test "arrays keep order, objects sort" do
      assert {:ok, "[3,{\"a\":2,\"b\":1}]"} = TrustProfile.jcs([3, %{"b" => 1, "a" => 2}])
    end

    test "string escaping: C0 controls, shorthand escapes, literals preserved" do
      assert {:ok, "{\"k\":\"a\\u0001b\\tc\\nd\\\\e\\\"fé\"}"} =
               TrustProfile.jcs(%{"k" => "a\u0001b\tc\nd\\e\"fé"})
    end

    test "UTF-16 code-unit key order: supplementary before BMP-high" do
      # JCS sorts by UTF-16 code units: the high surrogate of U+1F600
      # (0xD83D) is less than U+FFFD, so the supplementary-plane key sorts
      # FIRST even though its code point is larger. Non-ASCII is emitted
      # literally (minimal escaping).
      assert {:ok, j} = TrustProfile.jcs(%{"\u{1F600}" => 1, "\u{FFFD}" => 2})
      assert j == "{\"" <> "\u{1F600}" <> "\":1,\"" <> "\u{FFFD}" <> "\":2}"
    end

    test "numbers: integers within 2^53 - 1 emitted, 2^53 and beyond refused typed" do
      assert {:ok, "9007199254740991"} = TrustProfile.jcs(9_007_199_254_740_991)
      assert {:ok, "-9007199254740991"} = TrustProfile.jcs(-9_007_199_254_740_991)

      assert {:error, {:non_canonical_number, 9_007_199_254_740_992}} =
               TrustProfile.jcs(9_007_199_254_740_992)

      assert {:error, {:non_canonical_number, -9_007_199_254_740_992}} =
               TrustProfile.jcs(-9_007_199_254_740_992)
    end

    test "floats: -0.0 becomes 0, integral floats drop .0" do
      assert {:ok, "0"} = TrustProfile.jcs(-0.0)
      assert {:ok, "1"} = TrustProfile.jcs(1.0)
    end

    test "floats: ECMAScript fixed window — integral floats >= 1e16 stay fixed notation" do
      assert {:ok, "10000000000000000"} = TrustProfile.jcs(1.0e16)
      assert {:ok, "-10000000000000000"} = TrustProfile.jcs(-1.0e16)
      assert {:ok, "1234567890123456800"} = TrustProfile.jcs(1.2345678901234568e18)
      assert {:ok, "100000000000000000000"} = TrustProfile.jcs(1.0e20)
    end

    test "floats: fixed window — fractional values are point-expanded, not scientific" do
      assert {:ok, "0.0000012"} = TrustProfile.jcs(1.2e-6)
      assert {:ok, "-0.0000012"} = TrustProfile.jcs(-1.2e-6)
      assert {:ok, "1.5"} = TrustProfile.jcs(1.5)
      assert {:ok, "1234.5678"} = TrustProfile.jcs(1234.5678)
    end

    test "floats: >= 1e21 and < 1e-6 use ECMAScript scientific form (explicit sign, bare mantissa)" do
      assert {:ok, "1e+21"} = TrustProfile.jcs(1.0e21)
      assert {:ok, "-1e+21"} = TrustProfile.jcs(-1.0e21)
      assert {:ok, "2.5e+22"} = TrustProfile.jcs(2.5e22)
      assert {:ok, "1.5e-7"} = TrustProfile.jcs(1.5e-7)
      assert {:ok, "1e-7"} = TrustProfile.jcs(1.0e-7)
    end

    test "fixed/scientific boundary is 1e-6 and 1e21 exactly at single-ulp resolution (numedge oracle parity)" do
      # Lens-3 cycle-1: node-oracle parity over the ±1-ulp windows of the
      # ECMAScript fixed-notation boundary values (tmp/tp_numedge.exs, 47/47).
      assert {:ok, "0.000001"} = TrustProfile.jcs(1.0e-6)
      assert {:ok, "0.0000010000000000000002"} = TrustProfile.jcs(next_up(1.0e-6))
      assert {:ok, "9.999999999999997e-7"} = TrustProfile.jcs(next_down(1.0e-6))
      assert {:ok, "9.999999999999995e-7"} = TrustProfile.jcs(next_down(next_down(1.0e-6)))

      assert {:ok, "1e+21"} = TrustProfile.jcs(1.0e21)
      assert {:ok, "999999999999999900000"} = TrustProfile.jcs(next_down(1.0e21))
      assert {:ok, "1.0000000000000001e+21"} = TrustProfile.jcs(next_up(1.0e21))

      # integral floats below the window stay fixed; the smallest denormal
      # rounds to 0 digits (5e-324 -> "0" via ES semantics? no — 5e-324 is
      # nonzero: ES renders it "5e-324")
      assert {:ok, "5e-324"} = TrustProfile.jcs(5.0e-324)
      assert {:ok, "1.7976931348623157e+308"} = TrustProfile.jcs(1.7976931348623157e308)
      assert {:ok, "2.2250738585072014e-308"} = TrustProfile.jcs(2.2250738585072014e-308)
    end

    test "non-finite floats are structurally unreachable (Erlang floats are finite by construction)" do
      # JCS mandates refusing NaN/Infinity. In Erlang those values cannot be
      # constructed: the IEEE-754 NaN bit pattern fails `<<f::float>>` bit
      # reinterpretation (the runtime has no NaN/Inf float values), so jcs/1's
      # is_float clause can only ever see finite floats. This pins the
      # unrepresentability itself as the typed-refusal mechanism.
      bits = <<0x7FF8000000000000::64>>
      assert :nomatch == reinterpret_float(bits)

      # overflow raises instead of producing infinity
      max_finite = Float.max_finite()
      assert_raise(ArithmeticError, fn -> max_finite * 10 end)
    end

    test "duplicate keys are structurally impossible in canonical output (map keys are unique; JSON decode is last-wins)" do
      # Lens-3 cycle-2: JCS input arrives either as a decoded JSON document
      # (Jason.decode collapses duplicates FIRST-wins before jcs/1 sees the
      # document — an honest Jason-vs-JS divergence, pinned as decoded-form
      # behavior, not a jcs/1 concern) or as an Elixir map (unique keys by
      # construction). Either way jcs/1 emits every key exactly once.
      assert %{"a" => 1} = Jason.decode!(~s({"a":1,"a":2}))
      assert {:ok, ~s({"a":1})} = TrustProfile.jcs(Jason.decode!(~s({"a":1,"a":2})))

      # Elixir maps cannot hold duplicate keys — jcs/1's input space has no
      # duplicate-key member.
      assert {:ok, ~s({"a":1})} = TrustProfile.jcs(%{"a" => 1})
      assert %{1 => :a, 1.0 => :b} |> Map.keys() |> length() == 2
    end

    test "nested refusals propagate their typed reason at any depth" do
      # Lens-3 cycle-4: a nested non-canonical number used to collapse to
      # {:bad_json_value, container} at every depth (reason destroyed). The
      # typed reason now propagates: numbers keep :non_canonical_number,
      # non-JSON members keep their own :bad_json_value.
      assert {:error, {:non_canonical_number, 9_007_199_254_740_992}} =
               TrustProfile.jcs(%{"a" => 9_007_199_254_740_992})

      assert {:error, {:non_canonical_number, 9_007_199_254_740_992}} =
               TrustProfile.jcs([9_007_199_254_740_992])

      assert {:error, {:non_canonical_number, n}} =
               TrustProfile.jcs(%{"k" => [[9_007_199_254_740_992]]})

      assert n == 9_007_199_254_740_992

      assert {:error, {:bad_json_value, :atom}} = TrustProfile.jcs(%{"a" => :atom})
      assert {:error, {:bad_json_value, 1}} = TrustProfile.jcs(%{1 => :ok})
      assert {:error, {:bad_json_value, :atom}} = TrustProfile.jcs([:atom])
    end

    test "nested refusals name the OFFENDING member, not the container" do
      # Non-binary map keys now refuse with the key itself (was: the whole map).
      assert {:error, {:bad_json_value, 1}} = TrustProfile.jcs(%{1 => :ok})
      assert {:error, {:bad_json_value, %{} = k}} = TrustProfile.jcs(%{%{} => 1})
      assert k == %{}
    end

    test "verify/1 header/payload type confusion refuses typed, never raises (lens-3 fuzz law, deterministic subset)" do
      b64j = fn m -> Base.url_encode64(Jason.encode!(m), padding: false) end
      b64s = fn s -> Base.url_encode64(s, padding: false) end

      refuse = fn token, expected ->
        assert {:error, ^expected} = TrustProfile.verify(token)
      end

      b = fn -> b64s.("x") end

      # alg not a string / list-shaped
      refuse.(b64j.(%{"alg" => 1}) <> "." <> b64j.(%{}) <> "." <> b.(), :bad_alg)
      refuse.(b64j.(%{"alg" => ["RS256"]}) <> "." <> b64j.(%{}) <> "." <> b.(), :bad_alg)
      # key_id list-shaped
      refuse.(
        b64j.(%{"alg" => "RS256"}) <> "." <> b64j.(%{"key_id" => ["a"]}) <> "." <> b.(),
        :unknown_key_id
      )

      # float epochs (checked before RSA: kid gate fires first)
      refuse.(
        b64j.(%{"alg" => "RS256"}) <>
          "." <> b64j.(%{"not_before" => 1.5, "expires_at" => 2.5}) <> "." <> b.(),
        :unknown_key_id
      )

      # string epochs
      refuse.(
        b64j.(%{"alg" => "RS256"}) <>
          "." <> b64j.(%{"not_before" => "1", "expires_at" => "2"}) <> "." <> b.(),
        :unknown_key_id
      )

      # wrong segment counts / malformed shapes (measured: 4-segment token
      # fails b64 on the dotted tail; "a..b" fails b64 on the 1-char segment)
      assert {:error, :invalid_base64} = TrustProfile.verify("a.b.c.d")
      assert {:error, :invalid_base64} = TrustProfile.verify("a..b")
      assert {:error, :invalid_json} = TrustProfile.verify("....")
      assert {:error, :invalid_token} = TrustProfile.verify("")
    end

    test "verify/1 fence ordering is total and deterministic (lens-4 cycle-2)" do
      {:ok, env} = TrustProfile.new(subject: "fence-order pin")
      {:ok, token} = TrustProfile.sign(env)
      [h, p, s] = String.split(token, ".", parts: 3)
      hm = Jason.decode!(Base.url_decode64!(h, padding: false))
      pm = Jason.decode!(Base.url_decode64!(p, padding: false))
      enc = fn m -> Base.url_encode64(Jason.encode!(m), padding: false) end

      # Structural precedence, each witnessed 3x identical (harness:
      # tmp/tp_fence_order.exs, FENCE-ORDER: PASS):
      #   :bad_alg  >  :unknown_key_id (PAYLOAD key_id, pre-RSA)
      #   >  :bad_signature (header kid tamper is sig break, post-RSA)
      #   >  E-E cross-check refusals; header typ is informational in TP
      #   (TP.verify has NO typ gate — a foreign typ verifies, pinned as such).
      verdict = fn tok -> TrustProfile.verify(tok) end

      # bad payload-kid AND bad alg: alg wins (alg is checked first)
      assert {:error, {:bad_alg, "RS384"}} =
               verdict.(
                 enc.(Map.put(hm, "alg", "RS384")) <>
                   "." <>
                   enc.(Map.put(pm, "key_id", "deadbeefdeadbeef")) <> "." <> s
               )

      # bad payload-kid alone: kid gate fires before RSA (payload tamper broke
      # the signature, yet the refusal is the precise :unknown_key_id)
      assert {:error, :unknown_key_id} =
               verdict.(h <> "." <> enc.(Map.put(pm, "key_id", "deadbeefdeadbeef")) <> "." <> s)

      # absent payload key_id: same precise refusal
      assert {:error, :unknown_key_id} =
               verdict.(h <> "." <> enc.(Map.delete(pm, "key_id")) <> "." <> s)

      # header-kid tamper: E-E surface, signature break, :bad_signature
      assert {:error, :bad_signature} =
               verdict.(enc.(Map.put(hm, "kid", "deadbeefdeadbeef")) <> "." <> p <> "." <> s)

      # foreign header typ: TP has NO typ gate, but the header is signed, so a
      # typ value change breaks the signature — :bad_signature (the same
      # tampered token hits RS's typ fence FIRST: {:bad_typ, "other-v9"},
      # typ-before-RSA; see tmp/tp_fence_order.exs FENCE-ORDER output)
      assert {:error, :bad_signature} =
               verdict.(enc.(Map.put(hm, "typ", "other-v9")) <> "." <> p <> "." <> s)
    end

    test "sign/verify round-trip with escape-heavy subject; single-byte tamper refused (lens-4 cycle-5 pin)" do
      # fixed deterministic subset of tmp/tp_roundtrip_fuzz.exs (300-subject
      # fuzz: roundtrip=true; tamper refused=200 admitted=0)
      subj = "quote\" back\\ slash\t newline\n é \u{1F600} \u0000 ctl"

      {:ok, env} = TrustProfile.new(subject: subj)
      {:ok, token} = TrustProfile.sign(env)
      assert {:ok, payload} = TrustProfile.verify(token)
      assert payload["subject_digest"] == TrustProfile.Digest.hex(:crypto.hash(:sha256, subj))

      # flip one byte in the header segment -> refusal, never admission
      [h, p, s] = String.split(token, ".", parts: 3)
      <<pre::binary-size(4), _::size(8), post::binary>> = h
      tampered = <<pre::binary, ?X::size(8), post::binary>>
      assert {:error, _} = TrustProfile.verify(<<tampered::binary, ?., p::binary, ?., s::binary>>)
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

      {:ok, env} =
        TrustProfile.new(subject: "same", nonce: nonce, not_before: now, ttl: 60, generation: 7)

      # identical canonical bytes -> identical deterministic RS256 signature
      {:ok, t1} = TrustProfile.sign(env)
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

      assert {:ok,
              %{profile: :sovereign_enterprise, findings: ["all hardening requirements met"]}} =
               Deployment.validate(:sovereign_enterprise, cfg)
    end

    test "validate/2 is pure: same input, same verdict" do
      cfg = %{auth_mode: :enforce, tls: false, sb_shared_key: "k"}

      assert Deployment.validate(:sovereign_enterprise, cfg) ==
               Deployment.validate(:sovereign_enterprise, cfg)
    end

    test "deployment validation matrix fuzz: exhaustive grid, exact verdict per cell" do
      # hermetic: pin the certfile env so tls:nil cells are deterministic
      old_cert = Application.get_env(:smalt, :tls_certfile)
      old_key = Application.get_env(:smalt, :tls_keyfile)
      Application.delete_env(:smalt, :tls_certfile)
      Application.delete_env(:smalt, :tls_keyfile)

      try do
        auth_modes = [:enforce, :anonymous, :bearer, nil]
        tls_values = [true, false, :auto, nil]
        keys = ["secret", nil]

        for auth <- auth_modes,
            tls <- tls_values,
            key <- keys do
          cfg = %{auth_mode: auth, tls: tls, sb_shared_key: key}

          # loopback_dev admits every cell, and is pure
          assert {:ok, %{profile: :loopback_dev, findings: findings}} =
                   Deployment.validate(:loopback_dev, cfg)

          assert is_list(findings)

          assert Deployment.validate(:loopback_dev, cfg) ==
                   {:ok, %{profile: :loopback_dev, config: cfg, findings: findings}}

          # sovereign_enterprise: refusal iff any hardening requirement unmet; reasons exact
          expected_reasons =
            Enum.reject(
              [
                if(auth == :enforce, do: nil, else: :missing_auth_enforce),
                if(tls == true, do: nil, else: :tls_not_enabled),
                if(is_binary(key), do: nil, else: :sb_shared_key_missing)
              ],
              &is_nil/1
            )

          actual = Deployment.validate(:sovereign_enterprise, cfg)

          if expected_reasons == [] do
            assert {:ok,
                    %{
                      profile: :sovereign_enterprise,
                      findings: ["all hardening requirements met"]
                    }} = actual
          else
            assert {:refused, violations} = actual

            assert Enum.map(violations, &elem(&1, 0)) |> Enum.sort() ==
                     Enum.sort(expected_reasons)
          end
        end

        # closed enum + non-map configs stay typed at the boundary
        for bad_profile <- [:hybrid_dev, :pqc_dev, "classical", 42, nil, %{}],
            bad_config <- ["nope", 42, nil, [1, 2], :atom] do
          assert {:refused, [_ | _]} = Deployment.validate(bad_profile, %{})
          assert {:refused, [{:bad_config, _}]} = Deployment.validate(:loopback_dev, bad_config)
        end

        # string-keyed config maps are refused, never coerced-to-empty (AAIF law)
        for bad_config <- [%{"tls" => true}, %{"auth_mode" => :enforce, 1 => 2}] do
          assert {:refused, [{:bad_config, _}]} = Deployment.validate(:loopback_dev, bad_config)

          assert {:refused, [{:bad_config, _}]} =
                   Deployment.validate(:sovereign_enterprise, bad_config)
        end
      after
        if old_cert,
          do: Application.put_env(:smalt, :tls_certfile, old_cert),
          else: Application.delete_env(:smalt, :tls_certfile)

        if old_key,
          do: Application.put_env(:smalt, :tls_keyfile, old_key),
          else: Application.delete_env(:smalt, :tls_keyfile)
      end
    end

    test "nil-tls enterprise cell admits when explicit certfiles exist on disk" do
      cert = Path.join(System.tmp_dir!(), "smalt-tp-test-cert-#{:rand.uniform(1_000_000)}.pem")
      key = Path.join(System.tmp_dir!(), "smalt-tp-test-key-#{:rand.uniform(1_000_000)}.pem")
      File.write!(cert, "CERT")
      File.write!(key, "KEY")

      try do
        SmaltTest.Env.put_restored(tls_certfile: cert)
        SmaltTest.Env.put_restored(tls_keyfile: key)

        cfg = %{auth_mode: :enforce, tls: nil, sb_shared_key: "secret"}

        assert {:ok, %{profile: :sovereign_enterprise}} =
                 Deployment.validate(:sovereign_enterprise, cfg)

        assert %{tls: true} = Deployment.current_config()
      after
        File.rm(cert)
        File.rm(key)
        Application.delete_env(:smalt, :tls_certfile)
        Application.delete_env(:smalt, :tls_keyfile)
      end
    end

    test "corrupt cached dev cert regenerates typed under :auto — never crashes (lens-5 cycle-1 pin)" do
      # TLS-261014-01: the dev cert is per-seat state under tmp/dev-certs/,
      # keyed by lane key. Exercise the seat-keyed contract with an explicit
      # deterministic key instead of the legacy shared tmp/dev-cert.pem path.
      lane = "corpus-b-lens3-corrupt"
      {cert, key} = Smalt.TLS.dev_cert_paths(lane)
      File.mkdir_p!(Path.dirname(cert))
      File.rm(cert)
      File.rm(key)

      saved =
        for k <- [:tls, :tls_certfile, :tls_keyfile], do: {k, Application.get_env(:smalt, k)}

      try do
        Application.delete_env(:smalt, :tls_certfile)
        Application.delete_env(:smalt, :tls_keyfile)
        SmaltTest.Env.put_restored(tls: :auto)

        for content <- ["-----BEGIN CERTIFICATE-----\nMIIB\n", "nope\n", ""] do
          File.write!(cert, content)
          File.write!(key, content)

          assert {:ok, ^cert, ^key} = Smalt.TLS.ensure_dev_cert(lane)

          # regenerated file is a real, parseable certificate
          assert {:ok, pem} = File.read(cert)
          assert [{:Certificate, der, :not_encrypted} | _] = :public_key.pem_decode(pem)
          assert match?({:OTPCertificate, _, _, _}, :public_key.pkix_decode_cert(der, :otp))
        end
      after
        File.rm(cert)
        File.rm(key)

        for {k, v} <- saved do
          if v == nil,
            do: Application.delete_env(:smalt, k),
            else: Application.put_env(:smalt, k, v)
        end
      end
    end

    test "valid cached dev cert is NOT regenerated on boot (:auto) — parse_cert must accept real certs (lens-6 cycle-2 pin)" do
      # TLS-261014-01: seat-keyed contract — write a valid pair at the
      # deterministic seat-keyed paths and pin byte identity across a
      # ensure_dev_cert/1 call (no regeneration).
      lane = "corpus-b-lens3-valid"
      {cert, key} = Smalt.TLS.dev_cert_paths(lane)
      File.mkdir_p!(Path.dirname(cert))
      File.rm(cert)
      File.rm(key)

      saved =
        for k <- [:tls, :tls_certfile, :tls_keyfile], do: {k, Application.get_env(:smalt, k)}

      try do
        Application.delete_env(:smalt, :tls_certfile)
        Application.delete_env(:smalt, :tls_keyfile)
        SmaltTest.Env.put_restored(tls: :auto)

        # A freshly written valid cert must be accepted as-is: byte identity
        # across a boot proves no regeneration happened (mtime alone can race).
        :ok = Smalt.TLS.write_dev_cert(cert, key)
        bytes_before = File.read!(cert)
        assert {:ok, ^cert, ^key} = Smalt.TLS.ensure_dev_cert(lane)

        assert File.read!(cert) == bytes_before,
               "valid cached dev cert was regenerated — parse_cert rejects valid certs"
      after
        File.rm(cert)
        File.rm(key)

        for {k, v} <- saved do
          if v == nil,
            do: Application.delete_env(:smalt, k),
            else: Application.put_env(:smalt, k, v)
        end
      end
    end

    test "explicit corrupt certfile/keyfile is typed {:corrupt_certfile, path, reason}; bandit_opts raises typed ArgumentError (lens-6 cycle-2 pin)" do
      cert = Path.join(System.tmp_dir!(), "smalt-tp-l6-cert-#{:rand.uniform(1_000_000)}.pem")
      key = Path.join(System.tmp_dir!(), "smalt-tp-l6-key-#{:rand.uniform(1_000_000)}.pem")
      prev_tls = Application.get_env(:smalt, :tls)

      try do
        # Baseline: valid pair on disk (generated once, then mutated per cell).
        :ok = Smalt.TLS.write_dev_cert(cert, key)

        for {mutate, expect} <- [
              {fn -> File.write!(cert, "-----BEGIN CERTIFICATE-----\nTRUNCATEDGARBAGE\n") end,
               :unparseable_cert},
              {fn -> File.write!(key, "not a pem at all\n") end, :unparseable_key},
              # lens-8 cycle-2: empty key file — safe_pem_decode returns
              # {:ok, []} (not :error); this cell crashed WithClauseError
              # before the typed catch-all landed in validate_certfile_pair.
              {fn -> File.write!(key, "") end, :unparseable_key},
              {fn -> File.write!(cert, "") end, :unparseable_cert}
            ] do
          # fresh valid pair per cell, then corrupt exactly one file
          :ok = Smalt.TLS.write_dev_cert(cert, key)
          mutate.()

          SmaltTest.Env.put_restored(tls_certfile: cert)
          SmaltTest.Env.put_restored(tls_keyfile: key)

          assert {:error, {:corrupt_certfile, ^cert, ^expect}} = Smalt.TLS.ensure_dev_cert()

          try do
            Smalt.TLS.bandit_opts(Smalt.EgressRouter, 0)
            flunk("bandit_opts must fail closed on corrupt explicit certfiles")
          rescue
            e in ArgumentError ->
              assert String.contains?(Exception.message(e), "corrupt_certfile"),
                     "typed reason missing from bandit_opts raise: #{Exception.message(e)}"
          end
        end
      after
        File.rm(cert)
        File.rm(key)
        if prev_tls == nil do
          Application.delete_env(:smalt, :tls)
        else
          Application.put_env(:smalt, :tls, prev_tls)
        end
      end
    end

    test "verify/1 error shapes stay within the documented set over a hostile rotation corpus (lens-6 cycle-3 pin)" do
      {:ok, env} = TrustProfile.new(subject: "shape-pin")
      {:ok, base} = TrustProfile.sign(env)
      assert {:ok, _} = TrustProfile.verify(base)

      h0 =
        base
        |> String.split(".", parts: 2)
        |> hd()
        |> then(fn s -> Jason.decode!(Base.url_decode64!(s, padding: false)) end)

      p0 =
        base
        |> String.split(".")
        |> Enum.fetch!(1)
        |> then(fn s -> Jason.decode!(Base.url_decode64!(s, padding: false)) end)

      hostile = fn ->
        Enum.random([0, -1, 1.5, true, false, nil, [], %{"x" => 1}, String.duplicate("A", 64)])
      end

      allowed = [
        :invalid_token,
        :bad_signature,
        :invalid_json,
        :invalid_base64,
        :unknown_key_id,
        :bad_alg,
        :expired,
        :not_yet_valid
      ]

      b64j = fn m -> Base.url_encode64(Jason.encode!(m), padding: false) end

      for _ <- 1..300 do
        which = Enum.random([:alg, nil])

        h =
          if which,
            do: Map.put(h0, "alg", hostile.()),
            else: Map.drop(h0, ["alg"])

        p =
          Enum.random([
            Map.put(p0, Enum.random(Map.keys(p0)), hostile.()),
            Map.delete(p0, Enum.random(Map.keys(p0)))
          ])

        token = b64j.(h) <> "." <> b64j.(p) <> ".eA"

        case TrustProfile.verify(token) do
          {:ok, _} ->
            :ok

          {:error, r} ->
            assert r in allowed or match?({:bad_alg, _}, r) or match?({:malformed_envelope, _}, r),
                   "off-spec verify error shape: #{inspect(r)}"
        end
      end
    end

    test "current_config/0 reflects application environment" do
      old = Application.get_env(:smalt, :auth_mode)
      SmaltTest.Env.put_restored(auth_mode: :anonymous)

      assert %{auth_mode: :anonymous, tls: tls, sb_shared_key: sk} = Deployment.current_config()
      assert tls in [true, false, :auto]
      assert sk == Application.get_env(:smalt, :sb_shared_key)

      if old,
        do: Application.put_env(:smalt, :auth_mode, old),
        else: Application.delete_env(:smalt, :auth_mode)
    end
  end

  describe "Oracle battery (:oracle tier, lens-5 promotion of lane scratch)" do
    @describetag :oracle

    # Compact version of tmp/tp_oracle10k.exs's generator (same shape
    # distribution, fixed seed). 1k docs keeps the in-suite tier subsecond;
    # the 10k/20k scratch battery remains the deep stratum.
    defp oracle_doc(i) do
      :rand.seed(:exsss, {91, i, 5})

      case rem(i, 5) do
        0 ->
          %{oracle_key() => oracle_string(1 + :rand.uniform(8))}

        1 ->
          %{oracle_key() => oracle_number(), oracle_key() => :rand.uniform(1000)}

        2 ->
          %{
            oracle_key() => %{oracle_key() => oracle_string(4)},
            oracle_key() => [oracle_string(3)]
          }

        3 ->
          %{oracle_key() => for(_ <- 1..:rand.uniform(6), do: oracle_leaf())}

        _ ->
          %{oracle_key() => oracle_leaf(), "idx" => i}
      end
    end

    defp oracle_corpus(n) do
      # Deterministic adversarial prefix: the UTF-16 vs UTF-8 sort divergence
      # pairs (U+E000..U+FFFF vs astral) must co-occur in single maps so the
      # mutation arm can never pass vacuously. Without these, random
      # co-occurrence in a 1k corpus is <1 expected map — witnessed cycle-2
      # (mutation arm passed vacuously, court caught it).
      adversarial = [
        %{"￿" => 1, "􀀀" => 2},
        %{"\u{10FFFF}" => 1, "￿" => 2},
        %{"a" => %{"￿" => 1, "􀀀" => 2, "é" => 3}},
        %{"﻿" => 1, "￿" => 2, "􀀀" => 3, "😀" => 4},
        %{"k😀" => 1, "k￿" => 2}
      ]

      adversarial ++ Enum.map(1..n, &oracle_doc/1)
    end

    defp ours_from(docs) do
      for d <- docs do
        case TrustProfile.jcs(d) do
          {:ok, s} -> s
          {:error, r} -> ":refused:#{inspect(r)}"
        end
      end
    end

    defp oracle_key do
      case :rand.uniform(6) do
        1 -> for(_ <- 1..:rand.uniform(4), do: <<:rand.uniform(0x7F)>>) |> IO.iodata_to_binary()
        2 -> "k" <> Integer.to_string(:rand.uniform(1000))
        3 -> Enum.random(["a", "ab", "abc", "abd", "b", "A", "Z", "~", "0"])
        4 -> Enum.random(["é", "é", "ü", "日", "😀", "￿", "􀀀"])
        5 -> Enum.random(["x", "q\t", "z\n", "back\\slash", "quote\"q"])
        _ -> Enum.random(["ae", "aeb", "á", "ß", "s", "ss", "ﬁ", "f"])
      end
    end

    defp oracle_string(len) do
      for _ <- 1..len do
        case :rand.uniform(4) do
          1 ->
            <<?a + :rand.uniform(26) - 1>>

          2 ->
            <<:rand.uniform(0x7FF)::utf8>>

          3 ->
            c = :rand.uniform(0xFFFF - 0x800) + 0x800
            c = if c in 0xD800..0xDFFF, do: c + 0x800, else: c
            <<c::utf8>>

          _ ->
            Enum.random([" ", "F", "", "\"", "\\"])
        end
      end
      |> IO.iodata_to_binary()
    end

    defp oracle_number do
      case :rand.uniform(5) do
        1 -> :rand.uniform(9_007_199_254_740_992) - 1
        2 -> -(:rand.uniform(9_007_199_254_740_992) - 1)
        3 -> Enum.random([0, 1, -1, 9_007_199_254_740_952, 9_007_199_254_740_953])
        4 -> (:rand.uniform(20000) - 10000) * :math.pow(10, :rand.uniform(30) - 15)
        _ -> (:rand.uniform(2_000_000) - 1_000_000) / 1000.0
      end
    end

    defp oracle_leaf do
      case :rand.uniform(4) do
        1 -> oracle_string(3)
        2 -> :rand.uniform(2_000_000)
        3 -> (:rand.uniform(20000) - 10000) / 100.0
        _ -> Enum.random([true, false, nil])
      end
    end

    defp simple(v) when is_binary(v), do: elem(TrustProfile.jcs(v), 1)
    defp simple(v) when is_integer(v), do: Integer.to_string(v)
    defp simple(v) when is_float(v), do: elem(TrustProfile.jcs(v), 1)
    defp simple(v) when is_list(v), do: "[" <> Enum.map_join(v, ",", &simple/1) <> "]"
    defp simple(true), do: "true"
    defp simple(false), do: "false"
    defp simple(nil), do: "null"

    defp simple(%{} = m),
      do:
        "{" <>
          Enum.map_join(m, ",", fn {k, x} -> elem(TrustProfile.jcs(k), 1) <> ":" <> simple(x) end) <>
          "}"

    defp run_node_oracle(docs_jsonl) do
      path =
        Path.join(
          System.tmp_dir!(),
          "tp_suite_oracle_#{System.unique_integer([:positive])}.jsonl"
        )

      File.write!(path, docs_jsonl)

      try do
        {out, 0} = System.cmd("node", ["test/support/tp_oracle/tp_oracle.js", path])
        String.split(out, "\n", trim: true)
      after
        File.rm(path)
      end
    end

    defp run_python_oracle(docs_jsonl) do
      path =
        Path.join(
          System.tmp_dir!(),
          "tp_suite_oracle_py_#{System.unique_integer([:positive])}.jsonl"
        )

      File.write!(path, docs_jsonl)

      try do
        {out, 0} =
          System.cmd("sh", ["-c", "python3 test/support/tp_oracle/tp_oracle2.py < " <> path])

        String.split(out, "\n", trim: true)
      after
        File.rm(path)
      end
    end

    @tag :oracle
    test "V8 oracle parity over seeded 1k corpus; utf8-sort mutation must disagree (promoted from tmp/tp_oracle10k.exs)" do
      docs = oracle_corpus(1_000)
      jsonl = Enum.map_join(docs, "\n", &Jason.encode!/1)
      oracle = run_node_oracle(jsonl)
      ours = ours_from(docs)
      assert length(oracle) == length(ours)

      comparable =
        Enum.zip(ours, oracle)
        |> Enum.reject(fn {a, _} -> String.starts_with?(a, ":refused:") end)

      assert length(comparable) >= 900, "expected mostly-comparable corpus"
      mismatches = Enum.filter(comparable, fn {a, b} -> a != b end)
      assert mismatches == []

      # non-vacuity: a UTF-8-byte-order key sort must disagree with the oracle
      utf8_sorted =
        for d <- docs do
          case d do
            %{} = m ->
              "{" <>
                Enum.map_join(Enum.sort(m), ",", fn {k, v} ->
                  elem(TrustProfile.jcs(k), 1) <> ":" <> simple(v)
                end) <> "}"

            d ->
              simple(d)
          end
        end

      dis = Enum.zip(utf8_sorted, oracle) |> Enum.count(fn {a, b} -> a != b end)
      assert dis > 0, "utf8-sort mutation agreed with oracle — court vacuous"
    end

    @tag :oracle
    test "CPython oracle parity over seeded 1k corpus; utf8-sort mutation must disagree (promoted from tmp/tp_oracle2.exs)" do
      docs = oracle_corpus(1_000) |> Enum.map(&drop_floats/1)
      jsonl = Enum.map_join(docs, "\n", &Jason.encode!/1)
      oracle = run_python_oracle(jsonl)
      ours = ours_from(docs)
      assert length(oracle) == length(ours)

      comparable =
        Enum.zip(ours, oracle)
        |> Enum.reject(fn {a, _} -> String.starts_with?(a, ":refused:") end)

      assert length(comparable) >= 900
      mismatches = Enum.filter(comparable, fn {a, b} -> a != b end)
      assert mismatches == []

      utf8_sorted =
        for d <- docs do
          case d do
            %{} = m ->
              body =
                m
                |> Enum.sort(fn {a, _}, {b, _} -> a <= b end)
                |> Enum.map_join(",", fn {k, v} ->
                  elem(TrustProfile.jcs(k), 1) <> ":" <> simple(v)
                end)

              "{" <> body <> "}"

            d ->
              simple(d)
          end
        end

      dis = Enum.zip(utf8_sorted, oracle) |> Enum.count(fn {a, b} -> a != b end)
      assert dis > 0, "utf8-sort mutation agreed with the CPython oracle — court vacuous"
    end

    defp drop_floats(d) when is_float(d), do: 0
    defp drop_floats(d) when is_list(d), do: Enum.map(d, &drop_floats/1)
    defp drop_floats(%{} = m), do: Map.new(m, fn {k, v} -> {k, drop_floats(v)} end)
    defp drop_floats(d), do: d

    @tag :oracle
    test "deep-nesting stack safety: 50k list / 20k map depth ok (reduced-depth pin of tmp/tp_stack_safety.exs, which witnesses 500k/200k)" do
      assert {:ok, s} = TrustProfile.jcs(List.duplicate(1, 50_000))
      assert String.length(s) == 100_001

      deep_map = Enum.reduce(1..20_000, 1, fn _, acc -> %{"k" => acc} end)
      assert {:ok, s2} = TrustProfile.jcs(deep_map)
      assert String.length(s2) == 120_001
    end

    @tag :oracle
    test "oracle toolchain is present (guards the tier against silent env drift)" do
      assert {_, 0} = System.cmd("sh", ["-c", "command -v node >/dev/null"])
      assert {_, 0} = System.cmd("sh", ["-c", "command -v python3 >/dev/null"])
      assert File.regular?("test/support/tp_oracle/tp_oracle.js")
      assert File.regular?("test/support/tp_oracle/tp_oracle2.py")
    end
  end

  ## Helpers

  defp now, do: System.system_time(:second)

  # IEEE-754 single-ulp neighbors (lens-3 numedge pins). Reinterpretation of
  # finite bit patterns only — the NaN pattern is unrepresentable (see the
  # non-finite pin above), which is exactly what `:nomatch` documents.
  defp next_up(x) when x < 0.0, do: -next_down_pos(-x)
  defp next_up(+0.0), do: 5.0e-324
  defp next_up(x), do: next_up_pos(x)

  defp next_down(x) when x < 0.0, do: -next_up_pos(-x)
  defp next_down(+0.0), do: -5.0e-324
  defp next_down(x), do: next_down_pos(x)

  defp next_up_pos(x) do
    bits = float_bits(x)

    if bits >= 0x7FEFFFFFFFFFFFFF, do: x, else: from_bits(bits + 1)
  end

  defp next_down_pos(x) do
    bits = float_bits(x)
    if bits <= 1, do: +0.0, else: from_bits(bits - 1)
  end

  defp float_bits(x) do
    <<b::unsigned-integer-size(64)>> = <<x::float-size(64)>>
    b
  end

  defp from_bits(bits) do
    bytes = :binary.encode_unsigned(bits)
    bytes = String.duplicate(<<0>>, 8 - byte_size(bytes)) <> bytes
    <<f::float-size(64)>> = bytes
    f
  end

  # Reinterprets 8 bytes as a float; returns :nomatch when the bit pattern is
  # not a representable Erlang float (e.g. NaN).
  defp reinterpret_float(bits) do
    try do
      <<f::float-size(64)>> = bits
      f
    rescue
      _ -> :nomatch
    end
  end
end
