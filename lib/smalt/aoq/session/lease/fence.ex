defmodule Smalt.Aoq.Session.Lease.Fence do
  @moduledoc """
  Provider-lease binding and epoch/generation frame fence for an AoQ session.

  A session binds one lease (`id`, `epoch`, `generation`). Every frame is
  checked against it:

  - lease id never bound to this session: `{:error, {:unbound_lease, id}}`
  - frame epoch differs from the lease epoch, or `frame_ordinal` is below
    the lease generation: `{:error, {:stale_frame, detail}}`
  - `frame_ordinal` above the lease generation:
    `{:error, {:generation_ahead, detail}}`

  The generation is compared against `Smalt.Aoq.Frame` field
  `frame_ordinal` (u32). The fence is pure: a refusal never changes the
  lease value, so state read before and after is equal.

  Hardware-bound lease keys are out of scope (enclave attestation BLOCKED).
  """

  alias Smalt.Aoq.Epoch
  alias Smalt.Aoq.Frame

  @enforce_keys [:id, :epoch, :generation]
  defstruct [:id, :epoch, :generation]

  @type t :: %__MODULE__{
          id: term(),
          epoch: :genesis | :rotated_1 | :rotated_2,
          generation: non_neg_integer()
        }

  @type refusal ::
          {:unbound_lease, term()}
          | {:stale_frame, {:epoch | :generation, non_neg_integer(), non_neg_integer()}}
          | {:generation_ahead, {non_neg_integer(), non_neg_integer()}}

  @doc "Bind a lease. `:retired` is refused: it is never lawful on a live lease."
  @spec bind(term(), Epoch.t(), non_neg_integer()) :: {:ok, t()} | {:error, :retired_epoch}
  def bind(_id, :retired, _generation), do: {:error, :retired_epoch}

  def bind(id, epoch, generation)
      when epoch in [:genesis, :rotated_1, :rotated_2] and is_integer(generation) and
             generation >= 0 and generation <= 0xFFFFFFFF do
    {:ok, %__MODULE__{id: id, epoch: epoch, generation: generation}}
  end

  @doc """
  Renew a lease to a new epoch and generation. The pair must advance:
  epoch not below the current one, generation strictly above it.
  """
  @spec renew(t(), Epoch.t(), non_neg_integer()) ::
          {:ok, t()} | {:error, :retired_epoch | {:lease_regression, term()}}
  def renew(%__MODULE__{}, :retired, _generation), do: {:error, :retired_epoch}

  def renew(%__MODULE__{} = lease, epoch, generation)
      when epoch in [:genesis, :rotated_1, :rotated_2] and is_integer(generation) and
             generation <= 0xFFFFFFFF do
    if Epoch.to_wire(epoch) >= Epoch.to_wire(lease.epoch) and generation > lease.generation do
      {:ok, %{lease | epoch: epoch, generation: generation}}
    else
      {:error, {:lease_regression, {{lease.epoch, lease.generation}, {epoch, generation}}}}
    end
  end

  @doc "Check a frame naming `lease_id` against the bound lease."
  @spec check(t(), term(), Frame.t()) :: :ok | {:error, refusal()}
  def check(%__MODULE__{id: id} = lease, id, %Frame{} = frame) do
    want_epoch = Epoch.to_wire(lease.epoch)

    cond do
      frame.epoch != want_epoch ->
        {:error, {:stale_frame, {:epoch, frame.epoch, want_epoch}}}

      frame.frame_ordinal < lease.generation ->
        {:error, {:stale_frame, {:generation, frame.frame_ordinal, lease.generation}}}

      frame.frame_ordinal > lease.generation ->
        {:error, {:generation_ahead, {frame.frame_ordinal, lease.generation}}}

      true ->
        :ok
    end
  end

  def check(%__MODULE__{}, other_id, %Frame{}), do: {:error, {:unbound_lease, other_id}}
end
