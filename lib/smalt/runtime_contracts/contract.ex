defmodule Smalt.RuntimeContracts.Contract do
  @moduledoc """
  Behaviour for runtime integration contract modules.

  A contract module binds one plane (control / data / messaging) to its
  consumers with fast in-process assertions. The revops structural factory
  pass in `Smalt.RuntimeContracts` fans `verify/0` over every module
  implementing this behaviour.
  """

  @doc "Contract id, e.g. `:arm_envelope`."
  @callback name() :: atom()

  @doc "Plane the contract binds: `:control_plane`, `:data_plane`, `:messaging_plane`."
  @callback plane() :: atom()

  @doc "Consumer subject the contract binds (module or surface)."
  @callback consumer() :: String.t()

  @doc "Source pack the contract's invariants were fenced from."
  @callback source_pack() :: String.t()

  @doc "Runs all assertions, returning a `Smalt.RuntimeContracts.Support.result`."
  @callback check() :: Smalt.RuntimeContracts.Support.result()
end
