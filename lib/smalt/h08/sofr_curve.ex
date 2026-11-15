defmodule Smalt.H08.SofrCurve do
  @moduledoc """
  SOFR term structure and compounded-in-arrears average, integer math only.
  Curve points are `{tenor_days, zero_bps}` anchored on the latest NY Fed SOFR print plus
  the knot offsets in `Vocab.curve_knots/0`; discount factor = 1/(1 + z*t/360) in
  parts-per-billion (half-up). The average compounds the published daily series
  (act/360), each print accruing until the next print, the last for one day.
  """
  alias Smalt.H08.Vocab
  alias Smalt.Rates.NyFed

  @ppb 1_000_000_000

  def curve(spot_bps \\ NyFed.latest_bps(:sofr)) do
    points = for {t, off} <- Vocab.curve_knots(), do: [t, spot_bps + off]

    dfs =
      for [t, z] <- points do
        den = 3_600_000 + z * t
        %{"tenor_days" => t, "zero_bps" => z, "df_ppb" => div(2 * @ppb * 3_600_000 + den, 2 * den)}
      end

    %{"source" => "NYFED_SOFR", "spot_bps" => spot_bps, "day_count" => "ACT/360", "points" => points,
      "discount_factors" => dfs}
  end

  defp series do
    %{"refRates" => rows} = NyFed.ref_rates(:sofr)

    rows
    |> Enum.map(fn r -> {r["effectiveDate"], round(r["percentRate"] * 10_000)} end)
    |> Enum.sort()
  end

  @doc "Compounded average over [start, end] inclusive prints; {:ok, map} | {:error, :no_data}."
  def average(start_date, end_date) do
    rows = Enum.filter(series(), fn {d, _} -> d >= start_date and d <= end_date end)

    if rows == [] do
      {:error, :no_data}
    else
      days =
        rows
        |> Enum.with_index()
        |> Enum.map(fn {{d, r}, i} ->
          case Enum.at(rows, i + 1) do
            {nd, _} -> {r, Date.diff(Date.from_iso8601!(nd), Date.from_iso8601!(d))}
            nil -> {r, 1}
          end
        end)

      scale = 1_000_000_000_000
      den = 360_000_000

      idx =
        Enum.reduce(days, scale, fn {r, d}, acc ->
          acc + div(2 * acc * r * d + den, 2 * den)
        end)

      total = days |> Enum.map(&elem(&1, 1)) |> Enum.sum()
      # (idx/scale - 1) * 360 / total, expressed as percent * 10000.
      growth = idx - scale
      avg = div(2 * growth * 360 * 1_000_000 + scale * total, 2 * scale * total)

      {:ok,
       %{"start" => elem(hd(rows), 0), "end" => elem(List.last(rows), 0), "observations" => length(rows),
         "accrual_days" => total, "index_e12" => idx, "average_percent_x10000" => avg}}
    end
  end
end
