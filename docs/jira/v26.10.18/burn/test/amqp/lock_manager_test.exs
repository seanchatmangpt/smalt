defmodule Smalt.Amqp.LockManagerTest do
  use ExUnit.Case, async: false

  alias Smalt.Amqp.LockManager

  @tables [:smalt_sb_locks, :smalt_sb_sessions]

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

      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
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
      assert {:error, :not_found} =
               LockManager.renew("00000000-0000-4000-8000-000000000000", 1_000)
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
      assert {:ok, lock} =
               LockManager.session_acquire("q", "s1", now_ms: 1_000, duration_ms: 1_000)

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

        assert winners == 1,
               "phase got #{winners} winners: #{inspect(results |> Enum.frequencies() |> Map.to_list() |> List.first())}"

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

    test "R178j: sweep reclaims expired session token orphaned by re-acquire; live token survives" do
      {:ok, old} = LockManager.session_acquire("q", "s", now_ms: 1_000, duration_ms: 500)
      # expiry -> re-acquire overwrites the sessions row with a NEW token; the
      # old token row in :smalt_sb_locks would previously be swept never
      {:ok, fresh} = LockManager.session_acquire("q", "s", now_ms: 2_000, duration_ms: 30_000)
      assert old.lock_token != fresh.lock_token
      assert {:ok, _} = LockManager.get(fresh.lock_token)

      assert LockManager.sweep(3_000) >= 1

      # the orphaned old token is gone
      assert :error = LockManager.get(old.lock_token)
      # the live lock (sessions row + matching token) survives
      assert {:ok, _} = LockManager.get(fresh.lock_token)
      assert {:ok, %{lock_token: tok}} = Smalt.Store.get(:smalt_sb_sessions, {"q", "s"})
      assert tok == fresh.lock_token
    end

    # V261014-04 F2: renew-by-token on a session lock must renew the mirrored
    # {queue, session_id} record too — the stale :smalt_sb_sessions locked_until
    # caused spurious stale-expiry reclaims / double acquires.
    test "renew by token updates BOTH :smalt_sb_locks and :smalt_sb_sessions (F2)" do
      {:ok, lock} = LockManager.session_acquire("q", "s1", now_ms: 1_000, duration_ms: 1_000)

      assert {:ok, renewed} = LockManager.renew(lock.lock_token, 1_500)
      assert renewed.locked_until == 2_500

      assert {:ok, token_row} = LockManager.get(lock.lock_token)
      assert token_row.locked_until == 2_500

      assert {:ok, session_row} = Smalt.Store.get(:smalt_sb_sessions, {"q", "s1"})
      assert session_row.locked_until == 2_500
    end

    test "renew by token on a pure message lock creates no session rows (F2)" do
      {:ok, lock} = LockManager.acquire("q", 1, now_ms: 1_000, duration_ms: 1_000)

      assert {:ok, renewed} = LockManager.renew(lock.lock_token, 1_500)
      assert renewed.locked_until == 2_500

      # no session row materialized for the message lock's queue
      assert :error = Smalt.Store.get(:smalt_sb_sessions, {"q", nil})
      assert :ets.info(:smalt_sb_sessions, :size) == 0
    end

    # V261014-04 F3: release-vs-claim race court. Deterministic: both racers
    # inject now_ms; no sleeps. Post-state must be one of the two lawful
    # linearizations — {lock held by B intact} or {lock released, B loses} —
    # never a stale/held-by-A record or B's fresh lock silently deleted.
    test "racing session_release vs session_acquire yields only lawful post-states (F3)" do
      queue = "race-q-#{System.unique_integer([:positive])}"

      for phase <- 1..50 do
        Enum.each(@tables, &:ets.delete_all_objects/1)

        {:ok, a_lock} =
          LockManager.session_acquire(queue, "s1", now_ms: 1_000, duration_ms: 5_000)

        releaser =
          Task.async(fn -> LockManager.session_release(queue, "s1") end)

        claimer =
          Task.async(fn ->
            LockManager.session_acquire(queue, "s1", now_ms: 1_100, duration_ms: 5_000)
          end)

        assert :ok = Task.await(releaser)
        claim_result = Task.await(claimer)

        post_session = Smalt.Store.get(:smalt_sb_sessions, {queue, "s1"})
        post_token = LockManager.get(a_lock.lock_token)

        lawful? =
          case claim_result do
            # B won the claim: B's lock must be intact in the sessions table
            # (its own fresh token), and A's token must be gone.
            {:ok, b_lock} ->
              case post_session do
                {:ok, ^b_lock} -> post_token == :error and b_lock.lock_token != a_lock.lock_token
                _ -> false
              end

            # release won the serialization: B lost, nothing left behind
            {:error, :already_locked} ->
              post_session == :error and post_token == :error

            _ ->
              false
          end

        assert lawful?,
               "phase #{phase}: unlawful post-state " <>
                 inspect(claim: claim_result, session: post_session, a_token: post_token)
      end
    end
  end

  # R68: isolated property check for the .NET-GUID byte-reorder involution.
  # Only exercised end-to-end via real SDK probes before this — these two
  # pure functions are the wire-compat pinion; assert both directions and the
  # exact byte shape, not just "some 16 bytes".
  describe ".NET-GUID lock-token involution" do
    test "format_uuid∘token_to_raw is a byte-reorder involution with GUID shape" do
      for _ <- 1..25 do
        <<b0, b1, b2, b3, b4, b5, b6, b7, _rest::binary-size(8)>> = :crypto.strong_rand_bytes(16)

        hex = fn b -> :io_lib.format("~2.16.0b", [b]) |> IO.iodata_to_binary() end

        t =
          Enum.map_join([b0, b1, b2, b3], &hex.(&1)) <>
            "-" <>
            Enum.map_join([b4, b5], &hex.(&1)) <>
            "-" <>
            Enum.map_join([b6, b7], &hex.(&1)) <>
            "-0000-000000000000"

        # Involution at string level: the .NET-GUID permutation P is its own
        # inverse, so P(P(t)) == t. (format_uuid ∘ token_to_raw is P once;
        # applying it a second time restores the original dashed form.)
        raw = LockManager.token_to_raw(t)
        t2 = LockManager.format_uuid(raw)
        assert LockManager.format_uuid(LockManager.token_to_raw(t2)) == t

        # byte-level reorder shape: first 3 pairs swapped
        assert raw == <<b3, b2, b1, b0, b5, b4, b7, b6, 0::size(64)>>

        assert t2 ==
                 Enum.map_join([b3, b2, b1, b0], &hex.(&1)) <>
                   "-" <>
                   Enum.map_join([b5, b4], &hex.(&1)) <>
                   "-" <>
                   Enum.map_join([b7, b6], &hex.(&1)) <> "-0000-000000000000"
      end
    end
  end
end
