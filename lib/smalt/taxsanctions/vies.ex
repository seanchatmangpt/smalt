defmodule Smalt.TaxSanctions.Vies do
  @moduledoc "VIES VAT number check (format + registry) and DAC7 platform report shape."

  @formats %{
    "DE" => ~r/^\d{9}\z/, "FR" => ~r/^[A-Z0-9]{2}\d{9}\z/, "NL" => ~r/^\d{9}B\d{2}\z/,
    "IT" => ~r/^\d{11}\z/, "ES" => ~r/^[A-Z0-9]\d{7}[A-Z0-9]\z/, "BE" => ~r/^[01]\d{9}\z/,
    "IE" => ~r/^\d[A-Z0-9+*]\d{5}[A-Z]{1,2}\z/, "PL" => ~r/^\d{10}\z/, "AT" => ~r/^U\d{8}\z/
  }

  @doc "registry: MapSet of active 'CCNUMBER' strings."
  def check(vat, registry) when is_binary(vat) do
    v = vat |> String.upcase() |> String.replace(~r/[\s.\-]/, "")
    {cc, num} = String.split_at(v, 2)

    res = fn valid, reason -> %{valid: valid, reason: reason, country_code: cc, vat_number: num} end

    case @formats[cc] do
      nil -> res.(false, :unsupported_country)
      re ->
        cond do
          not Regex.match?(re, num) -> res.(false, :bad_format)
          not MapSet.member?(registry, cc <> num) -> res.(false, :not_registered)
          true -> res.(true, nil)
        end
    end
  end

  @doc "DAC7 report: reportable sellers (>=30 activities or >=EUR 2000 consideration)."
  def dac7_report(%{platform_id: pid, year: y, sellers: sellers}) do
    rows =
      for s <- sellers do
        q = s.quarterly_consideration_cents
        total = Enum.sum(q)

        %{
          seller_name: s.name, tin: s.tin, vat: Map.get(s, :vat), residence: s.residence,
          listings: s.listings, activities: s.activities,
          quarterly_consideration_cents: q, total_consideration_cents: total,
          fees_cents: Map.get(s, :fees_cents, 0),
          reportable?: s.activities >= 30 or total >= 200_000
        }
      end

    %{platform_id: pid, reporting_year: y, sellers: Enum.filter(rows, & &1.reportable?)}
  end
end
