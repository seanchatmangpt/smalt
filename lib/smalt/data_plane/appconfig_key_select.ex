defmodule Smalt.DataPlane.AppConfigKeySelect do
  @moduledoc """
  Unified App Config key-selector matching law (KD-A12 close, v26.11.6).

  ONE law, both faces (the live `/kv` list filter AND the snapshot key
  selector — previously `/kv` used an exact-or-glob grammar while snapshot
  selection was prefix-only, a shared-law inconsistency mirrored across
  smalt and arcus):

    - a `nil` or empty pattern matches everything;
    - a pattern containing `*` is a GLOB: `*` is the wildcard, every other
      byte literal — leading (`*access`), trailing (`tenant/*`) and mid
      (`a*c`) stars all match, including multiple stars;
    - a starless pattern is a PREFIX match (`tenant/` selects every key
      under the `tenant/` segment).

  Label filters are NOT this law: the `/kv` label query filter delegates
  here (same grammar on the label dimension, smalt `/kv` law), while
  snapshot label selectors stay EXACT (Azure parity posture).
  """

  @doc """
  Match `value` against `pattern` under the unified key-selector law.
  Non-binary values (a missing key/label on a record) never match a
  present pattern; `nil`/`""` patterns match everything.
  """
  @spec match(term(), term()) :: boolean()
  def match(_value, nil), do: true
  def match(_value, ""), do: true

  def match(value, pattern) when is_binary(value) and is_binary(pattern) do
    case String.split(pattern, "*") do
      # starless: prefix law
      [starless] ->
        String.starts_with?(value, starless)

      # glob law: exact/trailing/leading/mid '*' split
      parts ->
        [first | mid] = parts
        last = List.last(mid)

        if String.starts_with?(value, first) do
          rest = String.replace_prefix(value, first, "")

          case glob_mid(rest, Enum.drop(mid, -1)) do
            :nomatch -> false
            rest2 -> String.ends_with?(rest2, last)
          end
        else
          false
        end
    end
  end

  def match(_non_binary, _pattern), do: false

  # Consume the middle segments left-to-right at their FIRST occurrence
  # (the arcus matchGlob law — greedy-prefix, not backtracking).
  defp glob_mid(rest, []), do: rest

  defp glob_mid(rest, [part | mid]) do
    case String.split(rest, part, parts: 2) do
      [_l, r] -> glob_mid(r, mid)
      [_only] -> :nomatch
    end
  end
end
