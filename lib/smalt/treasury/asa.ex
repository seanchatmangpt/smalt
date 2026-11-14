defmodule Smalt.Treasury.Asa do
  @moduledoc """
  Lithic-style ASA (Authorization Stream Access) decision. Approve only when MCC,
  amount (integer cents) and geo (country) all match the card's spend rule. Pure,
  sub-100ms by construction; `decide/2` returns `{result, elapsed_us}`-less map.
  """
  @budget_us 100_000

  def decide(%{} = auth, %{} = rule) do
    t0 = System.monotonic_time(:microsecond)

    reasons =
      [
        {auth["mcc"] in rule.mccs, "MCC_MISMATCH"},
        {is_integer(auth["amount"]) and auth["amount"] > 0 and auth["amount"] <= rule.max_amount_cents, "AMOUNT_MISMATCH"},
        {merchant_country(auth) in rule.countries, "GEO_MISMATCH"}
      ]
      |> Enum.reject(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    el = System.monotonic_time(:microsecond) - t0
    over = el > @budget_us
    result = if reasons == [] and not over, do: "APPROVED", else: "DECLINED"
    %{"token" => auth["token"], "result" => result, "reasons" => if(over, do: ["TIMEOUT" | reasons], else: reasons), "elapsed_us" => el}
  end

  defp merchant_country(%{"merchant" => %{} = m}), do: m["country"]
  defp merchant_country(_), do: nil

  def response(d), do: %{"result" => d["result"], "token" => d["token"]}
end
