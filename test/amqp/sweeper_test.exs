defmodule Smalt.Amqp.SweeperTest do
  use ExUnit.Case, async: false

  alias Smalt.Amqp.{LockManager, Sweeper}

  @tables [:smalt_sb_locks, :smalt_sb_sessions, :smalt_sb_messages]
  @tombstones :smalt_sb_sweeper_lock_tombstones

  setup do
    Enum.each(@tables, fn table ->
      if :ets.info(table) == :undefined do
        :ets.new(table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])
      end
    end)

    Enum.each(@tables, &:ets.delete_all_objects/1)

    if :ets.info(@tombstones) == :undefined do
      :ets.new(@tombstones, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ets.delete_all_objects(@tombstones)

    on_exit(fn ->
      if :ets.info(@tombstones) != :undefined do
        :ets.delete_all_objects(@tombstones)
      end
    end)

    :ok
  end

  # audit Finding 3: run_pass used to let LockManager.sweep/0 reap expired
  # :message token rows before QueueStore.sweep/0 re-availed the rows, so a
  # renew of a just-expired token answered 404 :not_found where the pinned
  # contract (lock_manager.ex moduledoc) demands 410 :lock_lost.
  describe "message-lock tombstone grace (audit Finding 3)" do
    test "one pass: renew of just-swept message token is 410 :lock_lost, not 404" do
      {:ok, lock} = LockManager.acquire("tq", 1, now_ms: 1_000, duration_ms: 100)

      # expired long ago in wall-clock terms -> deterministic
      assert {:ok, %{kind: :message}} = LockManager.get(lock.lock_token)

      assert :ok = Sweeper.run_pass()

      # token row deleted by the sweeps, re-inserted by the grace
      assert {:ok, %{locked_until: 1_100}} = LockManager.get(lock.lock_token)

      assert {:error, :lock_lost} =
               LockManager.renew(lock.lock_token, System.system_time(:millisecond))
    end

    test "grace survives a second pass (tombstone refresh), still 410" do
      {:ok, lock} = LockManager.acquire("tq", 1, now_ms: 1_000, duration_ms: 100)

      assert :ok = Sweeper.run_pass()
      assert :ok = Sweeper.run_pass()

      assert {:ok, %{locked_until: 1_100}} = LockManager.get(lock.lock_token)

      assert {:error, :lock_lost} =
               LockManager.renew(lock.lock_token, System.system_time(:millisecond))
    end

    test "past the grace window the tombstone expires: renew is 404 :not_found" do
      Application.put_env(:smalt, :amqp_sweeper_lock_grace_ms, 1)

      try do
        {:ok, lock} = LockManager.acquire("tq", 1, now_ms: 1_000, duration_ms: 100)

        assert :ok = Sweeper.run_pass()
        assert {:ok, _} = LockManager.get(lock.lock_token)

        # first_swept_at + 1ms grace elapses
        Process.sleep(5)
        assert :ok = Sweeper.run_pass()

        assert :error = LockManager.get(lock.lock_token)

        assert {:error, :not_found} =
                 LockManager.renew(lock.lock_token, System.system_time(:millisecond))
      after
        Application.delete_env(:smalt, :amqp_sweeper_lock_grace_ms)
        :ets.delete_all_objects(@tombstones)
      end
    end

    test "grace disabled (0 ms): swept token stays deleted, renew 404 (old behavior)" do
      Application.put_env(:smalt, :amqp_sweeper_lock_grace_ms, 0)

      try do
        {:ok, lock} = LockManager.acquire("tq", 1, now_ms: 1_000, duration_ms: 100)

        assert :ok = Sweeper.run_pass()
        assert :error = LockManager.get(lock.lock_token)

        assert {:error, :not_found} =
                 LockManager.renew(lock.lock_token, System.system_time(:millisecond))
      after
        Application.delete_env(:smalt, :amqp_sweeper_lock_grace_ms)
      end
    end

    test "live (unexpired) message token is never tombstoned or swept" do
      {:ok, lock} = LockManager.acquire("tq", 1, duration_ms: 30_000)

      assert :ok = Sweeper.run_pass()

      assert {:ok, _} = LockManager.get(lock.lock_token)
      assert {:ok, _} = LockManager.renew(lock.lock_token, System.system_time(:millisecond))
    end
  end
end
