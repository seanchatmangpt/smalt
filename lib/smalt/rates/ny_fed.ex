defmodule Smalt.Rates.NyFed do
  @moduledoc "NY Fed Markets API twin: refRates JSON shape for SOFR/EFFR. Rates held as integer percent*10000."

  # {date, sofr_pct_x10000, effr_pct_x10000}  (4.3100% => 43100)
  @series [
    {"2026-11-10", 43_100, 43_300},
    {"2026-11-11", 43_200, 43_300},
    {"2026-11-12", 43_500, 43_300},
    {"2026-11-13", 43_000, 43_300}
  ]

  @spec ref_rates(:sofr | :effr) :: %{String.t() => [map()]}
  def ref_rates(type) when type in [:sofr, :effr] do
    idx = if type == :sofr, do: 1, else: 2
    rows = for t <- Enum.reverse(@series), do: row(type, elem(t, 0), elem(t, idx))
    %{"refRates" => rows}
  end

  @doc "Latest rate in integer bps."
  @spec latest_bps(:sofr | :effr) :: non_neg_integer()
  def latest_bps(type) do
    idx = if type == :sofr, do: 1, else: 2
    div(elem(List.last(@series), idx), 100)
  end

  defp row(type, date, pct4) do
    %{
      "effectiveDate" => date,
      "type" => type |> Atom.to_string() |> String.upcase(),
      "percentRate" => pct4 / 10_000,
      "percentPercentile1" => (pct4 - 200) / 10_000,
      "percentPercentile99" => (pct4 + 400) / 10_000,
      "volumeInBillions" => 1_000.0,
      "revisionIndicator" => ""
    }
  end
end
