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

  ## Durability contract (lens6, pinned — NOT durable across restart)

  `:smalt_pplan_tasks` is a memory-only public ETS owned by this module's
  GenServer. It is deliberately NOT in `Smalt.Store`'s `@tables`/`clear/0`
  set. The pinned contract:

    * **Table-owner restart wipes every record.** Stopping
      `Smalt.PPlan.Task` destroys the ETS (named tables die with their
      owner); a re-`ensure/0` starts an EMPTY table. Restart = full task
      loss, including attempts and held leases. This is the disclosed
      adaptation of the ash-pplan pack for a pure-Elixir substrate, not an
      oversight to "fix" with DETS later without a migration receipt.
      **Raise candidate (typed, prior art confirmed)**: a DETS twin behind
      the same function surface, per `AshPPlan.Reactor.Durable.Store.Dets`
      (sync-on-mutation, 60s bounded calls, repair-wait reopen,
      trap_exit-after-open) — do not hand-roll a different shape.
    * **`Smalt.Store` restart does NOT touch the table** (different owner),
      but the CAS paths (`claim/2`, `transition/4`, `recover/0`) exit
      `{:noproc, ...}` while the Store GenServer is down, while the direct
      read/write paths (`get/1`, `put/1`, `list/0`, `delete/1`) keep
      working — a half-degraded window, not a full outage. Callers wanting
      fail-soft claim semantics under a Store outage must catch the exit.
    * **Crash-stampede safety**: after a table-owner death, N concurrent
      `ensure/0` callers settle the table with zero crashes (losers admit
      `{:already_started, _}` instead of matching `{:ok, _}`).

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

  # Keys a transition patch may not touch: identity, court-controlled state and
  # lifecycle bookkeeping are owned by the machine, never by the caller's patch.
  # :claimed_by is machine-owned too (lens2 cycle-1): without it, a patch on the
  # lawful admitted->running edge forges a lease (transition(t, :running,
  # claimed_by: attacker) yields a :running record without claim/2's CAS
  # serialization or attempts bump — a lease-forgery vector).
  @protected_keys [:id, :status, :created_at, :updated_at, :attempts, :claimed_by]

  # Patch keys that are refused outright (not stripped): :__struct__ makes the
  # reduced record a struct-like map — outside the `t` contract and it crashes
  # the Enumerable fence itself on map patches (lens3 cycle-1 probe P1).
  # (The refusal is enforced inline in `transition/4`'s pre-Enum check; the
  # dead `@refused_patch_keys` attribute that used to sit here tripped
  # --warnings-as-errors and broke `mix smalt.gen` — docs lane cycle-9.)

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
  Idempotent; starts the GenServer if not running. Crash-stampede safe: N
  concurrent callers after a table-owner death race `GenServer.start/3`, and
  the losers get `{:error, {:already_started, _}}` — admitted, not crashed
  (lens6 cycle-1: the previous `{:ok, _pid} =` match crashed 44/50 racers and
  turned the recovery helper itself into a crash source during exactly the
  stampede it exists to absorb). ensure/0 also returns only once the table
  EXISTS: every branch waits out the winner's init (bounded), because a table
  op in the whereis-before-init window is a raw badarg — witnessed live by
  the ensure x claim storm court (lens6 cycle-2, `{:rescued, ArgumentError}`
  racer result before the fix).
  """
  @spec ensure() :: :ok
  def ensure do
    if :ets.info(@table) == :undefined do
      case GenServer.whereis(__MODULE__) do
        nil ->
          case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
            {:ok, _pid} -> :ok
            # A racing caller won the name; wait out its init (table create).
            {:error, {:already_started, _}} -> wait_table()
          end

        _pid ->
          wait_table()
      end
    else
      :ok
    end
  end

  @max_ensure_wait_tries 5_000

  defp wait_table(tries \\ @max_ensure_wait_tries)

  defp wait_table(0) do
    # Bounded: if the winner died before init created the table, the next
    # :ets op fails typed (badarg) rather than hanging the caller forever.
    :ok
  end

  defp wait_table(tries) do
    if :ets.info(@table) == :undefined do
      Process.sleep(1)
      wait_table(tries - 1)
    else
      :ok
    end
  end

  @doc """
  Inserts or overwrites the task record (manual read/write, no changeset).
  Returns `{:ok, task}` with `updated_at` refreshed. Fenced: `:status` must be
  a lawful machine status, otherwise `{:error, {:invalid_status, status}}`
  (a record written with a garbage status would be permanently stuck — the
  court refuses every edge out of an out-of-domain status). Also fenced
  (lens3 cycle-1, no-stuck-records law): `:id` must be a binary, `:attempts`
  a non-negative integer, `:claimed_by` a pid/nil/atom — otherwise
  `{:error, {:invalid_record, key}}`. Without the attempts fence, a record
  with `attempts: :NaN` is stored and then `claim/2` crashes
  (ArithmeticError on `attempts + 1`) on EVERY future claim: a wedged record
  recover/0 cannot unwedge.
  """
  @spec put(t()) ::
          {:ok, t()} | {:error, {:invalid_status, term()}} | {:error, {:invalid_record, atom()}}
  def put(task) do
    status = Map.get(task, :status)
    id = Map.get(task, :id)
    attempts = Map.get(task, :attempts)
    claimed_by = Map.get(task, :claimed_by)

    cond do
      status not in @statuses ->
        {:error, {:invalid_status, status}}

      not is_binary(id) ->
        {:error, {:invalid_record, :id}}

      not is_integer(attempts) or attempts < 0 ->
        {:error, {:invalid_record, :attempts}}

      not is_nil(claimed_by) and not is_pid(claimed_by) and not is_atom(claimed_by) ->
        {:error, {:invalid_record, :claimed_by}}

      true ->
        do_put(task)
    end
  end

  defp do_put(task) do
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

    # Walk keys + get rather than Store.list/1: the store's list/1 now
    # flat_maps each stored value (log-style tables), which does not fit
    # this table's one-map-per-key records.
    @table
    |> Store.keys()
    |> Enum.flat_map(fn key ->
      case Store.get(@table, key) do
        {:ok, task} -> [task]
        :error -> []
      end
    end)
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

  Patch keys in `@protected_keys` (`:id`, `:status`, `:created_at`,
  `:updated_at`, `:attempts`, `:claimed_by`) are ignored: identity and
  court-controlled lifecycle fields are machine-owned. A patch therefore can
  never replace the whole record map: every machine-owned key is stripped
  before the reduce, so even a patch carrying every remaining key yields a
  record whose identity, status, timestamps, attempts and lease stay
  machine-owned (pinned by the whole-record-replacement court row).

  Patch is a map or keyword list of plain field updates; a function patch is
  NOT accepted (the spec previously claimed it was — it would crash in the
  reduce). A patch carrying `:__struct__` is refused outright
  (`{:error, {:refused_key, :__struct__}}`) BEFORE the Enumerable walk: a
  struct-like patch map does not implement Enumerable, and a `__struct__` key
  landing in the record is outside the `t` contract either way (lens3 cycle-1).
  Non-pid claimants (`claim/2` with an atom/tuple) are by design
  treated as dead by `recover/0` (only real pids get liveness checks), so
  they hold the lease only until the next recover sweep.
  """
  @spec transition(t(), status(), map() | keyword()) ::
          {:ok, t()}
          | {:error, {:refused, status(), status()}}
          | {:error, {:refused_key, :__struct__}}
          | {:error, :conflict}
  def transition(task, to, patch \\ %{}, _opts \\ []) when is_map(patch) or is_list(patch) do
    :ok = ensure()

    # Refuse refused-key patches BEFORE any Enum walk: a struct-like patch map
    # does not implement Enumerable, so the fence's Enum.reject itself would
    # crash (lens3 cycle-1 probe P1).
    refused_key =
      Enum.find([:__struct__], fn key ->
        (is_map(patch) and Map.has_key?(patch, key)) or
          (is_list(patch) and Keyword.has_key?(patch, key))
      end)

    with :ok <- check_refused_key(refused_key),
         :ok <- validate_transition(task.status, to) do
      base =
        patch
        |> Enum.reject(fn {k, _v} -> k in @protected_keys end)
        |> Enum.reduce(task, fn {k, v}, acc -> Map.put(acc, k, v) end)
        |> Map.put(:status, to)
        |> Map.put(:updated_at, :erlang.monotonic_time())

      case Store.compare_and_swap(@table, task.id, task, base) do
        :ok -> {:ok, base}
        {:error, :conflict} = err -> err
      end
    end
  end

  defp check_refused_key(nil), do: :ok
  defp check_refused_key(key), do: {:error, {:refused_key, key}}

  @doc """
  Serialized exclusive claim: admitted -> running, leased to `claimant`,
  attempts bumped. Exactly one winner among concurrent claimants (the CAS runs
  inside the `Smalt.Store` GenServer). `:taken` when not claimable.

  The claimant contract (`pid() | atom()`) is enforced by guard: an
  off-contract claimant (tuple, binary, integer — anything `put/1`'s record
  fence would refuse) raises FunctionClauseError instead of writing a record
  shape the fence itself refuses (lens4 cycle-1: claim was the unfenced
  admission path around put/1's claimed_by fence).
  """
  @spec claim(id(), pid() | atom()) :: {:ok, t()} | :taken
  def claim(id, claimant) when is_pid(claimant) or is_atom(claimant) do
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
        # nil / garbage claimant counts as dead: a running task with no live
        # claimant must never be stuck (previously the truthy filter skipped
        # nil-claimed tasks, wedging them in :running forever).
        dead?(task.claimed_by) do
      next = %{
        task
        | status: :admitted,
          claimed_by: nil,
          updated_at: :erlang.monotonic_time()
      }

      case Store.compare_and_swap(@table, task.id, task, next) do
        :ok ->
          [next]

        # Another writer (a concurrent recover sweep or a claim) moved the
        # record first: this sweep did NOT recover it — report nothing rather
        # than misreporting the current record as recovered.
        {:error, :conflict} ->
          []
      end
    end
    |> List.flatten()
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

  # Lease liveness contract (pinned): recovery keys on pid identity, and the
  # BEAM may in principle recycle pids. If a dead claimant's pid is reused by
  # a new live process before a recover/0 sweep, dead?/1 sees the reused pid
  # as alive and the lease is NOT resurrected that sweep — the record stays
  # :running. This is a documented limitation, not silent corruption: the
  # operator escape is a manual put/1 overwrite (the record is fenced, so the
  # escape cannot smuggle an unlawful status). BEAM pid reuse in practice is
  # rare (monotonic pid counters per node); no in-process falsifiable test can
  # force reuse, so the contract is pinned here rather than test-driven.
  defp dead?(pid) when is_pid(pid), do: not Process.alive?(pid)
  defp dead?(_), do: true
end
