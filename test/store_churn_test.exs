defmodule Smalt.StoreChurnTest do
  @moduledoc """
  Mutation court for the churn-safe list law (Smalt.Store.list/1,
  list_prefix/2, keys/1): keys deleted MID-WALK must never raise
  (no MatchError from a stale `[{^key, val}]` match) and every returned
  value must be a value that was live in the table. Real ETS, real
  concurrent deleters — no doubles.
  """

  use ExUnit.Case, async: false

  @table :smalt_resources
  @prefix "/churn-test/"

  setup do
    # Isolate by prefix; never disturb other suites' rows in the shared table.
    on_exit(fn ->
      if :ets.info(@table) != :undefined do
        for key <- Smalt.Store.prefix_keys(@table, @prefix), do: :ets.delete(@table, key)
      end
    end)

    :ok
  end

  test "list/1 under concurrent mid-walk deletes: no MatchError, no phantom values" do
    seed_churn_table(200)

    values = run_churn(fn -> Smalt.Store.list(@table) end)

    assert Enum.all?(values, &is_map/1)

    assert values |> Enum.uniq_by(& &1["id"]) |> length() == length(values),
           "list/1 returned duplicate ids under churn"
  end

  test "list_prefix/2 under concurrent mid-walk deletes: no MatchError, all rows in prefix" do
    seed_churn_table(200)

    values = run_churn(fn -> Smalt.Store.list_prefix(@table, @prefix) end)

    assert length(values) > 0
    assert Enum.all?(values, fn v -> String.starts_with?(v["id"], @prefix) end)
  end

  test "keys/1 under concurrent mid-walk deletes: no MatchError, sorted" do
    seed_churn_table(200)

    keys = run_churn(fn -> Smalt.Store.keys(@table) end)

    assert keys == Enum.sort(keys)
  end

  # -- fail-closed store law -----------------------------------------------------

  # Parity with the admission gate: an unknown table is a typed hard failure,
  # never a silent success. :ets raises ArgumentError — pinned here so a
  # future "helpful" fallback (auto-create, empty-list return) cannot land
  # silently.
  test "unknown tables fail closed: get/put/delete/list never return a value" do
    assert_raise ArgumentError, fn -> Smalt.Store.get(:no_such_smalt_table, "k") end
    assert_raise ArgumentError, fn -> Smalt.Store.put(:no_such_smalt_table, "k", %{}) end
    assert_raise ArgumentError, fn -> Smalt.Store.delete(:no_such_smalt_table, "k") end
    assert_raise ArgumentError, fn -> Smalt.Store.list(:no_such_smalt_table) end
    assert_raise ArgumentError, fn -> Smalt.Store.compare_and_swap(:no_such_smalt_table, "k", 1, 2) end
  end

  test "CAS conflict returns typed {:error, :conflict}; win returns :ok" do
    key = "/churn-test/cas"

    :ets.insert(@table, {key, 1})

    assert Smalt.Store.compare_and_swap(@table, key, 1, 2) == :ok
    assert Smalt.Store.get(@table, key) == {:ok, 2}
    assert Smalt.Store.compare_and_swap(@table, key, 1, 3) == {:error, :conflict}
    assert Smalt.Store.get(@table, key) == {:ok, 2}

    :ets.delete(@table, key)
  end

  test "update_counter is atomic init-and-increment from 0" do
    key = "/churn-test/counter"

    assert Smalt.Store.update_counter(@table, key) == 1
    assert Smalt.Store.update_counter(@table, key, 5) == 6
    assert Smalt.Store.current_counter(@table, key) == 6

    :ets.delete(@table, key)
  end

  # -- exactly-one-winner law (compare_and_swap/4) -------------------------------

  # Same law the delete variant got (cycle-11): the etag check AND the insert
  # are ONE GenServer call (handle_call {:cas,...}), so N racers carrying the
  # same expected value yield exactly ONE :ok (its write wins) and N-1
  # {:error, :conflict}. The losers' table row must be the winner's new value,
  # never any racer's intermediate state.
  test "compare_and_swap/4: N racers, same expect — exactly one :ok, final value is the winner's" do
    key = "/churn-test/cas-race"

    for etag <- ["W/\"v0\"", "W/\"v1\""] do
      Smalt.Store.put(@table, key, etag)

      new_values =
        Map.new(1..32, fn i -> {i, "W/\"cas-race-#{i}\""} end)

      results =
        1..32
        |> Enum.map(fn i ->
          Task.async(fn ->
            Smalt.Store.compare_and_swap(@table, key, etag, new_values[i])
          end)
        end)
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :conflict})) == 31

      # The surviving row is EXACTLY the winner's new value (not an
      # intermediate state, not another racer's write).
      winner_index = Enum.find_index(results, &(&1 == :ok)) + 1
      assert Smalt.Store.get(@table, key) == {:ok, new_values[winner_index]}
    end

    :ets.delete(@table, key)
  end

  # -- no-lost-updates law (update_counter/3) ------------------------------------

  # The doc law: update_counter/3 is the BIF-level atomic init-and-increment
  # (`:ets.update_counter/4` with default `{key, 0}`). N concurrent
  # incrementers on a fresh key must yield the totals 1..N in some order —
  # every intermediate total appears exactly once and the final total is
  # exactly N. A read-increment-write mutant loses updates; this pins that
  # the BIF path survives real contention.
  test "update_counter/3: 32 racers on a fresh key — totals 1..N each exactly once, final N" do
    key = "/churn-test/counter-race"

    totals =
      1..32
      |> Enum.map(fn _ -> Task.async(fn -> Smalt.Store.update_counter(@table, key, 1) end) end)
      |> Enum.map(&Task.await/1)
      |> Enum.sort()

    assert totals == Enum.to_list(1..32)
    assert Smalt.Store.current_counter(@table, key) == 32

    :ets.delete(@table, key)
  end

  # Negative increments are first-class: the raw ETS contract does NOT clamp
  # or raise on a negative result (witnessed: 3 + (-10) = -7 in a real ETS
  # probe). Pinned so a future wrapper cannot silently change the shape of
  # the guarantee either direction.
  test "update_counter/3 negative result is allowed by the raw ETS contract (no clamp)" do
    key = "/churn-test/counter-neg"

    assert Smalt.Store.update_counter(@table, key, 3) == 3
    assert Smalt.Store.update_counter(@table, key, -10) == -7
    assert Smalt.Store.current_counter(@table, key) == -7

    :ets.delete(@table, key)
  end

  # Fail-closed parity: an unknown table raises ArgumentError in the CALLER
  # (:ets.update_counter / :ets.lookup on a missing table) — a hard failure,
  # never a silent 0 — and the shared Store GenServer survives.
  test "update_counter/current_counter on unknown table fail closed in the caller" do
    assert_raise ArgumentError, fn -> Smalt.Store.update_counter(:smalt_no_such_table, "k", 1) end
    assert_raise ArgumentError, fn -> Smalt.Store.current_counter(:smalt_no_such_table, "k") end

    assert Process.whereis(Smalt.Store) |> is_pid()
  end

  # -- exactly-one-winner law (compare_and_swap_delete/3) ------------------------

  # The doc law: N concurrent conditional deletes carrying the same etag must
  # yield EXACTLY ONE `:ok` and N-1 `{:error, :conflict}` — the etag check and
  # the delete are ONE GenServer call, so the read-check-delete TOCTOU that
  # let two racing conditional deletes both return 204 is structurally
  # impossible. Unpinned until now (cosmos.ex consumes this).
  test "compare_and_swap_delete/3: N racers, same etag — exactly one :ok, rest conflict" do
    key = "/churn-test/cas-delete"
    etag = "W/\"etag-1\""

    Smalt.Store.put(@table, key, etag)

    results =
      1..32
      |> Enum.map(fn _ ->
        Task.async(fn -> Smalt.Store.compare_and_swap_delete(@table, key, etag) end)
      end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :conflict})) == 31
    # the row is really gone
    assert Smalt.Store.get(@table, key) == :error
  end

  test "insert_new/3 under 64 racers on one key: exactly one insert, winner's value wins" do
    key = @prefix <> "insert-new-race"
    n = 64

    results =
      1..n
      |> Enum.map(fn i ->
        Task.async(fn ->
          Smalt.Store.insert_new(@table, key, %{"id" => key, "racer" => i})
        end)
      end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &(&1 == :ok)) == 1,
           "expected exactly one :ok, got #{Enum.count(results, &(&1 == :ok))}"

    assert Enum.count(results, &(&1 == {:error, :exists})) == n - 1

    # the stored row IS the single winner's payload (insert-only: no
    # overwrite can have happened, so the value identifies the winner)
    {:ok, stored} = Smalt.Store.get(@table, key)
    assert stored["racer"] in 1..n
    winner = stored["racer"]
    assert Enum.at(results, winner - 1) == :ok
  end

  test "insert_new/3 unknown table fails closed in the caller" do
    assert_raise ArgumentError, ~r/unknown table/, fn ->
      Smalt.Store.insert_new(:smalt_no_such_table, "k", "v")
    end

    # the shared Store GenServer survived
    assert Process.whereis(Smalt.Store) |> is_pid()
  end

  test "compare_and_swap_delete/3 unknown table fails closed in the caller" do
    assert_raise ArgumentError, ~r/unknown table/, fn ->
      Smalt.Store.compare_and_swap_delete(:smalt_no_such_table, "k", "e")
    end

    # the shared Store GenServer survived
    assert Process.whereis(Smalt.Store) |> is_pid()
  end

  # -- helpers -------------------------------------------------------------------

  # Repeats the (reader × deleter) race so the walk provably overlaps the
  # deletion window — deterministic kill for the strict-match mutation court.
  defp run_churn(reader) do
    results = Enum.map(1..5, fn _ ->
      # Re-seed per race: the deleter empties the prefix each iteration.
      seed_churn_table(200)
      run_churn_once(reader)
    end)

    List.last(results)
  end

  # Runs `reader` concurrently with a real deleter ripping rows out of the
  # table mid-walk. The reader returning at all proves no MatchError escaped
  # (an unhandled MatchError crashes the test process). Returns the read.
  defp run_churn_once(reader) do
    deleter =
      Task.async(fn ->
        for key <- Smalt.Store.prefix_keys(@table, @prefix) do
          :ets.delete(@table, key)
        end
      end)

    values = reader.()
    Task.await(deleter, 10_000)
    values
  end

  defp seed_churn_table(n) do
    for i <- 1..n do
      id = @prefix <> String.pad_leading(Integer.to_string(i), 4, "0")

      :ets.insert(@table, {id, %{"id" => id, "location" => "churntest"}})
    end
  end
end
