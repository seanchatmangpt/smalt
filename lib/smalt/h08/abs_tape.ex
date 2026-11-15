defmodule Smalt.H08.AbsTape do
  @moduledoc """
  ABS loan tape: expands an `AbsPool` barrel into per-loan rows (rate, term, seasoning,
  origination month, level payment) with integer math, plus pool strats (WAC, WAM,
  scheduled payment). Level payment = P*r*(1+r)^n/((1+r)^n-1), r = rate_bps/120000,
  rounded half-up. Tapes are stored by pool id; re-posting a pool id conflicts.
  """
  alias Smalt.H08.{Ledger, Vocab}
  alias Smalt.Rates.AbsPool

  def build(pool_id, principal_cents, n, as_of) do
    pool = AbsPool.pool(pool_id, principal_cents, n)
    rates = Vocab.tape_rates_bps()
    terms = Vocab.tape_terms()
    seas = Vocab.tape_seasoning()

    loans =
      pool["receivables"]
      |> Enum.with_index()
      |> Enum.map(fn {r, i} ->
        rate = Enum.at(rates, rem(i, length(rates)))
        term = Enum.at(terms, rem(i, length(terms)))
        s = Enum.at(seas, rem(i, length(seas)))
        remaining = term - s
        p = r["principal_cents"]

        %{"loan_id" => r["receivable_id"], "principal_cents" => p, "rate_bps" => rate, "original_term_months" => term,
          "seasoning_months" => s, "remaining_term_months" => remaining, "origination_month" => back(as_of, s),
          "payment_cents" => payment(p, rate, remaining)}
      end)

    total = Enum.sum(Enum.map(loans, & &1["principal_cents"]))
    wac = half_up(Enum.sum(for l <- loans, do: l["principal_cents"] * l["rate_bps"]), total)
    wam = half_up(Enum.sum(for l <- loans, do: l["principal_cents"] * l["remaining_term_months"]), total)

    %{"pool_id" => pool_id, "as_of" => as_of, "loans" => loans,
      "summary" => %{"loan_count" => length(loans), "principal_cents" => total, "wac_bps" => wac, "wam_months" => wam,
                     "scheduled_payment_cents" => Enum.sum(Enum.map(loans, & &1["payment_cents"]))}}
  end

  def payment(p, rate_bps, n) when n > 0 and p >= 0 do
    b = 120_000
    a = b + rate_bps
    an = Integer.pow(a, n)
    bn = Integer.pow(b, n)
    half_up(p * rate_bps * an, b * (an - bn))
  end

  def payment(_, _, _), do: 0

  defp half_up(_num, 0), do: 0
  defp half_up(num, den), do: div(2 * num + den, 2 * den)

  defp back(<<y::binary-size(4), "-", m::binary-size(2), _::binary>>, months) do
    total = String.to_integer(y) * 12 + String.to_integer(m) - 1 - months
    ny = div(total, 12)
    nm = rem(total, 12) + 1
    "#{ny}-#{nm |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  def store(%{"pool_id" => id} = tape) do
    if Ledger.get({:tape, id}), do: {:error, :exists}, else: {:ok, Ledger.put_kv({:tape, id}, tape)}
  end

  def fetch(id), do: Ledger.get({:tape, id})
end
