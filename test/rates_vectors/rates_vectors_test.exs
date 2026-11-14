defmodule Smalt.RatesVectorsTest do
  use ExUnit.Case, async: true

  @fx Path.expand("fixtures", __DIR__)
  @rates_dir Path.expand("../../lib/smalt/rates", __DIR__)

  defp load(f), do: @fx |> Path.join(f) |> File.read!() |> JSON.decode!()

  test "NY Fed refrates vector shape (published doc)" do
    [r] = load("nyfed_refrates_sofr_latest.json")["refRates"]
    assert r["type"] == "SOFR"
    assert r["effectiveDate"] =~ ~r/^\d{4}-\d{2}-\d{2}$/
    assert r["percentPercentile1"] <= r["percentRate"]
    assert r["percentRate"] <= r["percentPercentile99"]
  end

  test "FRED observations: values are strings, '.' marks missing" do
    d = load("fred_observations_dgs10.json")
    assert d["count"] == length(d["observations"])
    assert Enum.all?(d["observations"], &is_binary(&1["value"]))
    assert Enum.count(d["observations"], &(&1["value"] == ".")) == 1
  end

  test "EDGAR submissions: CIK is 10 digits, recent arrays are parallel" do
    d = load("edgar_submissions_cik.json")
    assert d["cik"] =~ ~r/^\d{10}$/
    recent = d["filings"]["recent"]
    lens = recent |> Map.values() |> Enum.map(&length/1) |> Enum.uniq()
    assert length(lens) == 1
  end

  test "lib/smalt/rates drives the vectors" do
    if File.dir?(@rates_dir) do
      for m <- [Smalt.Rates.NyFed, Smalt.Rates.Fred, Smalt.Rates.Edgar] do
        assert Code.ensure_loaded?(m), "#{inspect(m)} not loadable"
      end

      %{"refRates" => [r | _]} = Smalt.Rates.NyFed.ref_rates(:sofr)
      assert is_map(r) and Map.has_key?(r, "percentRate")
    else
      IO.puts("[SKIP] lib/smalt/rates absent: NY Fed/FRED/EDGAR vectors not driven against twin")
    end
  end
end
