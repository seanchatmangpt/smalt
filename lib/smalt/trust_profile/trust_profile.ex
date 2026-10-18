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
  * `:hybrid`, `:pqc` — typed refusals (`{:refused, :PQC_NOT_PROVISIONED, _}`) whenever the
    affidavit Wasm engine (`Smalt.Affidavit.WasmEngine`, started and healthy) is NOT running:
    no PQC is ever faked. When the engine IS running, `:pqc` is provisioned as an
    ENGINE-WITNESSED path: the profile/subject is sealed through
    `Smalt.Affidavit.Seal.admit_and_seal/2` (engine export `affi_admit_and_seal`, deontic
    modality 0x01 ACCEPT, tariff 0) over the real wasm artifact, and the returned CTRT token
    plus canonical `pqc_receipt` travel as the witness block inside signed envelopes. A
    `profile: "pqc"` payload without a well-formed, subject-bound witness never verifies
    (fail-closed both directions).
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
  * Numbers (§3.2.2.3): integers with `|n| <= 2^53 - 1` emitted as integers.
    Integers with `|n| >= 2^53` are REFUSED (not I-JSON doubles). Floats: integral
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
          {:refused, :PQC_NOT_PROVISIONED | :HYBRID_NOT_PROVISIONED | :UNKNOWN_PROFILE,
           String.t()}

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
  Resolves a CryptoProfile. `:classical` is real (RS256); `:hybrid` returns a
  typed refusal. `:pqc` refuses typed (`:PQC_NOT_PROVISIONED`) whenever the
  affidavit Wasm engine is not running — and returns a witness-backed
  provisioned profile when it is (engine-sealed CTRT witness block, modality
  0x01, tariff 0; see the moduledoc "Honest standing" section).
  """
  @spec profile(crypto_profile()) ::
          {:ok,
           %{
             required(:profile) => :classical | :pqc,
             required(:algorithms) => [String.t()],
             required(:canonicalization) => String.t(),
             required(:envelope_version) => String.t(),
             required(:provisioned) => boolean,
             optional(:witness) => map()
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

  def profile(:pqc) do
    case pqc_witness(@domain_tag) do
      {:ok, witness} ->
        {:ok,
         %{
           profile: :pqc,
           algorithms: ["ML-DSA-65"],
           canonicalization: @canonicalization,
           envelope_version: @envelope_version,
           provisioned: true,
           witness: witness
         }}

      :refused ->
        refusal(:PQC_NOT_PROVISIONED)
    end
  end

  @doc """
  Builds a `SignatureEnvelope` struct (pack structure: version, algorithm,
  key_id, profile, policy/revocation epochs, generation, 16-byte nonce,
  not_before/expires_at, 32-byte subject digest, audience).

  * `:nonce` defaults to 16 fresh random bytes.
  * `:not_before` defaults to now; `:expires_at` defaults to now + `:ttl`
    (default 300s).
  * `:key_id` defaults to the fingerprint of the active signing key.

  Malformed opts (non-binary subject, non-positive/non-integer ttl, non-integer
  epochs, non-binary nonce/key_id/audience) are refused typed:
  `{:error, {:malformed_envelope, :bad_opts}}` — never a crash.
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

  @spec new(keyword) :: {:ok, t()} | {:error, {:malformed_envelope, :bad_opts}} | refused()
  def new(opts) when is_list(opts) do
    case Keyword.fetch(opts, :subject) do
      {:ok, subject} ->
        case Keyword.get(opts, :profile, :classical) do
          :classical ->
            with :ok <- validate_opts(opts) do
              now = System.system_time(:second)
              ttl = Keyword.get(opts, :ttl, 300)
              not_before = Keyword.get(opts, :not_before, now)

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
                 not_before: not_before,
                 expires_at: not_before + ttl,
                 subject_digest: Digest.sha256(subject),
                 audience: Keyword.get(opts, :audience, "smalt")
               }}
            end

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
  @spec sign(t()) ::
          {:ok, String.t()}
          | {:error, {:malformed_envelope, :bad_fields | :bad_epochs}}
          | refused()
  def sign(%__MODULE__{profile: :classical} = envelope) do
    with :ok <- validate_envelope(envelope) do
      do_sign(envelope)
    end
  end

  # PQC engine-witness path: with the affidavit Wasm engine running, a :pqc
  # envelope signs over the RS256 substrate with the engine's CTRT seal
  # (modality 0x01, tariff 0) attached as the witness block. Without the
  # engine, the typed :PQC_NOT_PROVISIONED refusal is kept verbatim.
  def sign(%__MODULE__{profile: :pqc} = envelope) do
    with :ok <- validate_envelope(envelope),
         {:ok, witness} <- pqc_witness(envelope.subject_digest) do
      do_sign(envelope, witness)
    else
      :refused -> refusal(:PQC_NOT_PROVISIONED)
      {:error, _} = err -> err
    end
  end

  def sign(%__MODULE__{profile: prof}) do
    # Hand-built structs can carry any term in :profile (validate_envelope
    # checks the classical wire fields only). A non-atom or unknown atom must
    # refuse typed, not FunctionClauseError (witnessed: sign/1 on
    # profile: "str", trust-profile lens-8 cycle-3,
    # tmp/tp_construction_fuzz.exs).
    case prof do
      p when p in [:hybrid, :pqc] ->
        # :pqc is handled by the dedicated clause above; this arm now only
        # fires for :hybrid (typed refusal, unchanged).
        profile(p) |> refusal_from()

      other ->
        {:refused, :UNKNOWN_PROFILE,
         "profile must be :classical | :hybrid | :pqc, got #{inspect(other)}"}
    end
  end

  defp do_sign(envelope, witness \\ nil)

  defp do_sign(%__MODULE__{profile: :classical} = envelope, nil) do
    header = %{"alg" => "RS256", "typ" => @envelope_version, "kid" => envelope.key_id}
    payload = base_payload(envelope) |> Map.put("profile", "classical")
    jws(envelope, payload, header)
  end

  # PQC witness path: the signing substrate is RS256 (honest — we never claim
  # an ML-DSA signature over these bytes), while the engine-sealed CTRT token
  # rides inside the signed payload as the witness block.
  defp do_sign(%__MODULE__{profile: :pqc} = envelope, witness) when is_map(witness) do
    header = %{"alg" => "RS256", "typ" => @envelope_version, "kid" => envelope.key_id}

    payload =
      base_payload(envelope)
      |> Map.put("profile", "pqc")
      # Wire honesty: the payload declares the ACTUAL signing substrate
      # (RS256, so the E-E header/payload alg cross-check holds); the PQC
      # element is the engine witness, not the JWS signature algorithm.
      |> Map.put("algorithm", "RS256")
      |> Map.put("pqc_witness", witness)

    jws(envelope, payload, header)
  end

  defp base_payload(envelope) do
    %{
      "version" => envelope.version,
      "algorithm" => envelope.algorithm,
      "key_id" => envelope.key_id,
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
  end

  defp jws(envelope, payload, header) do
    with :ok <- epoch_sanity(envelope),
         {:ok, payload_jcs} <- jcs(payload),
         {:ok, header_json} <- jcs(header) do
      signing_input =
        Base.url_encode64(header_json, padding: false) <>
          "." <> Base.url_encode64(payload_jcs, padding: false)

      sig = :public_key.sign(signing_input, :sha256, private_key())
      {:ok, signing_input <> "." <> Base.url_encode64(sig, padding: false)}
    else
      # A hand-built struct can carry a wire string (audience/key_id) with
      # invalid UTF-8, or an epoch outside the 2^53 canonical-integer window:
      # jcs refuses, and that refusal must surface inside sign/1's @spec
      # vocabulary, not leak as a bare {:bad_json_value, _} /
      # {:non_canonical_number, _} (witnessed: sign(%{env | audience:
      # "ok" <> <<0xFF>>}) -> {:error, {:malformed_envelope, :bad_fields}},
      # trust-profile lens-9 cycle-3, tmp/tp_utf8_probe.exs).
      {:error, {:bad_json_value, _}} -> {:error, {:malformed_envelope, :bad_fields}}
      {:error, {:non_canonical_number, _}} -> {:error, {:malformed_envelope, :bad_fields}}
      {:error, {:malformed_envelope, :bad_epochs}} -> {:error, {:malformed_envelope, :bad_epochs}}
    end
  end

  @doc """
  Verifies an envelope JWS: splits, checks the header `alg` is exactly
  `"RS256"` (alg-confusion safe), verifies the RSA signature over the exact
  signing input, decodes the payload, and re-checks the payload-declared
  algorithm/profile against the header (E-E: nothing trusted from outside the
  signed bytes except the public key itself).
  """
  @spec verify(String.t()) ::
          {:ok, map()}
          | {:error,
             :invalid_token
             | :bad_signature
             | :invalid_json
             | :invalid_base64
             | :unknown_key_id
             | :bad_alg
             | {:bad_alg, term}
             | :expired
             | :not_yet_valid
             | {:malformed_envelope, :missing_epochs}}
  def verify(token) when is_binary(token) do
    with {:ok, header, payload, signing_input, sig} <- split(token),
         :ok <- check_alg(header),
         :ok <- check_key_id(payload),
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
  typed: integers with `|n| >= 2^53` and non-finite floats.
  """
  @spec jcs(term) ::
          {:ok, String.t()} | {:error, {:non_canonical_number, term} | {:bad_json_value, term}}
  def jcs(value)

  def jcs(nil), do: {:ok, "null"}
  def jcs(true), do: {:ok, "true"}
  def jcs(false), do: {:ok, "false"}
  def jcs(v) when is_integer(v), do: canonical_integer(v)
  def jcs(v) when is_float(v), do: canonical_float(v)

  def jcs(v) when is_binary(v) do
    # JCS input is I-JSON: strings are Unicode. A raw binary with invalid
    # UTF-8 is outside the domain — refuse typed. Silent byte-dropping (the
    # `for <<c::utf8 <- s>>` comprehension skips invalid sequences) produced
    # lossy, non-round-trippable "canonical" output AND a canonicalization
    # collision: two distinct envelopes (e.g. hostile :audience binaries
    # differing only in invalid bytes) signed to identical documents
    # (witnessed: jcs(<<0xFF>>) -> "\"\"", jcs("ok" <> <<0xFF>>) -> "\"ok\"",
    # trust-profile lens-9 cycle-3, tmp/tp_utf8_probe.exs).
    if String.valid?(v) do
      {:ok, escape_string(v)}
    else
      {:error, {:bad_json_value, v}}
    end
  end

  def jcs(v) when is_list(v) do
    with {:ok, parts} <-
           Enum.reduce_while(v, {:ok, []}, fn child, {:ok, acc} ->
             case jcs(child) do
               {:ok, s} -> {:cont, {:ok, [s | acc]}}
               {:error, _} = err -> {:halt, err}
             end
           end) do
      {:ok, "[" <> Enum.join(Enum.reverse(parts), ",") <> "]"}
    end
  end

  def jcs(v) when is_map(v) do
    with {:ok, pairs} <- sorted_pairs(v) do
      {:ok,
       "{" <> Enum.map_join(pairs, ",", fn {k, vj} -> escape_string(k) <> ":" <> vj end) <> "}"}
    end
  end

  def jcs(other), do: {:error, {:bad_json_value, other}}

  defp sorted_pairs(map) do
    entries =
      for {k, val} <- map do
        if is_binary(k) and String.valid?(k) do
          {k, val}
        else
          throw({:bad_json_value, k})
        end
      end

    sorted =
      Enum.sort_by(entries, fn {k, _} -> :unicode.characters_to_binary(k, :utf8, :utf16) end)

    Enum.reduce_while(sorted, {:ok, []}, fn {k, val}, {:ok, acc} ->
      case jcs(val) do
        {:ok, vj} -> {:cont, {:ok, [{k, vj} | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      error -> error
    end
  catch
    {:bad_json_value, k} -> {:error, {:bad_json_value, k}}
  end

  # 2^53 - 1, I-JSON / RFC 8785 §3.2.2.3
  @max_safe_integer 9_007_199_254_740_991

  defp canonical_integer(n) when abs(n) <= @max_safe_integer, do: {:ok, Integer.to_string(n)}
  defp canonical_integer(n), do: {:error, {:non_canonical_number, n}}

  defp canonical_float(f) do
    cond do
      not is_float(f) ->
        {:error, {:non_canonical_number, f}}

      f == 0.0 ->
        {:ok, "0"}

      # ECMAScript fixed notation window: 1e-6 <= |f| < 1e21
      abs(f) < 1.0e21 and abs(f) >= 1.0e-6 ->
        {:ok, shortest_fixed(f)}

      true ->
        {:ok, shortest_scientific(f)}
    end
  end

  # Shortest round-trip digits from Float.to_string/1, re-rendered in the form
  # ECMAScript Number::toString mandates for the fixed window (integral values
  # in plain integer notation — e.g. 1.0e16 -> "10000000000000000", not
  # "1.0e16" — and fractional values point-expanded, e.g. 1.2e-6 -> "0.0000012").
  defp shortest_fixed(f) do
    case Float.to_string(f) do
      fixed when is_binary(fixed) ->
        case String.split(fixed, "e") do
          [mantissa] ->
            trim_integral(mantissa)

          [mantissa, exp] ->
            {digits, int_len, neg} = expand_to_digits(mantissa)
            # strip trailing zeros of the digit string (right of the point):
            # e.g. "1.0e-6" digits "10" -> "1" so the output is "0.000001",
            # never "0.0000010"
            digits = String.trim_trailing(digits, "0")
            digits = if digits == "", do: "0", else: digits

            place_point({digits, int_len, neg}, String.to_integer(exp))
        end
    end
  end

  # ECMAScript scientific form: "1e+21", "1.5e-7", "-2.5e+20" — mantissa has a
  # single nonzero leading digit (no trailing ".0"), explicit sign on exponent.
  defp shortest_scientific(f) do
    case Float.to_string(f) do
      sci when is_binary(sci) ->
        case String.split(sci, "e") do
          [mantissa, exp] ->
            {digits, neg} = split_sign(mantissa)
            {int, frac} = split_dot(digits)
            frac = String.trim_trailing(frac, "0")

            mant =
              if frac == "",
                do: String.trim_leading(int, "0"),
                else: String.trim_leading(int, "0") <> "." <> frac

            expn = String.to_integer(exp)
            sign = if expn < 0, do: "-", else: "+"

            if(neg, do: "-", else: "") <> mant <> "e" <> sign <> Integer.to_string(abs(expn))

          [mantissa] ->
            trim_integral(mantissa)
        end
    end
  end

  defp trim_integral(mantissa) do
    case split_dot(mantissa) do
      {int, "0"} -> int
      {_int, _frac} -> mantissa
    end
  end

  # "1.5" -> {"15", 1}: digit string plus the count of digits left of the mantissa's point
  defp expand_to_digits(mantissa) do
    {digits, neg} = split_sign(mantissa)
    {int, frac} = split_dot(digits)
    {int <> frac, String.length(int), neg}
  end

  # digits * 10^(exp - (int_len-1)); the decimal point sits int_len + exp digits in
  defp place_point({digits, int_len, neg}, exp) do
    point = int_len + exp
    len = String.length(digits)

    body =
      cond do
        point <= 0 -> "0." <> String.duplicate("0", -point) <> digits
        point >= len -> String.pad_trailing(digits, point, "0")
        true -> String.slice(digits, 0, point) <> "." <> String.slice(digits, point, len - point)
      end

    if(neg, do: "-", else: "") <> body
  end

  defp split_sign(m), do: {String.trim_leading(m, "-"), String.starts_with?(m, "-")}
  defp split_dot(digits), do: String.split(digits, ".", parts: 2) |> list_pair()

  defp list_pair([a]), do: {a, ""}
  defp list_pair([a, b]), do: {a, b}

  # JCS string escaping operates on Unicode CODE POINTS (RFC 8785 §3.2.2.2),
  # never graphemes: grapheme clustering merges `"` or `\` with a following
  # combining mark into one grapheme, which used to fall to the catch-all and
  # be emitted RAW — dropping a required escape and yielding non-canonical,
  # even invalid, JSON (lens-2 cycle-3, 10000-doc node-oracle catch).
  defp escape_string(s) when is_binary(s) do
    "\"" <> for(<<c::utf8 <- s>>, into: "", do: escape_codepoint(c)) <> "\""
  end

  defp escape_codepoint(0x22), do: "\\\""
  defp escape_codepoint(0x5C), do: "\\\\"

  defp escape_codepoint(c) when c < 0x20 do
    case c do
      0x08 -> "\\b"
      0x09 -> "\\t"
      0x0A -> "\\n"
      0x0C -> "\\f"
      0x0D -> "\\r"
      _ -> "\\u" <> hex4(c)
    end
  end

  defp escape_codepoint(c), do: <<c::utf8>>

  defp hex4(c) do
    c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
  end

  ## Envelope internals

  # new/1 refuses typed instead of crashing on malformed opts (ttl: "x" used to
  # raise ArithmeticError at expires_at computation). Merged law includes the
  # store+graphlaw lane's minimal-unblock contribution: subject binary,
  # ttl positive integer.
  defp validate_opts(opts) do
    non_neg = fn k -> not Keyword.has_key?(opts, k) or (is_integer(opts[k]) and opts[k] >= 0) end
    integer = fn k -> not Keyword.has_key?(opts, k) or is_integer(opts[k]) end
    binary = fn k -> not Keyword.has_key?(opts, k) or is_binary(opts[k]) end
    ttl = Keyword.get(opts, :ttl, 300)
    ttl_ok = is_integer(ttl) and ttl > 0

    if is_binary(opts[:subject]) and ttl_ok and
         Enum.all?([
           integer.(:not_before),
           non_neg.(:policy_epoch),
           non_neg.(:revocation_epoch),
           non_neg.(:generation),
           binary.(:nonce),
           binary.(:key_id),
           binary.(:audience)
         ]) do
      :ok
    else
      {:error, {:malformed_envelope, :bad_opts}}
    end
  end

  # sign/1 refuses typed on hand-built structs whose fields violate the @type t
  # law (new/1 validates opts; the struct literal path bypassed it).
  defp validate_envelope(%__MODULE__{} = e) do
    if is_binary(e.version) and is_binary(e.algorithm) and is_binary(e.key_id) and
         is_binary(e.nonce) and is_binary(e.audience) and is_binary(e.subject_digest) and
         is_integer(e.policy_epoch) and e.policy_epoch >= 0 and
         is_integer(e.revocation_epoch) and e.revocation_epoch >= 0 and
         is_integer(e.generation) and e.generation >= 0 and
         is_integer(e.not_before) and is_integer(e.expires_at) do
      :ok
    else
      {:error, {:malformed_envelope, :bad_fields}}
    end
  end

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

  # -- PQC engine-witness path ----------------------------------------------

  # Engine availability is checked at call time (module loaded + named
  # process alive); the engine itself already failed closed on artifact
  # pin/import/export admission at start, so a running engine implies a
  # hash-verified artifact. Dynamic resolution keeps this module compiling
  # (and refusing typed) even before/without the WasmEngine lane's module.
  @pqc_engine Smalt.Affidavit.WasmEngine
  @pqc_seal Smalt.Affidavit.Seal

  defp engine_available? do
    match?({:module, _}, Code.ensure_loaded(@pqc_engine)) and
      match?({:module, _}, Code.ensure_loaded(@pqc_seal)) and
      is_pid(Process.whereis(@pqc_engine)) and
      Process.alive?(Process.whereis(@pqc_engine))
  end

  # ACVP ML-DSA-65 sigver KAT (NIST ACVP-Server ML-DSA-keyGen/signatureVerif
  # prompt, provenance pinned in affidavit fixtures; tcId with testPassed=true).
  # Proves the artifact's ML_DSA65 verify lane is REAL: the positive leg must
  # verify and a one-character tampered signature must flip to invalid.
  @ml_dsa65_kat_pk "86720c5fa190240ff983511c8da65e927adae446b663b8b3abf9a6216c3eab16a576ef6fb815989fc9d17bfb82c1aa10df0f7f0e9391f3886a538cb8bb78cef135ec0d44f880ff3984a80c33b3a5f32ab3ce6a88e251b25936acba499800c981b72e0264c60b335af64df62797fe53a5b8796949428b551899d2865044224b89769863d9c6e6dbbec3cf85e4163aa898e7825c2bf39b4950269fb4a276821cfc4a77c4726af9765de1988b161c5aa4268f60c942a816b30c455ebe1c2416d66eeee8ada865f120c67296bb799b0a58d08f8f2057732c10980d0931f476c6d74049e1dac0d547a75b48dc97779ee42d352e57b55b885f000399bf4870666f217fd5c6068a094c1cfc91a941c7a7a902ccf220239f54ff5ec056451891b18092a2e39f507f5ae4ef04960b63b491c855cc0bf64cea651a8c3ab0cf2e83293d14b3495fad64ea2c62ae9f5a8c2103e8d6272766a31529f869bc1e391078e9bff969561f7d56ed63a5c28d138cda69a83b93a6b6f24a13804cfea93dfa77fa8d59d881e23f0688f8315deb9d9876f9405fc910f48dddeb10091057ba5817749f19c866f9843e35ef8fa4092f09864bfbe4cd45e988ba77c9fb462f149ad43e7d744dad03d2879c75dd04c76d9bc4a5a20345cac4f3a42ba0e14749bc10633ec621e2ee8701e5738ed40234d2e4b72011087f218daaf6f7a0535f02a875d963fc6ce0fb687b72496240b6325799ad8a7dcb33950c4580a220c46490e8362b2032fc5adade85a244b6fff49637ef80a1167b4d5f1ed66e4d804f970849a1132c7e9a0dfa1da55db636c89a3612d691af2f3144b30b7eb6a7ad501f0561d2f8971cc4d66b158ec0c2086054024536c5453b6e058a045935801857b21b0e70d5a91f8a0f0e634a1f40908d8f4e251dfd301a7fc20ded777c2ee27d4944119958f0aae0cf86fac356d1f241a41c7f186c0615a0b1610b858c3ad53857d0debe8d89d8481abb086e8a069332e3a33222b65a25367fbd7a8234bc8ef1092abca80f29453e64d1a5e43c8abcb6bcf368ba9e067e686d438d8085719618b8c37ab5a3116ae41fe144395b551ffeae81d78efb0f9362a02a8ebba26405eedca4706ed8b474bb0b79071b4ba8e766c5b46bc52e8fdf34a4ab88b84a63eb8244e49a89a94dd2c5a7048f6a17277f6ffb5f3bb5d08f0a5fe601eaae080858a6073bf3645388421bec396e3d547fc66de8ebbac65aac2939acc15f6d81f114b237b68ab5226087a0bc6fc4aba68da26433ede7ce5bfc012eb7674cffe8fe4f8b3ade6facc2ef27b4f59f3eddf604415beb199639707b87d1b8e00d51ec0747fe260d6b4885fe5028a493d5615088627e5183500a456d3a647ac57d0ab96966b5fe7aaacf354c61530b6df9c477077384ec85161e012b3ae068d0b37de138174c6e6070817922ba044bdf1daa79818abdb45e297114a9226a827a4e21174f8c0b27907c314534f8074e7a71aa99fad2a0adaa7e87b40cd7e0581dd33c71ac0ed643abf3efa01c65e20a5380efb7213cbd86793299585f31b5df85f1f0cf605024eed16981b8d9f69d51b7625a2e154b5a279cf9bc2055e22dbbeee12d3f22d2534e176aa0f92364d264557b9b56254ca0bdaf7919bdca09a510e85d41745c7f3b1ec4d05ff5e1f1ad523ea1262577ee949d12c140cf0ef248e45ef902f0c735cbf36feec57d3d4b3925f85a12367f84f4cf00b58826972c5ea8eb8d19aac56654941be747c221f5d930df6ee6a32b7ed1b53c746bc875d761f22866c9be87e5125201fac82e9ff5581636e6344d82a62d470ecb29ca2bca5efecc0c9dc8a00242492513b047ecf7ec5de8d15b769d17f514139d0c8cf8ddade3beca44f0588489a869ca537cf76a55301706b8afcfffbd54c360e73c143506c0df52b32714790e87341d403fb4b4cbcea4eeb0b245be4829cbcf5f3f6bb68be9ad5fee52ef765a2ca2c1af5bbcedb0d82ea20cf41aa47dd4b639e14b1e699b351493edebf20f8c6c302ae2db61886c21ecf0e02380c6471c82543bb841356edc40b173b9459ac42a5f3042318f4e5ca84968d164ef4ad419bae3b23cba1e68a33579c260cb2b35f0f924c6fea20ec72250753ef166bdea02ad102268de3558fde33df8b42a19629f2cdde5fe4b9b92248de16f13de617a16b589d1c4f63268593004cd4e59dc152ada3c3822feb2d44b6294931df48b3d2b8d0a009e386854177872afb0f4028bc4a680ed8250b3dd8da76bf82a03233fc7ad3a022678cb8d87f6640dd74a50dd00d2407466095fe77fb22be521a3891693431ce32e9eeec1571aa5123913a7670ba9469e500a76a4e2a35710fa037e8c2f6442ca48baf905572d9d4d113ebae8ce459c80fc17e4ad40b19269114be8f294c994c9cfa00d467adff448d514a175f5a8a6ae8f9fba5c4edf90668278d08fb6969c17fe4c0f97a70b5ce5a0af982be5ca131af8152c3f34d85292f9ebd5a8a5688d6884b900564e59ef6b31e60f63497d0d3f4bcafab7d99c261b661507a672ad253e51380a5ec33a2d5f8292e5a385221021b66df37f3ef3b59b25f2cad9efa6dddaa013584fd42307dbe09f7bd90edc9db10ddae18d18b42ecf0d84e4d2fce0753e1e85bf36a2b0a72fcb7aaa9ac282fcdff50ea5932fe95ab9e0f928d0672b2726a732740a2ea6815344913d8033e996412febd59f9bc4b1e0eb97f668eff7ad74f3a4eaafdee1d07b25c6c57547b431db844c57eddd"
  @ml_dsa65_kat_msg "66a63fd89e4ac965583f64c7b73552ffd49a23b9ab139606357752c4eff45ced67f6d7e5326b7cd65a8e71f2fb3d9ccd2381c43e4f333c3d8c72431b2023f3c93260055303768198d872ede8512279789273e8e2be8e4e6d4ada5bb30354484776c31574b52e410c6382cc9da08718e726476f696b6a8c48d5bb824482e51ba5108d6f6a0a9fbf02dc544d4bd62328cc1ede991efa59d4e62d201475301d60b1cea3c1c85337c6bf656ac24050ba68e930b261e396e949d156c2a1d15f256c9f949d053f0d587e80c22f07432a2aa8cef1739a9dbdf44ed3e3ce21d2b788ee6daeed6af9885a5dcb4f1fd8e4bd2ca0779558594e921a8dff968e996a24ce9f9a13c570caa23e274ac22db84af3e5627c3946a1572202321fb80d37b0a420f9086accc91fa9d9bd36b07c51c539450cce3e3e8b1dd60a66dde41aa46075d7c713f2f19000b3a1bbc463786189e017395c6eac886c33ebf9facc7dc0659d21af110531dc73a27a7ac7aabe09d004325ba580428124e9cd45cf65327b2e6866836c4966bc3bbcb99eefd0713979ba5f2d47ab28cb218ef877c26d982d416a4b38e438c430327a06cd4b63101c618fb3679273e579a14abb317998364289050200edd3c82d22f2a12d25c915ddbf7210f8b02232436a390cad65e622d4a72c976140cf8e72886489c5b750b3adf721179c6cde6e216643cf7c455191abb8597dd8770dfed60e7dd71f4399863ab551fef692da2d25050e6e3fa69def5f83cd5e3e8b68fff518a97799037330d582761934b0147916970841760317808617da93746e09b1ce86ae0b0bf1c42d46857156262306391642cd473c3785a424b5695e30bab547d99d3c3be92bbbe4df4578fca73b35ef750b4d2ab5e24e0bc29837c7d6a472bf8119915c137c44646c832a8a42483d5b7c3f03a37937606afa4fb82e9027670acfbb44e497b22f79afc761164d485b7ac7c8ef3dae427ac5fe290f42f5f32bcd9a77d29ec204246b7db1e6f4fc5f940992ae22bcf50181a25a07e9bb1eac2a95bb5d76e151ed28e984e43f30e4d4cce7e42eef2089e72b1059248cebeda850bde2cbc9c946783881ceaba32012dbc6e6f2d7636e690d608426bc59896ff7942705510babbbbfbe489d592dea6b52cdb3aefbe282d0550fed77848805c0d5dafc950f72df8e75e1d55934c479fad809afc21a5f49f32a3777309a219c94187c61d228c274018fce0d44d6ad07cd408898211d1e3d36ac255884746e5c8326ac073b91b983702acce15895f51882bbec9ff7a4c34020b7f28bab339fcd7026a33aef30c2b9df7f3de45d3ef42937d08b2342df8326609b37fd4a9802ae0f2a1f4dbe2de90dde2e7f7acb23dc58b53d24aee1aef890736267d93ea1e85ff909083a96aa665b7f6cd23a70f689c874769e33f8fcb71764b6f72588697ab168ef7054eb51ce54701caa98c65c476a87f042b852514e6a5ef48b65fed77729049897b76110b8b72ef1844666150cf01bf5fc00927e4900a6d265a408fc45f56210aed24d636083f0d5379c51f53cc398946144ccda3ab36be41ac194a88c658dd53ca3d9a4857d39c9dacd32b5e4c193f94c9562d3cb9fb48777d2e09a4dcba2695135b6d0bde52ac3179779ee3ae3b7fb5ce1732fcedf0bf373968aaf41506054bc6c989bbcf0dbc0c430b2d692281e028222ebad1f5fd6ead173c098a6eff4c96e0b1759e53a1d478f938ea4c9dd66342f319f361acf60d3c67ed5da376a5453d57cb4f85c4e332258057d7f329c69a74df803fa42ca45220473a7195c754c0c12c0413384b42c332be2005ff264476e98324f8477671416af38ad89825f0459656fe4790a01d99d7c7b6157e1f55bb1fd2a7860ceb27cf73a4b345e52a8ae8d39e2554d16449810921e36f35e4e62e496ff3231ec3e3bbabcfabda2116cbcb26ec0a643d9f2b12f5b649f0a6d38f1f8ee46ca0e5b1d4de0262f3fc873f3753128a32c5047502b610e8e4e391e61eafcc33196869ee5569a10ed940553c0bdaa9ebd6b5735b52984cd68f4b2b85dcdba349388319d13ef94fb610570d4f8ca03400797ec1b1e8f4b62"
  @ml_dsa65_kat_sig "d31c1756b2edb80df4061c88eab9842bbd64e0e584ccb4233093929f12147c053209413fda3695dbc8a8bb53a951f23ad5c8ced4a069f23e7ef9a01dcc721c82d3c24041c2980eb9439bbee25ea53146511ab0579ce4b935b0950f0c367bd97dac8adfc6d4f63926c7adc8591bcdcc852e2e37aeea2362f8b88fe92254c73089a1af4cb06942bc22296ed34b1edeccab3d4de8b9c251d40013cc0f7d4dd0a6d23e4a6eaa74e5eaddee5645c71391b9da206feab5b9663b271186d8ba953ee8a2c7f8ac195de3dcd03b3b3f760f45325d85e6bcdc630a54b5886bd5aa9d6796d920f85fa982613bb0afdcfa95a6f10e207fb5a70c6ec7f33f48a7a99afb87aa2720a8d4ac5bc3cb2b2c687dbc812b720730a43b4b11dd270151f94b99e607aee35a2fbf8e7f2fa49a7d39f1501001690c1ccf3b1a0e5f88426a920f90493e8f0880c9a0b15475cce5f105592827d7ae19800e2f78435fb7465b3d5edd49496bff545510fc3775bae6d924b5c9fa8fcfee446162e301c8fcb103343018d275146ca47e0937ab3ef797ad09e090662a0d4adc90364ccd372180553bbd22fb956f7014c4cab240520623fdd262880eb6d5dbe5e912a4b96dc0647854928b01d2422a67231fa682f5475b0fdaab0c989d8bba182f160748cbf5dcaf478efed053af1f4703fb1c058123cfd008849e953ec17c98a85bf83ba8658237dfef0953d6f8f076c70ba52cfb1e498ff0d73cc1852133e6aa23a38ec77dc2766faebd5de83566fbb2c9b27cc32fe425e0751092a04ef21f331983e8338ebe17f0e5291b68ba69df27a8343204eae4ff7c36772b922840864325c30325b8143cce0885b8082beda9b1cb324deee3123245128e557146b8cb8ab8017e5ed3fa169a1368f32a43b5a666799cd98d4958e4debe865ed14d08f60d01f1eb9acf80a5087bbf12f4502d58c246cb805aee85e8cee22adfc65869840869e670c8f0d45c87d7fe8537fac9dc266b057f44dc36e358ad885da5e3c1c7b8f090a6025e10a23b1874fc2b69407cb15d9481641467e6d46b426e3d0028a5e7f5a6eb9345447c7c7943eabd9289df07e30ce2b76989013d42931e115c257a60f8a6b97bc0a9cf296c321c6b990255a16a4158266c1e88007ee9462a9387327d17a492daf95d222cadce02aceb1e3e2e9f4f392202b59a970c824ec2cd354b967b322df9ed821a87b601fd310f0450370825b69a2051aa4c3a6b119760208bebe323b148eeb4b83245befd8a5573b48def029713875aae5c7982d718da5bdf8a3f9674516a1d363ee46d8d2cda8acc6cf4d1abf4348e3ad2234b0c3c37f02e0745030c7a0fc08f82977c40d15399573bd976e379833317764f1c35f87b0517a046293d9c09d618ad1817fe7e7735b8a9fff12d37cad152c15d5cb6823a2cf3093b3629a1b8cd447bc7354ad9ce5320a1344940a4660a74db9e65136d5075d0a9d102407b67d227d1d8cf755996ecd8bbe8d01c58eb98bfaad8b0305f5e6051311851d71fc642a5a55335fd4dabd78a9d1fa9cb63f92b00da4f51e1d49fb152b3ae3f0de35977359e78c3a40dc6f85cd348858debddb5e208bbcb8caebb49b8f6a82dc3c0d1371146e71db07e493810f2fdc08ac9ff0208a117cec1bcf9a50391240692b5526d898062d855b0d6451c3868624acda87071db29de27728bdc5fae87f7b90ec3767748abd42f3dedeb41258937dffc15fd424b87221be9e84e410ee6d55348a6e0dc9b9f4664f493e1502d37f5c7a8b60f11c61705e9e38809a9a9a4abb8c655329b8c3946823bd3adaff78d457f05dc5c7d8488c3b56e93d61bcde222c00d22a46c207db445ec7f86a14f4b8445dc53fe9b94516496f2a6c6802fb007d87fd393d0b44402ebe0b2f2194cbe32885e21cefbd53cda1a9727ef3802bcedfd32912def13ae4be5f21acc02050c303e9540dbfb51fcf879783fd0d7ee250101acbcd1db2f155d505c19a4c06d5649a9d0bee759b24d2d3f327e15e0de68b499cba74148db4fedeaba91c97c88a02dcd30e0727d63b5366606f0772733efffb6fcf8f9cfee554f75ccea0bb365234b3832fbe1300176b2dcfb6eb65f0b6cd5824ec4961953048cfe904d2fcfce77bbeddaca65148af180c53354d458c2b51d0399cacca5705fc4fa2baf7c7352d2618c5e378c72d57782d54844d478fd855b18ee62e4a7b2540306fb52ae1c1a0e6e4f71d22ca8deb554c704d3dc1ff573c8c46a41abc60838da583d8e6cd445421fd2f2d57afa17682bbc95fd0245b1f1d4572c673e55f347a088efea0e156e077d6c7fd52eed21dd3b7f28f1af4049aa3e7ce35f3199a943aa0f22837c2f3a3a327f5155f0b56c04da8c317026330464b2e148a689166e8bef9dd840fc8b22c7f3b37cfe0849f5b0cea81e51a119b543445e81957a6428ef920f27fab6437dedf38a0add41d707b6aa28ba0fa09876338552f38d2a2378c45885e08cc18288f02867d7eaa8bb16f9e9bcf0de5b0e5c42f0560dfe9e0387633ca2bad2cfca6a9c67b0d97363d9ce3e4e6c3786c4023cda15651edf19e426bce2eef7044e908cd22f60a2d12e5c9492f5a71de86b8781acade59fe4f26291b73c69b8670cee4c1cae1127c7375f2125cc33b5c2538b2e02c66b0de876a07c29207af3fdaf394bea89b58ce1875c365ecd0220431c45d19b5eb5965a5a6a408159507943f246afc991630d23b2ca84541bd92d7eda19689c63048df0734f90d057f78cd6192ac19dedc229a15b72fa7a928d7c317ab7c45f41437fbc662281a1d0d799e5966b4c156b968c09012a627be4e8ccf432aeeb48f00a38febf930f286e407386d04d9371fdf4cd871933554ed8f3d8980e989764cc71737f9110052e0d5b20e4b1c285c0a6887ad7888919b6fe9b4f79e33476dfae62e5fd98860ab67026d754ca035bafa125d178320bb0ee4cd5864c86cc89ddc2aef474c90d9244de1233fe6df8b09312364826f2a27224663c811c012890c6bc67db909a3a0f9b671373ee921a432c5fa587b863ad764a6d721b022f4865a555f3bc54f564a0b73a7dfc16dc60ba50e7e85b0ede7e31fc21a9f126d1d437f90549cad54c480d925c22fc4615619c3bd8ba74d782aedb7f20124da48b7af1746de6f9e453a137768e495e44653dbef6881a0e2310fdebc8149be782885cd60134791d18371435e5291e9e20c334466598b300a6a57d841ffaa3d2990c478996b4cb599229172543ca6c3caf65947fb626205c085b501bd059682f52c25cdcec45121b9e688ff484f58559c0f4d7a8d1a03813e7205282636120972ca945c30dcf413ecb3aa9c87b8e88737eb2360e436809245dfdcd827d964bc527e96b9cf62aa103816c13c9368887f5893a9c0eda622388471cbb8311fe016855100c6ba0774ea2e3c174d0f9cc0e9a777c273a940f29d66b5e5253cae3a4e37527b67243e09e6b242b07995615bd1115ec7c8493471dc886b56df9c02a2bd2fb3588dd3e2c31c01f230a02ca3e247f5ef98557a97ac0faf1895c03f2be8c79063c990e706c6940ce36f4f839066ba67e6a684a5e72809a9783acb9db15974d291f93653f73106d3b228e498784eae305125981add4921556ee9e51e0d1fea5046f7a0c16d0dd53d57742f9c0c5457cd7194b366a962c59800417bd7675e8a6f67a4f00c9a0631d9b8828e2c8fb3a88d9d84edeae89cabda03562738239478ebf8ddc471cdc7f6a9be1b0ee42685bb4b1475330ba2c9059da3a4c361927fe6d2388e98cb34cbefc7a45ed40da8d4e6593cffe234d87d86997435b9c55c5e177979b509e673ddcea28df2a16085540d87d69695a4e23d88ff8c54d77a99d49c18b325978474d1d5ce1b3c77da4b8e5082bf499baf669f8cc29330691d01c8ac926e7e6fefe9eb0344815f5bce7fd5fb6401ca1f57cb4260e65c9a3d552c6eaf704a2995c490d69ca428e21301e99687178eff32b2bdd30b3ad89b6dfc0692617ac0621ec1c16ab247311213585f2d93b52847a029b4475aa1205135c5fcb3d55564144798917af5133336ea05865629383c3d1f194240397d73bacbecc215cf82895be7f195e35c3d9617fb1f9ec41050017b3449882c4985df25e7e68f11453d2fc1c57f367e26f59c63fe42a5d4ade44b6cb4486c9c76c59c50613a8d73b957640faf6dad3cdb95b68a235ba839f1f216a5eaabe1ce1017c6397b63f7975aad961791447777b12fd6939d3126200a84dad0807b4617c1e3866480d8340c21c736b560543c9dc371349f6a144995b5f52c94e2dc81b5d5be49a8e818fc3f28fb791d285d691c532dde515e664ea26a036f252d40d6559ce31a4009e1555131adf7b5ac849ad6b4eabae63e086c776e76c8a3b6ebed214ae0e95b60205ac232f5bc8dcd14dc77df43234000b996cc90f06848f89f34423d41aaa068cc14ca3561dd1ade7ccff60d781535278051eb2315a9c100c893d587ae560212f0386d989ed1d220d0127c7cd19fdac811fe64088f8b2e759db04071150c5c1775d39dd774fc30762aadd994858feeab8bf489779984ba92a93abefc82704530d4d3b086a9ed6184b8089e5157ca9c0c5d02c385068c3c4ebff0c3f728a8d91a3f81046c9e065b9dc000000000000000000000000000000000000000000050b131b1f22"

  # Witness construction (fail-closed, honest):
  # KD-COVERS: KD-89 (PQC attestation debt — closes only when the vendored
  # artifact's verify_signature lane actually supports ML_DSA65: the KAT
  # positive leg verifies AND the tamper leg flips; until that artifact
  # lands, this path stays :PQC_NOT_PROVISIONED by construction).
  #
  #   1. seal the canonical receipt through the engine C-ABI
  #      (`call_admit_and_seal/4`, tariff 0, deontic modality 0x01 ACCEPT)
  #      -> 352-byte CTRT (the [240..352] witness region is upstream-reserved
  #      and ZEROED by ffi.rs — the CTRT does NOT embed an ML-DSA signature);
  #   2. post-seal, drive the engine JSON surface op `verify_signature`
  #      alg=ML_DSA65 over the ACVP KAT: the witness evidence is the verify-op
  #      VERDICT (positive verifies AND one-character tamper flips invalid);
  #   3. any failure anywhere -> :refused, so the typed :PQC_NOT_PROVISIONED
  #      fallback stays the only non-witness outcome.
  defp pqc_witness(subject_digest) when is_binary(subject_digest) do
    if engine_available?() do
      canonical_receipt = %{
        subject_sha: Digest.hex(subject_digest),
        authority: @domain_tag,
        consequence: "smalt:trust-profile:pqc-witness:v1",
        replay: "smalt:trust-profile:profile-seal:v1",
        standing: "ALIVE"
      }

      delta = Jason.encode!(canonical_receipt)

      with {:ok, %{ctrt_bytes: ctrt}} <-
             @pqc_engine.call_admit_and_seal(delta, 0, 1, %{}),
           true <- is_binary(ctrt) and byte_size(ctrt) > 0,
           {:ok, true} <- mldsa65_kat_leg(:positive),
           {:ok, false} <- mldsa65_kat_leg(:tampered) do
        {:ok,
         %{
           "ctrt" => Base.encode64(ctrt),
           "pqc_receipt" => canonical_receipt,
           "mldsa65_kat" => %{"valid" => true, "tamper_refused" => true},
           "sealed_content_sha256" => Digest.hex(:crypto.hash(:sha256, delta))
         }}
      else
        _ -> :refused
      end
    else
      :refused
    end
  end

  # One leg of the ML-DSA-65 verify-op verdict through the engine JSON
  # surface. :positive runs the true KAT signature; :tampered flips one hex
  # char (anti-vacuity: a lane that cannot refuse must not provision).
  defp mldsa65_kat_leg(:positive) do
    mldsa65_verify_op(@ml_dsa65_kat_pk, @ml_dsa65_kat_msg, @ml_dsa65_kat_sig)
  end

  defp mldsa65_kat_leg(:tampered) do
    tampered = tamper_hex(@ml_dsa65_kat_sig)
    mldsa65_verify_op(@ml_dsa65_kat_pk, @ml_dsa65_kat_msg, tampered)
  end

  defp mldsa65_verify_op(pk_hex, msg_hex, sig_hex) do
    req =
      Jason.encode!(%{
        op: "verify_signature",
        alg: "ML_DSA65",
        public_key_hex: pk_hex,
        signing_input_hex: msg_hex,
        signature_hex: sig_hex
      })

    case @pqc_engine.call_json(req) do
      {:ok, resp} ->
        case Jason.decode(resp) do
          {:ok, %{"ok" => true, "valid" => v}} when is_boolean(v) -> {:ok, v}
          _ -> :refused
        end

      _ ->
        :refused
    end
  end

  defp tamper_hex(hex) when is_binary(hex) do
    first = binary_part(hex, 0, 1)
    flipped = if first == "f", do: "0", else: "f"
    flipped <> binary_part(hex, 1, byte_size(hex) - 1)
  end

  # Fail-closed witness re-check on the verify side: a payload claiming
  # profile "pqc" must carry a well-formed witness whose pqc_receipt
  # subject_sha binds the payload's subject_digest. The CTRT itself is opaque
  # offline; its authenticity rests on the RS256 signature over the payload
  # plus the engine's seal at signing time.
  defp witness_bound?(%{"ctrt" => ctrt, "pqc_receipt" => %{"subject_sha" => sha}}, subject_digest)
       when is_binary(ctrt) and byte_size(ctrt) > 0,
       do: sha == subject_digest

  defp witness_bound?(_, _), do: false

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

  # Rotation fence (closes the cycle-8 falsifier): the signed payload key_id
  # must be the fingerprint of the ACTIVE key. Sits before check_rsa so a
  # stale (pre-rotation) token is refused with the precise :unknown_key_id
  # reason instead of a generic bad_signature. Single-key trust plane: no
  # other key_id is resolvable, so anything else is refused. Lens-2 cycle-2
  # RE-FALSIFIED the fingerprint-allowlist Raise (witnessed: a retired-key
  # token under an open allowlist still fails check_rsa with :bad_signature,
  # because a fingerprint cannot recover the retired public key); see
  # tmp/errc/trust-profile-lens2/cycle-2.md before re-proposing it.
  defp check_key_id(%{"key_id" => kid}) when is_binary(kid) do
    if kid == key_id(), do: :ok, else: {:error, :unknown_key_id}
  end

  defp check_key_id(_), do: {:error, :unknown_key_id}

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
  # E-E cross-check plus profile/version pinning (pack gate 060 parity): a
  # signature from the active key over a payload claiming another profile or
  # envelope version must not verify.
  defp cross_check(header, payload) do
    with :ok <- header_payload_match(header, payload),
         :ok <- pinned_fields(payload) do
      :ok
    end
  end

  defp header_payload_match(%{"alg" => alg, "kid" => kid}, %{"algorithm" => alg, "key_id" => kid}),
       do: :ok

  defp header_payload_match(_, _), do: {:error, {:bad_alg, :header_payload_mismatch}}

  defp pinned_fields(%{"profile" => "classical", "version" => v}), do: pinned_version(v)

  # PQC witness tokens: profile "pqc" verifies ONLY with a well-formed
  # witness block whose pqc_receipt binds the payload's subject_digest.
  # Anything else (missing witness, empty ctrt, unbound receipt) is refused
  # exactly like a profile mismatch — fail-closed.
  defp pinned_fields(%{
         "profile" => "pqc",
         "version" => v,
         "subject_digest" => sha,
         "pqc_witness" => witness
       }) do
    if pinned_version(v) == :ok and witness_bound?(witness, sha) do
      :ok
    else
      {:error, {:bad_alg, :pqc_witness_invalid}}
    end
  end

  defp pinned_fields(%{"profile" => "pqc"}) do
    {:error, {:bad_alg, :pqc_witness_missing}}
  end

  defp pinned_fields(_),
    do: {:error, {:bad_alg, :payload_profile_mismatch}}

  defp pinned_version(@envelope_version), do: :ok
  defp pinned_version(_), do: {:error, {:bad_alg, :envelope_version_mismatch}}

  defp check_time(%{"not_before" => nb, "expires_at" => ea})
       when is_integer(nb) and is_integer(ea) do
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
