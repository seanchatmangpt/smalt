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

  # Disposition (lens 6, ERRC-Reduce): `consumer/0` and `source_pack/0` were
  # typed callbacks that verify/1 never read and NO code read anywhere
  # (grep-evidenced lens 6: zero callers outside their own defs). The
  # consumer/source-pack metadata lives canonically in the ggen ontology
  # (`rtc:consumer`, `rtc:sourcePack` in ggen/ontology.ttl) and projects into
  # the generated catalog entries (@entry map), so the hand-module copies were
  # pure duplication — deleted, not pinned.

  @doc "Runs all assertions, returning a `Smalt.RuntimeContracts.Support.result`."
  @callback check() :: Smalt.RuntimeContracts.Support.result()
end
