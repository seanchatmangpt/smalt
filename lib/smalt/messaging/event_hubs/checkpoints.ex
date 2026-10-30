defmodule Smalt.Messaging.EventHubs.Checkpoints do
  @moduledoc """
  Checkpoint management (CAS, processing leases, reconcile) — extracted
  verbatim from `Smalt.Messaging.EventHubs` along the `# -- Checkpoint
  management` fence (T10 tail split, v26.10.29 r10d). Same serialization law:
  every write rides the `Smalt.Messaging.EventHubs.Server` transaction point;
  `ensure_tables/0` stays the parent's public face.
  """

  @partitions :smalt_eh_partitions
  @checkpoints :smalt_eh_checkpoints

  alias Smalt.Messaging.EventHubs
  alias Smalt.Messaging.EventHubs.Server, as: EHServer

  # -- Checkpoint management ------------------------------------------------------

  @doc """
  Compare-and-swap the checkpoint for `{group, partition}`: succeeds only when the
  current checkpoint equals `expect`. Returns `:ok` or `{:error, :conflict}`.
  Routing through the internal serialised server (`Smalt.Messaging.EventHubs.Server`)
  unifies serialization with `reserve_processing/4` — exactly one of N concurrent
  callers with the same `expect` wins, race-free by construction.
  """
  @spec compare_and_swap(String.t(), String.t(), map(), map()) :: :ok | {:error, :conflict}
  def compare_and_swap(group, partition, expect, new)
      when is_binary(group) and is_binary(partition) and is_map(expect) and is_map(new) do
    EventHubs.ensure_tables()
    key = {group, partition}

    # NO caller-side seed of the checkpoint row (lens-4 F-2, the F-1 window
    # class): a lookup-then-insert seed here raced `reserve_processing` — a
    # claim written by the serialized server between the lookup and the insert
    # was clobbered by the stale seed insert, silently dropping a live lease
    # (two consumers hold one partition). The serialized `cas_claim_blind`
    # handler already treats an absent row as the zero checkpoint, so the seed
    # carried zero semantics; all checkpoint writes are now serialized.

    # Claim-blind CAS (lens-2 cycle 2): `reconcile/2` — the documented
    # authoritative view — strips the `"claim"` lease field, so a client
    # building `expect` from it could never win while a lease rides the same
    # row. The CAS therefore compares against the claim-stripped checkpoint and
    # preserves the live claim on write. Routing through the serialized server
    # unifies serialization with `reserve_processing/4` (claim writes), closing
    # the reserve-vs-CAS race where the two wrote different serialization
    # points.
    EHServer.transaction({:cas_claim_blind, key, expect, new})
  end

  # Checkpoints are keyed {group, partition}; a claim row lives inside the same
  # map.

  @doc """
  Acquire a processing lease on `{group, partition}` for `owner` lasting `ttl_ms`.
  `:ok` if the lease is free/expired/already owned by `owner`; `{:error, :conflict}`
  if another live owner holds it. Expired leases are reclaimed by `sweep/0` or
  lazily on the next reservation.

  The caller passes a RELATIVE `ttl_ms`; the expiry (`until`) is computed inside
  the serialized server from its own clock (V261014-04 F5) — one clock source
  for the claim-free check and the stored expiry.
  """
  @spec reserve_processing(String.t(), String.t(), term(), pos_integer()) ::
          :ok | {:error, :conflict}
  def reserve_processing(group, partition, owner, ttl_ms)
      when is_binary(group) and is_binary(partition) and is_integer(ttl_ms) and ttl_ms > 0 do
    EventHubs.ensure_tables()
    EHServer.transaction({:reserve, {group, partition}, owner, ttl_ms})
  end

  @doc """
  Authoritative view for `{group, partition}`: the partition's assigned sequence
  (broker truth) and the stored checkpoint. Never fails on missing rows — absent
  state reads as zero/empty.
  """
  @spec reconcile(String.t(), String.t()) :: {:ok, map()}
  def reconcile(group, partition) do
    EventHubs.ensure_tables()

    partition_seq =
      case :ets.lookup(@partitions, partition) do
        [{^partition, %{"seq" => seq}}] -> seq
        _ -> 0
      end

    checkpoint =
      case :ets.lookup(@checkpoints, {group, partition}) do
        [{_k, cp}] -> Map.delete(cp, "claim")
        [] -> nil
      end

    {:ok,
     %{
       "group" => group,
       "partition" => partition,
       "seq" => partition_seq,
       # audit-A22-F3: offsets are wire strings everywhere else in this module
       # (send_event, the KD-53 split path) — reconcile must match.
       "offset" => Integer.to_string(partition_seq),
       "checkpoint" => checkpoint
     }}
  end
end
