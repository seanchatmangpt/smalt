defmodule Smalt.Amqp10.Ledger do
  @moduledoc """
  Connection-independent owner of the AMQP 1.0 settled-ledger ETS table
  `:amqp10_settled` (JA-1 finding #2, fixed as BK-41).

  Replaces the previous bare `spawn` + `park()` receive loop inside
  `Smalt.Amqp10.Connection` with a proper `proc_lib`/GenServer owner using
  the JA-R2 / `policy.ex` idiom:

    * the table is created in `init/1` with
      `heir: Process.whereis(:init)`, so holder death transfers ownership to
      the always-alive `:init` process and the CONTENTS SURVIVE — holder
      death no longer silently loses the ledger (the previous holder carried
      no heir: its death deleted the table);
    * the owner is a named singleton (`{:local, __MODULE__}`); name
      registration is atomic, so concurrent `ensure/0` callers can never
      race to two owners — losers get `{:error, {:already_started, _}}`;
    * `ensure/0` is deliberately UNLINKED (`GenServer.start`, not
      `start_link`): a connection's crash cascade must not take the ledger
      owner with it, preserving the disclosed intentional-lifetime semantics
      (ledger outlives every connection);
    * a restarted owner ADOPTS an existing table rather than recreating it,
      so post-kill restarts read the pre-kill contents;
    * the table is `:public`: the connection (and courts) insert directly;
      the owner's only job is lifecycle + heir custody.

  Heir custody keeps the no-lost-ledger window closed even though the owner
  is unsupervised: between an owner's death and the next `ensure/0`, the
  table still exists (owned by `:init`), so concurrent writers keep landing
  settled transfers with no gap.
  """

  use GenServer

  @table :amqp10_settled

  @doc """
  Idempotent, unlinked start of the ledger owner. Returns `:ok` whether it
  started fresh or was already running; any other error is returned typed.
  """
  @spec ensure() :: :ok | {:error, term()}
  def ensure do
    case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Pid of the live owner, if any (courts kill it for real)."
  @spec owner() :: pid() | nil
  def owner, do: Process.whereis(__MODULE__)

  @impl true
  def init(:ok) do
    # IMPL-6 label schema (JA-15 gap G1): map label with service/role/
    # correlation_id, queryable by service/role like every other labeled owner.
    Process.set_label(%{
      service: :amqp,
      role: :settled_ledger_owner,
      correlation_id: @table
    })

    heir = Process.whereis(:init)

    if :ets.info(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        # 3-tuple heir option (policy.ex shadow-table law idiom): owner death
        # hands the table — contents intact — to the always-alive :init.
        # (Elixir 1.20: tuple must precede keyword pairs in a list literal.)
        {:heir, heir, []},
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    # Existing table (heir-passed to :init by a dead prior owner): adopt
    # as-is — contents preserved, ownership stays with :init.
    {:ok, %{}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
