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

  def balanced?(%{"principal_cents" => p, "receivables" => r}) when is_integer(p) and is_list(r) do
    Enum.all?(r, &(is_map(&1) and is_integer(&1["principal_cents"]))) and
      Enum.sum(Enum.map(r, & &1["principal_cents"])) == p
  end

  def balanced?(_), do: false

  @doc """
  Tranches: list of {name, share_bps, spread_bps}; shares must total 10_000.

  Interest rule: pool-level interest = floor(sum(amt_i * coupon_i) / 120_000).
  Each tranche but the last gets floor(amt_i * coupon_i / 120_000); the LAST tranche
  receives the remainder cents, so tranche interest sums exactly to pool-level interest.
  """
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

    pool_interest =
      div(Enum.sum(for r <- rows, do: r["principal_cents"] * r["coupon_bps"]), 10_000 * 12)

    {init, [final]} = Enum.split(rows, -1)
    assigned = Enum.sum(for r <- init, do: r["monthly_interest_cents"])
    init ++ [Map.put(final, "monthly_interest_cents", pool_interest - assigned)]
  end
end
