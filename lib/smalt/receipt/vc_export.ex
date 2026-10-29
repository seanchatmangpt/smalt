defmodule Smalt.Receipt.VcExport do
  @moduledoc """
  W3C-B (v26.10.22): VC 2.0 **export face** for the ATH-1 ledger receipt
  (`Smalt.Sync.Receipt` — the 40-word / 320-byte framed sha256-chain token).

  The binary receipt stays the wire format; this module wraps it into a
  W3C Verifiable Credentials 2.0 JSON-LD structure so external verifiers
  can consume it with standard VC libraries.

  ## Receipt-term law (current substrate)

      bytes  0..3   magic 0x534D4C54 ("SMLT")
      bytes  4..7   version 1
      bytes  8..15  leafCount uint64 BE (frames sealed)
      bytes 16..47  sha256-chain root (32 bytes)
      bytes 48..319 reserved, all zero

  `credentialSubject.frameCount` and `credentialSubject.merkleRoot` are
  READ FROM THE TERM (never trusted from caller args unless explicitly
  overridden), so the VC cannot diverge from the binary it certifies.

  ## Honest gap (typed UNSUPPORTED-with-falsifier)

  The proof is NOT a registered W3C Data-Integrity cryptosuite. It reuses
  the substrate's REAL signer (`Smalt.Security.ReceiptSigner`, RS256
  detached-JWS via `:public_key`) — the classical signer that actually
  exists in this repo. `receipt_signer` produces no ML-DSA / secure-element
  signatures, so no post-quantum proof type is claimed.

  Falsifier for the UNSUPPORTED row: a stock W3C Data-Integrity verifier
  run against `to_vc/2` output fails to verify the proof — cryptosuite
  `smalt-rs256-jws` is not in any registered suite registry. Close
  condition: implement a registered suite (or an ML-DSA leg in
  `receipt_signer`) and re-run this court against external vectors.

  ## Structure

      %{
        "@context" => ["https://www.w3.org/ns/credentials/v2", <inline receipt context>],
        "type" => ["VerifiableCredential", "MerkleReceiptCredential"],
        "issuer" => <substrate node identity>,
        "credentialSubject" => %{
          "receiptDigest" => lowercase hex of the 320-byte term,
          "seqHorizon" => %{"first" => n, "last" => m},
          "frameCount" => n,        # from term bytes 8..15
          "merkleRoot" => hex of term bytes 16..47
        },
        "proof" => %{
          "type" => "DataIntegrityProof",
          "cryptosuite" => "smalt-rs256-jws",
          "proofPurpose" => "assertionMethod",
          "verificationMethod" => <issuer>#key-1,
          "proofPayloadSha256" => sha256 of the canonicalized subject,
          "proofValue" => <RS256 detached-JWS over the canonical subject claims>
        }
      }
  """

  alias Smalt.Security.ReceiptSigner

  @base_context "https://www.w3.org/ns/credentials/v2"
  @receipt_type "MerkleReceiptCredential"
  @cryptosuite "smalt-rs256-jws"
  @receipt_ns "https://smalt.dev/ns/receipt/v1#"
  @receipt_size 320

  @receipt_context %{
    "@version" => 1.1,
    "MerkleReceiptCredential" => %{"@id" => @receipt_ns <> "MerkleReceiptCredential"},
    "receiptDigest" => %{"@id" => @receipt_ns <> "receiptDigest"},
    "seqHorizon" => %{"@id" => @receipt_ns <> "seqHorizon"},
    "first" => %{"@id" => @receipt_ns <> "first"},
    "last" => %{"@id" => @receipt_ns <> "last"},
    "frameCount" => %{"@id" => @receipt_ns <> "frameCount"},
    "merkleRoot" => %{"@id" => @receipt_ns <> "merkleRoot"},
    "proofPayloadSha256" => %{"@id" => @receipt_ns <> "proofPayloadSha256"}
  }

  @doc """
  Wraps a 320-byte receipt term (binary, or the 640-char lowercase hex
  token as returned by `Smalt.Sync.Receipt.mint/1`) into a VC 2.0 map.

  Required options:

    * `:issuer` — substrate node identity (string), embedded as `"issuer"`.
    * `:seq_horizon` — `{first_seq, last_seq}` integer tuple.

  Optional:

    * `:frame_count` — override (DANGEROUS: the term's own leafCount wins
      by default; an override that disagrees with the term is refused).
    * `:merkle_root` — override (same refusal law).
    * `:id` — credential id.

  Raises on a non-320-byte term, bad magic/version, or a nonzero reserved
  region.
  """
  @spec to_vc(binary() | String.t(), keyword()) :: map()
  def to_vc(receipt, opts) when is_list(opts) do
    term = decode_term(receipt)

    unless byte_size(term) == @receipt_size do
      raise ArgumentError, "receipt term must be #{@receipt_size} bytes, got #{byte_size(term)}"
    end

    case term do
      <<0x534D_4C54::32, 1::32, leaf_count::64, root::binary-size(32), 0::(272 * 8)>> ->
        build_vc(term, leaf_count, root, opts)

      <<0x534D_4C54::32, version::32, _::binary>> ->
        raise ArgumentError, "unsupported receipt version #{version}"

      _ ->
        raise ArgumentError, "bad receipt magic"
    end
  end

  @doc """
  Round-trip verify: re-canonicalizes `credentialSubject`, checks the
  proof's payload digest and the RS256 signature through
  `ReceiptSigner.verify/1`. Returns `{:ok, subject}` or `{:error, term}`.
  """
  @spec verify_vc(map()) :: {:ok, map()} | {:error, term}
  def verify_vc(%{"credentialSubject" => subject, "proof" => proof})
      when is_map(subject) and is_map(proof) do
    with %{"cryptosuite" => @cryptosuite} <- proof,
         %{"proofValue" => jws, "proofPayloadSha256" => digest} <- proof,
         ^digest <- sha256_hex(canonical_subject(subject)),
         {:ok, claims} <- ReceiptSigner.verify(jws),
         ^digest <- claims["subjectSha256"] do
      {:ok, subject}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_proof, other}}
    end
  end

  def verify_vc(_), do: {:error, :invalid_vc}

  @doc "The neutral receipt credential type emitted by `to_vc/2`."
  def receipt_type, do: @receipt_type

  ## internals

  defp decode_term(term) when is_binary(term) and byte_size(term) == @receipt_size, do: term

  defp decode_term(token) when is_binary(token) do
    with 640 <- byte_size(token),
         {:ok, term} <- Base.decode16(token, case: :lower) do
      term
    else
      _ ->
        raise ArgumentError,
              "receipt must be a 320-byte term or 640-char lowercase hex token"
    end
  end

  defp build_vc(term, leaf_count, root, opts) do
    issuer = Keyword.fetch!(opts, :issuer)
    {first, last} = Keyword.fetch!(opts, :seq_horizon)
    frame_count = overridden(opts, :frame_count, leaf_count, "frameCount")
    merkle_root_hex = Base.encode16(overridden(opts, :merkle_root, root, "merkleRoot"), case: :lower)

    subject = %{
      "receiptDigest" => Base.encode16(term, case: :lower),
      "seqHorizon" => %{"first" => first, "last" => last},
      "frameCount" => frame_count,
      "merkleRoot" => merkle_root_hex
    }

    canonical = canonical_subject(subject)
    digest = sha256_hex(canonical)

    proof = %{
      "type" => "DataIntegrityProof",
      "cryptosuite" => @cryptosuite,
      "proofPurpose" => "assertionMethod",
      "verificationMethod" => "#{issuer}#key-1",
      "proofPayloadSha256" => digest,
      "proofValue" =>
        ReceiptSigner.sign(%{"cryptosuite" => @cryptosuite, "subjectSha256" => digest})
    }

    vc = %{
      "@context" => [@base_context, @receipt_context],
      "type" => ["VerifiableCredential", @receipt_type],
      "issuer" => issuer,
      "credentialSubject" => subject,
      "proof" => proof
    }

    case Keyword.fetch(opts, :id) do
      {:ok, id} -> Map.put(vc, "id", id)
      :error -> vc
    end
  end

  # Term-own fields win: an explicit override that disagrees with the term
  # is refused rather than silently shadowing it.
  defp overridden(opts, key, term_value, name) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        if value == term_value do
          value
        else
          raise ArgumentError,
                "#{name} override #{inspect(value)} disagrees with the receipt term " <>
                  "(#{inspect(term_value)}); the term is authoritative"
        end

      :error ->
        term_value
    end
  end

  defp canonical_subject(subject) do
    subject
    |> Jason.encode!()
    |> sha256_hex()
    |> then(&%{"canonicalSubjectSha256" => &1, "subject" => subject})
    |> Jason.encode!()
  end

  defp sha256_hex(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)
end
