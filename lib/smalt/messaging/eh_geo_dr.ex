defmodule Smalt.Messaging.EhGeoDr do
  @moduledoc """
  Event Hubs geo-DR metadata face (Azure parity surface, emulator scale).

  Azure Event Hubs geo-disaster-recovery is a namespace-pairing metadata
  operation: a **disaster recovery alias** binds a primary namespace and a
  partner (secondary) namespace; `failover` promotes the partner to primary;
  `break-pairing` dissolves the alias without failing over. This module is the
  **metadata plane only**: the alias record IS the capability at emulator scale
  (no actual namespace replication, no event copying between namespaces —
  documented honestly here, not claimed silently).

  Storage: `:smalt_eh_geo_dr` table, key = alias name. Records carry:

  | Field | Meaning |
  |---|---|
  | `"alias"` | disaster recovery alias name |
  | `"primary_namespace_id"` | ARM id of the namespace currently holding the primary designation |
  | `"partner_namespace_id"` | ARM id of the paired partner namespace |
  | `"role_by_ns"` | `%{ns_id => :primary \\| :secondary}` — the designation map `failover/1` flips |
  | `"last_commit_succeeded"` | epoch ms of the last successful alias commit (set on create/update and failover) |
  | `"provisioning_state"` | `"Succeeded" \\| "FailedOver" \\| "Broken"` |

  Lifecycle contract (typed faces, ARM wire-visible 4xx-class shape):

  - `create_or_update_alias/3` — idempotent PUT. Re-PUT while `"Succeeded"`
    updates fields and preserves the original created ts.
  - `failover/1` — requires a **paired** alias (provisioning_state
    `"Succeeded"`). Flips the primary designation between the two namespaces.
    Post-failover the alias is `"FailedOver"`; a second `failover/1` is
    typed-refused (`AliasNotPaired`) — it must go through break-pairing +
    a fresh pairing first.
  - `break_pairing/1` — valid only while paired (`"Succeeded"`).
    **Post-failover break-pairing is typed-refused** (`PairingAlreadyFailedOver`)
    at this surface, per the v26.10.19 caps-wave contract.
  - `delete_alias/1` — removes the record from any state.

  Table ownership follows the lens-5 discipline used by
  `Smalt.Messaging.EventHubs`: the named table is created inside this module's
  own lazily-started named GenServer, so it is server-owned and never dies with
  a mortal caller.
  """

  use GenServer

  @table :smalt_eh_geo_dr
  @name __MODULE__

  @typedoc "Typed face (ARM wire-visible 4xx-class surface)."
  @type face :: %{
          required(:status) => pos_integer(),
          required(:code) => String.t(),
          required(:condition) => String.t(),
          required(:description) => String.t()
        }

  @type alias_record :: %{
          String.t() => String.t() | integer() | %{String.t() => :primary | :secondary}
        }

  # -- Public API ----------------------------------------------------------------

  @doc """
  Idempotent PUT of a disaster recovery alias binding `primary_namespace_id`
  to `partner_namespace_id`. Returns `{:ok, record}`.
  """
  @spec create_or_update_alias(String.t(), String.t(), String.t()) ::
          {:ok, alias_record()}
  def create_or_update_alias(alias_name, primary_namespace_id, partner_namespace_id)
      when is_binary(alias_name) and is_binary(primary_namespace_id) and is_binary(partner_namespace_id) do
    transaction({:create_or_update, alias_name, primary_namespace_id, partner_namespace_id})
  end

  @doc """
  Get the alias record. `{:ok, record}` or `{:error, face}` (404 `AliasNotFound`).
  """
  @spec get_alias(String.t()) :: {:ok, alias_record()} | {:error, face()}
  def get_alias(alias_name) when is_binary(alias_name) do
    transaction({:get, alias_name})
  end

  @doc "List all alias records (empty list when none)."
  @spec list_aliases() :: [alias_record()]
  def list_aliases do
    transaction(:list)
  end

  @doc """
  Failover: flip the primary designation from the current primary namespace to
  the partner. Requires a paired (`"Succeeded"`) alias; otherwise
  `{:error, face}` (409 `AliasNotPaired`).
  """
  @spec failover(String.t()) :: {:ok, alias_record()} | {:error, face()}
  def failover(alias_name) when is_binary(alias_name) do
    transaction({:failover, alias_name})
  end

  @doc """
  Dissolve the pairing without failover. Only valid while the alias is paired
  (`"Succeeded"`); post-failover this is typed-refused
  (`{:error, face}` 409 `PairingAlreadyFailedOver`).
  """
  @spec break_pairing(String.t()) :: {:ok, alias_record()} | {:error, face()}
  def break_pairing(alias_name) when is_binary(alias_name) do
    transaction({:break_pairing, alias_name})
  end

  @doc "Delete the alias record from any state. Returns `:ok`."
  @spec delete_alias(String.t()) :: :ok
  def delete_alias(alias_name) when is_binary(alias_name) do
    transaction({:delete, alias_name})
  end

  @doc "Idempotently ensure the `:smalt_eh_geo_dr` table exists. Returns `:ok`."
  @spec ensure_table() :: :ok
  def ensure_table do
    ensure_started()
    GenServer.call(@name, :ensure_table)
  end

  # -- Serialized server (lens-5: table owned by an immortal-named process) ------

  defp transaction(request) do
    ensure_started()
    GenServer.call(@name, request)
  end

  defp ensure_started do
    case Process.whereis(@name) do
      nil ->
        # BK-104: the direct GenServer.start here raced the supervisor's own
        # restart of the killed permanent child — when the caller's start won
        # the name, the supervisor's restart attempt failed :already_started,
        # its retry loop blew the restart intensity and the
        # IntegrationSupervisor exited :shutdown (whole-plane bounce,
        # witnessed mid-court). Route the lazy start through the supervisor;
        # only when no IntegrationSupervisor is running (integration-only
        # plane, bare test VM) do we fall back to an unlinked self-start,
        # where no supervisor exists to race.
        case supervised_start() do
          :ok ->
            :ok

          {:error, :integration_supervisor_not_running} ->
            unlinked_start(:eh_geo_dr_server_start_failed)

          {:error, reason} ->
            exit({:eh_geo_dr_server_start_failed, reason})
        end

      _pid ->
        :ok
    end
  end

  defp supervised_start do
    sup = Process.whereis(Smalt.Plane.IntegrationSupervisor)

    if is_nil(sup) do
      {:error, :integration_supervisor_not_running}
    else
      case Supervisor.start_child(sup, child_spec([])) do
        {:ok, _pid} -> :ok
        # The supervisor owns the child spec and is (re)starting it — never
        # start under our own process.
        {:error, {:already_started, _pid}} -> :ok
        {:error, {:already_present, _id}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp unlinked_start(fail_tag) do
    case GenServer.start(__MODULE__, :ok, name: @name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> exit({fail_tag, reason})
    end
  end

  # SPOF-B / A-4: supervised-start contract (permanent child of
  # IntegrationSupervisor). `use GenServer` child_spec would default to a
  # start_link/1 that did not exist — disclosed explicit form here.
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, @name))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :ref, :default)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @impl true
  def init(:ok) do
    do_ensure_table()
    {:ok, %{}}
  end

  # Runs inside the named server process: the named table is server-owned and
  # never dies with a mortal caller. Serialized by the server mailbox.
  # SPOF-B / A-4: heir 3-tuple (shadow-table law) — the alias metadata survives
  # an owner crash even before supervision restarts it.
  defp do_ensure_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true,
        heir: Process.whereis(:init) || self()
      ])
    end

    :ok
  end

  @impl true
  def handle_call(:ensure_table, _from, state) do
    {:reply, do_ensure_table(), state}
  end

  @impl true
  def handle_call({:create_or_update, alias_name, primary_id, partner_id}, _from, state) do
    now = now_ms()

    rec =
      case :ets.lookup(@table, alias_name) do
        [{^alias_name, rec}] when is_map(rec) ->
          if rec["provisioning_state"] == "Succeeded" do
            # Idempotent re-PUT: preserve original created ts, refresh commit.
            rec
            |> Map.put("primary_namespace_id", primary_id)
            |> Map.put("partner_namespace_id", partner_id)
            |> Map.put("role_by_ns", %{primary_id => :primary, partner_id => :secondary})
            |> Map.put("last_commit_succeeded", now)
          else
            fresh_alias_record(alias_name, primary_id, partner_id, now)
          end

        _ ->
          fresh_alias_record(alias_name, primary_id, partner_id, now)
      end

    :ets.insert(@table, {alias_name, rec})
    {:reply, {:ok, rec}, state}
  end

  @impl true
  def handle_call({:get, alias_name}, _from, state) do
    {:reply, lookup(alias_name), state}
  end

  @impl true
  def handle_call(:list, _from, state) do
    recs =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {_k, rec} -> rec end)
      |> Enum.sort_by(& &1["created"])

    {:reply, recs, state}
  end

  @impl true
  def handle_call({:failover, alias_name}, _from, state) do
    reply =
      with {:ok, rec} <- lookup(alias_name),
           :ok <- require_paired(rec) do
        flipped =
          rec["role_by_ns"]
          |> Map.new(fn {ns, role} -> {ns, flip(role)} end)

        now = now_ms()

        new_rec =
          rec
          |> Map.put("role_by_ns", flipped)
          |> Map.put("primary_namespace_id", rec["partner_namespace_id"])
          |> Map.put("partner_namespace_id", rec["primary_namespace_id"])
          |> Map.put("provisioning_state", "FailedOver")
          |> Map.put("last_commit_succeeded", now)

        :ets.insert(@table, {alias_name, new_rec})
        {:ok, new_rec}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:break_pairing, alias_name}, _from, state) do
    reply =
      with {:ok, rec} <- lookup(alias_name),
           :ok <- require_paired(rec, :break) do
        new_rec =
          rec
          |> Map.put("provisioning_state", "Broken")
          |> Map.put("last_commit_succeeded", now_ms())

        :ets.insert(@table, {alias_name, new_rec})
        {:ok, new_rec}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:delete, alias_name}, _from, state) do
    :ets.delete(@table, alias_name)
    {:reply, :ok, state}
  end

  # -- Helpers ---------------------------------------------------------------------

  defp lookup(alias_name) do
    case :ets.lookup(@table, alias_name) do
      [{^alias_name, rec}] -> {:ok, rec}
      [] -> {:error, alias_not_found(alias_name)}
    end
  end

  # failover requires the pairing intact; break-pairing additionally refuses a
  # `"FailedOver"` alias (typed, distinct condition per lifecycle edge).
  defp require_paired(rec), do: require_paired(rec, :failover)

  defp require_paired(rec, :failover) do
    case rec["provisioning_state"] do
      "Succeeded" -> :ok
      _ -> {:error, alias_not_paired(rec["alias"])}
    end
  end

  defp require_paired(rec, :break) do
    case rec["provisioning_state"] do
      "Succeeded" -> :ok
      "FailedOver" -> {:error, pairing_already_failed_over(rec["alias"])}
      "Broken" -> {:error, alias_not_paired(rec["alias"])}
    end
  end

  defp flip(:primary), do: :secondary
  defp flip(:secondary), do: :primary

  defp face(status, code, condition, description) do
    %{status: status, code: code, condition: condition, description: description}
  end

  defp alias_not_found(name),
    do: face(404, "AliasNotFound", "alias_not_found", "geo-DR alias #{inspect(name)} does not exist")

  defp alias_not_paired(name),
    do:
      face(
        409,
        "AliasNotPaired",
        "alias_not_paired",
        "geo-DR alias #{inspect(name)} is not in a paired (Succeeded) state"
      )

  defp pairing_already_failed_over(name),
    do:
      face(
        409,
        "PairingAlreadyFailedOver",
        "pairing_already_failed_over",
        "geo-DR alias #{inspect(name)} has already failed over; break-pairing is refused at this surface"
      )

  defp fresh_alias_record(alias_name, primary_id, partner_id, now),
    do: %{
      "alias" => alias_name,
      "primary_namespace_id" => primary_id,
      "partner_namespace_id" => partner_id,
      "role_by_ns" => %{primary_id => :primary, partner_id => :secondary},
      "last_commit_succeeded" => now,
      "created" => now,
      "provisioning_state" => "Succeeded"
    }

  defp now_ms, do: System.system_time(:millisecond)
end
