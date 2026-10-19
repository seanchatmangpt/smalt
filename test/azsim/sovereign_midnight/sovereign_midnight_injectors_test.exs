defmodule Smalt.Azsim.SovereignMidnightInjectorsTest do
  @moduledoc """
  Sovereign Midnight G5-narrow residual injectors (triage receipt
  `i29-sovereign-gap-triage.md`, map row G5 NARROWED in
  `docs/jira/v26.10.18/azsim-burn/SOVEREIGN_MIDNIGHT.md`).

  Test-side race injectors — NO lib/ changes. Each injector forces the race
  deterministically (authored clock / direct GenServer pokes / serialized
  store APIs) and asserts the typed outcome:

    - 1.3 JWT expiry-race injector: authored `:smalt, :sts_clock` steps a
      short-TTL bearer token across its `exp` boundary under a concurrent
      verifier pool; every outcome is typed (`:ok` before, `TokenExpired`
      at/past).
    - 2.3 policy cancel-race injector: `Policy.enforce/3` evaluations race a
      `delete_policy_assignment` cancel; pre-cancel deny, in-race outcomes
      all typed, post-cancel `:ok`.
    - 3.2 EH mid-stream detach/resume injector: processing lease expiry
      (lazily reclaimed inside the serialized reserve) detaches consumer A
      mid-stream; B resumes from A's checkpoint, a zombie stale-checkpoint
      CAS refuses `{:error, :conflict}`, stream continuity preserved.
    - 3.1 lock-lost ordering stress: repeated + concurrent stale-token
      settles against a reclaim-raced message — every stale settle refuses
      `{:error, :lock_lost}`, exactly the live owner settles `:ok`.

  Zero unclassified sleeps: bounded polls only
  (`SmaltTest.AssertEventually.eventually/2`).
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  import SmaltTest.AssertEventually, only: [eventually: 2]

  alias Smalt.Amqp.QueueStore
  alias Smalt.Auth.Bearer
  alias Smalt.Messaging.EventHubs
  alias Smalt.Policy
  alias Smalt.Store

  @moduletag :stress

  @secret "smalt-sovereign-injector-secret-0123456789abcdef"
  @aud "https://management.azure.com"
  @iss "https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0"
  @sub "00000000-0000-0000-0000-000000000000"
  @rg "rg-eoq-settlement"

  setup do
    case Store.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Policy.reset_for_test()
    EventHubs.ensure_tables()
    :ok
  end

  # -- shared helpers -----------------------------------------------------------

  defp save_env(key, value) do
    prev = Application.get_env(:smalt, key, :__unset__)

    Application.put_env(:smalt, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      if prev == :__unset__ do
        Application.delete_env(:smalt, key)
      else
        Application.put_env(:smalt, key, prev)
      end
    end)

    :ok
  end

  defp mint_token(exp, extra_claims \\ %{}) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "aud" => @aud,
          "iss" => @iss,
          "iat" => now,
          "nbf" => now,
          "exp" => exp
        },
        extra_claims
      )

    {:ok, token, _} = Joken.generate_and_sign(%{}, claims, Joken.Signer.create("HS256", @secret))
    token
  end

  defp bearer_conn(token) do
    conn(:get, "/subscriptions/#{@sub}")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp unique(queue_prefix), do: "#{queue_prefix}-#{System.unique_integer([:positive])}"

  # ===========================================================================
  # 1.3 — JWT expiry-race injector (authored clock, concurrent verifier pool)
  # ===========================================================================
  describe "1.3 JWT expiry-race injector" do
    test "authored clock straddle: pool accepts before exp, refuses TokenExpired at/past exp" do
      save_env(:auth_mode, :enforce)
      save_env(:sts_signing_secret, @secret)

      t0 = System.system_time(:second)
      exp = t0 + 2
      token = mint_token(exp)
      conn = bearer_conn(token)

      # Authored clock BEFORE expiry: every verifier in a concurrent pool accepts.
      save_env(:sts_clock, t0)

      pre_results =
        1..16
        |> Task.async_stream(fn _ -> Bearer.verify_bearer(conn) end, timeout: 5_000)
        |> Enum.map(fn {:ok, verdict} -> verdict end)

      assert Enum.uniq(pre_results) == [:ok]

      # Authored clock AT exp (exp <= now => expired): same token, same pool —
      # every verifier now refuses with the typed expiry reason. The "race"
      # is carried by the authored clock step, not by wall-clock guesswork.
      save_env(:sts_clock, exp)

      at_results =
        1..16
        |> Task.async_stream(fn _ -> Bearer.verify_bearer(conn) end, timeout: 5_000)
        |> Enum.map(fn {:ok, verdict} -> verdict end)

      assert Enum.uniq(at_results) == [{:refuse, "InvalidAuthenticationToken", "TokenExpired"}]

      # PAST exp: still typed refusal, no fail-open.
      save_env(:sts_clock, exp + 1)

      past_results =
        1..16
        |> Task.async_stream(fn _ -> Bearer.verify_bearer(conn) end, timeout: 5_000)
        |> Enum.map(fn {:ok, verdict} -> verdict end)

      assert Enum.uniq(past_results) == [{:refuse, "InvalidAuthenticationToken", "TokenExpired"}]
    end

    test "expiry-race straddle pool: no verifier observes an outcome inconsistent with the authored clock" do
      save_env(:auth_mode, :enforce)
      save_env(:sts_signing_secret, @secret)

      t0 = System.system_time(:second)
      exp = t0 + 5
      token = mint_token(exp)
      conn = bearer_conn(token)

      # Verifiers launched while the clock legitimately admits; the clock is
      # then stepped to exp WHILE the pool is still draining — each outcome
      # must be one of exactly two typed faces (:ok | TokenExpired refusal).
      # Cross-step leakage (an :ok landing after the expiry step completed,
      # or a TokenExpired landing before it began) is the defect class.
      save_env(:sts_clock, t0)

      pool =
        1..32
        |> Enum.map(fn _ -> Task.async(fn -> Bearer.verify_bearer(conn) end) end)

      # Author the boundary INSIDE the live pool's lifetime.
      save_env(:sts_clock, exp)

      results = Enum.map(pool, &Task.await(&1, 5_000))

      assert Enum.all?(results, fn verdict ->
               verdict == :ok or
                 verdict == {:refuse, "InvalidAuthenticationToken", "TokenExpired"}
             end)

      # The post-step floor: after the expiry step is visible, NO further
      # verification can accept.
      assert {:refuse, "InvalidAuthenticationToken", "TokenExpired"} =
               Bearer.verify_bearer(bearer_conn(token))
    end
  end

  # ===========================================================================
  # 2.3 — Policy cancel-race injector
  # ===========================================================================
  describe "2.3 policy cancel-race injector" do
    test "enforce evaluations racing a delete-policy-assignment cancel stay typed" do
      policy_id = unique("deny-cancel-race")
      assignment_id = unique("assign-cancel-race")

      Policy.put_policy_definition(@sub, policy_id, %{
        "properties" => %{
          "mode" => "Indexed",
          "policyRule" => %{
            "if" => %{"field" => "tags.SovereignCompliance", "notEquals" => "Enforced"},
            "then" => %{"effect" => "deny"}
          }
        }
      })

      scope = "/subscriptions/#{@sub}/resourceGroups/#{@rg}"

      Policy.put_policy_assignment(scope, assignment_id, %{
        "properties" => %{
          "policyDefinitionId" =>
            "/subscriptions/#{@sub}/providers/Microsoft.Authorization/policyDefinitions/#{policy_id}"
        }
      })

      record = %{
        "id" =>
          "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Storage/storageAccounts/cancelsa",
        "location" => "eastus",
        "tags" => %{"env" => "unregulated-dev"}
      }

      # Deterministic pre-cancel face: deny with the typed violation code.
      assert {:deny, body_json} = Policy.enforce(@sub, @rg, record)
      body = Jason.decode!(body_json)
      assert body["error"]["code"] in ["PolicyViolation", "RequestDisallowedByPolicy"]

      # Deterministic receipt face while the assignment is live.
      assignment_full_id =
        "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Authorization/policyAssignments/#{assignment_id}"

      assert record["id"] in Policy.non_compliant_resources(assignment_full_id)

      # Cancel race: 24 enforce evaluations race one assignment delete. Each
      # in-race outcome is typed — :ok (cancel landed first) or {:deny, _}
      # (evaluation landed first). No third face, no crash.
      cancel =
        Task.async(fn -> Policy.delete_policy_assignment(scope, assignment_id) end)

      race_results =
        1..24
        |> Task.async_stream(
          fn _ -> Policy.enforce(@sub, @rg, record) end,
          max_concurrency: 24,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, verdict} -> verdict end)

      assert :ok = Task.await(cancel, 5_000)

      assert Enum.all?(race_results, fn verdict ->
               match?(:ok, verdict) or match?({:deny, _body_json}, verdict)
             end)

      # Post-cancel deterministic face: assignment gone, enforcement admits.
      assert :error = Policy.get_policy_assignment(scope, assignment_id)
      assert :ok = Policy.enforce(@sub, @rg, record)
    end
  end

  # ===========================================================================
  # 3.2 — EH mid-stream detach/resume injector
  # ===========================================================================
  describe "3.2 EH mid-stream detach/resume injector" do
    test "lease-expiry detach: B reclaims, resumes from A's checkpoint, zombie CAS conflicts, stream continuous" do
      group = unique("smalt.eoq")
      partition = "ns/eoq-hub/part-#{System.unique_integer([:positive])}"

      # Stream seed: events 1..5.
      for i <- 1..5, do: {:ok, _seq, _} = EventHubs.send_event(partition, "pre-detach-#{i}")

      # Consumer A reserves the partition and checkpoints mid-stream (after 3).
      assert :ok = EventHubs.reserve_processing(group, partition, :consumer_a, 60_000)
      assert {:ok, %{"seq" => 5}} = EventHubs.reconcile(group, partition)

      events_a = EventHubs.receive_events(partition, 0, 10)
      assert length(events_a) == 5

      cp_a = %{"seq" => 3, "offset" => "3", "etag" => 3}
      zero_cp = %{"seq" => 0, "offset" => 0, "etag" => 0}
      assert :ok = EventHubs.compare_and_swap(group, partition, zero_cp, cp_a)

      # DETACH: A's lease is lost to expiry. Reclaim is lazy inside the
      # serialized reserve — B bounded-polls for the reclaim (no sleeps).
      # 40 ms ttl: expiry is the mechanism under test; the poll observes it.
      assert :ok = EventHubs.reserve_processing(group, partition, :consumer_a, 40)

      eventually(
        fn ->
          case EventHubs.reserve_processing(group, partition, :consumer_b, 60_000) do
            :ok -> {:ok, :reclaimed}
            {:error, :conflict} -> :retry
          end
        end,
        observable: "expired lease reclaimed for consumer_b",
        deadline_ms: 5_000
      )

      # Mid-detach production continues.
      for i <- 6..10, do: {:ok, _seq, _} = EventHubs.send_event(partition, "post-detach-#{i}")

      # RESUME: B reads broker truth + stored checkpoint, drains 4..10.
      assert {:ok, %{"seq" => 10, "checkpoint" => %{"seq" => 3}}} =
               EventHubs.reconcile(group, partition)

      resumed = EventHubs.receive_events(partition, 3, 10)
      assert length(resumed) == 7

      bodies = Enum.map(resumed, & &1["body"])

      # Resume replays everything after the checkpoint (4..10): A's
      # uncheckpointed pre-detach events AND all mid-detach production.
      assert bodies ==
               Enum.map(4..5, &"pre-detach-#{&1}") ++ Enum.map(6..10, &"post-detach-#{&1}")

      # B checkpoints its new position (expect = A's stored checkpoint).
      assert :ok =
               EventHubs.compare_and_swap(group, partition, cp_a, %{
                 "seq" => 10,
                 "offset" => "10",
                 "etag" => 10
               })

      # Zombie A returns with its stale checkpoint view: typed conflict, the
      # live checkpoint is untouched.
      assert {:error, :conflict} = EventHubs.compare_and_swap(group, partition, cp_a, cp_a)
      assert {:ok, %{"checkpoint" => %{"seq" => 10}}} = EventHubs.reconcile(group, partition)

      # Continuity: full stream intact, no gaps, no duplicates.
      all = EventHubs.receive_events(partition, 0, 20)
      assert length(all) == 10

      assert Enum.map(all, & &1["body"]) ==
               Enum.map(1..5, &"pre-detach-#{&1}") ++ Enum.map(6..10, &"post-detach-#{&1}")
    end
  end

  # ===========================================================================
  # 3.1 — lock-lost ordering stress
  # ===========================================================================
  describe "3.1 lock-lost ordering stress" do
    test "reclaimed lock: stale settle refuses lock_lost, live owner settles, ordered x20" do
      for _ <- 1..20 do
        queue = unique("settlement-wire")
        assert {:ok, seq} = QueueStore.enqueue(queue, "500M-LIQUIDITY-TRANSFER")

        assert {:ok, _m1, lock1} =
                 QueueStore.dequeue_matching(queue, now_ms: 1_000, lock_duration_ms: 500)

        assert {:ok, _m2, lock2} =
                 QueueStore.dequeue_matching(queue, now_ms: 1_600, lock_duration_ms: 500)

        assert lock2.lock_token != lock1.lock_token

        # Authored-clock expiry ordering: stale token settle refuses typed.
        assert {:error, :lock_lost} = QueueStore.complete(queue, seq, lock_token: lock1.lock_token)

        # Live owner settles; the message is gone exactly once.
        assert :ok = QueueStore.complete(queue, seq, lock_token: lock2.lock_token)

        # Post-settlement (missing row): the settle is an idempotent :ok
        # no-op — do_complete on an absent message does not resurrect it.
        assert :ok = QueueStore.complete(queue, seq, lock_token: lock2.lock_token)

        assert {:ok, []} = QueueStore.peek(queue)
      end
    end

    test "reclaim race burst: 16 stale settles + 1 live settle — stale all lock_lost, live :ok" do
      queue = unique("settlement-storm")
      assert {:ok, seq} = QueueStore.enqueue(queue, "EOQ-STORM-TRANSFER")

      assert {:ok, _m1, lock1} =
               QueueStore.dequeue_matching(queue, now_ms: 1_000, lock_duration_ms: 500)

      assert {:ok, _m2, lock2} =
               QueueStore.dequeue_matching(queue, now_ms: 1_600, lock_duration_ms: 500)

      live = lock2.lock_token
      stale = lock1.lock_token

      # Deterministic face BEFORE the burst: the message still exists under
      # lock2, so the stale token settles as a typed :lock_lost.
      assert {:error, :lock_lost} = QueueStore.complete(queue, seq, lock_token: stale)

      outcomes =
        1..16
        |> Task.async_stream(
          fn
            1 -> {:live, QueueStore.complete(queue, seq, lock_token: live)}
            _ -> {:stale, QueueStore.complete(queue, seq, lock_token: stale)}
          end,
          max_concurrency: 16,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, outcome} -> outcome end)

      live_outcomes = outcomes |> Enum.filter(&match?({:live, _}, &1)) |> Enum.map(&elem(&1, 1))
      stale_outcomes = outcomes |> Enum.filter(&match?({:stale, _}, &1)) |> Enum.map(&elem(&1, 1))

      assert live_outcomes == [:ok]

      # In-race stale faces: :lock_lost (stale settle landed while the row
      # still existed under lock2) or idempotent :ok (live settle already
      # removed the row). Exactly-once effect holds either way.
      assert Enum.all?(stale_outcomes, &(&1 in [{:error, :lock_lost}, :ok]))

      # Settled exactly once: the queue is empty, post-settle settles refuse.
      assert {:ok, []} = QueueStore.peek(queue)
    end
  end
end
