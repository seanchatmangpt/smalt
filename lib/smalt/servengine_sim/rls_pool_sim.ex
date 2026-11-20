defmodule Smalt.ServengineSim.RlsPoolSim do
  @moduledoc """
  Pure-Elixir simulator for PostgreSQL 16 pooled-connection RLS behavior and
  `with_platform_scope` outer-transaction leak detection.

  Models two production failure classes observed with pooled PG16 connections:

    1. **Pooled `app.current_tenant_id` `''` vs `NULL` (`NULLIF(..., '')::uuid`)**:
       On a brand-new PG16 backend connection, `current_setting('app.current_tenant_id', true)`
       returns SQL `NULL` (`nil`). Once *any* transaction on that connection sets
       `app.current_tenant_id` (even via `SET LOCAL`), PG16 registers the custom
       placeholder GUC in the backend session. After `COMMIT`, `ROLLBACK`, `RESET ALL`,
       or `DISCARD ALL`, subsequent checkouts from the pool see `''` (empty string)
       instead of `NULL`. An RLS policy using `current_setting(...)::uuid` (`:raw_cast`)
       passes on fresh connections (`NULL::uuid`) but fails on reused pooled connections
       with SQLSTATE `22P02` (`invalid input syntax for type uuid: ""`). Wrapping with
       `NULLIF(current_setting('app.current_tenant_id', true), '')::uuid` (`:nullif_cast`)
       normalizes `''` back to `NULL` so the policy fails closed (`0` rows / `42501`)
       without crashing.

    2. **`with_platform_scope` outer-transaction leak**:
       PostgreSQL `SET LOCAL` is scoped to the top-level transaction, not a
       `SAVEPOINT`. When `with_platform_scope` runs inside an already-open outer
       transaction (`tx_depth > 0`), an inner `Repo.transaction` opens a `SAVEPOINT`
       and `RELEASE SAVEPOINT` on normal return **retains** `SET LOCAL app.platform_scope = 'true'`
       in the outer transaction. Subsequent tenant-scoped queries in that outer
       transaction silently bypass tenant isolation. `with_platform_scope/3` and
       `detect_outer_tx_leak/3` model both the leaky `:naive` path and guarded
       `:reject_outer_tx`, `:detect`, and `:restore` strategies.
  """

  @tenant_guc "app.current_tenant_id"
  @platform_scope_guc "app.platform_scope"
  @default_watch_gucs [@platform_scope_guc, @tenant_guc]

  @uuid_36_re ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
  @uuid_32_re ~r/^[0-9a-fA-F]{32}$/

  defmodule Conn do
    @moduledoc "Simulated PG16 backend connection with GUC and transaction/savepoint state."
    @type t :: %__MODULE__{
            id: pos_integer(),
            session_gucs: %{optional(String.t()) => String.t()},
            local_gucs: %{optional(String.t()) => String.t()},
            defined_gucs: MapSet.t(String.t()),
            tx_depth: non_neg_integer(),
            savepoints: [
              {%{optional(String.t()) => String.t()}, %{optional(String.t()) => String.t()}}
            ],
            warnings: [atom() | tuple()]
          }

    defstruct id: 1,
              session_gucs: %{},
              local_gucs: %{},
              defined_gucs: MapSet.new(),
              tx_depth: 0,
              savepoints: [],
              warnings: []
  end

  defmodule Pool do
    @moduledoc "Simulated connection pool tracking idle/checked-out connections and reset policy."
    @type checkin_reset :: :none | :reset_all | :fresh_conn
    @type order :: :lifo | :fifo

    @type t :: %__MODULE__{
            idle: [Conn.t()],
            checked_out: %{optional(pos_integer()) => Conn.t()},
            checkin_reset: checkin_reset(),
            order: order(),
            size: pos_integer()
          }

    defstruct idle: [],
              checked_out: %{},
              checkin_reset: :none,
              order: :lifo,
              size: 1
  end

  @type pg_error :: {:pg_error, String.t(), atom(), String.t()}
  @type policy_mode :: :nullif_cast | :raw_cast
  @type platform_mode :: :reject_outer_tx | :detect | :naive | :restore

  @doc "The tenant GUC name (`\"app.current_tenant_id\"`)."
  @spec tenant_guc() :: String.t()
  def tenant_guc, do: @tenant_guc

  @doc "The platform scope GUC name (`\"app.platform_scope\"`)."
  @spec platform_scope_guc() :: String.t()
  def platform_scope_guc, do: @platform_scope_guc

  @doc "Creates a fresh PG16 connection with no defined custom GUCs."
  @spec new_conn(keyword()) :: Conn.t()
  def new_conn(opts \\ []) do
    %Conn{
      id: Keyword.get(opts, :id, 1),
      session_gucs: Keyword.get(opts, :session_gucs, %{}),
      local_gucs: %{},
      defined_gucs: MapSet.new(Map.keys(Keyword.get(opts, :session_gucs, %{}))),
      tx_depth: 0,
      savepoints: [],
      warnings: []
    }
  end

  @doc "Returns true when the connection is currently inside an active transaction."
  @spec in_transaction?(Conn.t()) :: boolean()
  def in_transaction?(%Conn{tx_depth: depth}), do: depth > 0

  @doc """
  Simulates PostgreSQL `current_setting(name, missing_ok)`.

  Returns:
    * `{:ok, value}` from `local_gucs`, falling back to `session_gucs`
    * `{:ok, ""}` if `name` was previously registered via `SET`/`SET LOCAL` on this session
    * `{:ok, nil}` if `name` has never been defined and `missing_ok == true`
    * `{:error, {:pg_error, "42704", :undefined_object, ...}}` if never defined and `missing_ok == false`
  """
  @spec current_setting(Conn.t(), String.t(), boolean()) ::
          {:ok, String.t() | nil} | {:error, pg_error()}
  def current_setting(%Conn{} = conn, name, missing_ok \\ false) when is_binary(name) do
    cond do
      Map.has_key?(conn.local_gucs, name) ->
        {:ok, Map.fetch!(conn.local_gucs, name)}

      Map.has_key?(conn.session_gucs, name) ->
        {:ok, Map.fetch!(conn.session_gucs, name)}

      MapSet.member?(conn.defined_gucs, name) ->
        {:ok, ""}

      missing_ok ->
        {:ok, nil}

      true ->
        {:error,
         pg_error("42704", :undefined_object, ~s(unrecognized configuration parameter "#{name}"))}
    end
  end

  @doc """
  Simulates `SET LOCAL <name> = '<value>'` inside a transaction.

  Fails with `25P01` when called outside a transaction (`tx_depth == 0`).
  Inside a transaction, marks `name` as defined on the backend session so that
  after transaction end it reverts to `""` rather than `nil`.
  """
  @spec set_local(Conn.t(), String.t(), String.t()) :: {:ok, Conn.t()} | {:error, pg_error()}
  def set_local(%Conn{tx_depth: 0}, _name, _value) do
    {:error,
     pg_error(
       "25P01",
       :no_active_sql_transaction,
       "SET LOCAL can only be used in transaction blocks"
     )}
  end

  def set_local(%Conn{} = conn, name, value) when is_binary(name) and is_binary(value) do
    updated = %{
      conn
      | local_gucs: Map.put(conn.local_gucs, name, value),
        defined_gucs: MapSet.put(conn.defined_gucs, name)
    }

    {:ok, updated}
  end

  @doc """
  Simulates `SET <name> = '<value>'` (session-level GUC assignment).

  Session-level GUCs participate in transaction rollback if set inside a
  transaction, and persist across transactions and pool checkins unless reset.
  """
  @spec set_session(Conn.t(), String.t(), String.t()) :: {:ok, Conn.t()}
  def set_session(%Conn{} = conn, name, value) when is_binary(name) and is_binary(value) do
    updated = %{
      conn
      | session_gucs: Map.put(conn.session_gucs, name, value),
        local_gucs: Map.delete(conn.local_gucs, name),
        defined_gucs: MapSet.put(conn.defined_gucs, name)
    }

    {:ok, updated}
  end

  @doc """
  Simulates `SELECT set_config(name, value, is_local)`.

  When `value` is `nil`, PostgreSQL `set_config` is `STRICT` and leaves GUC state
  unchanged. When `is_local` is `true` outside a transaction, PG registers the
  custom placeholder GUC for the single statement and immediately reverts it to `""`.
  """
  @spec set_config(Conn.t(), String.t(), String.t() | nil, boolean()) ::
          {:ok, String.t() | nil, Conn.t()}
  def set_config(%Conn{} = conn, name, nil, _is_local) when is_binary(name) do
    {:ok, nil, conn}
  end

  def set_config(%Conn{tx_depth: 0} = conn, name, value, true)
      when is_binary(name) and is_binary(value) do
    updated = %{
      conn
      | defined_gucs: MapSet.put(conn.defined_gucs, name),
        warnings: [:set_local_outside_tx | conn.warnings]
    }

    {:ok, value, updated}
  end

  def set_config(%Conn{} = conn, name, value, true) when is_binary(name) and is_binary(value) do
    {:ok, updated} = set_local(conn, name, value)
    {:ok, value, updated}
  end

  def set_config(%Conn{} = conn, name, value, false) when is_binary(name) and is_binary(value) do
    {:ok, updated} = set_session(conn, name, value)
    {:ok, value, updated}
  end

  @doc """
  Simulates PostgreSQL `RESET ALL`.

  Clears `session_gucs` (and `local_gucs` if outside a transaction), while
  preserving `defined_gucs` — matching PG16 where custom placeholder GUCs remain
  registered as `""` rather than reverting to `NULL`.
  """
  @spec reset_all(Conn.t()) :: {:ok, Conn.t()}
  def reset_all(%Conn{} = conn) do
    {:ok, %{conn | session_gucs: %{}, local_gucs: %{}}}
  end

  @doc """
  Simulates PostgreSQL `DISCARD ALL`.

  Refuses inside a transaction block (`25001`), and outside a transaction resets
  session state while keeping registered custom placeholder GUCs as `""`.
  """
  @spec discard_all(Conn.t()) :: {:ok, Conn.t()} | {:error, pg_error()}
  def discard_all(%Conn{tx_depth: depth}) when depth > 0 do
    {:error,
     pg_error(
       "25001",
       :active_sql_transaction,
       "DISCARD ALL cannot run inside a transaction block"
     )}
  end

  def discard_all(%Conn{} = conn), do: reset_all(conn)

  @doc "Opens a top-level transaction (`BEGIN`) or nested `SAVEPOINT`."
  @spec begin_tx(Conn.t()) :: {:ok, Conn.t()}
  def begin_tx(%Conn{} = conn) do
    snapshot = {conn.session_gucs, conn.local_gucs}
    {:ok, %{conn | tx_depth: conn.tx_depth + 1, savepoints: [snapshot | conn.savepoints]}}
  end

  @doc """
  Commits the top-level transaction or releases the innermost savepoint.

  Crucially, `RELEASE SAVEPOINT` (`tx_depth > 1`) pops the savepoint without
  reverting `local_gucs`, so any `SET LOCAL` executed inside the savepoint
  persists in the outer transaction until top-level `COMMIT` or `ROLLBACK`.
  """
  @spec commit_tx(Conn.t()) :: {:ok, Conn.t()} | {:error, pg_error()}
  def commit_tx(%Conn{tx_depth: 0}) do
    {:error, pg_error("25P01", :no_active_sql_transaction, "there is no transaction in progress")}
  end

  def commit_tx(%Conn{tx_depth: 1} = conn) do
    {:ok, %{conn | tx_depth: 0, local_gucs: %{}, savepoints: []}}
  end

  def commit_tx(%Conn{tx_depth: depth, savepoints: [_top | rest]} = conn) when depth > 1 do
    {:ok, %{conn | tx_depth: depth - 1, savepoints: rest}}
  end

  @doc "Rolls back the top-level transaction or rolls back to the innermost savepoint."
  @spec rollback_tx(Conn.t()) :: {:ok, Conn.t()} | {:error, pg_error()}
  def rollback_tx(%Conn{tx_depth: 0}) do
    {:error, pg_error("25P01", :no_active_sql_transaction, "there is no transaction in progress")}
  end

  def rollback_tx(%Conn{tx_depth: depth, savepoints: [{prev_session, prev_local} | rest]} = conn)
      when depth >= 1 do
    next_local = if depth == 1, do: %{}, else: prev_local

    {:ok,
     %{
       conn
       | tx_depth: depth - 1,
         session_gucs: prev_session,
         local_gucs: next_local,
         savepoints: rest
     }}
  end

  @doc """
  Executes `fun.(tx_conn)` inside a transaction (or nested savepoint).

  Callback return values:
    * `{:ok, value, next_conn}` -> commits / releases savepoint
    * `{:rollback, reason, next_conn}` -> rolls back / rolls back to savepoint
    * `{:error, reason, next_conn}` -> rolls back and returns `{:error, reason, rolled_back_conn}`
  """
  @spec transaction(Conn.t(), (Conn.t() -> tuple())) ::
          {:ok, any(), Conn.t()} | {:rollback, any(), Conn.t()} | {:error, any(), Conn.t()}
  def transaction(%Conn{} = conn, fun) when is_function(fun, 1) do
    {:ok, tx_conn} = begin_tx(conn)

    case fun.(tx_conn) do
      {:ok, value, %Conn{} = next_conn} ->
        {:ok, committed} = commit_tx(next_conn)
        {:ok, value, committed}

      {:rollback, reason, %Conn{} = next_conn} ->
        {:ok, rolled_back} = rollback_tx(next_conn)
        {:rollback, reason, rolled_back}

      {:error, reason, %Conn{} = next_conn} ->
        {:ok, rolled_back} = rollback_tx(next_conn)
        {:error, reason, rolled_back}
    end
  end

  @doc """
  Parses and canonicalizes a PostgreSQL UUID text literal.

  Rejects `""` and malformed UUIDs with SQLSTATE `22P02` (`invalid_text_representation`).
  """
  @spec parse_uuid(String.t()) :: {:ok, String.t()} | {:error, pg_error()}
  def parse_uuid(value) when is_binary(value) do
    trimmed =
      value
      |> String.trim()
      |> strip_braces()

    cond do
      trimmed == "" ->
        {:error,
         pg_error(
           "22P02",
           :invalid_text_representation,
           ~s(invalid input syntax for type uuid: "#{value}")
         )}

      Regex.match?(@uuid_36_re, trimmed) ->
        {:ok, String.downcase(trimmed)}

      Regex.match?(@uuid_32_re, trimmed) ->
        <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
          e::binary-size(12)>> =
          String.downcase(trimmed)

        {:ok, "#{a}-#{b}-#{c}-#{d}-#{e}"}

      true ->
        {:error,
         pg_error(
           "22P02",
           :invalid_text_representation,
           ~s(invalid input syntax for type uuid: "#{value}")
         )}
    end
  end

  defp strip_braces("{" <> rest) do
    if String.ends_with?(rest, "}"),
      do: binary_part(rest, 0, byte_size(rest) - 1),
      else: "{" <> rest
  end

  defp strip_braces(other), do: other

  @doc """
  Evaluates the RLS tenant expression on `conn`.

    * `:nullif_cast` — `NULLIF(current_setting('app.current_tenant_id', true), '')::uuid`
      maps both `nil` (`NULL`) and `""` (`''`) to `{:ok, nil}`.
    * `:raw_cast` — `current_setting('app.current_tenant_id', true)::uuid`
      maps `nil` to `{:ok, nil}` but raises `22P02` on `""`.
  """
  @spec eval_tenant_id(Conn.t(), policy_mode()) :: {:ok, String.t() | nil} | {:error, pg_error()}
  def eval_tenant_id(%Conn{} = conn, policy_mode \\ :nullif_cast)
      when policy_mode in [:nullif_cast, :raw_cast] do
    {:ok, raw} = current_setting(conn, @tenant_guc, true)

    case {policy_mode, raw} do
      {_, nil} -> {:ok, nil}
      {:nullif_cast, ""} -> {:ok, nil}
      {:raw_cast, ""} -> parse_uuid("")
      {_, value} -> parse_uuid(value)
    end
  end

  @doc "Returns true when `app.platform_scope` evaluates to `\"true\"` on `conn`."
  @spec platform_scope?(Conn.t()) :: boolean()
  def platform_scope?(%Conn{} = conn) do
    current_setting(conn, @platform_scope_guc, true) == {:ok, "true"}
  end

  @doc """
  Simulates an RLS-protected `SELECT` over `rows`.

  Options:
    * `:policy_mode` — `:nullif_cast` (default) or `:raw_cast`
    * `:allow_platform_scope` — whether `app.platform_scope = 'true'` bypasses tenant filtering (default `true`)
    * `:tenant_key` — key on each row map holding the tenant UUID (default `:tenant_id`)
  """
  @spec query_rows(Conn.t(), [map()], keyword()) :: {:ok, [map()]} | {:error, pg_error()}
  def query_rows(%Conn{} = conn, rows, opts \\ []) when is_list(rows) do
    policy_mode = Keyword.get(opts, :policy_mode, :nullif_cast)
    allow_platform = Keyword.get(opts, :allow_platform_scope, true)
    tenant_key = Keyword.get(opts, :tenant_key, :tenant_id)

    with {:ok, tenant_uuid} <- eval_tenant_id(conn, policy_mode) do
      cond do
        allow_platform and platform_scope?(conn) ->
          {:ok, rows}

        is_nil(tenant_uuid) ->
          {:ok, []}

        true ->
          matching =
            Enum.filter(rows, fn row ->
              case Map.fetch(row, tenant_key) do
                {:ok, row_tid} when is_binary(row_tid) ->
                  case parse_uuid(row_tid) do
                    {:ok, canonical} -> canonical == tenant_uuid
                    _ -> false
                  end

                _ ->
                  false
              end
            end)

          {:ok, matching}
      end
    end
  end

  @doc """
  Simulates an RLS `WITH CHECK` policy on inserting `row`.

  Returns `{:ok, row}` when permitted, `{:error, {:pg_error, "42501", :insufficient_privilege, ...}}`
  when denied, or `22P02` when `:raw_cast` encounters `""`.
  """
  @spec insert_row(Conn.t(), map(), keyword()) :: {:ok, map()} | {:error, pg_error()}
  def insert_row(%Conn{} = conn, row, opts \\ []) when is_map(row) do
    policy_mode = Keyword.get(opts, :policy_mode, :nullif_cast)
    allow_platform = Keyword.get(opts, :allow_platform_scope, true)
    tenant_key = Keyword.get(opts, :tenant_key, :tenant_id)

    with {:ok, tenant_uuid} <- eval_tenant_id(conn, policy_mode) do
      allowed? =
        (allow_platform and platform_scope?(conn)) or
          (not is_nil(tenant_uuid) and
             case Map.fetch(row, tenant_key) do
               {:ok, row_tid} when is_binary(row_tid) -> parse_uuid(row_tid) == {:ok, tenant_uuid}
               _ -> false
             end)

      if allowed? do
        {:ok, row}
      else
        {:error,
         pg_error("42501", :insufficient_privilege, "new row violates row-level security policy")}
      end
    end
  end

  @doc """
  Creates a simulated connection pool.

  Options:
    * `:size` — number of pooled backend connections (default `1`)
    * `:checkin_reset` — `:none` (default), `:reset_all`, or `:fresh_conn`
    * `:order` — `:lifo` (default, matching DBConnection) or `:fifo`
  """
  @spec new_pool(keyword()) :: Pool.t()
  def new_pool(opts \\ []) do
    size = Keyword.get(opts, :size, 1)
    checkin_reset = Keyword.get(opts, :checkin_reset, :none)
    order = Keyword.get(opts, :order, :lifo)

    if size < 1 do
      raise ArgumentError, "pool size must be >= 1, got: #{inspect(size)}"
    end

    idle = Enum.map(1..size, fn id -> new_conn(id: id) end)
    %Pool{idle: idle, checked_out: %{}, checkin_reset: checkin_reset, order: order, size: size}
  end

  @doc "Checks out an idle connection from the pool."
  @spec checkout(Pool.t()) :: {:ok, Conn.t(), Pool.t()} | {:error, :pool_exhausted}
  def checkout(%Pool{idle: []}), do: {:error, :pool_exhausted}

  def checkout(%Pool{idle: [conn | rest]} = pool) do
    {:ok, conn, %{pool | idle: rest, checked_out: Map.put(pool.checked_out, conn.id, conn)}}
  end

  @doc """
  Returns a connection back to the pool, applying the pool's `checkin_reset` policy.

  Options:
    * `:on_dirty_tx` — `:rollback` (default, rolls back open tx before returning) or `:refuse`
  """
  @spec checkin(Pool.t(), Conn.t(), keyword()) ::
          {:ok, Pool.t()} | {:error, {:dirty_transaction, non_neg_integer()}, Pool.t()}
  def checkin(%Pool{} = pool, %Conn{} = conn, opts \\ []) do
    on_dirty_tx = Keyword.get(opts, :on_dirty_tx, :rollback)

    if conn.tx_depth > 0 and on_dirty_tx == :refuse do
      {:error, {:dirty_transaction, conn.tx_depth}, pool}
    else
      cleaned = sanitize_on_checkin(conn, pool.checkin_reset)
      checked_out = Map.delete(pool.checked_out, conn.id)

      idle =
        case pool.order do
          :lifo -> [cleaned | pool.idle]
          :fifo -> pool.idle ++ [cleaned]
        end

      {:ok, %{pool | idle: idle, checked_out: checked_out}}
    end
  end

  defp sanitize_on_checkin(%Conn{} = conn, reset_mode) do
    conn = rewind_open_tx(conn)

    case reset_mode do
      :none ->
        conn

      :reset_all ->
        {:ok, reset} = reset_all(conn)
        reset

      :fresh_conn ->
        new_conn(id: conn.id)
    end
  end

  defp rewind_open_tx(%Conn{tx_depth: 0} = conn), do: conn

  defp rewind_open_tx(%Conn{} = conn) do
    {:ok, rolled_back} = rollback_tx(conn)

    rewind_open_tx(%{
      rolled_back
      | warnings: [:dirty_tx_rolled_back_on_checkin | rolled_back.warnings]
    })
  end

  @doc """
  Checks out a connection, calls `fun.(conn)`, and checks it back in.

  `fun.(conn)` must return `{result, updated_conn}`.
  """
  @spec with_conn(Pool.t(), (Conn.t() -> {any(), Conn.t()}), keyword()) ::
          {any(), Pool.t()} | {:error, :pool_exhausted}
  def with_conn(%Pool{} = pool, fun, opts \\ []) when is_function(fun, 1) do
    case checkout(pool) do
      {:ok, conn, pool_after_out} ->
        {result, next_conn} = fun.(conn)
        {:ok, pool_after_in} = checkin(pool_after_out, next_conn, opts)
        {result, pool_after_in}

      {:error, :pool_exhausted} ->
        {:error, :pool_exhausted}
    end
  end

  @doc """
  Inspects a pooled connection for carryover GUC hazards:
    * `empty_placeholder_gucs` — custom GUCs currently reading `""` (`''`) instead of `nil` (`NULL`)
    * `unreset_session_gucs` — session GUCs still holding values across checkouts
    * `raw_cast_hazard?` — true when `app.current_tenant_id` reads `""` (crashes `:raw_cast`)
  """
  @spec inspect_pool_conn(Conn.t()) :: map()
  def inspect_pool_conn(%Conn{} = conn) do
    empty_placeholders =
      conn.defined_gucs
      |> Enum.filter(fn name ->
        current_setting(conn, name, true) == {:ok, ""}
      end)
      |> Enum.sort()

    %{
      conn_id: conn.id,
      tx_depth: conn.tx_depth,
      tenant_setting: elem(current_setting(conn, @tenant_guc, true), 1),
      platform_scope_setting: elem(current_setting(conn, @platform_scope_guc, true), 1),
      empty_placeholder_gucs: empty_placeholders,
      unreset_session_gucs: conn.session_gucs,
      local_gucs: conn.local_gucs,
      raw_cast_hazard?: current_setting(conn, @tenant_guc, true) == {:ok, ""},
      warnings: Enum.reverse(conn.warnings)
    }
  end

  @doc """
  Executes `fun.(scoped_conn)` under platform scope (`app.platform_scope = 'true'`).

  Options:
    * `:mode` — controls outer-transaction handling:
      * `:reject_outer_tx` (default): refuses before mutating any GUC if `conn.tx_depth > 0`
      * `:naive`: runs `transaction/2` + `SET LOCAL app.platform_scope = 'true'` without guard;
        inside an outer transaction, `RELEASE SAVEPOINT` leaks `platform_scope = 'true'`
      * `:detect`: executes the transaction/savepoint and runs `detect_outer_tx_leak/3` on exit,
        returning `{:refused, leak_report, after_conn}` if an outer-tx leak occurred
      * `:restore`: saves prior `app.platform_scope` (and `app.current_tenant_id` if
        `:clear_tenant` is set) and restores them before releasing the savepoint
    * `:clear_tenant` — also clears `app.current_tenant_id` (`""`) inside the scope (default `false`)
    * `:watch_gucs` — additional GUCs monitored by `:detect`
  """
  @spec with_platform_scope(Conn.t(), (Conn.t() -> tuple()), keyword()) ::
          {:ok, any(), Conn.t()}
          | {:refused, map(), Conn.t()}
          | {:rollback, any(), Conn.t()}
          | {:error, any(), Conn.t()}
  def with_platform_scope(%Conn{} = conn, fun, opts \\ []) when is_function(fun, 1) do
    mode = Keyword.get(opts, :mode, :reject_outer_tx)
    clear_tenant? = Keyword.get(opts, :clear_tenant, false)

    case mode do
      :reject_outer_tx ->
        if in_transaction?(conn) do
          {:refused,
           %{
             reason: :outer_transaction_active,
             tx_depth: conn.tx_depth,
             leaked_gucs: [],
             message:
               "with_platform_scope refused: cannot use SET LOCAL inside active outer transaction (tx_depth=#{conn.tx_depth})"
           }, conn}
        else
          run_naive_platform_tx(conn, fun, clear_tenant?)
        end

      :naive ->
        run_naive_platform_tx(conn, fun, clear_tenant?)

      :detect ->
        case run_naive_platform_tx(conn, fun, clear_tenant?) do
          {:ok, value, after_conn} ->
            case detect_outer_tx_leak(conn, after_conn, opts) do
              :ok -> {:ok, value, after_conn}
              {:leak_detected, report} -> {:refused, report, after_conn}
            end

          other ->
            other
        end

      :restore ->
        run_restoring_platform_tx(conn, fun, clear_tenant?)
    end
  end

  defp run_naive_platform_tx(conn, fun, clear_tenant?) do
    transaction(conn, fn tx_conn ->
      {:ok, tx_conn} = set_local(tx_conn, @platform_scope_guc, "true")

      tx_conn =
        if clear_tenant? do
          {:ok, cleared} = set_local(tx_conn, @tenant_guc, "")
          cleared
        else
          tx_conn
        end

      fun.(tx_conn)
    end)
  end

  defp run_restoring_platform_tx(conn, fun, clear_tenant?) do
    {:ok, prior_platform} = current_setting(conn, @platform_scope_guc, true)
    {:ok, prior_tenant} = current_setting(conn, @tenant_guc, true)

    transaction(conn, fn tx_conn ->
      {:ok, tx_conn} = set_local(tx_conn, @platform_scope_guc, "true")

      tx_conn =
        if clear_tenant? do
          {:ok, cleared} = set_local(tx_conn, @tenant_guc, "")
          cleared
        else
          tx_conn
        end

      case fun.(tx_conn) do
        {:ok, value, next_conn} ->
          restored = restore_guc(next_conn, @platform_scope_guc, prior_platform)

          restored =
            if clear_tenant? do
              restore_guc(restored, @tenant_guc, prior_tenant)
            else
              restored
            end

          {:ok, value, restored}

        other ->
          other
      end
    end)
  end

  defp restore_guc(%Conn{tx_depth: 0} = conn, _name, _prior), do: conn

  defp restore_guc(%Conn{} = conn, name, nil) do
    # In PG, SET LOCAL cannot "undefine" a custom placeholder GUC back to NULL;
    # restoring to "" disables platform_scope and preserves fail-closed semantics
    # under NULLIF(..., '')::uuid.
    {:ok, updated} = set_local(conn, name, "")
    updated
  end

  defp restore_guc(%Conn{} = conn, name, prior) when is_binary(prior) do
    {:ok, updated} = set_local(conn, name, prior)
    updated
  end

  @doc """
  Compares connection GUC state before and after a scoped operation (such as
  `with_platform_scope`) to detect outer-transaction or session-level leaks.

  Returns `:ok` when clean, or `{:leak_detected, report}` when:
    * `after_conn.tx_depth > 0` and `app.platform_scope` escalated to `"true"`
    * `after_conn.tx_depth > 0` and `app.current_tenant_id` changed in the outer tx
    * `after_conn.tx_depth > 0` and any other watched GUC mutated
    * `after_conn.tx_depth == 0` and `session_gucs` mutated (session-level `SET` leak)
  """
  @spec detect_outer_tx_leak(Conn.t(), Conn.t(), keyword()) :: :ok | {:leak_detected, map()}
  def detect_outer_tx_leak(%Conn{} = before_conn, %Conn{} = after_conn, opts \\ []) do
    watch_gucs =
      Keyword.get(opts, :watch_gucs, [])
      |> Kernel.++(@default_watch_gucs)
      |> Enum.uniq()

    findings =
      []
      |> maybe_add_outer_tx_findings(before_conn, after_conn, watch_gucs)
      |> maybe_add_session_leak_findings(before_conn, after_conn)
      |> Enum.reverse()

    if findings == [] do
      :ok
    else
      reason =
        if after_conn.tx_depth > 0 do
          :outer_transaction_leak
        else
          :session_guc_leak
        end

      {:leak_detected,
       %{
         reason: reason,
         findings: findings,
         leaked_gucs: findings |> Enum.map(& &1.guc) |> Enum.uniq(),
         before_tx_depth: before_conn.tx_depth,
         after_tx_depth: after_conn.tx_depth,
         before_gucs: snapshot_gucs(before_conn, watch_gucs),
         after_gucs: snapshot_gucs(after_conn, watch_gucs)
       }}
    end
  end

  defp maybe_add_outer_tx_findings(findings, _before_conn, %Conn{tx_depth: 0}, _watch_gucs),
    do: findings

  defp maybe_add_outer_tx_findings(findings, before_conn, after_conn, watch_gucs) do
    Enum.reduce(watch_gucs, findings, fn guc, acc ->
      {:ok, before_val} = current_setting(before_conn, guc, true)
      {:ok, after_val} = current_setting(after_conn, guc, true)

      cond do
        guc == @platform_scope_guc and after_val == "true" and before_val != "true" ->
          [
            %{
              kind: :platform_scope_leaked,
              guc: guc,
              before: before_val,
              after: after_val,
              tx_depth: after_conn.tx_depth
            }
            | acc
          ]

        guc == @tenant_guc and after_val != before_val ->
          [
            %{
              kind: :tenant_id_leaked,
              guc: guc,
              before: before_val,
              after: after_val,
              tx_depth: after_conn.tx_depth
            }
            | acc
          ]

        guc not in [@platform_scope_guc, @tenant_guc] and after_val != before_val ->
          [
            %{
              kind: :guc_leaked,
              guc: guc,
              before: before_val,
              after: after_val,
              tx_depth: after_conn.tx_depth
            }
            | acc
          ]

        true ->
          acc
      end
    end)
  end

  defp maybe_add_session_leak_findings(findings, before_conn, %Conn{tx_depth: 0} = after_conn) do
    Enum.reduce(after_conn.session_gucs, findings, fn {guc, after_val}, acc ->
      before_val = Map.get(before_conn.session_gucs, guc)

      if after_val != before_val do
        [
          %{
            kind: :session_guc_leaked,
            guc: guc,
            before: before_val,
            after: after_val,
            tx_depth: 0
          }
          | acc
        ]
      else
        acc
      end
    end)
  end

  defp maybe_add_session_leak_findings(findings, _before_conn, _after_conn), do: findings

  defp snapshot_gucs(conn, watch_gucs) do
    Map.new(watch_gucs, fn guc ->
      {:ok, val} = current_setting(conn, guc, true)
      {guc, val}
    end)
  end

  defp pg_error(sqlstate, atom_code, message) do
    {:pg_error, sqlstate, atom_code, message}
  end
end
