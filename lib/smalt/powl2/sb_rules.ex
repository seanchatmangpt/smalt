defmodule Smalt.Powl2.ServiceBusRuleManager do
  @moduledoc """
  POWL-8 in-memory Service Bus rule manager: ETS set
  `{topic, sub, rule} -> {compiled_filter, target_pid}` plus an ordered_set DLQ.
  Filter evaluation REUSES the substrate's fail-closed SQL-filter parser
  (`Smalt.SbRules.parse_sql/1` + `filter_matches_for_test?/2`) — no second
  parser is minted (N implementations of one calculus = O(N^2) drift).

  Delivery (80/20, parity with `Smalt.SbRules.subscription_admits?/2`):
  `publish/2` groups rules per subscription, admits iff ANY filter matches
  (a `:true_filter` rule stores the `{true, nil}` marker, exactly like
  `Smalt.SbRules.true_filter?/1`); sends `{:amcp_transfer, meta}` placeholder
  replaced below.
  """

  use GenServer

  @table :powl8_sb_rules
  @dlq :powl8_sb_rules_dlq
  @typed_400 {:error, 400, "InvalidFilter"}

  def table, do: @table
  def dlq, do: @dlq
  def typed_400, do: @typed_400

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Put a rule. `sql_or_true` is a SQL filter string or `:true_filter`. `:ok` or typed 400."
  def put_rule(topic, sub, rule, sql_or_true, target_pid) do
    with {:ok, filter} <- compile_filter(sql_or_true) do
      :ets.insert(@table, {{topic, sub, rule}, filter, resolve_target(target_pid)})
      :ok
    else
      {:error, _frag} -> @typed_400
      :nonbinary -> {:error, 400, "InvalidFilter: non-binary rule body"}
    end
  end

  defp resolve_target(pid) when is_pid(pid), do: pid

  defp resolve_target(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> raise ArgumentError, "unknown rule target #{inspect(name)}"
      pid -> pid
    end
  end

  @doc "Rules for one subscription: sorted `{rule_name, filter, target_pid}`."
  def get_rules(topic, sub) do
    @table
    |> :ets.match_object({{topic, sub, :_}, :_, :_})
    |> Enum.map(fn {key, f, pid} -> {elem(key, 2), f, pid} end)
    |> Enum.sort()
  end

  def delete_rule(topic, sub, rule), do: :ets.delete(@table, {topic, sub, rule})

  @doc """
  Publish to a topic. Returns `{:ok, [pid]}` on live delivery or
  `{:dlq, [], key}` when zero live matched deliveries occurred.
  """
  def publish(topic, msg) when is_map(msg) do
    subs =
      @table
      |> :ets.match_object({{topic, :_, :_}, :_, :_})
      |> Enum.group_by(fn {key, _f, _p} -> elem(key, 1) end)

    delivered =
      for {_sub, rules} <- subs,
          {key, filter, pid} <- rules,
          matches?(filter, msg),
          alive?(pid) do
        send(pid, {:amqp_transfer, transfer_meta(topic, elem(key, 1), msg)})
        pid
      end

    case delivered do
      [] -> {:dlq, [], insert_dlq(topic, msg)}
      pids -> {:ok, pids}
    end
  end

  @doc "DLQ rows `{key, topic, msg}` oldest first (monotone key)."
  def dlq_rows, do: @dlq |> :ets.tab2list() |> Enum.sort_by(fn {k, _t, _m} -> k end)

  def dlq_clear, do: :ets.delete_all_objects(@dlq)

  # :true_filter stores the substrate true-filter marker ({true, nil}) -- the
  # 80/20 SQL grammar refuses "1=1" (leading numeric literal), so the
  # true-filter face rides the marker path (Smalt.SbRules.true_filter?/1 parity).
  defp compile_filter(:true_filter), do: {:ok, {true, nil}}

  defp compile_filter(sql) when is_binary(sql) do
    case Smalt.SbRules.parse_sql(sql) do
      {:ok, ast} -> {:ok, {:sql_ast, ast}}
      err -> err
    end
  end

  defp compile_filter(_), do: :nonbinary

  defp matches?({true, nil}, _msg), do: true

  defp matches?({:sql_ast, ast}, msg), do: Smalt.SbRules.filter_matches_for_test?(ast, msg)

  defp alive?(pid), do: is_pid(pid) and Process.alive?(pid)

  defp transfer_meta(topic, sub, msg) do
    %{topic: topic, sub: sub, body: msg[:body], message_id: msg[:message_id],
      label: msg[:label], app_props: msg[:app_props] || %{}}
  end

  defp insert_dlq(topic, msg) do
    key = System.unique_integer([:positive, :monotonic])
    true = :ets.insert(@dlq, {key, topic, typed_msg(topic, msg)})
    key
  end

  defp typed_msg(topic, msg) do
    %{topic: topic, body: msg[:body], message_id: msg[:message_id],
      label: msg[:label], app_props: msg[:app_props] || %{}}
  end

  ## GenServer — ETS ownership only (reads/writes are direct ETS)

  # SPOF-B / A-4: heir 3-tuple on both tables (shadow-table law, EhThrottle
  # idiom). The manager is lazy-started by first callers/tests; without the
  # heir a crash or exit of the owner (or its linking starter) silently wiped
  # rule + DLQ state; now the tables re-parent to :init and survive.
  def init(:ok) do
    heir = Process.whereis(:init) || self()

    :ok = ensure_table(@table, [:set, :named_table, :public, read_concurrency: true, heir: heir])

    :ok =
      ensure_table(@dlq, [:ordered_set, :named_table, :public, read_concurrency: true, heir: heir])

    {:ok, %{}}
  end

  @stale_table_wait_ms 15_000

  # BK-CENS3 stale-delete law (F8 shared-ETS wound class,
  # docs/jira/v26.10.22/receipts/bkcens3-final-hop.md): the heir'd table
  # survives a CRASH death under :init ownership with identical options, so a
  # bare :ets.new in a restarted init raises :already_exists (witnessed ×6
  # under batch load). Before creating, check table ownership: delete the
  # stale table when its owner differs from this incarnation — waiting
  # bounded on a monitor when the previous owner is still dying (structural
  # sync on a real observable, never a sleep).
  defp ensure_table(name, opts) do
    case :ets.info(name, :owner) do
      :undefined ->
        _ = :ets.new(name, opts)
        :ok

      owner when owner == self() ->
        :ok

      owner ->
        # The :init pid is always alive, so an heir-held stale table must not
        # be waited on — the owning incarnation is already gone by
        # construction. Only a live non-:init owner (a prior incarnation
        # still mid-death) earns the bounded monitor wait.
        init_pid = Process.whereis(:init)
        heir_held? = owner == init_pid

        if Process.alive?(owner) and not heir_held? do
          ref = Process.monitor(owner)

          receive do
            {:DOWN, ^ref, :process, ^owner, _reason} -> :ok
          after
            @stale_table_wait_ms -> :ok
          end
        end

        if :ets.info(name) != :undefined, do: _ = :ets.delete(name)
        _ = :ets.new(name, opts)
        :ok
    end
  end
end
