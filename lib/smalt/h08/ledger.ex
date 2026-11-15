defmodule Smalt.H08.Ledger do
  @moduledoc """
  Stateful account ledger over the shared `:smalt_treasury` ETS table. Accounts reuse
  the `{:account, id}` key (same shape Plaid auth/balance already read), so postings
  show up in balances. Entries are append-only per account; card holds reduce
  available but not current until cleared. Mutations serialize on a global lock.
  """
  alias Smalt.Treasury.Router

  @t :smalt_treasury
  @lock :smalt_h08_ledger

  defp tx(fun) do
    Router.ensure()
    :global.trans({@lock, self()}, fun, [node()], :infinity)
  end

  defp lookup(k) do
    Router.ensure()

    case :ets.lookup(@t, k) do
      [{_, v}] -> v
      _ -> nil
    end
  end

  defp put(k, v), do: (:ets.insert(@t, {k, v}); v)

  def account(id), do: lookup({:account, id})
  def entries(id), do: lookup({:h08_entries, id}) || []
  def hold(token), do: lookup({:h08_hold, token})
  def card(token), do: lookup({:rule, token})
  def decision(token), do: lookup({:h08_asa_decision, token})
  def put_decision(token, d), do: put({:h08_asa_decision, token}, d)
  def put_card(token, rule), do: put({:rule, token}, rule)
  def seen_msg?(msg_id), do: lookup({:h08_msg, msg_id}) != nil
  def mark_msg(msg_id), do: put({:h08_msg, msg_id}, true)
  def get(k), do: lookup({:h08_kv, k})
  def put_kv(k, v), do: put({:h08_kv, k}, v)

  def open(id, %{} = attrs) do
    tx(fn ->
      if lookup({:account, id}) do
        {:error, :exists}
      else
        o = Map.fetch!(attrs, :opening_cents)

        a = %{account_id: id, account: Map.fetch!(attrs, :account), routing: Map.fetch!(attrs, :routing),
              available_cents: o, current_cents: o}

        put({:h08_entries, id}, [])
        {:ok, put({:account, id}, a)}
      end
    end)
  end

  @doc "Opening balance derived from current minus net posted entries."
  def opening_cents(id) do
    a = account(id)
    net = Enum.reduce(entries(id), 0, fn e, s -> if e.direction == :credit, do: s + e.amount_cents, else: s - e.amount_cents end)
    a.current_cents - net
  end

  def post(id, dir, cents, attrs) when dir in [:debit, :credit] and is_integer(cents) and cents > 0 do
    tx(fn ->
      case lookup({:account, id}) do
        nil -> {:error, :not_found}
        a -> if dir == :debit and a.available_cents < cents, do: {:error, :insufficient_funds}, else: {:ok, apply_entry(a, dir, cents, attrs, true)}
      end
    end)
  end

  def post(_, _, _, _), do: {:error, :invalid_amount}

  def place_hold(token, id, cents, attrs) when is_integer(cents) and cents > 0 do
    tx(fn ->
      cond do
        lookup({:h08_hold, token}) != nil -> {:error, :duplicate}
        true ->
          case lookup({:account, id}) do
            nil ->
              {:error, :not_found}

            a when is_map(a) ->
              if a.available_cents < cents do
                {:error, :insufficient_funds}
              else
                put({:account, id}, Map.put(a, :available_cents, a.available_cents - cents))
                h = %{token: token, account_id: id, amount_cents: cents, state: :open, name: attrs.name, created: attrs.created}
                put({:h08_hold, token}, h)
                put({:h08_holds, id}, (lookup({:h08_holds, id}) || []) ++ [token])
                {:ok, h}
              end
          end
      end
    end)
  end

  def clear_hold(token, cents, booked) do
    tx(fn ->
      case lookup({:h08_hold, token}) do
        nil -> {:error, :not_found}
        %{state: s} when s != :open -> {:error, :not_open}
        %{amount_cents: amt} when cents > amt -> {:error, :amount_exceeds_hold}
        h ->
          a = lookup({:account, h.account_id})
          # Release the unused remainder to available; current moves by the cleared amount.
          a = Map.put(a, :available_cents, a.available_cents + h.amount_cents - cents)
          e = apply_entry(a, :debit, cents, %{end_to_end_id: token, booked: booked, name: h.name}, false)
          put({:h08_hold, token}, %{h | state: :cleared})
          {:ok, e}
      end
    end)
  end

  def void_hold(token) do
    tx(fn ->
      case lookup({:h08_hold, token}) do
        nil -> {:error, :not_found}
        %{state: s} when s != :open -> {:error, :not_open}
        h ->
          a = lookup({:account, h.account_id})
          put({:account, h.account_id}, Map.put(a, :available_cents, a.available_cents + h.amount_cents))
          {:ok, put({:h08_hold, token}, %{h | state: :voided})}
      end
    end)
  end

  def open_holds(id) do
    (lookup({:h08_holds, id}) || [])
    |> Enum.map(&lookup({:h08_hold, &1}))
    |> Enum.filter(&(&1.state == :open))
  end

  defp apply_entry(a, dir, cents, attrs, touch_available?) do
    sign = if dir == :credit, do: 1, else: -1
    a2 = Map.put(a, :current_cents, a.current_cents + sign * cents)
    a2 = if touch_available?, do: Map.put(a2, :available_cents, a.available_cents + sign * cents), else: a2
    id = a.account_id
    es = entries(id)

    e = %{seq: length(es) + 1, direction: dir, amount_cents: cents, end_to_end_id: attrs.end_to_end_id,
          booked: attrs.booked, name: attrs.name}

    put({:account, id}, a2)
    put({:h08_entries, id}, es ++ [e])
    e
  end
end
