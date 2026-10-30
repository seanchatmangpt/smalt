defmodule Smalt.DataPlane.Cosmos.Accounts do
  # T09 cosmos split (lane L10, v26.10.29): account-level face over the Cosmos
  # engine (`Smalt.DataPlane.Cosmos`). Delegation is in-process and total —
  # wire behavior byte-identical with the pre-split engine.
  @moduledoc """
  Cosmos account-level face (store readiness).

  One of the T09 aggregate faces (Accounts / Databases / Containers / Docs)
  over `Smalt.DataPlane.Cosmos`; every entry point forwards to the engine,
  which remains the wire-semantics owner.
  """

  defdelegate store_ready?(), to: Smalt.DataPlane.Cosmos
end
