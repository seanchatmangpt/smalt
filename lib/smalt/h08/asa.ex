defmodule Smalt.H08.Asa do
  @moduledoc """
  Lithic ASA (Authorization Stream Access) decision engine with real funds logic.
  Order: card state, merchant rule (MCC / per-auth cap / country), account link, then
  an atomic available-balance hold: amount greater than available declines
  INSUFFICIENT_FUNDS. Approvals place a hold (available drops, current unchanged) that
  `clear/3` converts into a booked debit or `void/1` releases. Replaying an auth token
  returns the first decision without a second hold.
  """
  alias Smalt.H08.{Ledger, Vocab}

  @doc "auth: Lithic authorization payload (string keys). Returns {:ok, decision} | {:error, field}."
  def authorize(%{} = auth) do
    with {:ok, token} <- need(auth, "token", &is_binary/1),
         {:ok, card} <- need(auth, "card_token", &is_binary/1),
         {:ok, cents} <- need(auth, "amount", &(is_integer(&1) and &1 > 0)),
         {:ok, created} <- need(auth, "created", &is_binary/1) do
      case Ledger.decision(token) do
        %{} = d -> {:ok, Map.put(d, "replayed", true)}
        nil -> {:ok, decide(token, card, cents, created, auth)}
      end
    end
  end

  defp need(m, k, ok?), do: if(ok?.(m[k]), do: {:ok, m[k]}, else: {:error, k})

  defp decide(token, card, cents, created, auth) do
    {result, reasons, acct_id} =
      case Ledger.card(card) do
        nil -> {Vocab.asa_card_closed(), ["NO_RULE"], nil}
        rule -> evaluate(rule, token, cents, created, auth)
      end

    avail = if acct_id, do: Ledger.account(acct_id).available_cents, else: nil

    d = %{"token" => token, "card_token" => card, "amount" => cents, "created" => created,
          "result" => result, "reasons" => reasons, "available_cents" => avail}

    case Ledger.decision(token) do
      %{} = first -> Map.put(first, "replayed", true)
      nil -> Ledger.put_decision(token, d)
    end
  end

  defp evaluate(rule, token, cents, created, auth) do
    acct_id = Map.get(rule, :account_id)

    case Map.get(rule, :state, "OPEN") do
      "CLOSED" -> {Vocab.asa_card_closed(), ["CARD_CLOSED"], acct_id}
      "PAUSED" -> {Vocab.asa_card_paused(), ["CARD_PAUSED"], acct_id}
      _ -> merchant_then_funds(rule, acct_id, token, cents, created, auth)
    end
  end

  defp merchant_then_funds(rule, acct_id, token, cents, created, auth) do
    m = if is_map(auth["merchant"]), do: auth["merchant"], else: %{}

    reasons =
      [
        {m["mcc"] in rule.mccs, "MCC_MISMATCH"},
        {cents <= rule.max_amount_cents, "AMOUNT_MISMATCH"},
        {m["country"] in rule.countries, "GEO_MISMATCH"}
      ]
      |> Enum.reject(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    cond do
      reasons != [] ->
        {Vocab.asa_unauthorized_merchant(), reasons, acct_id}

      acct_id == nil or Ledger.account(acct_id) == nil ->
        {Vocab.asa_account_state_fail(), ["ACCOUNT_NOT_LINKED"], nil}

      true ->
        name = m["descriptor"] || ""

        case Ledger.place_hold(token, acct_id, cents, %{name: name, created: created}) do
          {:ok, _} -> {Vocab.asa_approve(), [], acct_id}
          {:error, :insufficient_funds} -> {Vocab.asa_insufficient_funds(), ["INSUFFICIENT_FUNDS"], acct_id}
          {:error, :duplicate} -> {Vocab.asa_approve(), [], acct_id}
        end
    end
  end

  @doc "Clearing: books a debit for `cents` (default: full hold) on the booked date."
  def clear(token, cents, booked) do
    case Ledger.hold(token) do
      nil -> {:error, :not_found}
      h -> Ledger.clear_hold(token, cents || h.amount_cents, booked)
    end
  end

  def void(token), do: Ledger.void_hold(token)

  @doc "Lithic synchronous response body."
  def response(d), do: Map.take(d, ["token", "result"])
end
