defmodule Smalt.TaxSanctions.TinMatch do
  @moduledoc "IRS TIN-match result codes 0-8 against a caller-supplied TIN registry."

  def code_meaning(0), do: :match
  def code_meaning(1), do: :tin_missing_or_malformed
  def code_meaning(2), do: :tin_not_issued
  def code_meaning(3), do: :name_tin_mismatch
  def code_meaning(4), do: :invalid_request
  def code_meaning(5), do: :duplicate_request
  def code_meaning(6), do: :matched_ssn
  def code_meaning(7), do: :matched_ein
  def code_meaning(8), do: :matched_ssn_and_ein

  @doc "Returns integer code. registry: %{tin => %{name, type: :ssn | :ein}}; seen: MapSet of {norm_name, tin}."
  def match(name, tin, registry, seen \\ MapSet.new())

  def match(name, tin, _r, _s) when not is_binary(name) or not is_binary(tin), do: 4
  def match("", _tin, _r, _s), do: 4

  def match(name, tin, registry, seen) do
    t = String.replace(tin, ~r/[-\s]/, "")

    cond do
      MapSet.member?(seen, {norm(name), t}) -> 5
      not Regex.match?(~r/^\d{9}$/, t) -> 1
      not Map.has_key?(registry, t) -> 2
      norm(registry[t].name) != norm(name) -> 3
      registry[t].type == :ssn -> 6
      registry[t].type == :ein -> 7
    end
  end

  def matched?(code), do: code in [0, 6, 7, 8]

  defp norm(s), do: s |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "")
end
