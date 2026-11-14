defmodule Smalt.Rates.Edgar do
  @moduledoc "SEC EDGAR twin: submissions and companyfacts JSON shapes (CIK zero-padded to 10)."

  @companies %{
    320_193 => %{name: "Example Holdings Inc.", tickers: ["EXH"], sic: "3571", assets: 352_583_000_000},
    789_019 => %{name: "Sample Software Corp.", tickers: ["SSC"], sic: "7372", assets: 411_976_000_000}
  }

  def pad_cik(cik) when is_integer(cik), do: cik |> Integer.to_string() |> String.pad_leading(10, "0")

  def submissions(cik) do
    with {:ok, c} <- fetch(cik) do
      {:ok,
       %{
         "cik" => pad_cik(cik),
         "entityType" => "operating",
         "sic" => c.sic,
         "name" => c.name,
         "tickers" => c.tickers,
         "filings" => %{
           "recent" => %{
             "accessionNumber" => ["0001628280-26-000001"],
             "filingDate" => ["2026-11-01"],
             "form" => ["10-K"],
             "primaryDocument" => ["form10k.htm"]
           },
           "files" => []
         }
       }}
    end
  end

  def company_facts(cik) do
    with {:ok, c} <- fetch(cik) do
      {:ok,
       %{
         "cik" => cik,
         "entityName" => c.name,
         "facts" => %{
           "us-gaap" => %{
             "Assets" => %{
               "label" => "Assets",
               "units" => %{
                 "USD" => [
                   %{
                     "end" => "2026-09-30",
                     "val" => c.assets,
                     "accn" => "0001628280-26-000001",
                     "fy" => 2026,
                     "fp" => "FY",
                     "form" => "10-K",
                     "filed" => "2026-11-01"
                   }
                 ]
               }
             }
           }
         }
       }}
    end
  end

  defp fetch(cik) do
    case Map.fetch(@companies, cik) do
      {:ok, c} -> {:ok, c}
      :error -> {:error, :not_found}
    end
  end
end
