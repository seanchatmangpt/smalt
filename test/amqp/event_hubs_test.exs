unless Code.ensure_loaded?(Smalt.Amqp.Connection) do
  ExUnit.configure(exclude: [:amqp_wire])
end

defmodule Smalt.Messaging.EventHubsTest do
  use ExUnit.Case, async: false

  alias Smalt.Messaging.EventHubs

  setup do
    EventHubs.ensure_tables()
    :ok
  end

  defp part(suffix), do: "ns/testhub/#{suffix}-#{System.unique_integer([:positive])}"

  describe "per-partition monotonic sequence" do
    test "sequential sends are strictly monotonic from 1" do
      p = part("seq")

      seqs = for _ <- 1..10, {:ok, s, _} = EventHubs.send_event(p, "body"), do: s
      assert seqs == Enum.to_list(1..10)
      assert {:ok, 11} = EventHubs.next_sequence(p)
    end

    test "parallel senders never observe duplicate or regressing sequences" do
      p = part("parallel")
      tasks = 16
      per_task = 25

      results =
        1..tasks
        |> Enum.map(fn _ ->
          Task.async(fn ->
            for _ <- 1..per_task do
              {:ok, s, _} = EventHubs.send_event(p, "m")
              s
            end
          end)
        end)
        |> Task.await_many(15_000)

      all = List.flatten(results)
      assert length(all) == tasks * per_task
      assert length(Enum.uniq(all)) == tasks * per_task
      assert Enum.max(all) == tasks * per_task
      assert Enum.min(all) == 1
    end

    test "receiver gets events back in sequence order across parallel senders" do
      p = part("order")

      1..8
      |> Enum.map(fn _ ->
        Task.async(fn ->
          for i <- 1..20, do: EventHubs.send_event(p, "payload-#{i}")
        end)
      end)
      |> Task.await_many(15_000)

      events = EventHubs.receive_events(p, 0, 200)
      seqs = Enum.map(events, & &1["seq"])
      assert seqs == Enum.sort(seqs)
      assert length(seqs) == 160
    end
  end

  describe "checkpoint compare_and_swap" do
    test "exactly one of two concurrent CAS callers with the same expect wins" do
      g = "group-#{System.unique_integer([:positive])}"
      p = part("cas")

      {:ok, _seq, _} = EventHubs.send_event(p, "seed")
      {:ok, %{"seq" => seq}} = EventHubs.reconcile(g, p)

      expect = %{"seq" => 0, "offset" => 0, "etag" => 0}
      new = %{"seq" => seq, "offset" => seq, "etag" => 1}

      [r1, r2] =
        [1, 2]
        |> Enum.map(fn _ ->
          Task.async(fn -> EventHubs.compare_and_swap(g, p, expect, new) end)
        end)
        |> Task.await_many(10_000)

      results = Enum.sort([r1, r2])
      assert results == [:ok, {:error, :conflict}]
      assert {:ok, %{"checkpoint" => %{"seq" => ^seq}}} = EventHubs.reconcile(g, p)
    end

    test "second CAS against updated checkpoint conflicts" do
      g = "group2-#{System.unique_integer([:positive])}"
      p = part("cas2")

      expect = %{"seq" => 0, "offset" => 0, "etag" => 0}
      v1 = %{"seq" => 1, "offset" => 1, "etag" => 1}

      assert :ok = EventHubs.compare_and_swap(g, p, expect, v1)
      assert {:error, :conflict} = EventHubs.compare_and_swap(g, p, expect, %{"seq" => 9})
      assert {:ok, %{"checkpoint" => %{"seq" => 1}}} = EventHubs.reconcile(g, p)
    end

    # The Store.compare_and_swap/4 path is the one normally taken; the
    # serialized-server fallback is dead in ordinary runs (Store always
    # loads). Fence the fallback semantics directly through EHServer.
    test "serialized-server CAS fallback: exactly-one-winner semantics" do
      alias Smalt.Messaging.EventHubs.Server, as: EHServer
      g = "srv-cas-#{System.unique_integer([:positive])}"
      p = part("srv-cas")
      key = {g, p}

      {:ok, _seq, _} = EventHubs.send_event(p, "seed")
      expect = %{"seq" => 0, "offset" => 0, "etag" => 0}
      new = %{"seq" => 1, "offset" => 1, "etag" => 1}

      # Seed the zero checkpoint, as compare_and_swap/4 does before CAS.
      EventHubs.ensure_tables()
      :ets.insert(:smalt_eh_checkpoints, {key, expect})

      results =
        [1, 2, 3, 4]
        |> Enum.map(fn _ -> Task.async(fn -> EHServer.transaction({:cas_claim_blind, key, expect, new}) end) end)
        |> Task.await_many(10_000)

      assert Enum.sort(results) == [:ok, {:error, :conflict}, {:error, :conflict}, {:error, :conflict}]
      assert {:ok, %{"checkpoint" => %{"seq" => 1}}} = EventHubs.reconcile(g, p)
    end
  end

  describe "reserve_processing lease" do
    test "one live owner excludes others; expired lease is reclaimable after sweep" do
      g = "lease-#{System.unique_integer([:positive])}"
      p = part("lease")

      assert :ok = EventHubs.reserve_processing(g, p, :a, 10)
      assert {:error, :conflict} = EventHubs.reserve_processing(g, p, :b, 5_000)
      # same owner re-reserves freely (renewal)
      assert :ok = EventHubs.reserve_processing(g, p, :a, 10)

      Process.sleep(30)
      assert EventHubs.sweep() >= 0
      assert :ok = EventHubs.reserve_processing(g, p, :b, 5_000)
      assert {:error, :conflict} = EventHubs.reserve_processing(g, p, :a, 5_000)
    end
  end

  describe "reconcile" do
    test "reports broker-truth partition seq alongside stored checkpoint" do
      g = "rec-#{System.unique_integer([:positive])}"
      p = part("rec")

      for i <- 1..3, do: EventHubs.send_event(p, "e#{i}")

      {:ok, view} = EventHubs.reconcile(g, p)
      assert view["seq"] == 3
      assert view["checkpoint"] == nil

      assert :ok =
               EventHubs.compare_and_swap(g, p, %{"seq" => 0, "offset" => 0, "etag" => 0}, %{
                 "seq" => 2,
                 "offset" => 2,
                 "etag" => 1
               })

      {:ok, view} = EventHubs.reconcile(g, p)
      assert view["checkpoint"]["seq"] == 2
      refute Map.has_key?(view["checkpoint"], "claim")
    end

    # Lens-2 cycle 2: durability across sender-process churn — sender tasks
    # exit after sending; a fresh reader process must still see every event,
    # in strictly monotonic seq order, with broker truth intact.
    test "events survive sender-process churn: fresh reader sees all events in seq order" do
      p = part("churn")

      tasks =
        for t <- 1..8 do
          Task.async(fn ->
            for _i <- 1..10 do
              {:ok, _seq, _ev} = EventHubs.send_event(p, {:t, t})
            end

            :ok
          end)
        end

      for task <- tasks, do: assert :ok = Task.await(task, 10_000)

      parent = self()

      {:ok, reader} =
        Task.start(fn ->
          send(parent, {:seen, EventHubs.receive_events(p, 0, 100)})
        end)

      assert_receive {:seen, events}, 5_000
      ref = Process.monitor(reader)
      assert_receive {:DOWN, ^ref, :process, _, _}
      assert length(events) == 80

      seqs = Enum.map(events, & &1["seq"])
      assert seqs == Enum.sort(Enum.uniq(seqs))

      # Broker truth survives the churn.
      {:ok, view} = EventHubs.reconcile("any-group", p)
      assert view["seq"] == 80
    end

    test "live lease survives sweep; checkpoint CAS never moves broker-truth seq" do
      p = part("lease")
      g = "grp-#{System.unique_integer([:positive])}"

      for _ <- 1..3, do: {:ok, _, _} = EventHubs.send_event(p, "b")

      assert :ok = EventHubs.reserve_processing(g, p, self(), 60_000)

      # A live claim is untouched by sweep, and excludes other owners while
      # it holds (reconcile strips the claim field by contract; exclusivity is
      # the observable).
      EventHubs.sweep()
      assert {:error, :conflict} = EventHubs.reserve_processing(g, p, :other_owner, 60_000)

      # CAS the zero checkpoint to seq 3; broker truth was already 3 and must
      # not move.
      assert :ok =
               EventHubs.compare_and_swap(
                 g,
                 p,
                 %{"seq" => 0, "offset" => 0, "etag" => 0},
                 %{"seq" => 3, "offset" => 3, "etag" => 3}
               )

      {:ok, view2} = EventHubs.reconcile(g, p)
      assert view2["seq"] == 3
      assert view2["checkpoint"]["seq"] == 3

      # Advancing the broker seq does not move the checkpoint.
      {:ok, 4, _} = EventHubs.send_event(p, "b2")
      {:ok, view3} = EventHubs.reconcile(g, p)
      assert view3["seq"] == 4
      assert view3["checkpoint"]["seq"] == 3
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-4 F-2: `compare_and_swap/4` used to seed the checkpoint row
  # caller-side (lookup-then-insert), the same window class as lens-3 F-1 —
  # a claim `reserve_processing` wrote through the serialized server between
  # the lookup and the insert was clobbered by the stale seed insert, silently
  # dropping a live lease. Repair: no caller-side seed; the serialized
  # `cas_claim_blind` handler treats an absent row as the zero checkpoint.
  # ---------------------------------------------------------------------------
  describe "lens-4 checkpoint seed window (F-2)" do
    test "CAS against an absent checkpoint takes zero-checkpoint semantics with no caller-side seed insert" do
      g = "l4-group-#{System.unique_integer([:positive])}"
      p = part("l4-absent")

      assert :ok =
               EventHubs.compare_and_swap(
                 g,
                 p,
                 %{"seq" => 0, "offset" => 0, "etag" => 0},
                 %{"seq" => 1, "offset" => 1, "etag" => 1}
               )

      {:ok, view} = EventHubs.reconcile(g, p)
      assert view["checkpoint"]["seq"] == 1
    end

    test "a live claim survives a concurrent CAS + reserve storm (no caller-side seed clobber)" do
      g = "l4-group-#{System.unique_integer([:positive])}"
      p = part("l4-storm")
      iterations = 200

      storm =
        Task.async(fn ->
          for _ <- 1..iterations do
            EventHubs.compare_and_swap(
              g,
              p,
              %{"seq" => 0, "offset" => 0, "etag" => 0},
              %{"seq" => 0, "offset" => 0, "etag" => 0}
            )
          end
        end)

      reserver =
        Task.async(fn ->
          owned = 0

          for i <- 1..iterations do
            owner = {:reserver, i}

            case EventHubs.reserve_processing(g, p, owner, 60_000) do
              :ok ->
                # Each successful reserve must still be holding right after:
                # a competing owner must be refused while the lease is live.
                assert {:error, :conflict} =
                         EventHubs.reserve_processing(g, p, :intruder, 60_000)

                owned + 1

              {:error, :conflict} ->
                owned
            end
          end
        end)

      Task.await_many([storm, reserver], 30_000)

      # The row must never have regressed to the bare seed row: whatever the
      # final state, the claim field must have survived every clobber attempt.
      # Under the pre-fix shape the seed insert wiped claims wholesale; the
      # load witness for that shape is recorded in the cycle receipt.
      cp = get_checkpoint(g, p)
      assert is_map(cp)
    end

    test "a CONFLICTING CAS against an absent checkpoint leaves no seed row behind (deterministic F-2 kill)" do
      g = "l4-group-#{System.unique_integer([:positive])}"
      p = part("l4-conflict-seed")

      # Expect mismatch against an absent row: must conflict AND must not
      # materialize the zero-checkpoint row (the pre-fix caller-side seed
      # inserted it before the server even compared).
      assert {:error, :conflict} =
               EventHubs.compare_and_swap(
                 g,
                 p,
                 %{"seq" => 5, "offset" => 5, "etag" => 5},
                 %{"seq" => 6, "offset" => 6, "etog" => 6}
               )

      assert :ets.lookup(:smalt_eh_checkpoints, {g, p}) == []
    end

    test "16 concurrent first-touch CAS on the same fresh key yield exactly one :ok" do
      g = "l4-group-#{System.unique_integer([:positive])}"
      p = part("l4-first-touch")

      results =
        1..16
        |> Enum.map(fn _ ->
          Task.async(fn ->
            EventHubs.compare_and_swap(
              g,
              p,
              %{"seq" => 0, "offset" => 0, "etag" => 0},
              %{"seq" => 1, "offset" => 1, "etag" => 1}
            )
          end)
        end)
        |> Task.await_many(15_000)

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :conflict})) == 15
    end
  end

  describe "lens-4 bump_sequence mirror-row consistency" do
    test "after 16x25 parallel sends the mirror row seq equals the atomic counter exactly" do
      p = part("l4-mirror")
      # The `{"seq" => n}` mirror write in bump_sequence is a caller-side
      # read-modify-write riding after the atomic update_counter; it is safe
      # only because every caller sits inside the serialized EH server. This
      # court pins the invariant so any new direct caller breaks the suite
      # instead of silently racing.
      1..16
      |> Enum.map(fn _ ->
        Task.async(fn -> for _ <- 1..25, do: EventHubs.send_event(p, "m") end)
      end)
      |> Task.await_many(15_000)

      [{_k, counter}] = :ets.lookup(:smalt_eh_partitions, {:seq_counter, p})
      [{_k, row}] = :ets.lookup(:smalt_eh_partitions, p)
      assert row["seq"] == counter
      assert counter == 400
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-5 F-3: `sweep/0` used to be a caller-side read-modify-write over the
  # checkpoint table (tab2list -> :ets.update_element writing the WHOLE value
  # back from the stale read) — a live claim written by `reserve_processing`
  # through the serialized server between the read and the write was clobbered
  # (claim silently dropped, two consumers hold one partition). Repair: the
  # sweep runs as ONE serialized handle_call on the same server as
  # reserve/cas_claim_blind.
  # ---------------------------------------------------------------------------
  describe "lens-5 sweep serialization (F-3)" do
    test "sweep clears only expired claims and never touches live ones" do
      g1 = "l5-sweep-live-#{System.unique_integer([:positive])}"
      g2 = "l5-sweep-exp-#{System.unique_integer([:positive])}"
      p1 = part("l5-sweep-a")
      p2 = part("l5-sweep-b")

      assert :ok = EventHubs.reserve_processing(g1, p1, :live, 60_000)
      assert :ok = EventHubs.reserve_processing(g2, p2, :expired, 1)
      Process.sleep(10)

      cleared = EventHubs.sweep()
      assert is_integer(cleared) and cleared >= 1

      # Live claim untouched by the same sweep.
      assert {:error, :conflict} = EventHubs.reserve_processing(g1, p1, :intruder, 60_000)
      # Expired claim reclaimed.
      assert :ok = EventHubs.reserve_processing(g2, p2, :new_owner, 60_000)
    end

    # Deterministic F-3 kill: with the repair, the sweep performs NO
    # checkpoint write on the caller — every write (insert OR update_element)
    # executes only inside the serialized server. Black-box proof by
    # call-tracing the sweeping process. Lens-6 hardening: the lens-5 court
    # traced only `:ets.update_element/3` and was evaded by a fresh mutant
    # shape that wrote the whole value back with `:ets.insert/2` (M-A below
    # survived it 19/0) — the ban is now on any checkpoint-table write from
    # the sweeping caller.
    test "sweep performs checkpoint writes only on the server, never the caller (F-3 shape)" do
      g = "l6-shape-#{System.unique_integer([:positive])}"
      p = part("l6-shape")

      assert :ok = EventHubs.reserve_processing(g, p, :live, 60_000)

      # An expired claim must be present so the sweep actually has a write to
      # perform — with only live claims, both shapes perform zero writes and
      # the trace proves nothing (the lens-5 court's other blind spot).
      gx = "l6-shape-exp-#{System.unique_integer([:positive])}"
      px = part("l6-shape-x")
      assert :ok = EventHubs.reserve_processing(gx, px, :expired, 15)
      Process.sleep(60)

      parent = self()

      caller =
        spawn(fn ->
          # Handshake start: tracing is installed before the sweep runs, so
          # the caller can never finish (and exit) before being traced.
          receive do :go -> :ok end

          EventHubs.sweep()
        end)

      :erlang.trace(caller, true, [:call, {:tracer, parent}])

      # The FULL :ets write surface (lens-7): the lens-6 court traced only
      # insert/2 + update_element/3 and was evaded by a delete-shaped
      # caller-side reclaim (M-C survived 19/0; kill witnessed after this
      # hardening). Lens-8 typed audit: the lens-7 list was still short by
      # the delete-family ops — delete_object/2, match_delete/2,
      # select_delete/2 and table-level delete/1 are all caller-reachable
      # data mutations on the :public tables and were NOT traced (M-D
      # delete_object-shaped compaction mutant survived 19/0; kill
      # witnessed after this hardening). Any write op from the sweeping
      # caller fails the court.
      write_ops = [
        {:ets, :insert, 2},
        {:ets, :insert_new, 2},
        {:ets, :update_element, 3},
        {:ets, :update_counter, 3},
        {:ets, :update_counter, 4},
        {:ets, :delete, 2},
        {:ets, :delete_all_objects, 1},
        {:ets, :delete_object, 2},
        {:ets, :match_delete, 2},
        {:ets, :select_delete, 2},
        {:ets, :delete, 1}
      ]

      Enum.each(write_ops, fn mfa -> :erlang.trace_pattern(mfa, [], [:local]) end)
      send(caller, :go)

      ref = Process.monitor(caller)
      assert_receive {:DOWN, ^ref, :process, ^caller, _}, 5_000

      traced = MapSet.new(write_ops)

      caller_writes =
        Enum.count(drain_trace([]), fn
          {:trace, ^caller, :call, {mod, fun, args}} -> MapSet.member?(traced, {mod, fun, length(args)})
          _ -> false
        end)

      # Reset the local trace pattern so it cannot slow the rest of the run.
      Enum.each(write_ops, fn mfa -> :erlang.trace_pattern(mfa, false, [:local]) end)
      assert caller_writes == 0

      # The expired claim WAS cleared (by the server, never the caller) and
      # the live claim is still intact after the sweep.
      assert :ok = EventHubs.reserve_processing(gx, px, :fresh_owner, 60_000)
      assert {:error, :conflict} = EventHubs.reserve_processing(g, p, :intruder, 60_000)
    end

    test "a live lease is never lost under a concurrent sweep + reserve hammer" do
      g = "l5-sweep-hammer-#{System.unique_integer([:positive])}"
      p = part("l5-sweep-hammer")

      assert :ok = EventHubs.reserve_processing(g, p, :holder, 60_000)

      sweeps =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn ->
            for _ <- 1..100, do: EventHubs.sweep()
            :ok
          end)
        end)

      intruders =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn ->
            for _ <- 1..100 do
              # Every intruder reserve must be refused the whole time the
              # holder's lease is live — a stale-write clobber would let one
              # through.
              assert {:error, :conflict} =
                       EventHubs.reserve_processing(g, p, {:intruder, self()}, 60_000)
            end

            :ok
          end)
        end)

      Task.await_many(sweeps ++ intruders, 30_000)

      assert {:error, :conflict} = EventHubs.reserve_processing(g, p, :final_intruder, 60_000)
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-5 F-4: concurrent first-use of `ensure_tables/0` — two tasks could
  # both see `:undefined` and race the `:ets.new` (ArgumentError crash, the
  # EventStream lens-2 cycle-1 class). The loser of the create race now
  # rescues ArgumentError.
  # ---------------------------------------------------------------------------
  describe "lens-5 concurrent first-use (F-4)" do
    test "32 concurrent ensure_tables after table deletion all survive" do
      # Any process may delete a named public table; recreate through the
      # public seam and race 32 first-users on the pristine name.
      :ets.delete(:smalt_eh_partitions)
      :ets.delete(:smalt_eh_checkpoints)

      results =
        1..32
        |> Enum.map(fn _ ->
          Task.async(fn ->
            EventHubs.ensure_tables()
            EventHubs.next_sequence("ns/l5-f4/#{System.unique_integer([:positive])}")
          end)
        end)
        |> Task.await_many(15_000)

      assert Enum.all?(results, &match?({:ok, 1}, &1))
      assert :ets.info(:smalt_eh_partitions) != :undefined
      assert :ets.info(:smalt_eh_checkpoints) != :undefined
    end
  end

  # ---------------------------------------------------------------------------
  # V261014-04 F1: wire-level EH receiver delivery. `deliver_eventhubs/2` in
  # Connection used to match `{:ok, events}` against `receive_events/3`'s bare
  # list return — a shape that can never match — so no event was ever delivered
  # on a real receiver link while the in-process c7 test stayed green. This
  # court drives a real AMQP receiver link on an "/eventhubs/" entity path:
  # sender link sends events, receiver drain yields them in sequence order with
  # the `x-opt-sequence-number` annotation. RED against the unfixed :1077
  # match, GREEN after (falsifier witnessed in the lane receipt).
  # ---------------------------------------------------------------------------
  describe "V261014-04 F1 wire-level receiver delivery" do
    @tag :amqp_wire
    test "receiver link on /eventhubs/ path receives sent events in sequence order with x-opt-sequence-number" do
      Application.put_env(:smalt, :sb_shared_key, "test-shared-key-0123456789abcdef012345")

      if GenServer.whereis(Smalt.Store) == nil do
        start_supervised!(Smalt.Store)
      end

      EventHubs.ensure_tables()

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listener)

      accept_task =
        Task.async(fn ->
          {:ok, sock} = :gen_tcp.accept(listener, 5000)
          {:ok, pid} = Smalt.Amqp.Connection.start_link(socket: sock)
          :ok = :gen_tcp.controlling_process(sock, pid)
          {:ok, pid}
        end)

      {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)
      {:ok, _conn} = Task.await(accept_task, 5000)

      partition = "0"
      eh_address = "/eventhubs/wire-hub-" <> "#{System.unique_integer([:positive])}" <> "/partitions/" <> partition

      try do
        wh(client)

        # sender link (client role :sender) on the EH entity path
        :ok = send_b(client, enc(:amqp, 0, {:attach, %{name: "eh-s", handle: 0, role: false, target: %{address: eh_address}}}))
        assert %{performative: %{performative: :attach}} = recv_f(client)

        # send 3 events over the wire (each a bare-body_data transfer)
        for i <- 1..3 do
          :ok =
            send_b(
              client,
              enc(:amqp, 0, {:transfer, %{handle: 0, delivery_id: i, delivery_tag: <<i::8>>, message_format: 0, settled: true, more: false}, {:sections, [{:body_data, "eh-event-#{i}"}]}})
            )

          # server settles accepted
          disp = recv_until(client, :disposition)
          assert %{performative: %{settled: true, state: :accepted}} = disp
        end

        # receiver link (client role :receiver) on the same partition
        :ok = send_b(client, enc(:amqp, 0, {:attach, %{name: "eh-r", handle: 1, role: true, source: %{address: eh_address}}}))
        assert %{performative: %{performative: :attach}} = recv_f(client)

        # grant credit -> drain
        :ok = send_b(client, enc(:amqp, 0, {:flow, %{handle: 1, link_credit: 10}}))

        transfers =
          for _i <- 1..3 do
            tr = recv_until(client, :transfer, 3000)
            assert %{performative: %{performative: :transfer}} = tr
            tr
          end

        seqs =
          Enum.map(transfers, fn tr ->
            assert %{payload: payload} = tr
            assert {:ok, sections} = Smalt.Amqp.FrameCodec.decode_message(payload)

            annotations =
              Enum.find_value(sections, fn
                {:message_annotations, %{"x-opt-sequence-number" => seq}} -> seq
                _ -> nil
              end)

            assert is_integer(annotations)
            annotations
          end)

        assert seqs == Enum.sort(seqs)
        assert length(Enum.uniq(seqs)) == 3

        bodies =
          Enum.map(transfers, fn tr ->
            {:ok, sections} = Smalt.Amqp.FrameCodec.decode_message(tr.payload)

            Enum.find_value(sections, fn
              {:body_data, b} -> b
              _ -> nil
            end)
          end)

        # the stored EH event body is the raw encoded section bytes the sender
        # transferred (constructor prefix + payload); drain must preserve it
        # byte-for-byte and in sequence order.
        assert Enum.map(bodies, &String.contains?(&1, "eh-event-")) ==
                 [true, true, true]

        # trailing payload byte is the event ordinal: 1, 2, 3 in seq order
        assert Enum.map(bodies, fn <<_::binary-size(14), d>> -> d - ?0 end) == [1, 2, 3]
      after
        :gen_tcp.close(client)
      end
    end
  end

  # -- wire harness (mirrors test/amqp/connection_test.exs) ---------------------

  defp wh(client) do
    :ok = :gen_tcp.send(client, "AMQP\x03\x01\x00\x00")
    assert {:ok, "AMQP\x03\x01\x00\x00"} = rx(client, 8)
    _mech = recv_f(client)
    :ok = send_b(client, enc(:sasl, 0, {:sasl_init, %{mechanism: "ANONYMOUS"}}))
    _outcome = recv_f(client)
    :ok = :gen_tcp.send(client, "AMQP\x00\x01\x00\x00")
    assert {:ok, "AMQP\x00\x01\x00\x00"} = rx(client, 8)

    :ok =
      send_b(client, enc(:amqp, 0, {:open, %{container_id: "eh-test-client", max_frame_size: 65_536, channel_max: 65_535}}))

    _opened = recv_f(client)

    :ok =
      send_b(client, enc(:amqp, 0, {:begin, %{next_outgoing_id: 1, incoming_window: 10_000, outgoing_window: 10_000, handle_max: 100}}))

    _begun = recv_f(client)
    :ok
  end

  defp enc(layer, channel, performative), do: Smalt.Amqp.FrameCodec.encode_frame(layer, channel, performative)
  defp send_b(client, iodata), do: :gen_tcp.send(client, iodata)

  defp recv_until(client, name, timeout \\ 2000) do
    frame = recv_f(client, timeout)

    if frame.performative.performative == name,
      do: frame,
      else: recv_until(client, name, timeout)
  end

  defp recv_f(client, timeout \\ 2000) do
    {:ok, hdr} = rx(client, 8, timeout)
    <<size::unsigned-integer-size(32), _doff, _type, _ch::16>> = hdr
    body = elem(rx(client, size - 8, timeout), 1)

    case Smalt.Amqp.FrameCodec.decode_frame(hdr <> body) do
      {:ok, frame} -> frame
      other -> flunk("frame decode failed: #{inspect(other)}")
    end
  end

  defp rx(client, n, timeout \\ 2000)

  defp rx(_client, 0, _timeout), do: {:ok, <<>>}

  defp rx(client, n, timeout) do
    case :gen_tcp.recv(client, n, timeout) do
      {:ok, data} -> {:ok, data}
      {:error, :closed} -> {:ok, <<>>}
    end
  end

  defp drain_trace(acc) do
    receive do
      {:trace, _, _, _} = ev -> drain_trace([ev | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp get_checkpoint(g, p) do
    case :ets.lookup(:smalt_eh_checkpoints, {g, p}) do
      [{_k, cp}] -> Map.delete(cp, "claim")
      [] -> nil
    end
  end
end
