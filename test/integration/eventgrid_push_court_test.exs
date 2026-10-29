defmodule Smalt.Integration.EventGridPushCourt do
  # W1 — Event Grid push-style routing court (v26.10.22, MIX_BUILD_ROOT=_build-w1).
  #
  # Real wire face (Bandit + Smalt.EgressRouter + raw :httpc, no test-adapter
  # conns, no mocks) against the REAL sieve (Smalt.POWL2.LawCompiler-compiled
  # SHACL guards). Gates:
  #
  #   Gate 1 — subscribe two SHACL shapes (A: data.kind required; B: data.kind
  #           in (alert) AND data.priority <= 10) over the real
  #           POST /eventgrid/subscriptions route; an event matching BOTH
  #           delivers TWICE (one WAL frame per subscription, durable
  #           JSON-lines on disk, delivery records typed).
  #   Gate 2 — an event matching ONLY shape A delivers to A only; an event
  #           matching NEITHER delivers zero and increments the typed
  #           :no_matching_subscription counter.
  #   Gate 3 — mutation: DELETE /eventgrid/subscriptions/:name stops
  #           delivery (post-delete event delivering only to the deleted
  #           sub lands zero new frames; deleted sub 404s on GET).
  #   Gate 4 — boundary refusals: malformed shape → typed 400 InvalidShape;
  #           unknown subscription GET/DELETE → typed 404.
  #   Gate 5 — sb_queue destination delivers a REAL queue message (created at
  #           subscribe, visible via QueueStorage.peek_messages, base64
  #           MessageText decodes to the CloudEvent).
  #
  # Chicago discipline: real collaborators only (real HTTP client, real
  # server, real file WAL, real queue store); assertions on final state
  # (statuses, WAL file lines, queue rows, counters), never call counts.

  use ExUnit.Case, async: false

  # Audited bounded-poll implementation (no-sleep doctrine). Required here so
  # the setup convergence below polls the real observable, never paces on a
  # bare sleep.
  Code.require_file(Path.expand("../internal/poll_helper.exs", __DIR__))

  @moduletag :w1_eventgrid_push

  alias Smalt.EventGrid.PushRouter
  alias Smalt.DataPlane.QueueStorage

  @scope "/smalt/prod/w1"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)

    wal_dir =
      Path.expand("tmp/w1-court-wal-#{System.unique_integer([:positive])}")

    Application.put_env(:smalt, :eventgrid_push, wal_dir: wal_dir)

    # Reserve an OS-assigned port, then bind Bandit to it (ja5/sj4 pattern).
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)

    {:ok, server} = Bandit.start_link(plug: Smalt.EgressRouter, scheme: :http, port: port)

    on_exit(fn ->
      Process.whereis(Smalt.EventGrid.PushRouter) |> is_pid() && PushRouter.reset()
      File.rm_rf!(wal_dir)
    end)

    %{port: port, wal_dir: wal_dir}
  end

  setup do
    # BK-EGPC setup-race repair: `Process.whereis(PushRouter) ||
    # start_supervised!(PushRouter)` was a check-then-act race — PushRouter is
    # a lazily-started named GenServer (Smalt.EventGrid.PushRouter.server/0),
    # so a concurrent lazy start (async test / webhook ingest) between the
    # whereis(nil) and the start_supervised! made the latter raise on
    # {:error, {:already_started, _}} — the witnessed in-batch setup flake.
    # Race-safe ensure via the module's own already_started-tolerant seam,
    # then bounded convergence on the REAL observable: the named process is
    # alive AND answering a real GenServer call (counters/0). Fail-closed via
    # the audited Poll helper.
    pid = PushRouter.server()

    assert {:ok, ^pid} =
             SmaltTest.Internal.Poll.eventually(
               fn ->
                 case Process.whereis(PushRouter) do
                   ^pid ->
                     case PushRouter.counters() do
                       %{} = ctr when is_map(ctr) -> {:ok, pid}
                       other -> {:error, {:counters, other}}
                     end

                   other ->
                     {:error, {:whereis, other}}
                 end
               end,
               timeout_ms: 5_000,
               poll_ms: 20
             )

    PushRouter.reset()
    # The KD-101 receiver only accepts pushes for a REGISTERED subscriber
    # (Event Grid parity: the webhook subscription exists before the push).
    # "w1-court-sub" is the upstream hook the CloudEvents batch arrives on;
    # the accepted batch then runs the PushRouter sieve.
    Smalt.EventGridWebhook.register("w1-court-sub")
    :ok
  end

  # -- shapes -----------------------------------------------------------------

  defp shape_a_ttl do
    ~s(ex:ShapeA a sh:NodeShape; sh:property [ sh:path kind ; sh:minCount 1 ] .)
  end

  # B: kind MUST be "alert" (sh:in) AND priority present under ceiling 10.
  defp shape_b_ttl do
    """
    ex:ShapeB a sh:NodeShape; sh:property [ sh:path kind ; sh:in ( alert ) ], [ sh:path priority ; sh:maxInclusive 10 ] .
    """
    |> String.trim_trailing("\n")
  end

  defp sub_body(name, shape, ttl, destination) do
    Jason.encode!(%{
      "name" => name,
      "scope" => @scope,
      "shape_ref" => %{"shape" => shape, "ttl" => ttl},
      "destination" => destination
    })
  end

  # -- wire helpers ---------------------------------------------------------------

  defp req(method, path, body \\ nil) do
    url = ~c"http://127.0.0.1:#{port()}" ++ String.to_charlist(path)

    http_req =
      if body do
        {url, [{~c"content-type", ~c"application/json"}], ~c"application/json", body}
      else
        {url, []}
      end

    {:ok, {{_ver, status, _reason}, _headers, resp_body}} =
      :httpc.request(method, http_req, [], body_format: :binary)

    {status, resp_body}
  end

  defp port, do: Process.get(:w1_port) || raise("port not stashed")

  defp post_event(id, data) do
    body =
      Jason.encode!(%{
        "specversion" => "1.0",
        "id" => id,
        "source" => @scope <> "/sensor",
        "type" => "smalt.w1.probe",
        "data" => data
      })

    req(:post, "/eventgrid/hooks/w1-court-sub", body)
  end

  defp wal_frames(wal_dir, sub) do
    path = Path.join(wal_dir, "wal-#{sub}.jsonl")

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      {:error, _} ->
        []
    end
  end

  # -- Gate 1: two shapes, event matching both delivers twice ----------------------

  test "gate 1: dual-shape subscription, event matching both delivers twice (real WAL frames)", %{
    port: port,
    wal_dir: wal_dir
  } do
    Process.put(:w1_port, port)

    {201, body} = req(:put, "/eventgrid/subscriptions", sub_body("sub-a", "ShapeA", shape_a_ttl(), %{"type" => "wal"}))
    assert %{"name" => "sub-a", "scope" => @scope} = Jason.decode!(body)

    {201, _} = req(:put, "/eventgrid/subscriptions", sub_body("sub-b", "ShapeB", shape_b_ttl(), %{"type" => "wal"}))

    {200, body} = post_event("ev-both-1", %{"kind" => "alert", "priority" => 5})
    assert %{"received" => true} = Jason.decode!(body)

    # BOTH subscriptions deliver; each WAL file carries the frame ON DISK.
    frames_a = wal_frames(wal_dir, "sub-a")
    frames_b = wal_frames(wal_dir, "sub-b")
    assert [%{"seq" => 0, "event_id" => "ev-both-1", "subscription" => "sub-a"}] = frames_a
    assert [%{"seq" => 0, "event_id" => "ev-both-1", "subscription" => "sub-b"}] = frames_b

    # Delivery records typed with the destination.
    assert [%{"event_id" => "ev-both-1", "destination" => %{"type" => "wal", "file" => f}} | _] =
             PushRouter.deliveries("sub-a")

    assert String.ends_with?(f, "wal-sub-a.jsonl")

    ctr = PushRouter.counters()
    assert ctr.matched == 2
    assert ctr.delivered == 2
    assert ctr.wal_frames == 2
    assert ctr.no_matching_subscription == 0
  end

  # -- Gate 2: selective sieve — A-only, neither ---------------------------------

  test "gate 2: event matching only shape A delivers to A only; matching neither delivers zero", %{
    port: port,
    wal_dir: wal_dir
  } do
    Process.put(:w1_port, port)

    {201, _} = req(:put, "/eventgrid/subscriptions", sub_body("sub-a2", "ShapeA", shape_a_ttl(), %{"type" => "wal"}))
    {201, _} = req(:put, "/eventgrid/subscriptions", sub_body("sub-b2", "ShapeB", shape_b_ttl(), %{"type" => "wal"}))

    # kind=info conforms to A (kind present) but NOT B (kind not in (alert)).
    {200, _} = post_event("ev-only-a", %{"kind" => "info", "priority" => 5})

    frames_a = wal_frames(wal_dir, "sub-a2")
    frames_b = wal_frames(wal_dir, "sub-b2")
    assert [%{"event_id" => "ev-only-a"}] = frames_a
    assert [] = frames_b

    # priority=99, kind absent: A refuses (minCount) and B refuses
    # (maxInclusive ceiling) — zero delivery, typed counter.
    {200, _} = post_event("ev-neither", %{"priority" => 99})

    assert length(wal_frames(wal_dir, "sub-a2")) == 1
    assert wal_frames(wal_dir, "sub-b2") == []

    ctr = PushRouter.counters()
    assert ctr.matched == 1
    assert ctr.delivered == 1
    assert ctr.no_matching_subscription == 1

    # Per-sub delivery record view over the same face.
    {200, body} = req(:get, "/eventgrid/subscriptions/sub-a2/deliveries")
    assert %{"deliveries" => [%{"event_id" => "ev-only-a"}]} = Jason.decode!(body)
  end

  # -- Gate 3: mutation — delete stops delivery ----------------------------------

  test "gate 3: subscription DELETE stops delivery", %{port: port, wal_dir: wal_dir} do
    Process.put(:w1_port, port)

    {201, _} = req(:put, "/eventgrid/subscriptions", sub_body("sub-gone", "ShapeA", shape_a_ttl(), %{"type" => "wal"}))

    {200, _} = post_event("ev-pre-delete", %{"kind" => "x"})
    assert [%{"event_id" => "ev-pre-delete"}] = wal_frames(wal_dir, "sub-gone")

    {200, body} = req(:delete, "/eventgrid/subscriptions/sub-gone")
    assert %{"deleted" => "sub-gone"} = Jason.decode!(body)

    # Deleted sub is gone from the registry (404) and no longer receives.
    {404, _} = req(:get, "/eventgrid/subscriptions/sub-gone")
    {200, _} = post_event("ev-post-delete", %{"kind" => "x"})

    assert length(wal_frames(wal_dir, "sub-gone")) == 1
    assert PushRouter.deliveries("sub-gone") |> length() == 1
    assert Enum.all?(PushRouter.deliveries("sub-gone"), &(&1["event_id"] == "ev-pre-delete"))
  end

  # -- Gate 4: boundary refusals ---------------------------------------------------

  test "gate 4: malformed shape refused typed 400; unknown subscription 404", %{port: port} do
    Process.put(:w1_port, port)

    # Malformed TTL (unsupported constraint keyword) → InvalidShape.
    {400, body} =
      req(
        :put,
        "/eventgrid/subscriptions",
        sub_body("sub-bad", "ShapeBad", "ex:ShapeBad a sh:NodeShape; sh:property [ sh:path kind ; sh:bogus 1 ] .", %{
          "type" => "wal"
        })
      )

    assert %{"error" => %{"code" => "InvalidShape"}} = Jason.decode!(body)

    # Unknown shape IRI → InvalidShape too.
    {400, body} =
      req(:put, "/eventgrid/subscriptions", sub_body("sub-bad2", "NoSuchShape", shape_a_ttl(), %{"type" => "wal"}))

    assert %{"error" => %{"code" => "InvalidShape"}} = Jason.decode!(body)

    # Invalid scope (no leading slash) → InvalidScope.
    {400, body} =
      req(:put, "/eventgrid/subscriptions", %{
        "name" => "sub-scope",
        "scope" => "no-slash",
        "shape_ref" => %{"shape" => "ShapeA", "ttl" => shape_a_ttl()},
        "destination" => %{"type" => "wal"}
      }
      |> Jason.encode!())

    assert %{"error" => %{"code" => "InvalidScope"}} = Jason.decode!(body)

    {404, _} = req(:get, "/eventgrid/subscriptions/never-subscribed")
    {404, _} = req(:delete, "/eventgrid/subscriptions/never-subscribed")
  end

  # -- Gate 5: sb_queue destination = real queue message ---------------------------

  test "gate 5: sb_queue destination lands a real queue message", %{port: port} do
    Process.put(:w1_port, port)

    {201, _} =
      req(
        :put,
        "/eventgrid/subscriptions",
        sub_body("sub-sb", "ShapeA", shape_a_ttl(), %{"type" => "sb_queue", "account" => "w1acct", "queue" => "w1-queue"})
      )

    {200, _} = post_event("ev-sb-1", %{"kind" => "queue-me"})

    # Real queue store holds the message; MessageText decodes to the event.
    {:ok, 200, _headers, xml} = QueueStorage.peek_messages("w1acct", "w1-queue", %{})

    # MessageText is base64 on the wire — the raw XML can never contain the
    # event id literally; decode assertions below are the load-bearing check.
    assert xml =~ "<QueueMessage>" and xml =~ "MessageText"

    decoded =
      xml
      |> message_texts()
      |> Enum.map(&Base.decode64!/1)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(decoded, &(&1["id"] == "ev-sb-1" and &1["data"]["kind"] == "queue-me"))

    ctr = PushRouter.counters()
    assert ctr.sb_messages == 1
    assert ctr.delivered >= 1
  end

  defp message_texts(xml) do
    Regex.scan(~r/<MessageText>(.*?)<\/MessageText>/s, xml, capture: :all_but_first)
    |> List.flatten()
  end
end
