# T-08 court (integration tier): Service Bus native DLQ, scheduled messages,
# message deferral.
#
# Chicago discipline: real Store ensemble, real QueueStore GenServer (its
# serialized claim/settle server), real SbRules fan-out. No mocks, no sleeps.
#
# Time-fenced per the event_hubs injected-clock pattern: every visibility
# assertion rides injected `now_ms` / `:scheduled_enqueue_time` values —
# "invisible before" is `now_ms: due - 1`, "receivable on time" is
# `now_ms: due`. Zero process sleeps.
#
# First executed 2026-10-29 (L8 finishing lane, v26.10.29): 6/6 green after
# fixing the SbRules→SbDelivery DLQ-name seam (double $deadletterqueue suffix)
# and amending the over-pinned dlq_seq != seq assertion (per-entity counters
# legitimately collide at 1 on fresh queues — real-Azure semantics).

defmodule Smalt.Integration.SbDeliveryTest do
  use ExUnit.Case, async: false

  alias Smalt.Amqp.QueueStore
  alias Smalt.Messaging.SbDelivery
  alias Smalt.SbRules
  alias Smalt.Store

  @queue "t08q"
  @topic "t08t"
  @sub "t08s"
  # Storage spelling of the subscription address (QueueStore entity row).
  @sub_queue "#{@topic}/Subscriptions/#{@sub}"
  # sb_rules fan_out/4's own target spelling (lowercase segment).
  @fanout_queue "#{@topic}/subscriptions/#{@sub}"

  @t0 1_700_000_000_000
  @due @t0 + 60_000

  @sub_base "/subscriptions/sub-t08/resourcegroups/rg-t08"
  @ns "ns-t08"

  setup do
    ensure_store()
    {:ok, _} = QueueStore.ensure_queue(@queue)

    on_exit(fn -> cleanup() end)

    :ok
  end

  # -- DLQ round-trip (queue): reason + original props intact on the subqueue --

  test "dead-letter moves a queue message to <queue>/$deadletterqueue with reason and props intact" do
    {:ok, seq} =
      QueueStore.enqueue(@queue, "poison-1",
        message_id: "mid-1",
        app_props: %{"corr" => "abc"},
        now_ms: @t0
      )

    assert {:ok, m, lock} = QueueStore.dequeue_matching(@queue, now_ms: @t0)
    assert m.seq == seq

    assert {:ok, dlq_seq} =
             SbDelivery.dead_letter(@queue, m.seq, "poison", "bad payload",
               lock_token: lock.lock_token
             )

    # Moved, not copied: the source queue holds nothing.
    assert {:ok, []} = QueueStore.peek(@queue)
    # The DLQ copy carries a fresh sequence in the DLQ's OWN counter space (SB
    # parity: per-entity counters — the DLQ's first copy is seq 1 even when the
    # source row's seq numerically collides; L8 amended the earlier `!=` pin,
    # which real-Azure semantics refute). Identity is pinned on the row itself:
    # the DLQ row's sequence_number/1 must equal the dead_letter return.
    assert is_integer(dlq_seq)

    dlq = SbDelivery.dlq_name(@queue)
    assert dlq == "#{@queue}/$deadletterqueue"

    assert {:ok, [dlq_msg]} = QueueStore.peek(dlq)
    assert dlq_msg.body == "poison-1"
    assert dlq_msg.message_id == "mid-1"
    # SDK parity: reason/description ride APPLICATION PROPERTIES; originals intact.
    assert dlq_msg.app_props["DeadLetterReason"] == "poison"
    assert dlq_msg.app_props["DeadLetterErrorDescription"] == "bad payload"
    assert dlq_msg.app_props["corr"] == "abc"
    # Mirrored on annotations too.
    assert dlq_msg.annotations["DeadLetterReason"] == "poison"
    # Sequence numbers surface on the received row.
    assert SbDelivery.sequence_number(dlq_msg) == dlq_seq

    # The subqueue is a real AMQP-receivable entity: a receiver on the
    # DLQ address claims the copy through the normal receive path.
    assert {:ok, dlq_m, dlq_lock} = QueueStore.dequeue_matching(dlq, now_ms: @t0 + 1)
    assert dlq_m.body == "poison-1"

    assert :ok =
             QueueStore.complete(dlq, dlq_m.seq, lock_token: dlq_lock.lock_token, now_ms: @t0 + 1)
  end

  # -- DLQ round-trip (subscription): <topic>/Subscriptions/<sub>/... ------------

  test "dead-letter moves a subscription message to its subscription DLQ subqueue" do
    assert SbDelivery.subscription_dlq_name(@topic, @sub) == SbDelivery.dlq_name(@sub_queue)
    assert SbDelivery.subscription_dlq_name(@topic, @sub) ==
             "#{@topic}/Subscriptions/#{@sub}/$deadletterqueue"

    {:ok, _} = QueueStore.ensure_queue(@sub_queue)

    {:ok, seq} = QueueStore.enqueue(@sub_queue, "sub-poison", app_props: %{"k" => "v"}, now_ms: @t0)

    assert {:ok, m, lock} = QueueStore.dequeue_matching(@sub_queue, now_ms: @t0)
    assert m.seq == seq

    assert {:ok, _dlq_seq} =
             SbDelivery.dead_letter(@sub_queue, m.seq, "poison", nil, lock_token: lock.lock_token)

    assert {:ok, [dlq_msg]} = QueueStore.peek(SbDelivery.dlq_name(@sub_queue))
    assert dlq_msg.body == "sub-poison"
    assert dlq_msg.app_props["DeadLetterReason"] == "poison"
    assert dlq_msg.app_props["k"] == "v"
    assert {:ok, []} = QueueStore.peek(@sub_queue)
  end

  # -- Scheduled: invisible-before / receivable-after, injected timestamps -------

  test "scheduled message is invisible before its timestamp and receivable exactly on time" do
    {:ok, seq} =
      QueueStore.enqueue(@queue, "later", scheduled_enqueue_time: @due, now_ms: @t0)

    {:ok, [row]} = QueueStore.peek(@queue)
    # Record extension: the scheduled-enqueue timestamp surfaces on the row.
    assert SbDelivery.scheduled_enqueue_at(row) == @due
    # Visibility gate: fenced at the timestamp.
    refute SbDelivery.visible?(row, @due - 1)
    assert SbDelivery.visible?(row, @due)

    # The receive path honors the same gate: nothing before the timestamp.
    assert :empty = QueueStore.dequeue_matching(@queue, now_ms: @due - 1)
    # Receivable exactly on time, sequence number surfaced.
    assert {:ok, m, lock} = QueueStore.dequeue_matching(@queue, now_ms: @due)
    assert m.seq == seq
    assert SbDelivery.sequence_number(m) == seq

    assert :ok = QueueStore.complete(@queue, m.seq, lock_token: lock.lock_token, now_ms: @due)
  end

  # -- Schedule cancel ------------------------------------------------------------

  test "schedule_cancel kills a scheduled message by sequence number before it fires" do
    {:ok, seq} =
      QueueStore.enqueue(@queue, "cancelled", scheduled_enqueue_time: @due, now_ms: @t0)

    assert :ok = SbDelivery.schedule_cancel(@queue, seq)
    # Never fires: the receive path at/after the timestamp sees nothing.
    assert :empty = QueueStore.dequeue_matching(@queue, now_ms: @due + 1)
    assert {:ok, []} = QueueStore.peek(@queue)

    # Typed refusals: a live (non-scheduled) row is not cancellable...
    {:ok, live_seq} = QueueStore.enqueue(@queue, "live", now_ms: @t0)
    assert {:error, :not_scheduled} = SbDelivery.schedule_cancel(@queue, live_seq)
    # ...and neither is an absent one.
    assert {:error, :not_found} = SbDelivery.schedule_cancel(@queue, 99_999)
  end

  # -- Deferral round-trip ----------------------------------------------------------

  test "defer hides the message from normal receive; receive_deferred resurfaces it by sequence" do
    {:ok, _} = QueueStore.enqueue(@queue, "hold-me", now_ms: @t0)

    assert {:ok, m1, lock1} = QueueStore.dequeue_matching(@queue, now_ms: @t0)
    # The defer settlement (AMQP modified disposition, undeliverable-here);
    # defer/3 releases the settlement lock internally.
    assert is_binary(lock1.lock_token)
    assert :ok = QueueStore.defer(@queue, m1.seq, [])

    # Record extension: the deferral flag surfaces on the row; visibility gate closes.
    {:ok, [row]} = QueueStore.peek(@queue)
    assert SbDelivery.deferred?(row)
    refute SbDelivery.visible?(row, @t0)
    # The normal receive path never surfaces a deferred row again.
    assert :empty = QueueStore.dequeue_matching(@queue, now_ms: @t0)

    # Sequence-only receive: a non-deferred sequence fails the batch atomically.
    assert {:error, {:not_deferred, _}} = SbDelivery.receive_deferred(@queue, [m1.seq + 500])

    assert {:ok, [m2]} = SbDelivery.receive_deferred(@queue, [m1.seq], now_ms: @t0)
    assert m2.seq == m1.seq
    assert SbDelivery.sequence_number(m2) == m1.seq
    assert m2.body == "hold-me"

    # Settle the deferred delivery; the sequence is spent afterwards.
    assert :ok = QueueStore.complete(@queue, m2.seq, lock_token: m2.lock_token, now_ms: @t0)
    assert {:error, {:not_deferred, _}} = SbDelivery.receive_deferred(@queue, [m1.seq], now_ms: @t0)
  end

  # -- Filter no-match: default (no DLQ) + config-keyed DLQ ------------------------

  test "filter no-match skips by default; config :sb_dlq_on_filter_no_match dead-letters the copy" do
    seed_rules("color = 'red'")

    sub_dlq = SbDelivery.subscription_dlq_name(@topic, @sub)

    prev = Application.get_env(:smalt, :sb_dlq_on_filter_no_match, :absent)

    on_exit(fn ->
      case prev do
        :absent -> Application.delete_env(:smalt, :sb_dlq_on_filter_no_match)
        v -> Application.put_env(:smalt, :sb_dlq_on_filter_no_match, v)
      end
    end)

    match_msg = %{body: "match-1", message_id: "mid-red", app_props: %{"color" => "red"}}
    no_match_msg = %{body: "nm-1", message_id: "mid-blue", app_props: %{"color" => "blue"}}

    # DEFAULT (real-Azure face): no-match copy is skipped — nothing in the
    # subscription queue, nothing in the DLQ.
    Application.delete_env(:smalt, :sb_dlq_on_filter_no_match)
    assert [] = SbRules.fan_out(@sub_base, @ns, @topic, no_match_msg)
    assert {:ok, []} = QueueStore.peek(sub_dlq)

    # Sanity: the rules path still admits a matching message.
    assert [@sub] = SbRules.fan_out(@sub_base, @ns, @topic, match_msg)
    assert {:ok, [m]} = QueueStore.peek(@fanout_queue)
    assert m.body == "match-1"

    # OPT-IN: the no-match copy is dead-lettered into the subscription's DLQ
    # subqueue with DeadLetterReason + original application properties intact.
    Application.put_env(:smalt, :sb_dlq_on_filter_no_match, true)
    assert [] = SbRules.fan_out(@sub_base, @ns, @topic, no_match_msg)

    assert {:ok, [dlq_msg]} = QueueStore.peek(sub_dlq)
    assert dlq_msg.body == "nm-1"
    assert dlq_msg.message_id == "mid-blue"
    assert dlq_msg.app_props["DeadLetterReason"] == "NoFilterMatch"
    assert dlq_msg.app_props["color"] == "blue"
    # The matching path is unaffected by the opt-in.
    assert [@sub] = SbRules.fan_out(@sub_base, @ns, @topic, match_msg)
  end

  # -- helpers ----------------------------------------------------------------------

  defp ensure_store do
    if :ets.info(:smalt_sb_queues) == :undefined do
      {:ok, _} = GenServer.start_link(Smalt.Store, [])
    end

    :ok
  end

  # Seed the ARM subscription record (:smalt_resources) and one SQL rule
  # (:smalt_sb_rules) under the exact key contract fan_out/4 reads.
  defp seed_rules(sql) do
    sub_key =
      String.downcase("#{@sub_base}/namespaces/#{@ns}/topics/#{@topic}/subscriptions/#{@sub}")

    Store.put(:smalt_resources, sub_key, %{
      "id" => sub_key,
      "name" => @sub,
      "type" => "Microsoft.ServiceBus/namespaces/topics/subscriptions",
      "properties" => %{}
    })

    rule_key = SbRules.rule_key(@sub_base, @ns, @topic, @sub, "t08-color")

    rule_record =
      SbRules.build_rule_record("t08-color", String.downcase("#{sub_key}/rules/t08-color"), %{
        "filterType" => "SqlFilter",
        "sqlExpression" => sql
      })

    :ok = SbRules.put_rule(:smalt_sb_rules, rule_key, rule_record)
    :ok
  end

  defp cleanup do
    sb_prefix_delete(:smalt_sb_queues, "t08")

    if :ets.info(:smalt_sb_messages) != :undefined do
      for {k, _} <- :ets.tab2list(:smalt_sb_messages),
          is_tuple(k) and is_binary(elem(k, 0)) and String.starts_with?(elem(k, 0), "t08") do
        :ets.delete(:smalt_sb_messages, k)
      end
    end

    contains_delete(:smalt_resources, "t08")
    contains_delete(:smalt_sb_rules, "t08")

    :ok
  end

  defp sb_prefix_delete(table, prefix) do
    if :ets.info(table) != :undefined do
      for k <- Store.keys(table), is_binary(k) and String.starts_with?(k, prefix) do
        Store.delete(table, k)
      end
    end

    :ok
  end

  defp contains_delete(table, needle) do
    if :ets.info(table) != :undefined do
      for k <- Store.keys(table), is_binary(k) and String.contains?(k, needle) do
        Store.delete(table, k)
      end
    end

    :ok
  end
end
