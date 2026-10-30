defmodule Smalt.Mcp.Tool.CosmosFeed do
  @moduledoc """
  MCP Cosmos change-feed read family: `cosmos.changefeed.peek` (read-only
  PEEK of docs pending above the persisted cursor) and
  `cosmos.changefeed.cursor` (the cursor value only).

  Both are READ-ONLY: the wire `change_feed/3` advances the persisted
  per-container cursor ({2, db, coll} in :smalt_cosmos_pk_meta) as a side
  effect, so the MCP read surface cannot call it (read-only by law). Cursor
  semantics mirrored from `Cosmos.do_change_feed/2` (ts boundary + seen-etag
  pins); cursor-record absence = fresh feed (ts 0, empty seen map), same as
  `Cosmos.cf_cursor/1`.

  References the generated TTL surface (`Smalt.Mcp.Descriptor`); never
  redefines tool metadata. Returns the standard tool envelope:
  `{:ok, result}` | `{:refusal, code, message}` — `nil` when the tool id is
  not in this family.
  """

  @invalid_params_code "INVALID_PARAMS"

  # The {2, db, coll} pk_meta record is the per-container change-feed cursor
  # (the same key the wire change_feed/3 advances).
  @cf_cursor_key_index 2

  def input_schema("cosmos.changefeed.peek") do
    %{
      "type" => "object",
      "required" => ["db", "coll"],
      "properties" => %{
        "db" => %{"type" => "string"},
        "coll" => %{"type" => "string"}
      }
    }
  end

  def input_schema("cosmos.changefeed.cursor") do
    %{
      "type" => "object",
      "required" => ["db", "coll"],
      "properties" => %{
        "db" => %{"type" => "string"},
        "coll" => %{"type" => "string"}
      }
    }
  end

  def input_schema(_other), do: nil

  def invoke("cosmos.changefeed.peek", args) do
    case args do
      %{"db" => db, "coll" => coll} when is_binary(db) and is_binary(coll) ->
        if :ets.info(:smalt_cosmos_docs) == :undefined or
             :ets.info(:smalt_cosmos_pk_meta) == :undefined do
          {:refusal, "STORE_NOT_READY", "refused: cosmos store tables not initialized"}
        else
          cursor_key = {@cf_cursor_key_index, db, coll}
          cursor = cf_cursor_read(cursor_key)

          pending =
            :smalt_cosmos_docs
            |> Smalt.Store.list_prefix("#{db}/#{coll}/")
            |> Enum.filter(fn doc -> cf_doc_new?(doc, cursor) end)
            |> Enum.sort_by(&{&1["_ts"] || 0, &1["id"]})

          {:ok,
           %{
             "db" => db,
             "coll" => coll,
             "pending" => pending,
             "count" => length(pending),
             "cursor_advanced" => false
           }}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: cosmos.changefeed.peek requires db and coll"}
    end
  end

  def invoke("cosmos.changefeed.cursor", args) do
    case args do
      %{"db" => db, "coll" => coll} when is_binary(db) and is_binary(coll) ->
        if :ets.info(:smalt_cosmos_pk_meta) == :undefined do
          {:refusal, "STORE_NOT_READY", "refused: cosmos store tables not initialized"}
        else
          cursor = cf_cursor_read({@cf_cursor_key_index, db, coll})

          {:ok,
           %{
             "db" => db,
             "coll" => coll,
             "cursor" => %{
               "ts" => cursor["ts"],
               "seen_count" => map_size(cursor["seen"])
             },
             "cursor_advanced" => false
           }}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: cosmos.changefeed.cursor requires db and coll"}
    end
  end

  def invoke(_other, _args), do: nil

  # Read-only mirror of Cosmos.cf_cursor/1 + cf_is_new?/2 (same ts-boundary +
  # seen-etag semantics, cursor record NEVER advanced here).
  defp cf_cursor_read(cursor_key) do
    case :ets.lookup(:smalt_cosmos_pk_meta, cursor_key) do
      [{^cursor_key, %{"ts" => ts, "seen" => seen}}]
      when is_integer(ts) and is_map(seen) ->
        %{"ts" => ts, "seen" => seen}

      _ ->
        %{"ts" => 0, "seen" => %{}}
    end
  end

  defp cf_doc_new?(doc, cursor) do
    ts = doc["_ts"] || 0

    ts > cursor["ts"] or
      (ts == cursor["ts"] and cursor["seen"][doc["id"]] != doc["_etag"])
  end
end
