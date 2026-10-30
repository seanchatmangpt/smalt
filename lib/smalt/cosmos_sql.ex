defmodule Smalt.CosmosSql do
  # T09 cosmos split (lane L10, v26.10.29): the SQL engine moved verbatim to
  # `Smalt.DataPlane.Cosmos.Sql` (lib/smalt/data_plane/cosmos/sql.ex). This
  # defdelegate shim keeps every `Smalt.CosmosSql.*` call site, court, and the
  # internal-tier census row (test/internal/internal_tier_census_test.exs)
  # unchanged. Wire behavior is byte-identical: delegation is in-process and
  # total (every public arity is forwarded, defaults included).
  @moduledoc """
  Compatibility shim for the Cosmos SQL engine.

  The engine now lives at `Smalt.DataPlane.Cosmos.Sql`
  (`lib/smalt/data_plane/cosmos/sql.ex`); every public function — including
  default arguments — is forwarded unchanged.
  """

  defdelegate parse(query, params \\ %{}), to: Smalt.DataPlane.Cosmos.Sql
  defdelegate eval_doc(query, doc), to: Smalt.DataPlane.Cosmos.Sql
  defdelegate eval_docs(query, docs), to: Smalt.DataPlane.Cosmos.Sql
  defdelegate run(query, docs, params \\ %{}), to: Smalt.DataPlane.Cosmos.Sql
  defdelegate eval_fn(name, args, doc), to: Smalt.DataPlane.Cosmos.Sql
  defdelegate get_in_doc(doc, path), to: Smalt.DataPlane.Cosmos.Sql
  defdelegate truthy?(expr, doc, params), to: Smalt.DataPlane.Cosmos.Sql
  defdelegate tokenize(str), to: Smalt.DataPlane.Cosmos.Sql
end
