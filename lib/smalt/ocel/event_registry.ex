defmodule Smalt.Ocel.EventRegistry do
  @moduledoc """
  Closed vocabulary of smalt OCEL event types.

  # PROJECTED FROM THE CLOSED VOCABULARY -- regenerable, do not hand-edit
  # (see the smalt-substrate-pack ontology; this file is a projection and
  # may be regenerated from the graph without loss).

  Every OCEL 2.0 event emitted into the smalt sink must carry one of these
  `"type"` values. The gate (`event_type?/1`) is log-and-drop: an unknown
  type is never admitted into the log and never raises — the caller logs
  the drop and moves on (same discipline as
  `Xaas.Ultracode.Ocel.Validator`'s closed type laws, applied at emission
  time instead of adjudication time).
  """

  @event_types ~w(
    arm.resource.transition
    cosmos.doc.crud
    blob.custody.transition
    amqp.delivery.settled
    skr.release
    ledger.append
  )

  @doc "The closed vocabulary of admissible event types (sorted)."
  @spec event_types() :: [String.t()]
  def event_types, do: @event_types

  @doc """
  Gate: is `type` an admissible event type? Pure, total, never raises.
  """
  @spec event_type?(term()) :: boolean()
  def event_type?(type) when is_binary(type), do: type in @event_types
  def event_type?(_), do: false

  @doc """
  Closed object-type vocabulary. Events reference objects of these types
  only (ids only — the matter-isolation law: never payloads).
  """
  @spec object_types() :: [String.t()]
  def object_types, do: ~w(resource partition document blob queue session message skr ledger)
end
