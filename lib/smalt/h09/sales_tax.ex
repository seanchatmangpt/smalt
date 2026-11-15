defmodule Smalt.H09.SalesTax do
  @moduledoc "State sales-tax return computation. Integer cents; basis-point rates; half-up rounding."
  alias Smalt.H09.Vocab

  def compute(%{"state" => st, "period" => per, "lines" => lines} = b) when is_binary(st) and is_list(lines) do
    rates = Map.merge(Vocab.state_rates_bps(), ints(b["rates_bps"]))

    with {:ok, bps} <- fetch_rate(rates, st),
         {:ok, {y, m}} <- period(per),
         {:ok, rows} <- rows(lines, bps) do
      gross = sum(rows, :gross_cents)
      exempt = sum(rows, :exempt_cents)
      returns = sum(rows, :returns_cents)
      taxable = sum(rows, :taxable_cents)
      tax = sum(rows, :tax_cents)
      timely = b["timely"] == true
      disc = if timely, do: min(half_up(tax * Vocab.vendor_discount_bps(), 10_000), Vocab.vendor_discount_cap_cents()), else: 0

      {:ok,
       %{
         state: st,
         period: per,
         rate_bps: bps,
         lines: rows,
         gross_cents: gross,
         exempt_cents: exempt,
         returns_cents: returns,
         taxable_cents: taxable,
         tax_cents: tax,
         vendor_discount_cents: disc,
         net_due_cents: tax - disc,
         due_date: due_date(y, m) |> Date.to_iso8601()
       }}
    end
  end

  def compute(_), do: {:error, {Vocab.err(:invalid), [:state, :period, :lines]}}

  defp ints(%{} = m), do: for({k, v} <- m, is_binary(k), is_integer(v) and v >= 0, into: %{}, do: {k, v})
  defp ints(_), do: %{}

  defp fetch_rate(rates, st) do
    case Map.fetch(rates, st) do
      {:ok, r} -> {:ok, r}
      :error -> {:error, {Vocab.err(:unknown_state), st}}
    end
  end

  defp period(<<y::binary-size(4), "-", m::binary-size(2)>>) do
    with {yi, ""} <- Integer.parse(y), {mi, ""} <- Integer.parse(m), true <- mi in 1..12 do
      {:ok, {yi, mi}}
    else
      _ -> {:error, {Vocab.err(:bad_period), :format}}
    end
  end

  defp period(_), do: {:error, {Vocab.err(:bad_period), :format}}

  defp rows(lines, bps) do
    Enum.reduce_while(lines, {:ok, []}, fn l, {:ok, acc} ->
      with %{} <- l,
           g when is_integer(g) and g >= 0 <- l["gross_cents"],
           e when is_integer(e) and e >= 0 <- Map.get(l, "exempt_cents", 0),
           r when is_integer(r) and r >= 0 <- Map.get(l, "returns_cents", 0),
           true <- e + r <= g do
        t = g - e - r
        row = %{jurisdiction: l["jurisdiction"], gross_cents: g, exempt_cents: e, returns_cents: r, taxable_cents: t, tax_cents: half_up(t * bps, 10_000)}
        {:cont, {:ok, acc ++ [row]}}
      else
        _ -> {:halt, {:error, {Vocab.err(:invalid), [:lines]}}}
      end
    end)
  end

  defp sum(rows, k), do: rows |> Enum.map(&Map.fetch!(&1, k)) |> Enum.sum()
  defp half_up(n, d), do: div(n * 2 + d, 2 * d)

  # due on the configured day of the following month, rolled forward off weekends
  defp due_date(y, m) do
    {ny, nm} = if m == 12, do: {y + 1, 1}, else: {y, m + 1}
    d = Date.new!(ny, nm, Vocab.sales_tax_due_day())

    case Date.day_of_week(d) do
      6 -> Date.add(d, 2)
      7 -> Date.add(d, 1)
      _ -> d
    end
  end
end
