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
