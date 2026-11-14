defmodule Smalt.TaxSanctionsVectorsTest do
  use ExUnit.Case, async: true

  @vectors Path.join(__DIR__, "vectors.json") |> File.read!() |> Jason.decode!()
  @mod Smalt.TaxSanctions

  test "pub1220 fields lie within record, ordered, non-overlapping" do
    v = @vectors["pub1220_b_record"]
    ranges = v["fields"] |> Map.values() |> Enum.sort()
    assert Enum.all?(ranges, fn [a, b] -> a <= b and b <= v["record_length"] end)

    assert ranges
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.all?(fn [[_, b], [a, _]] -> b < a end)

    assert v["fields"]["payee_tin"] == [12, 20]
  end

  test "irs codes 0..8; ofac sample has 12 columns; vies sample has required keys" do
    codes = @vectors["irs_tin_match"]["codes"] |> Map.keys() |> Enum.sort()
    assert codes == Enum.map(0..8, &to_string/1)

    ofac = @vectors["ofac_sdn"]
    assert length(Regex.scan(~r/"[^"]*"|[^,]+/, ofac["sample"])) == length(ofac["columns"])

    vies = @vectors["vies_check_vat"]
    assert Enum.all?(vies["required_keys"], &Map.has_key?(vies["sample"], &1))
  end

  test "drives Smalt.TaxSanctions when present" do
    tm = Smalt.TaxSanctions.TinMatch
    assert Code.ensure_loaded?(tm)

    for {code, _} <- @vectors["irs_tin_match"]["codes"] do
      assert is_atom(tm.code_meaning(String.to_integer(code)))
    end
  end
end
