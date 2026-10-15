defmodule Smalt.TrustProfile do
  @moduledoc """
  Cryptographic trust profiles for Smalt receipt signing, adapted from the
  `affidavit-trust-plane-pack` (CryptoProfile classical|hybrid|pqc,
  SignatureEnvelope structure, JCS/RFC 8785 canonicalization).

  ## Honest standing

  * `:classical` — REAL and tested: RSA-2048/RS256 (the `receipt_signer`
    substrate) over a canonical `SignatureEnvelope`. The pack's Ed25519 path
    has no Smalt counterpart; the classical profile here is RS256 only, stated
    as such. No PQC is faked.
  * `:hybrid`, `:pqc` — typed refusals (`{:refused, :PQC_NOT_PROVISIONED, _}`).
    The pack's ML-DSA-65 is aspirational upstream; here the typed refusal IS
    the integration of the profile scaffolding. When a real ML-DSA
    implementation is provisioned, `profile/1` admits it and nothing else in
    this module changes.

  ## Canonicalization (JCS, RFC 8785 subset)

  `Smalt.Security.ReceiptSigner` signs the `Jason.encode!` of the claims map.
  Jason emits map keys in Erlang term order (byte order for UTF-8 binaries)
  with Jason's escaping/number formatting — a *sorted-key JSON* form, close to
  but not exactly JCS (JCS sorts by UTF-16 code units and mandates ECMAScript
  number formatting). Rather than touch the existing signer, this module owns
  a JCS-subset canonicalizer and pins the difference in `jcs/1`; envelope
  signing here uses JCS bytes. For envelope documents built by this module
  (ASCII keys, integer numbers, escaped-string values) the two forms agree,
  which the test suite pins.

  JCS subset implemented, stated honestly:

  * Strings, objects, arrays, `null`, booleans: conformant. Object keys sort by
    UTF-16 code units (RFC 8785 §3.2.3). Escaping per §3.2.2.2: `"` `\\` and
    C0 controls only, `\\b \\t \\n \\f \\r` shorthands, lowercase `\\u00xx`
    otherwise, everything else literal.
  * Numbers (§3.2.2.3): integers with `|n| <= 2^53` emitted as integers.
    Integers beyond 2^53 are REFUSED (not I-JSON doubles). Floats: integral
    floats with `|f| < 1e21` render in integer notation (`-0.0` → `0`);
    otherwise ECMAScript-style shortest round-trip via `Float.to_string/1`
    (which yields e.g. `1.0e-7`-style scientific form); non-finite floats are
    refused. This covers the RFC 8785 Appendix B integer/string/object cases
    exercised in tests; full IEEE-754 double formatting is NOT claimed.
  """

  @envelope_version "ctp-envelope-v1"
  @canonicalization "JCS-RFC8785-subset"
  @domain_tag "smalt:trust-profile:v1"

  alias __MODULE__.Digest

  @type crypto_profile :: :classical | :hybrid | :pqc
  @type refused ::
          {:refused, :PQC_NOT_PROVISIONED | :HYBRID_NOT_PROVISIONED, String.t()}

  @doc "Envelope version emitted by this module."
  @spec envelope_version() :: String.t()
  def envelope_version, do: @envelope_version

  @doc "Canonicalization identity for envelope bytes."
  @spec canonicalization() :: String.t()
  def canonicalization, do: @canonicalization

  @doc "Domain-separation tag mixed into every signing pre-image."
  @spec domain_tag() :: String.t()
  def domain_tag, do: @domain_tag

  @doc """
  Resolves a CryptoProfile. `:classical` is real (RS256); `:hybrid`/`:pqc`
  return a typed refusal — the pack's ML-DSA-65 is aspirational and Smalt
  does not fake PQC.
  """
  @spec profile(crypto_profile()) ::
          {:ok, %{
            required(:profile) => :classical,
            required(:algorithms) => [String.t()],
            required(:canonicalization) => String.t(),
            required(:envelope_version) => String.t(),
            required(:provisioned) => boolean
          }}
          | refused()
  def profile(:classical) do
    {:ok,
     %{
       profile: :classical,
       algorithms: ["RS256"],
       canonicalization: @canonicalization,
       envelope_version: @envelope_version,
       provisioned: true
     }}
  end

  def profile(:hybrid), do: refusal(:HYBRID_NOT_PROVISIONED)
  def profile(:pqc), do: refusal(:PQC_NOT_PROVISIONED)

  @doc """
  Builds a `SignatureEnvelope` struct (pack structure: version, algorithm,
  key_id, profile, policy/revocation epochs, generation, 16-byte nonce,
  not_before/expires_at, 32-byte subject digest, audience).

  * `:nonce` defaults to 16 fresh random bytes.
  * `:not_before` defaults to now; `:expires_at` defaults to now + `:ttl`
    (default 300s).
  * `:key_id` defaults to the fingerprint of the active signing key.
  """
  defstruct [
    :version,
    :algorithm,
    :key_id,
    :profile,
    :policy_epoch,
    :revocation_epoch,
    :generation,
    :nonce,
    :not_before,
    :expires_at,
    :subject_digest,
    :audience
  ]

  @type t :: %__MODULE__{
          version: String.t(),
          algorithm: String.t(),
          key_id: String.t(),
          profile: :classical,
          policy_epoch: non_neg_integer,
          revocation_epoch: non_neg_integer,
          generation: non_neg_integer,
          nonce: binary,
          not_before: non_neg_integer,
          expires_at: non_neg_integer,
          subject_digest: binary,
          audience: String.t()
  }

  @spec new(keyword) :: {:ok, t()} | refused()
  def new(opts) when is_list(opts) do
    case Keyword.fetch(opts, :subject) do
      {:ok, subject} ->
        case Keyword.get(opts, :profile, :classical) do
          :classical ->
            now = System.system_time(:second)
            ttl = Keyword.get(opts, :ttl, 300)

            {:ok,
             %__MODULE__{
               version: @envelope_version,
               algorithm: "RS256",
               key_id: Keyword.get(opts, :key_id, key_id()),
               profile: :classical,
               policy_epoch: Keyword.get(opts, :policy_epoch, 0),
               revocation_epoch: Keyword.get(opts, :revocation_epoch, 0),
               generation: Keyword.get(opts, :generation, 0),
               nonce: Keyword.get(opts, :nonce, :crypto.strong_rand_bytes(16)),
               not_before: Keyword.get(opts, :not_before, now),
               expires_at: Keyword.get(opts, :not_before, now) + ttl,
               subject_digest: Digest.sha256(subject),
               audience: Keyword.get(opts, :audience, "smalt")
             }}

          prof ->
            profile(prof) |> refusal_from()
        end

      :error ->
        raise ArgumentError, "Smalt.TrustProfile.new/1 requires :subject"
    end
  end

  @doc """
  Signs the envelope's canonical document with RS256 (RSA-SHA256 over the
  JCS bytes of the domain-separated envelope document). The algorithm, key id
  and nonce live INSIDE the signed bytes (RFC-SA2A-007-errata E-E): they can
  never be carried outside the signature.

  Returns `{:ok, jws_compact_string}`.
  """
  @spec sign(t()) :: {:ok, String.t()} | refused()
  def sign(%__MODULE__{profile: :classical} = envelope) do
    header = %{"alg" => "RS256", "typ" => @envelope_version, "kid" => envelope.key_id}

    payload = %{
      "version" => envelope.version,
      "algorithm" => envelope.algorithm,
      "key_id" => envelope.key_id,
      "profile" => "classical",
      "policy_epoch" => envelope.policy_epoch,
      "revocation_epoch" => envelope.revocation_epoch,
      "generation" => envelope.generation,
      "nonce" => Digest.hex(envelope.nonce),
      "not_before" => envelope.not_before,
      "expires_at" => envelope.expires_at,
      "subject_digest" => Digest.hex(envelope.subject_digest),
      "audience" => envelope.audience,
      "domain_tag" => @domain_tag
    }

    with :ok <- epoch_sanity(envelope),
         {:ok, payload_jcs} <- jcs(payload) do
      header_json = jcs!(header)
      signing_input = Base.url_encode64(header_json, padding: false) <> "." <> Base.url_encode64(payload_jcs, padding: false)
      sig = :public_key.sign(signing_input, :sha256, private_key())
      {:ok, signing_input <> "." <> Base.url_encode64(sig, padding: false)}
    end
  end

  def sign(%__MODULE__{profile: prof}), do: profile(prof) |> refusal_from()

  @doc """
  Verifies an envelope JWS: splits, checks the header `alg` is exactly
  `"RS256"` (alg-confusion safe), verifies the RSA signature over the exact
  signing input, decodes the payload, and re-checks the payload-declared
  algorithm/profile against the header (E-E: nothing trusted from outside the
  signed bytes except the public key itself).
  """
  @spec verify(String.t()) ::
          {:ok, map()} | {:error, :invalid_token | :bad_signature | {:bad_alg, term} | :expired}
  def verify(token) when is_binary(token) do
    with {:ok, header, payload, signing_input, sig} <- split(token),
         :ok <- check_alg(header),
         :ok <- check_rsa(signing_input, sig),
         :ok <- cross_check(header, payload),
         :ok <- check_time(payload) do
      {:ok, payload}
    end
  end

  def verify(_), do: {:error, :invalid_token}

  ## JCS canonicalization (RFC 8785 subset) — see moduledoc.

  @doc """
  RFC 8785 (JCS) canonical JSON of a decoded-JSON-shaped value. Refuses,
  typed: integers with `|n| > 2^53` and non-finite floats.
  """
  @spec jcs(term) :: {:ok, String.t()} | {:error, {:non_canonical_number, term} | {:bad_json_value, term}}
  def jcs(value)

  def jcs(nil), do: {:ok, "null"}
  def jcs(true), do: {:ok, "true"}
  def jcs(false), do: {:ok, "false"}
  def jcs(v) when is_integer(v), do: canonical_integer(v)
  def jcs(v) when is_float(v), do: canonical_float(v)

  def jcs(v) when is_binary(v), do: {:ok, escape_string(v)}

  def jcs(v) when is_list(v) do
    {:ok, "[" <> Enum.map_join(v, ",", &jcs!/1) <> "]"}
  rescue
    _ -> {:error, {:bad_json_value, v}}
  end

  def jcs(v) when is_map(v) do
    with {:ok, pairs} <- sorted_pairs(v) do
      {:ok,
       "{" <> Enum.map_join(pairs, ",", fn {k, vj} -> escape_string(k) <> ":" <> vj end) <> "}"}
    end
  end

  def jcs(other), do: {:error, {:bad_json_value, other}}

  defp jcs!(value) do
    case jcs(value) do
      {:ok, s} -> s
      {:error, reason} -> raise ArgumentError, "jcs: #{inspect(reason)}"
    end
  end

  defp sorted_pairs(map) do
    {:ok,
     map
     |> Enum.map(fn
       {k, _} = pair when is_binary(k) -> pair
       {k, _} -> raise {:bad_json_value, k}
     end)
     |> Enum.sort_by(fn {k, _} -> :unicode.characters_to_binary(k, :utf8, :utf16) end)
     |> Enum.map(fn {k, val} -> {k, jcs!(val)} end)}
  rescue
    _ -> {:error, {:bad_json_value, map}}
  end

  defp canonical_integer(n) when abs(n) <= 9_007_199_254_740_952, do: {:ok, Integer.to_string(n)}
  defp canonical_integer(n), do: {:error, {:non_canonical_number, n}}

  defp canonical_float(f) do
    cond do
      not is_float(f) -> {:error, {:non_canonical_number, f}}
      f == 0.0 -> {:ok, "0"}
      abs(f) < 1.0e21 and abs(f) >= 1.0e-6 ->
        # fixed notation: integer-valued floats lose the trailing ".0" per ECMAScript
        if f == trunc(f) do
          {:ok, Float.to_string(f) |> String.trim_trailing(".0")}
          # fallback for values whose shortest form still needs a fraction
        else
          {:ok, scientific_min(f)}
        end

      true ->
        {:ok, scientific_min(f)}
    end
  end

  defp scientific_min(f), do: Float.to_string(f)

  defp escape_string(s) when is_binary(s) do
    "\"" <> Enum.map_join(String.graphemes(s), "", fn
      "\"" -> "\\\""
      "\\" -> "\\\\"
      "\b" -> "\\b"
      "\t" -> "\\t"
      "\n" -> "\\n"
      "\f" -> "\\f"
      "\r" -> "\\r"
      g ->
        case g do
          <<c::utf8>> when c < 0x20 -> "\\u" <> hex4(c)
          _ -> g
        end
    end) <> "\""
  end

  defp hex4(c) do
    c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
  end

  ## Envelope internals

  defp epoch_sanity(%__MODULE__{not_before: nb, expires_at: ea})
       when is_integer(nb) and is_integer(ea) and ea > nb,
       do: :ok

  defp epoch_sanity(_), do: {:error, {:malformed_envelope, :bad_epochs}}

  defp refusal_from({:ok, _} = ok), do: ok
  defp refusal_from({:refused, _, _} = r), do: r

  defp refusal(reason) do
    {:refused, reason,
     "profile not provisioned in Smalt: no real ML-DSA/hybrid implementation exists here; " <>
       "the typed refusal is the integration of the profile scaffolding (pack ML-DSA-65 is aspirational)"}
  end

  ## Crypto substrate (mirrors Smalt.Security.ReceiptSigner's key resolution)

  @key_ref {__MODULE__, :keypair}

  @doc "Public fingerprint (first 16 hex chars of SHA-256 over DER public key) of the active signing key."
  @spec key_id() :: String.t()
  def key_id do
    {_priv, pub} = keypair()
    der = :public_key.der_encode(:RSAPublicKey, pub)
    Digest.hex(:crypto.hash(:sha256, der)) |> binary_part(0, 16)
  end

  defp keypair do
    case :persistent_term.get(@key_ref, :missing) do
      :missing -> generate_and_cache()
      pair -> pair
    end
  end

  defp generate_and_cache do
    global_key = {__MODULE__, :keygen_lock}

    :global.trans({global_key, node()}, fn ->
      case :persistent_term.get(@key_ref, :missing) do
        :missing ->
          pair =
            case Application.get_env(:smalt, :receipt_signing_key) do
              %{private: priv_pem, public: pub_pem} ->
                {pem_decode(priv_pem), pem_decode(pub_pem)}

              _ ->
                priv = :public_key.generate_key({:rsa, 2048, 65_537})
                {priv, derive_public(priv)}
            end

          :persistent_term.put(@key_ref, pair)
          pair

        pair ->
          pair
      end
    end)
  end

  defp derive_public(key) when is_tuple(key) and elem(key, 0) == :RSAPrivateKey do
    :public_key.der_encode(:RSAPublicKey, {:RSAPublicKey, elem(key, 2), elem(key, 3)})
    |> then(&:public_key.der_decode(:RSAPublicKey, &1))
  end

  defp derive_public(%{modulus: m, publicExponent: e}) do
    :public_key.der_encode(:RSAPublicKey, {:RSAPublicKey, m, e})
    |> then(&:public_key.der_decode(:RSAPublicKey, &1))
  end

  defp pem_decode(pem) do
    pem |> :public_key.pem_decode() |> hd() |> :public_key.pem_entry_decode()
  end

  defp private_key do
    {priv, _} = keypair()
    priv
  end

  defp check_rsa(signing_input, sig) do
    {_, pub} = keypair()

    if :public_key.verify(signing_input, :sha256, sig, pub) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp check_alg(%{"alg" => "RS256"}), do: :ok
  defp check_alg(%{"alg" => other}) when is_binary(other), do: {:error, {:bad_alg, other}}
  defp check_alg(_), do: {:error, :bad_alg}

  # E-E: the header's alg/kid must match what the signed payload declares.
  defp cross_check(%{"alg" => alg, "kid" => kid}, %{"algorithm" => alg, "key_id" => kid}), do: :ok
  defp cross_check(_, _), do: {:error, {:bad_alg, :header_payload_mismatch}}

  defp check_time(%{"not_before" => nb, "expires_at" => ea}) when is_integer(nb) and is_integer(ea) do
    now = System.system_time(:second)

    cond do
      now < nb -> {:error, :not_yet_valid}
      now > ea -> {:error, :expired}
      true -> :ok
    end
  end

  defp check_time(_), do: {:error, {:malformed_envelope, :missing_epochs}}

  defp split(token) do
    case String.split(token, ".", parts: 3) do
      [h, p, s] ->
        with {:ok, header_bin} <- b64d(h),
             {:ok, payload_bin} <- b64d(p),
             {:ok, header} <- json(header_bin),
             {:ok, payload} <- json(payload_bin),
             {:ok, sig} <- b64d(s) do
          {:ok, header, payload, h <> "." <> p, sig}
        end

      _ ->
        {:error, :invalid_token}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  defp json(bin) do
    case Jason.decode(bin) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_json}
    end
  rescue
    _ -> {:error, :invalid_json}
  end

  defp b64d(s) do
    case Base.url_decode64(s, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :invalid_base64}
    end
  rescue
    _ -> {:error, :invalid_base64}
  end
end

defmodule Smalt.TrustProfile.Digest do
  @moduledoc false

  @spec sha256(term) :: binary
  def sha256(subject) when is_binary(subject), do: :crypto.hash(:sha256, subject)
  def sha256(subject), do: subject |> :erlang.term_to_binary() |> :crypto.hash(:sha256)

  @spec hex(binary) :: String.t()
  def hex(bin) when is_binary(bin) do
    bin
    |> Base.encode16(case: :lower)
  end
end
