defmodule Smalt.DataPlane.Cosmos.Containers do
  # T09 cosmos split (lane L10, v26.10.29): container-level face over the
  # Cosmos engine (`Smalt.DataPlane.Cosmos`), including the container-child
  # script/UDF/trigger surfaces (typed refusals). Delegation is in-process
  # and total — wire behavior byte-identical with the pre-split engine.
  @moduledoc """
  Cosmos container face (create / replace / list / meta / rid, analytical
  store, partition-key ranges, script refusals).
  """

  defdelegate create_collection(db, coll, body, headers \\ %{}), to: Smalt.DataPlane.Cosmos
  defdelegate replace_collection(db, coll, body, headers \\ %{}), to: Smalt.DataPlane.Cosmos
  defdelegate list_collections(db, headers \\ %{}), to: Smalt.DataPlane.Cosmos
  defdelegate partition_key_ranges(db, coll, headers \\ %{}), to: Smalt.DataPlane.Cosmos
  defdelegate define_container(db, coll, paths), to: Smalt.DataPlane.Cosmos
  defdelegate container_meta(db, coll, headers \\ %{}), to: Smalt.DataPlane.Cosmos
  defdelegate container_meta_checked(db, coll, headers \\ %{}), to: Smalt.DataPlane.Cosmos
  defdelegate effective_ttl(db, coll), to: Smalt.DataPlane.Cosmos
  defdelegate analytical_store_sweep(db, coll), to: Smalt.DataPlane.Cosmos
  defdelegate delete_collection(db, coll, headers), to: Smalt.DataPlane.Cosmos
  defdelegate drop_container(db, coll), to: Smalt.DataPlane.Cosmos
  defdelegate coll_rid(db, coll), to: Smalt.DataPlane.Cosmos
  defdelegate list_sprocs(db, coll, headers \\ %{}), to: Smalt.DataPlane.Cosmos
  defdelegate create_sproc(db, coll, body, headers \\ %{}), to: Smalt.DataPlane.Cosmos
  defdelegate execute_sproc(db, coll, name, args, headers \\ %{}), to: Smalt.DataPlane.Cosmos
  defdelegate get_sproc(db, coll, name, headers \\ %{}), to: Smalt.DataPlane.Cosmos
  defdelegate replace_sproc(db, coll, name, body, headers \\ %{}), to: Smalt.DataPlane.Cosmos
  defdelegate delete_sproc(db, coll, name, headers \\ %{}), to: Smalt.DataPlane.Cosmos
  defdelegate list_udfs(db, coll), to: Smalt.DataPlane.Cosmos
  defdelegate put_udf(db, coll, name, body), to: Smalt.DataPlane.Cosmos
  defdelegate get_udf(db, coll, name), to: Smalt.DataPlane.Cosmos
  defdelegate delete_udf(db, coll, name), to: Smalt.DataPlane.Cosmos
  defdelegate list_triggers(db, coll), to: Smalt.DataPlane.Cosmos
  defdelegate put_trigger(db, coll, name, body), to: Smalt.DataPlane.Cosmos
  defdelegate get_trigger(db, coll, name), to: Smalt.DataPlane.Cosmos
  defdelegate delete_trigger(db, coll, name), to: Smalt.DataPlane.Cosmos
end
