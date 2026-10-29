# GLD-2 — CDC incremental ingestion court (plain elixir, stdlib only).
# Run: elixir test/integration/gld2_cdc_court.exs   (exit 0 = PASS)
# No Process.sleep anywhere. Fully deterministic: no :rand, fixed corpus.

defmodule Gld2.Cdc do
  @moduledoc """
  Change-data-capture incremental ingestion over plain OCEL-shaped maps
  (same envelope shape as `Smalt.Ocel`). Epoch snapshot = full ingest fold;
  delta log = append-only OCEL event stream; ledger = pure left fold over
  time-ordered events.
  """

  @ts0 "2026-10-21T00:00:00Z"
  @ts_ins "2026-10-21T00:05:00Z"
  @ts_upd "2026-10-21T00:06:00Z"
  @ts_del "2026-10-21T00:07:00Z"

  # --- fixture builders ---------------------------------------------------

  def epoch1_events(n) do
    for i <- 1..n do
      event("e-ing-#{pad(i)}", "ingest", @ts0, "epoch1", i * 100, "row-#{i}")
    end
  end

  def delta_events do
    inserts =
      for i <- 101..120 do
        event("e-ins-#{pad(i)}", "insert", @ts_ins, "t-ins", i * 100, "row-#{i}")
      end

    updates =
      for k <- 1..10 do
        oid = "row-#{k * 2}"
        old_value = k * 2 * 100

        [
          event("e-upd-#{pad(k)}-before", "update_before", @ts_upd, "t-upd-#{k}", old_value, oid),
          event("e-upd-#{pad(k)}-after", "update_after", @ts_upd, "t-upd-#{k}", 1_000_000 + k, oid)
        ]
      end

    deletes =
      for k <- 1..5 do
        # deletes target rows that exist after epoch1+inserts+updates
        oid = "row-#{k * 7 + 50}"
        event("e-del-#{k}", "delete", @ts_del, "t-del-#{k}", nil, oid)
      end

    inserts ++ Enum.concat(updates) ++ deletes
  end

  defp event(id, type, time, tx, value, oid) do
    attrs = %{"op" => type, "tx" => tx}
    attrs = if is_nil(value), do: attrs, else: Map.put(attrs, "value", value)

    %{
      "id" => id,
      "type" => type,
      "time" => time,
      "attributes" => attrs,
      "relationships" => [%{"objectId" => oid, "qualifier" => "row"}]
    }
  end

  defp pad(i), do: String.pad_leading(Integer.to_string(i), 4, "0")

  # --- projection -----------------------------------------------------------

  @doc "Ledger = ordered fold. Returns %{state: map, tombstones: MapSet, seen: MapSet}."
  def project(events, acc \\ %{state: %{}, tombstones: MapSet.new(), seen: MapSet.new()}) do
    events
    |> Enum.sort_by(&{&1["time"], &1["id"]})
    |> Enum.reduce(acc, &apply_event/2)
  end

  defp apply_event(ev, acc) do
    id = ev["id"]
    oid = hd(ev["relationships"])["objectId"]

    if MapSet.member?(acc.seen, id) do
      # idempotent replay: an already-applied event id is a no-op
      acc
    else
      acc = %{acc | seen: MapSet.put(acc.seen, id)}

      case ev["type"] do
        t when t in ["ingest", "insert"] ->
          %{acc | state: Map.put(acc.state, oid, ev["attributes"])}

        "update_before" ->
          # observation of prior state: recorded in seen, state unchanged
          acc

        "update_after" ->
          %{acc | state: Map.put(acc.state, oid, ev["attributes"])}

        "delete" ->
          state = Map.delete(acc.state, oid)
          %{acc | state: state, tombstones: MapSet.put(acc.tombstones, oid)}

        other ->
          raise "Gld2.Cdc: unknown event type #{inspect(other)} (fail-closed)"
      end
    end
  end

  def digest(%{state: state, tombstones: tombstones}) do
    :crypto.hash(:sha256, :erlang.term_to_binary({state, MapSet.to_list(tombstones) |> Enum.sort()}))
    |> Base.encode16(case: :lower)
  end

  @doc "Object state at latest timestamp = its state entry, or :deleted if tombstoned."
  def object_state(ledger, oid) do
    if MapSet.member?(ledger.tombstones, oid), do: :deleted, else: Map.get(ledger.state, oid)
  end
end

defmodule Gld2.Court do
  alias Gld2.Cdc

  @epoch1_rows 100
  @ins 20
  @upd 10
  @del 5

  defp assert!(cond, msg) do
    unless cond, do: raise("GLD-2 COURT FAIL: " <> msg)
    IO.puts("  ok  " <> msg)
  end

  def run do
    IO.puts("GLD-2 CDC COURT")

    epoch1 = Cdc.epoch1_events(@epoch1_rows)
    delta = Cdc.delta_events()

    # --- leg 1: exact delta reflection ------------------------------------
    l1 = Cdc.project(epoch1)
    assert!(map_size(l1.state) == @epoch1_rows, "epoch1 ledger holds exactly 100 rows")
    assert!(MapSet.size(l1.seen) == @epoch1_rows, "epoch1 event count == 100")

    l2 = Cdc.project(delta, l1)
    assert!(
      MapSet.size(l2.seen) == @epoch1_rows + @ins + 2 * @upd + @del,
      "event count == 145 (100 ingest + 20 insert + 20 update-pair + 5 delete)"
    )
    assert!(map_size(l2.state) == @epoch1_rows + @ins - @del, "ledger rows == 115 (100+20-5, no phantoms)")

    # updated ids show after-image at latest timestamp
    for k <- 1..@upd do
      oid = "row-#{k * 2}"
      st = Cdc.object_state(l2, oid)
      assert!(st != nil and st["value"] == 1_000_000 + k and st["tx"] == "t-upd-#{k}",
        "updated #{oid} at latest timestamp == after-image")
    end

    # inserted ids present
    for i <- 101..120 do
      assert!(Cdc.object_state(l2, "row-#{i}")["value"] == i * 100, "inserted row-#{i} present")
    end

    # deleted ids absent, tombstoned, no phantom rows anywhere
    for k <- 1..@del do
      oid = "row-#{k * 7 + 50}"
      assert!(Cdc.object_state(l2, oid) == :deleted, "deleted #{oid} tombstoned, absent from state")
    end

    phantom = MapSet.to_list(l2.seen)
    assert!(length(phantom) == @epoch1_rows + @ins + 2 * @upd + @del, "no phantom events")

    every_oid_with_event =
      l2.seen
      |> then(fn _ ->
        (epoch1 ++ delta)
        |> Enum.map(&hd(&1["relationships"])["objectId"])
        |> MapSet.new()
      end)

    state_oids = MapSet.new(Map.keys(l2.state))
    unexplained = MapSet.difference(state_oids, every_oid_with_event)
    assert!(MapSet.size(unexplained) == 0, "no phantom rows: every state row traces to a producing event")

    # --- leg 2: idempotent replay ------------------------------------------
    replay = Cdc.project(delta, l2)
    assert!(Cdc.digest(replay) == Cdc.digest(l2), "same delta applied twice == identical ledger digest")

    full_replay = Cdc.project(epoch1 ++ delta ++ delta ++ epoch1)
    assert!(Cdc.digest(full_replay) == Cdc.digest(l2), "full replay with duplicated epochs == identical digest")

    # --- leg 3: durability (typed PENDING journal, real segment file) -------
    journal_leg =
      case Code.ensure_loaded?(:"Elixir.Smalt.Storage.Journal") do
        true -> {:journal, :landed}
        false -> {:journal, :pending, "PROD-1"}
      end

    seg_path = Path.join(System.tmp_dir!(), "gld2-delta-segment-#{:os.system_time(:nano_seconds)}.log")

    try do
      # append-only segment: one JSON-ish term line per event (use inspect, readable)
      File.mkdir_p!(Path.dirname(seg_path))

      Enum.each(delta, fn ev ->
        File.write!(seg_path, inspect(ev) <> "\n", [:append])
      end)

      from_disk =
        seg_path
        |> File.stream!()
        |> Enum.map(&Code.eval_string(String.trim_trailing(&1)) |> elem(0))
        |> then(&Cdc.project(&1, l1))

      assert!(Cdc.digest(from_disk) == Cdc.digest(l2), "delta replayed from durable segment == identical ledger digest")
    after
      File.rm(seg_path)
    end

    case journal_leg do
      {:journal, :pending, wo} ->
        IO.puts("  PENDING  Smalt.Storage.Journal not landed (#{wo}); durability proven via real segment file replay")

      {:journal, :landed} ->
        raise "GLD-2: Journal landed — upgrade this leg to exercise it (fail loudly rather than silently skip)"
    end

    # --- leg 4: tamper non-vacuity ------------------------------------------
    tampered = List.replace_at(delta, 0, put_in(delta |> Enum.at(0), ["attributes", "value"], 999_999))

    l2_t = Cdc.project(tampered, l1)
    assert!(Cdc.digest(l2_t) != Cdc.digest(l2), "tampered delta provably changes ledger digest")

    bad_after =
      Enum.map(delta, fn ev ->
        if ev["type"] == "update_after" and ev["attributes"]["tx"] == "t-upd-1" do
          put_in(ev, ["attributes", "value"], 42)
        else
          ev
        end
      end)

    l2_bad = Cdc.project(bad_after, l1)
    assert!(Cdc.object_state(l2_bad, "row-2")["value"] == 42 and Cdc.digest(l2_bad) != Cdc.digest(l2),
      "after-image tamper flips projected state (court is not tautological)")

    digest = Cdc.digest(l2)
    IO.puts("GLD-2 COURT: PASS")
    IO.puts("ledger digest: #{digest}")
    IO.puts("events: #{MapSet.size(l2.seen)}  rows: #{map_size(l2.state)}  tombstones: #{MapSet.size(l2.tombstones)}")
    IO.puts("journal: " <> inspect(journal_leg))
    :ok
  end
end

case Gld2.Court.run() do
  :ok -> System.halt(0)
  other ->
    IO.puts("GLD2 COURT: FAIL #{inspect(other)}")
    System.halt(1)
end
