defmodule Smalt.Amqp.LockManagerTest do
  use ExUnit.Case, async: false

  alias Smalt.Amqp.LockManager

  @tables [:smalt_sb_locks, :smalt_sb_sessions]

  setup do
    Enum.each(@tables, fn table ->
      if :ets.info(table) == :undefined do
        :ets.new(table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
      end
    end)

    Enum.each(@tables, &:ets.delete_all_objects/1)
    :ok
  end

  describe "clamp_duration/1" do
    test "bounds are 100..30000, default 30000" do
      assert LockManager.clamp_duration(nil) == 30000
      assert LockManager.clamp_duration(50) == 100
      assert LockManager.clamp_duration(100) == 100
      assert LockManager.clamp_duration(5_000) == 5_000
      assert LockManager.clamp_duration(30_000) == 30_000
      assert LockManager.clamp_duration(60_000) == 30_000
    end
  end

  describe "expired?/2" do
    test "pure check on locked_until" do
      assert LockManager.expired?(1_000, 1_000)
      assert LockManager.expired?(999, 1_000)
      refute LockManager.expired?(1_001, 1_000)
      refute LockManager.expired?(%{locked_until: 1_001}, 1_000)
      assert LockManager.expired?(%{locked_until: 1_000}, 1_000)
    end
  end

  describe "acquire/3 and renew/3 (message locks)" do
    test "acquire stores lock with clamped expiry and UUID v4 token" do
      assert {:ok, lock} = LockManager.acquire("q", 1, now_ms: 1_000, duration_ms: 10_000)
      assert lock.locked_until == 11_000
      assert lock.queue == "q"
      assert lock.seq == 1
      assert lock.kind == :message
      assert {:ok, ^lock} = LockManager.get(lock.lock_token)

      assert Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
               lock.lock_token
             )

      # unique across acquires
      {:ok, lock2} = LockManager.acquire("q", 2, now_ms: 1_000)
      refute lock2.lock_token == lock.lock_token

      # clamped: 10 ms request -> 100 ms window
      assert {:ok, short} = LockManager.acquire("q", 3, now_ms: 1_000, duration_ms: 10)
      assert short.locked_until == 1_100
    end

    test "renew extends locked_until by the lock duration" do
      {:ok, lock} = LockManager.acquire("q", 1, now_ms: 1_000, duration_ms: 1_000)
      assert {:ok, renewed} = LockManager.renew(lock.lock_token, 1_500)
      assert renewed.locked_until == 2_500
      assert {:ok, persisted} = LockManager.get(lock.lock_token)
      assert persisted.locked_until == 2_500
    end

    test "renew with explicit duration clamps" do
      {:ok, lock} = LockManager.acquire("q", 1, now_ms: 1_000, duration_ms: 1_000)
      assert {:ok, renewed} = LockManager.renew(lock.lock_token, 1_500, duration_ms: 99_999)
      assert renewed.locked_until == 31_500
    end

    test "renew unknown token -> 404 :not_found" do
      assert {:error, :not_found} = LockManager.renew("00000000-0000-4000-8000-000000000000", 1_000)
    end

    test "renew expired token -> 410 :lock_lost" do
      {:ok, lock} = LockManager.acquire("q", 1, now_ms: 1_000, duration_ms: 500)
      assert lock.locked_until == 1_500
      assert {:error, :lock_lost} = LockManager.renew(lock.lock_token, 1_501)
      # exactly at expiry is already expired (locked_until <= now)
      {:ok, lock2} = LockManager.acquire("q", 2, now_ms: 1_000, duration_ms: 500)
      assert {:error, :lock_lost} = LockManager.renew(lock2.lock_token, 1_500)
    end

    test "renew before expiry succeeds" do
      {:ok, lock} = LockManager.acquire("q", 1, now_ms: 1_000, duration_ms: 500)
      assert {:ok, _} = LockManager.renew(lock.lock_token, 1_499)
    end

    test "release deletes the lock" do
      {:ok, lock} = LockManager.acquire("q", 1, now_ms: 1_000)
      assert :ok = LockManager.release(lock.lock_token)
      assert :error = LockManager.get(lock.lock_token)
      # release of unknown token is still :ok
      assert :ok = LockManager.release("nope")
    end
  end

  describe "session locks" do
    test "session_acquire / renew / release keyed by {queue, session_id}" do
      assert {:ok, lock} = LockManager.session_acquire("q", "s1", now_ms: 1_000, duration_ms: 1_000)
      assert lock.kind == :session
      assert lock.session_id == "s1"
      assert lock.locked_until == 2_000

      # second acquire while held -> :already_locked
      assert {:error, :already_locked} = LockManager.session_acquire("q", "s1", now_ms: 1_500)

      assert {:ok, renewed} = LockManager.session_renew("q", "s1", 1_500)
      assert renewed.locked_until == 2_500

      assert :ok = LockManager.session_release("q", "s1")
      assert {:ok, _} = LockManager.session_acquire("q", "s1", now_ms: 2_000)
    end

    test "expired session lock can be re-acquired; renew of it is :lock_lost" do
      {:ok, _lock} = LockManager.session_acquire("q", "s1", now_ms: 1_000, duration_ms: 500)

      assert {:error, :lock_lost} = LockManager.session_renew("q", "s1", 1_501)
      assert {:ok, _} = LockManager.session_acquire("q", "s1", now_ms: 1_501)
    end

    test "session_renew unknown session -> :not_found" do
      assert {:error, :not_found} = LockManager.session_renew("q", "ghost", 1_000)
    end

    test "different sessions on same queue, same session on different queues are independent" do
      assert {:ok, _} = LockManager.session_acquire("q", "s1", now_ms: 1_000)
      assert {:ok, _} = LockManager.session_acquire("q", "s2", now_ms: 1_000)
      assert {:ok, _} = LockManager.session_acquire("other", "s1", now_ms: 1_000)
    end

    test "200-racer session_acquire: exactly 1 winner, 199 already_locked (20 phases)" do
      for _phase <- 1..20 do
        Enum.each(@tables, &:ets.delete_all_objects/1)

        results =
          1..200
          |> Task.async_stream(
            fn _ -> LockManager.session_acquire("race", "s1", duration_ms: 5_000) end,
            max_concurrency: 200,
            timeout: 30_000
          )
          |> Enum.map(fn {:ok, v} -> v end)

        winners = Enum.count(results, &match?({:ok, _}, &1))
        losers = Enum.count(results, &match?({:error, :already_locked}, &1))

        assert winners == 1, "phase got #{winners} winners: #{inspect(results |> Enum.frequencies() |> Map.to_list() |> List.first())}"
        assert losers == 199

        :ok = LockManager.session_release("race", "s1")
      end
    end

    test "sweep/1 reclaims expired session locks and orphaned tokens" do
      {:ok, lock} = LockManager.session_acquire("q", "old", now_ms: 1_000, duration_ms: 500)
      {:ok, live} = LockManager.session_acquire("q", "live", now_ms: 1_000, duration_ms: 30_000)
      {:ok, orphan} = LockManager.acquire("q", 7, now_ms: 1_000, duration_ms: 500)

      assert LockManager.sweep(1_500) >= 2

      # expired session lock fully reclaimed
      assert :error = LockManager.get(lock.lock_token)
      assert {:error, :not_found} = LockManager.session_renew("q", "old", 1_500)

      # live session lock untouched
      assert {:ok, _} = LockManager.get(live.lock_token)

      # expired message-lock token GC'd
      assert :error = LockManager.get(orphan.lock_token)
    end
  end
end
