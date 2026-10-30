defmodule Smalt.DataPlane.Cosmos.Databases do
  # T09 cosmos split (lane L10, v26.10.29): database-level face over the
  # Cosmos engine (`Smalt.DataPlane.Cosmos`). Delegation is in-process and
  # total — wire behavior byte-identical with the pre-split engine.
  @moduledoc """
  Cosmos database face (create / list / delete, rid derivation).
  """

  defdelegate create_db(db, headers \\ %{}), to: Smalt.DataPlane.Cosmos
  defdelegate list_dbs(headers \\ %{}), to: Smalt.DataPlane.Cosmos
  defdelegate delete_database(db, headers), to: Smalt.DataPlane.Cosmos
  defdelegate drop_db(db), to: Smalt.DataPlane.Cosmos
  defdelegate db_rid(db), to: Smalt.DataPlane.Cosmos
end
