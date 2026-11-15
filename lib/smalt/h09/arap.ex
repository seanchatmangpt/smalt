defmodule Smalt.H09.Arap do
  @moduledoc "AR/AP sync: idempotent upsert by external_id, version cursor, open-balance aging."
  alias Smalt.H09.{Vocab, State}

  @kinds ~w(ar ap)

  def sync(%{"entity" => ent, "kind" => kind, "records" => recs}) when is_binary(ent) and kind in @kinds and is_list(recs) do
    with {:ok, rs} <- norm(recs) do
      State.update(fn s ->
        key = {ent, kind}
        cur = Map.get(s.arap, key, %{})

        {cur2, counts} =
          Enum.reduce(rs, {cur, %{created: 0, updated: 0, unchanged: 0}}, fn r, {m, c} ->
            case Map.get(m, r.external_id) do
              nil -> {Map.put(m, r.external_id, r), Map.update!(c, :created, &(&1 + 1))}
              ^r -> {m, Map.update!(c, :unchanged, &(&1 + 1))}
              _ -> {Map.put(m, r.external_id, r), Map.update!(c, :updated, &(&1 + 1))}
            end
          end)

        changed = counts.created + counts.updated > 0
        v = if changed, do: s.version + 1, else: s.version
        {{:ok, Map.put(counts, :cursor, v)}, %{s | arap: Map.put(s.arap, key, cur2), version: v}}
      end)
    end
  end

  def sync(_), do: {:error, {Vocab.err(:invalid), [:entity, :kind, :records]}}

  defp norm(recs) do
    Enum.reduce_while(recs, {:ok, []}, fn r, {:ok, acc} ->
      if is_map(r) and is_binary(r["external_id"]) and is_integer(r["amount_cents"]) and r["amount_cents"] >= 0 and
           r["status"] in ["open", "paid"] do
        {:cont,
         {:ok,
          acc ++
            [%{external_id: r["external_id"], counterparty: r["counterparty"], amount_cents: r["amount_cents"], due_date: r["due_date"], status: r["status"]}]}}
      else
        {:halt, {:error, {Vocab.err(:invalid), [:records]}}}
      end
    end)
  end

  def get(ent, kind, as_of) when kind in @kinds do
    case Date.from_iso8601(as_of) do
      {:ok, asof} ->
        recs = State.get(fn s -> s.arap |> Map.get({ent, kind}, %{}) |> Map.values() end)
        open = Enum.filter(recs, &(&1.status == "open"))
        aging = Enum.reduce(open, %{current: 0, d1_30: 0, d31_60: 0, d61_90: 0, d90_plus: 0}, fn r, a -> Map.update!(a, bucket(r.due_date, asof), &(&1 + r.amount_cents)) end)

        {:ok,
         %{
           entity: ent,
           kind: kind,
           record_count: length(recs),
           open_count: length(open),
           open_balance_cents: open |> Enum.map(& &1.amount_cents) |> Enum.sum(),
           aging: aging,
           records: Enum.sort_by(recs, & &1.external_id)
         }}

      _ ->
        {:error, {Vocab.err(:invalid), [:as_of]}}
    end
  end

  def get(_, _, _), do: {:error, {Vocab.err(:invalid), [:kind]}}

  defp bucket(nil, _), do: :current

  defp bucket(due, asof) do
    case Date.from_iso8601(due) do
      {:ok, d} ->
        age = Date.diff(asof, d)

        cond do
          age <= 0 -> :current
          age <= 30 -> :d1_30
          age <= 60 -> :d31_60
          age <= 90 -> :d61_90
          true -> :d90_plus
        end

      _ ->
        :current
    end
  end
end
