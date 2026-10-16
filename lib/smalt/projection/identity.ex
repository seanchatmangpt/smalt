defmodule Smalt.Projection.Identity do
  @moduledoc """
  The ONE identity fence for every projection surface
  (`Smalt.Projection.SemanticEpoch`, `Smalt.Projection.Admission`,
  `Smalt.Semantic.StoreRead`, `Smalt.AshExtension.SubstrateResource.ManualRead`).

  R_missing_identity, generalized (lens-3 -> lens-4): a projected row's
  identity key must carry at least one VISIBLE codepoint. Refused:

    * any non-binary (integer epoch, list, 2-tuple, nil) — no identity bits;
    * `""` — the lens-3 blank-id class;
    * whitespace-only binaries — `"  \\t\\n"` sorts/serves as an id yet
      renders as nothing; two such rows collide visually and in logs while
      remaining distinct keys, and a single one is unreadable identity;
    * invisible-format-only binaries — zero-width space/joiners, BOM
      (U+200B-U+200F, U+FEFF, soft hyphen, bidi controls): "abc" and
      "abc\\u200B" must not be confusable, so a key made ONLY of these is
      refused.

  A binary with at least one visible codepoint is valid — the fence is the
  zero-identity-bits class, not a charset policy.

  ## Adoption contract (lens-7, witnessed lens-6 cycle 3)

  `valid?/1` is THE canonical zero-identity-bits validator. Consumers MUST:

    1. **Adopt, don't reimplement.** Replace any inline blank/nil id check
       with this one function (N implementations of one identity calculus
       drift quadratically; one function, N consumers, is the collapse).
    2. **Membership, not charset.** Refuse only the class with zero visible
       codepoints (`""`, whitespace-only, invisible-format-only, non-binary).
       `"abc\\u200B"` is VALID — byte identity, not rendering. Do not add
       charset rules here.
    3. **Layer conjuncts; never fork the fence.** Surfaces with extra
       identity requirements compose `valid?/1` as ONE conjunct of their own
       chain (e.g. `Smalt.DataPlane.BlobStorage.check_blob_name/1` layers
       control-char and 1024-byte-bound conjuncts around it) — they do not
       write a second validator.

  Consumers witnessed: SemanticEpoch.refuse_duplicate_ids,
  Admission.refuse_degenerate_ids, StoreRead.identity?,
  ManualRead.identity?, BlobStorage.check_blob_name.
  """

  # Invisible format characters (Unicode Cf) plus soft hyphen — characters
  # that occupy an id slot but render as nothing.
  @invisible ~r|[\x{00AD}\x{180E}\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{FEFF}]|u

  @doc """
  `true` iff `id` is a binary containing at least one visible codepoint
  (neither Unicode whitespace nor an invisible format character).
  """
  @spec valid?(term()) :: boolean()
  def valid?(id)

  def valid?(id) when is_binary(id) do
    id |> String.replace(@invisible, "") |> String.trim() != ""
  end

  def valid?(_), do: false
end
