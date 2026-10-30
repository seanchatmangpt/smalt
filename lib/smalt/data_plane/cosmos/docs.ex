defmodule Smalt.DataPlane.Cosmos.Docs do
  # T09 cosmos split (lane L10, v26.10.29): document-level face over the
  # Cosmos engine (`Smalt.DataPlane.Cosmos`) — CRUD, bulk, query, change
  # feed + continuation tokens, list feed, rid derivation. Delegation is
  # in-process and total — wire behavior byte-identical with the pre-split
  # engine.
  @moduledoc """
  Cosmos document face (CRUD, bulk, query, change feed, list feed).
  """

  defdelegate create_doc(db, coll, body, headers), to: Smalt.DataPlane.Cosmos
  defdelegate get_doc(db, coll, doc_id, headers), to: Smalt.DataPlane.Cosmos
  defdelegate put_doc(db, coll, doc_id, body, headers), to: Smalt.DataPlane.Cosmos
  defdelegate patch_doc(db, coll, doc_id, ops, headers), to: Smalt.DataPlane.Cosmos
  defdelegate delete_doc(db, coll, doc_id, headers), to: Smalt.DataPlane.Cosmos
  defdelegate bulk_operations(db, coll, ops, headers), to: Smalt.DataPlane.Cosmos
  defdelegate list_docs(db, coll, prefix \\ "", headers \\ %{}), to: Smalt.DataPlane.Cosmos
  defdelegate query_docs(db, coll, body, headers), to: Smalt.DataPlane.Cosmos
  defdelegate change_feed_cursor(db, coll, headers \\ %{}), to: Smalt.DataPlane.Cosmos
  defdelegate change_feed(db, coll, params \\ %{}, headers \\ %{}), to: Smalt.DataPlane.Cosmos
  defdelegate doc_rid(db, coll, id), to: Smalt.DataPlane.Cosmos
end
