defmodule Smalt.Rates.AbsPool do
  @moduledoc """
  ABS loan-tape barrel: PoolBackedSecurity pool of receivables whose principal
  sum equals pool principal (integer cents), with SOFR+spread tranche pricing
  in bps integer math.
  """

  alias Smalt.Rates.NyFed

  @doc "Split `principal_cents` into `n` receivables; sum is exactly principal."
  def pool(id, principal_cents, n) when principal_cents > 0 and n > 0 do
    base = div(principal_cents, n)
    extra = rem(principal_cents, n)

    recs =
      for i <- 1..n do
        %{
          "receivable_id" => "#{id}-R#{String.pad_leading(Integer.to_string(i), 4, "0")}",
          "principal_cents" => base + if(i <= extra, do: 1, else: 0)
        }
      end

    %{"type" => "PoolBackedSecurity", "pool_id" => id, "principal_cents" => principal_cents, "receivables" => recs}
  end

  def balanced?(%{"principal_cents" => p, "receivables" => r}),
    do: Enum.sum(Enum.map(r, & &1["principal_cents"])) == p

  @doc "Tranches: list of {name, share_bps, spread_bps}; shares must total 10_000."
  def price(pool, tranches, sofr_bps \\ NyFed.latest_bps(:sofr)) do
    if Enum.sum(for {_, s, _} <- tranches, do: s) != 10_000,
      do: raise(ArgumentError, "shares must sum to 10000 bps")

    p = pool["principal_cents"]
    last = length(tranches) - 1

    {rows, _} =
      tranches
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn {{name, share, spread}, i}, acc ->
        amt = if i == last, do: p - acc, else: div(p * share, 10_000)
        coupon = sofr_bps + spread

        {%{
           "tranche" => name,
           "principal_cents" => amt,
           "coupon_bps" => coupon,
           "monthly_interest_cents" => div(amt * coupon, 10_000 * 12)
         }, acc + amt}
      end)

    rows
  end
end
