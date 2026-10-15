defmodule Smalt.PPlan.Task do
  @moduledoc """
  Durable P-PLAN task resource over the Smalt substrate (`Smalt.Store` ETS).

  Store-backed manual read/write: the resource is a plain map persisted with
  `Smalt.Store.put/get/delete/list` on the `:smalt_pplan_tasks` table (the same
  substrate that carries the ARM LRO op records). No Ash runtime: `ash` is an
  optional dep of smalt and the ash-pplan pack family renders consumer modules,
  so this module is the disclosed adaptation of the ash-pplan pack family
  (see docs/PACK_INTEGRATION/ash-pplan.md) for smalt's pure-Elixir substrate.

  Protocol-court-validated state machine (adapted from
  packs/ash-pplan-protocol-court-pack ontology `pcp:runMachine`, narrowed to the
  durable task-store surface this lane specifies):

      admitted -> running -> succeeded | failed

  Terminal states absorb (no out-edges). Every write that changes `status` goes
  through `transition/4`, which consults the court (`validate_transition/2`)
  before the store write; a refused edge raises a typed refusal.

  Claim/recover durability (adapted from the chaos-pack kill-phase contract and
  the store-conformance claim laws): `claim/2` takes an exclusive, serialized
  lease via `Smalt.Store.compare_and_swap/4`; if the claimant process dies
  mid-transition, `recover/0` returns the task to `:admitted` (claimable
  again). The kill-mid-transition chaos row in test/pplan_test.exs exercises
  exactly that: claim -> kill claimant -> task returns to claimable.
  """

  use GenServer

  alias Smalt.Store

  @table :smalt_pplan_tasks
  @statuses [:admitted, :running, :succeeded, :failed]
  @terminal [:succeeded, :failed]
  @transitions [admitted: :running, running: :succeeded, running: :failed]

  @typedoc "Task id (binary key in the store table)."
  @type id :: String.t()

  @typedoc "Task status in the protocol court machine."
  @type status :: :admitted | :running | :succeeded | :failed

  @type t :: %{
          required(:id) => id(),
          required(:status) => status(),
          required(:claimed_by) => pid() | nil,
          required(:attempts) => pos_integer(),
          required(:effects) => %{String.t() => pos_integer()},
          required(:created_at) => DateTime.t(),
          required(:updated_at) => integer()
        }

  @type transition :: {status(), status()}

  @doc "Statuses of the protocol court machine."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Terminal statuses (absorbing)."
  @spec terminal() :: [status()]
  def terminal, do: @terminal

  @doc "Allowed transitions of the protocol court machine."
  @spec transitions() :: [{status(), status()}]
  def transitions, do: @transitions

  @doc """
  Ensures the store table exists (the table owner is this module's GenServer).
  Idempotent; starts the GenServer if not running.
  """
  @spec ensure() :: :ok
  def ensure do
    if :ets.info(@table) == :undefined do
      case GenServer.whereis(__MODULE__) do
        nil ->
          {:ok, _pid} = GenServer.start(__MODULE__, :ok, name: __MODULE__)
          :ok

        _pid ->
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Inserts or overwrites the task record (manual read/write, no changeset).
  Returns `{:ok, task}` with `updated_at` refreshed.
  """
  @spec put(t()) :: {:ok, t()}
  def put(task) do
    :ok = ensure()
    task = %{task | updated_at: :erlang.monotonic_time()}
    Store.put(@table, task.id, task)
    {:ok, task}
  end

  @doc """
  Reads a task record; `nil` when absent (`Smalt.Store.get/2` returns
  `:error | {:ok, v}`).
  """
  @spec get(id()) :: t() | nil
  def get(id) do
    :ok = ensure()
    case Store.get(@table, id) do
      {:ok, task} -> task
      :error -> nil
    end
  end

  @doc "Deletes a task record. Idempotent."
  @spec delete(id()) :: :ok
  def delete(id) do
    :ok = ensure()
    Store.delete(@table, id)
  end

  @doc "Lists all task records in key order (deterministic)."
  @spec list() :: [t()]
  def list do
    :ok = ensure()
    Store.list(@table)
  end

  @doc """
  Protocol court: validates a from->to edge against the machine. Returns `:ok`
  when the edge is lawful, `{:error, {:refused, from, to}}` otherwise.
  Terminal states absorb: any out-edge from a terminal status is refused
  (terminal_absorbing, a chaos-pack invariant).
  """
  @spec validate_transition(status(), status()) ::
          :ok | {:error, {:refused, status(), status()}}
  def validate_transition(from, to) do
    cond do
      from not in @statuses or to not in @statuses ->
        {:error, {:refused, from, to}}

      from in @terminal ->
        {:error, {:refused, from, to}}

      {from, to} in @transitions ->
        :ok

      true ->
        {:error, {:refused, from, to}}
    end
  end

  @doc """
  Applies one court-validated transition to the task, CAS'd on the current
  record so a concurrent writer conflicts instead of clobbering. Returns
  `{:ok, next}` or `{:error, {:refused, from, to}}` / `{:error, :conflict}`.
  """
  @spec transition(t(), status(), (t() -> t()) | map(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def transition(task, to, patch \\ %{}, _opts \\ []) when is_map(patch) or is_list(patch) do
    :ok = ensure()

    with :ok <- validate_transition(task.status, to) do
      base =
        patch
        |> Enum.reduce(task, fn {k, v}, acc -> Map.put(acc, k, v) end)
        |> Map.put(:status, to)
        |> Map.put(:updated_at, :erlang.monotonic_time())

      case Store.compare_and_swap(@table, task.id, task, base) do
        :ok -> {:ok, base}
        {:error, :conflict} = err -> err
      end
    end
  end

  @doc """
  Serialized exclusive claim: admitted -> running, leased to `claimant`,
  attempts bumped. Exactly one winner among concurrent claimants (the CAS runs
  inside the `Smalt.Store` GenServer). `:taken` when not claimable.
  """
  @spec claim(id(), pid() | atom()) :: {:ok, t()} | :taken
  def claim(id, claimant) do
    :ok = ensure()

    case get(id) do
      nil ->
        :taken

      task ->
        case validate_transition(task.status, :running) do
          :ok ->
            next = %{
              task
              | status: :running,
                claimed_by: claimant,
                attempts: task.attempts + 1,
                updated_at: :erlang.monotonic_time()
            }

            case Store.compare_and_swap(@table, id, task, next) do
              :ok -> {:ok, next}
              {:error, :conflict} -> :taken
            end

          {:error, _} ->
            :taken
        end
    end
  end

  @doc """
  Kill-mid-transition recovery (chaos-pack kill phase): returns every
  `:running` task whose claimant process is dead back to `:admitted`
  (claimable again). Terminal tasks are never recovered (terminal absorbing).
  """
  @spec recover() :: [t()]
  def recover do
    :ok = ensure()

    for task <- list(),
        task.status == :running,
        claimed = task.claimed_by,
        dead?(claimed) do
      next = %{
        task
        | status: :admitted,
          claimed_by: nil,
          updated_at: :erlang.monotonic_time()
      }

      case Store.compare_and_swap(@table, task.id, task, next) do
        :ok -> next
        {:error, :conflict} -> get(task.id)
      end
    end
  end

  # ---- GenServer (table owner) ----

  @doc false
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [
        :ordered_set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    {:ok, %{}}
  end

  defp dead?(pid) when is_pid(pid), do: not Process.alive?(pid)
  defp dead?(_), do: true
end
