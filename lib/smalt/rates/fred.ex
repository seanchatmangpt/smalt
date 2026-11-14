defmodule Smalt.Rates.Fred do
  @moduledoc "FRED series/observations twin (values are strings, '.' for missing, as upstream)."

  @series %{
    "SOFR" => [{"2026-11-10", "4.31"}, {"2026-11-11", "4.32"}, {"2026-11-12", "4.35"}, {"2026-11-13", "4.30"}],
    "DFF" => [{"2026-11-10", "4.33"}, {"2026-11-11", "4.33"}, {"2026-11-12", "."}, {"2026-11-13", "4.33"}]
  }

  @spec observations(String.t()) :: {:ok, map()} | {:error, map()}
  def observations(series_id) do
    case Map.fetch(@series, series_id) do
      {:ok, obs} ->
        {:ok,
         %{
           "realtime_start" => "2026-11-14",
           "realtime_end" => "2026-11-14",
           "observation_start" => elem(hd(obs), 0),
           "observation_end" => elem(List.last(obs), 0),
           "units" => "lin",
           "count" => length(obs),
           "observations" =>
             for {d, v} <- obs do
               %{"realtime_start" => "2026-11-14", "realtime_end" => "2026-11-14", "date" => d, "value" => v}
             end
         }}

      :error ->
        {:error, %{"error_code" => 400, "error_message" => "Bad Request.  The series does not exist."}}
    end
  end
end
