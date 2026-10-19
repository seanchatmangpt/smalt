defmodule Smalt.StoreDetsTest do
  use ExUnit.Case, async: false

  @tables [:dm_t_resources, :dm_t_docs]

  setup do
    dir = Path.join(System.tmp_dir!(), "smalt_dets_mirror_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    tables = @tables

    Enum.each(tables, fn table ->
      if :ets.info(table) == :undefined do
        :ets.new(table, [:ordered_set, :public, :named_table])
      end

      :ets.delete_all_objects(table)
    end)

    %{dir: dir, tables: tables}
  end

  test "mirror captures writes within interval + epsilon", %{dir: dir} do
    {:ok, pid} =
      Smalt.Store.DetsMirror.start_link(dir: dir, tables: @tables, interval: 50)

    :ets.insert(:dm_t_resources, {"/r/a", %{"name" => "a"}})
    :ets.insert(:dm_t_docs, {"docs/1", %{"id" => 1}})

    # Poll-replaceable sync-wait (sleeps.md §A3): poll the closed dets read
    # until both mirrored rows are on disk instead of sleeping past one tick.
    SmaltTest.AssertEventually.eventually(
      fn ->
        rows_res = probe_rows(~c"#{dir}/dm_t_resources.dets")
        rows_docs = probe_rows(~c"#{dir}/dm_t_docs.dets")

        if {"/r/a", %{"name" => "a"}} in rows_res and {"docs/1", %{"id" => 1}} in rows_docs do
          {:ok, :flushed}
        else
          {:retry, %{resources: length(rows_res), docs: length(rows_docs)}}
        end
      end,
      deadline_ms: 5_000,
      observable: "DetsMirror flushed /r/a and docs/1 to disk"
    )

    # Read the dets files directly (closed read) to prove rows hit disk.
    # FLAKE_LEDGER F12 (receipts/i24-store-dets-torn.md): under full-suite
    # fleet load the mirror GenServer can be mid-`:dets.sync/1` when the
    # probe lands — header/footer momentarily torn — so a repair:false open
    # returns {:needs_repair, _} or :not_a_dets_file even though the file is
    # healthy. Bounded-retry the probe; a file still torn after the budget
    # fails loudly with a typed message naming the torn state. repair:false
    # is NEVER widened to true — that would mask real corruption.
    rows_res = probe_rows(~c"#{dir}/dm_t_resources.dets")
    assert {"/r/a", %{"name" => "a"}} in rows_res

    rows_docs = probe_rows(~c"#{dir}/dm_t_docs.dets")
    assert {"docs/1", %{"id" => 1}} in rows_docs

    GenServer.stop(pid)
  end

  test "restore inserts rows after simulated table clear", %{dir: dir} do
    :ets.insert(:dm_t_resources, {"/r/a", %{"name" => "a"}})
    :ets.insert(:dm_t_resources, {"/r/b", %{"name" => "b"}})

    {:ok, pid} =
      Smalt.Store.DetsMirror.start_link(dir: dir, tables: @tables, interval: 3_600_000)

    Smalt.Store.DetsMirror.sync(pid)

    # Simulate crash/loss: wipe the hot table
    :ets.delete_all_objects(:dm_t_resources)
    assert :ets.info(:dm_t_resources, :size) == 0

    {:ok, counts} = Smalt.Store.DetsMirror.restore(pid)
    assert counts[:dm_t_resources] == 2
    assert {:ok, %{"name" => "a"}} == lookup_val(:dm_t_resources, "/r/a")
    assert {:ok, %{"name" => "b"}} == lookup_val(:dm_t_resources, "/r/b")

    GenServer.stop(pid)
  end

  test "re-restore is idempotent and ETS stays source of truth", %{dir: dir} do
    :ets.insert(:dm_t_resources, {"/r/a", %{"name" => "hot"}})

    {:ok, pid} =
      Smalt.Store.DetsMirror.start_link(dir: dir, tables: @tables, interval: 3_600_000)

    Smalt.Store.DetsMirror.sync(pid)

    # ETS row mutated after sync: restore must NOT clobber it
    :ets.insert(:dm_t_resources, {"/r/a", %{"name" => "hotter"}})

    {:ok, counts1} = Smalt.Store.DetsMirror.restore(pid)
    assert counts1[:dm_t_resources] == 0
    assert {:ok, %{"name" => "hotter"}} == lookup_val(:dm_t_resources, "/r/a")

    # Second restore after clear: same rows inserted exactly once
    :ets.delete_all_objects(:dm_t_resources)
    {:ok, counts2} = Smalt.Store.DetsMirror.restore(pid)
    assert counts2[:dm_t_resources] == 1
    {:ok, counts3} = Smalt.Store.DetsMirror.restore(pid)
    assert counts3[:dm_t_resources] == 0

    GenServer.stop(pid)
  end

  @tag timeout: 30_000
  test "restore replays ledger meta so enforce-existence admits post-restore appends",
       %{dir: dir} do
    import Smalt.Store, only: [put: 3, get: 2, update_counter: 3, current_counter: 2]
    table = :smalt_ledger_meta

    # R81: shared app-owned table — clear pre-seed so prior tests (e.g.
    # security_hardening) cannot make counts == 2+N.
    if :ets.info(table) == :undefined do
      :ets.new(table, [:ordered_set, :public, :named_table])
    end

    :ets.delete_all_objects(table)

    put(table, {:latest, "L1"}, %{"txId" => "t9"})

    assert 3 == update_counter(table, {:seq, "L1"}, 3)

    {:ok, pid} =
      Smalt.Store.DetsMirror.start_link(dir: dir, tables: [table], interval: 3_600_000)

    Smalt.Store.DetsMirror.sync(pid)
    :ets.delete_all_objects(table)

    # Without meta replay, ledger_writer's enforce-existence gate refuses the
    # next append (404 class) and duplicate counters restart from 0.
    {:ok, counts} = Smalt.Store.DetsMirror.restore(pid)
    assert counts[table] == 2

    assert {:ok, %{"txId" => "t9"}} == get(table, {:latest, "L1"})

    # The restored seq counter RESUMES (not resets): post-restore append moves
    # it forward from the replayed value.
    assert 3 == current_counter(table, {:seq, "L1"})
    assert 4 == update_counter(table, {:seq, "L1"}, 1)

    GenServer.stop(pid)
  end

  test "corrupt dets file fails start_link closed with clear error", %{dir: dir} do
    File.write!(Path.join(dir, "dm_t_resources.dets"), "not a dets file at all")

    assert_raise ArgumentError, ~r/cannot open mirror file.*dm_t_resources/i, fn ->
      Smalt.Store.DetsMirror.start_link(dir: dir, tables: @tables, interval: 3_600_000)
    end
  end

  # 600s budget: receipts/i20b-contention-mechanism.md measured a 350x sync tail
  # under 16-core machine load, and receipts/r241 witnessed the previous 300s
  # budget blow out under load (4/4 green quiet at 93-204s body time).
  @tag :stress
  @tag timeout: 600_000
  test "restore x insert_new churn: insert_new :ok implies the FRESH value wins (no stale clobber)",
       %{
         dir: dir
       } do
    table = :dm_t_resources
    {clobbers, total_wins, vacuous_rounds} = race_rounds(table, dir)

    assert clobbers == [], """
    stale clobber witnessed for #{length(clobbers)} key(s): #{inspect(Enum.take(clobbers, 5))}
    restore must never run a bare :ets.lookup+:ets.insert that can interleave
    with a concurrent insert_new — it must route through Smalt.Store.insert_new/3.
    """

    # Non-vacuity pin: the court must WITNESS fresh wins, not pass on zero
    # coverage (a mutant that makes restore never touch a hot key would
    # survive a court whose racers never landed an :ok).
    assert total_wins > 0,
           "churn court landed zero fresh wins over #{@max_rounds} rounds " <>
             "(#{vacuous_rounds} vacuous) — court is vacuous"
  end

  # The lookup-vs-insert clobber window in a non-atomic restore is a few
  # nanoseconds wide; a single restore pass hits it only ~40% of the time
  # (measured on this court). So the court REPEATS the race: each round seeds a
  # fresh key namespace into the mirror, wipes the hot table, races a FIXED
  # attempt budget of fresh insert_new attempts against the concurrent
  # restore, and checks the no-clobber invariant. Attempt density is bounded
  # by construction (no spin-until-flag), restore's RETURN is the
  # deterministic completion signal, and vacuous rounds (zero :ok attempts
  # anywhere in the round) are counted so a vacuous court can never pass
  # silently. A non-atomic restore survives one round with p~0.9; the
  # 120-round x 50-attempt budget keeps mutant survival below ~2% and makes
  # it COMPUTABLE instead of load-dependent.
  @max_rounds 120
  @racer_keys 100
  @attempts_per_key 50

  defp race_rounds(table, dir) do
    1..@max_rounds
    |> Task.async_stream(
      fn round -> race_round(table, round, Path.join(dir, "round-#{round}")) end,
      max_concurrency: 1,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce({[], 0, 0}, fn
      {:ok, {clobbers, wins, vacuous}}, {cs, w, v} ->
        {cs ++ clobbers, w + wins, v + vacuous}

      {:exit, reason}, _acc ->
        flunk("churn round crashed or timed out: #{inspect(reason)}")
    end)
  end

  defp race_round(table, round, rdir) do
    File.mkdir_p!(rdir)
    {:ok, sup} = Task.Supervisor.start_link(name: nil)

    # Per-round supervision: mirror + racers + restore all live under a
    # per-round Task.Supervisor — a crash fails the ROUND loudly (async_stream
    # sees the exit) instead of orphaning tasks or black-holing to the 600s
    # timeout. The mirror GenServer itself is linked to this round task; the
    # supervisor tears everything down at round end.
    {:ok, mirror_pid} =
      Smalt.Store.DetsMirror.start_link(dir: rdir, tables: [table], interval: 3_600_000)

    keys = Enum.map(1..@racer_keys, &key(round, &1))
    stale = Enum.map(keys, &{&1, %{"gen" => "stale", "round" => round}})

    # Seed STALE rows into the FRESH per-round mirror.
    :ets.insert(table, stale)
    Smalt.Store.DetsMirror.sync(mirror_pid)

    # Wipe the hot table, then race FIXED-budget racers against the restore:
    # each racer performs exactly @attempts_per_key insert_new attempts and
    # reports its attempt ledger. Loser attempts (key already taken) are
    # consumed and recorded, so the round is never silently vacuous.
    :ets.delete_all_objects(table)

    racers =
      for {k, i} <- Enum.with_index(keys, 1) do
        Task.Supervisor.async_nolink(sup, fn ->
          fresh = %{"gen" => "fresh", "round" => round, "i" => i}

          oks =
            1..@attempts_per_key
            |> Enum.count(fn _ ->
              match?(:ok, Smalt.Store.insert_new(table, k, fresh))
            end)

          {k, oks}
        end)
      end

    # restore runs CONCURRENTLY with the racers; its RETURN is the
    # deterministic completion signal for the round.
    restore_task =
      Task.Supervisor.async_nolink(sup, fn -> Smalt.Store.DetsMirror.restore(mirror_pid) end)

    {:ok, _} = Task.await(restore_task, 30_000)

    results = Task.await_many(racers, 30_000)

    Supervisor.stop(sup)
    GenServer.stop(mirror_pid, :normal)

    # Audit: any key a racer WON (>=1 :ok) must hold the FRESH payload — a
    # bare :ets.lookup+:ets.insert in restore interleaves with a racer :ok
    # and ends stale. Wins are counted for the non-vacuity pin; a round where
    # no racer landed any :ok is vacuous and counted (never a silent pass).
    {clobbers, wins} =
      Enum.reduce(results, {[], 0}, fn {k, oks}, {cs, w} ->
        case :ets.lookup(table, k) do
          [{^k, %{"gen" => "fresh"}}] ->
            {cs, w + min(oks, 1)}

          [{^k, val}] when oks > 0 ->
            {[{k, val} | cs], w}

          _ ->
            {cs, w}
        end
      end)

    {clobbers, wins, if(wins == 0, do: 1, else: 0)}
  end

  # Closed-read probe with a bounded torn-state retry. The mirror holds the
  # dets file open and rewrites it on every sync; a probe racing a sync can
  # observe the transient torn state ({:needs_repair, _} or :not_a_dets_file).
  # Budget: 20 attempts x 250ms = 5s, sized to cover the measured 4008ms
  # sync fat tail (receipts/i20b-contention-mechanism.md). Persistent tear
  # (real corruption) still fails — with a message naming the torn state.
  @probe_attempts 20
  @probe_backoff_ms 250

  defp probe_rows(path) do
    Enum.reduce_while(1..@probe_attempts, nil, fn attempt, _acc ->
      case :dets.open_file(String.to_atom("probe_#{System.unique_integer([:positive])}"),
             file: path,
             repair: false
           ) do
        {:ok, dets} ->
          rows = :dets.match_object(dets, :_)
          :dets.close(dets)
          {:halt, rows}

        {:error, {:needs_repair, _}} = torn ->
          retry_or_raise(torn, path, attempt)

        {:error, {:not_a_dets_file, _}} = torn ->
          retry_or_raise(torn, path, attempt)

        # defensive: some OTP streams emit the bare-atom form
        {:error, tag} = torn when tag in [:needs_repair, :not_a_dets_file] ->
          retry_or_raise(torn, path, attempt)

        {:error, other} ->
          raise "dets probe of #{path} failed with unexpected error: #{inspect(other)}"
      end
    end)
  end

  defp retry_or_raise(_torn, path, attempt) when attempt < @probe_attempts do
    Process.sleep(@probe_backoff_ms)  # SLEEP-CLASS: POLL-STEP — bounded probe backoff retry
    {:cont, nil}
  end

  defp retry_or_raise(torn, path, _attempt) do
    raise """
    dets probe of #{path} still torn after #{@probe_attempts}x#{@probe_backoff_ms}ms: \
    #{inspect(torn)}. Either real corruption (fail closed) or the mirror's sync \
    exceeded the probe budget — both are loud, never a silent pass.
    """
  end

  defp lookup_val(table, key) do
    case :ets.lookup(table, key) do
      [{^key, val}] -> {:ok, val}
      [] -> :error
    end
  end

  defp key(round, i), do: "/churn/r#{round}/#{String.pad_leading(Integer.to_string(i), 4, "0")}"
end
