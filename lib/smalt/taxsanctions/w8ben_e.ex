defmodule Smalt.TaxSanctions.W8BenE do
  @moduledoc "W-8BEN-E structural validation."

  @required [:entity_name, :country_of_incorporation, :chapter3_status, :permanent_address,
             :signature, :signed_on, :capacity]
  @statuses ~w(corporation partnership simple_trust grantor_trust complex_trust estate
               central_bank tax_exempt_org private_foundation international_org)

  @doc "Returns :ok or {:error, [reasons]}."
  def validate(%{} = f) do
    errs =
      Enum.flat_map(@required, fn k -> if Map.get(f, k) in [nil, ""], do: [{:missing, k}], else: [] end) ++
        status(f) ++ us(f) ++ treaty(f)

    if errs == [], do: :ok, else: {:error, errs}
  end

  defp status(%{chapter3_status: s}) when is_binary(s) and s not in @statuses,
    do: [{:invalid, :chapter3_status}]

  defp status(_), do: []

  defp us(%{country_of_incorporation: "US"}), do: [{:invalid, :us_entity_must_use_w9}]
  defp us(_), do: []

  defp treaty(%{treaty_country: c} = f) when not is_nil(c) do
    cond do
      not Map.get(f, :lob_qualified, false) -> [{:missing, :limitation_on_benefits}]
      not is_number(Map.get(f, :treaty_rate_pct)) -> [{:missing, :treaty_rate_pct}]
      true -> []
    end
  end

  defp treaty(_), do: []

  @doc "Valid through Dec 31 of the third year following signing."
  def expires_on(%Date{year: y}), do: Date.new!(y + 3, 12, 31)
end
