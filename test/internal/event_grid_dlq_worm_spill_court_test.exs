defmodule Smalt.EventGridDlqWormSpillCourtTest do
  @moduledoc """
  BK-DLQ3 court: write_dlq_blob / spill_to_dlq handle put_blob's 3-tuple
  errors ({:error, :worm_locked | :precondition_failed | :too_large, msg},
  blob_storage.ex) — the unhandled reachable shape BK-EGDT typed as its
  successor order (receipt bkegdt-deletion.md). Pre-fix, a 3-tuple hit a
  CaseClauseError inside the EventGrid GenServer at DLQ-spill time.

  Chicago: real EventGrid GenServer, real BlobStorage WORM machinery (a
  container legal hold via the real set_legal_hold — the create arm's only
  create-blocking policy, blob_storage.ex R5), real Store-backed spill. No
  mocks. Falsifier legs:

    1. WORM-locked DLQ: real spill runs, NO crash, the typed failure is
       logged, the event stays inflight (never loss), and re-subscribing a
       live pid recovers it.
    2. Control (no WORM): the same spill succeeds — {:dead_lettered, _} face,
       inflight cleared, dlq_seq advanced, telemetry emitted — proving the
       new clause did not swallow the success arm.
    3. Direct witness: put_blob on the held container answers the exact
       3-tuple (non-vacuity: the shape the new clause admits is the shape
       the real face produces).
  """

  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Smalt.DataPlane.BlobStorage
  alias Smalt.Messaging.EventGrid

  Code.require_file("poll_helper.exs", __DIR__)

  @sub :dlqworm

  setup do
    prev = Application.get_env(:smalt, :event_grid)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:smalt, :event_grid)
        prev -> Application.put_env(:smalt, :event_grid, prev)
      end
    end)

    :ok
  end

  defp fresh_topic do
    topic = :"eg-dlq3-topic-#{System.unique_integer([:positive])}"
    EventGrid.reset(topic)
    topic
  end

  def never_acking_subscriber do
    receive do
      _ -> never_acking_subscriber()
    end
  end

  # Telemetry handler (MFA — remote capture, no anonymous-fn penalty): bumps
  # the dead_lettered counter. Measurements: %{attempts: n}; the count itself
  # is 1 per spill.
  def count_dead_lettered(_name, %{attempts: _}, _meta, tbl) do
    :ets.update_counter(tbl, :dead_lettered, 1)
  end

  # Real BlobStorage fixture: creates (and optionally WORM-holds) the
  # container the spill will actually target — dlq_container_name/2 appends
  # "-#{subscriber_name}" to cfg.container, so with @sub == :dlqworm the
  # spill writes "egdlq<uniq>-dlqworm" while cfg.container is the base.
  # Legal hold = the create arm's only create-blocking policy (blob_storage R5).
  defp make_container(uniq, hold?) do
    account = "egdlq#{uniq}"
    base = "egdlq#{uniq}"
    target = "#{base}-dlqworm"
    {:ok, _} = BlobStorage.create_container(account, target)

    if hold? do
      assert hold_ok?(account, target), "set_legal_hold refused the fixture container"
    end

    {account, base}
  end

  defp hold_ok?(account, container) do
    case BlobStorage.set_legal_hold(account, container, true) do
      {:ok, 200, _headers, _body} -> true
      other -> flunk("set_legal_hold refused: #{inspect(other)}")
    end
  end

  test "leg 1: WORM-held DLQ container — spill runs without CaseClauseError, event retained" do
    topic = fresh_topic()
    uniq = System.unique_integer([:positive])
    {account, container} = make_container(uniq, true)
    set_dlq_env_with(2, account, container)

    # Leg 3 (direct witness): the real face answers the exact 3-tuple the new
    # clause admits.
    probe = BlobStorage.put_blob(account, "#{container}-dlqworm", "0-probe.json", "{}")

    assert {:error, :worm_locked, _msg} = probe,
           "put_blob on a hold-bearing container must answer {:error, :worm_locked, msg}, " <>
             "got: #{inspect(probe)}"

    # Real spill over the held container through the DOWN timer.
    {{_pending, {_id, :inflight, attempts}, false}, log} = spill_with_log(topic, 2)

    assert attempts >= 2

    assert Process.alive?(EventGrid.server()),
           "EventGrid GenServer crashed on the 3-tuple (CaseClauseError)"

    assert log =~ "DLQ write failed",
           "expected the typed DLQ-failure log, got: #{inspect(log)}"

    assert log =~ ":worm_locked"

    # Re-subscribing a live pid recovers the retained event: never loss.
    me = self()
    :ok = EventGrid.subscribe(topic, @sub, me)

    assert_receive {:event_grid, _t, _n, "probe-e-1", _envelope, _sys}, 5_000
  end

  test "leg 2: control (no WORM) — the same spill succeeds, dead-lettered face unchanged" do
    topic = fresh_topic()
    uniq = System.unique_integer([:positive])
    {account, container} = make_container(uniq, false)
    set_dlq_env_with(2, account, container)

    counter = :"eg_dlq3_ctr_#{uniq}"
    :ets.new(counter, [:public, :named_table, :set])
    :ets.insert(counter, [{:dead_lettered, 0}])

    handler = :"eg_dlq3_h_#{uniq}"

    :ok =
      :telemetry.attach(
        handler,
        [:smalt, :event_grid, :dead_lettered],
        &__MODULE__.count_dead_lettered/4,
        counter
      )

    on_exit(fn ->
      :telemetry.detach(handler)

      if :ets.whereis(counter) != :undefined, do: :ets.delete(counter)
    end)

    {{0, nil, _alive}, log} = spill_with_log(topic, 2)

    assert :ets.lookup_element(counter, :dead_lettered, 2) == 1
    refute log =~ "DLQ write failed"
  end

  # Arms a dead subscriber with one inflight event (real publish + real DOWN,
  # per-subscription retry_policy capping the budget at max_attempts), then
  # captures the log while the real DLQ timer drives the state to convergence:
  #   leg 1 (WORM-held): retained shape — the exhausted event stays inflight
  #     AT the cap (the retained spill loop keeps attempts pinned at max);
  #   leg 2 (no WORM): spilled shape — inflight cleared, queue drained.
  defp spill_with_log(topic, max_attempts) do
    subscriber = spawn(__MODULE__, :never_acking_subscriber, [])

    :ok =
      EventGrid.subscribe(topic, @sub, subscriber,
        retry_policy: {max_attempts, 3_600}
      )

    assert EventGrid.publish(topic, %{id: "probe-e-1"}) == :fresh
    # Subscriber death -> real DOWN -> mark_down keeps inflight, timer re-arms.
    Process.exit(subscriber, :kill)

    me = self()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, status} =
          SmaltTest.Internal.Poll.eventually(fn ->
            case EventGrid.status(topic, @sub) do
              # Retained shape (leg 1): attempts pinned AT the cap with the
              # event still inflight — reachable ONLY through the failed-spill
              # retained loop (a pre-spill tick has attempts < max, a spilled
              # event has inflight == nil).
              {p, {id, _ev, _ts, att}, false} when att >= max_attempts ->
                {:ok, {p, {id, :inflight, att}, false}}

              # Spilled shape (leg 2): inflight cleared, queue drained.
              {0, nil, _alive} = done ->
                {:ok, done}

              _other ->
                :error
            end
          end)

        send(me, {:dlq3_status, status})
      end)

    assert_receive {:dlq3_status, status}, 5_000
    {status, log}
  end

  defp set_dlq_env_with(max_attempts, account, container) do
    Application.put_env(:smalt, :event_grid,
      dlq: [
        enabled: true,
        account: account,
        container: container,
        max_delivery_attempts: max_attempts,
        retry_backoff_ms: 5
      ]
    )
  end
end
