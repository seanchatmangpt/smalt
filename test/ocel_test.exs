defmodule Smalt.OcelTest do
  use ExUnit.Case, async: false

  alias Smalt.Ocel
  alias Smalt.Ocel.DeviationAdmission
  alias Smalt.Ocel.EventRegistry
  alias Smalt.Ocel.Conformance
  alias Smalt.Telemetry.OcelEmitter
  alias Smalt.Telemetry.OcelNdjson

  @tmp_dir Path.join(["tmp", "ocel_test_#{System.system_time(:nanosecond)}"])

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    SmaltTest.Env.put_restored(ocel_dir: @tmp_dir)

    on_exit(fn ->
      File.rm_rf!(@tmp_dir)
    end)

    :ok
  end

  defp obj(id, type), do: %{"id" => id, "type" => type, "attributes" => %{}}

  defp ev(id, type, time, object_ids) do
    %{
      "id" => id,
      "type" => type,
      "time" => time,
      "attributes" => %{},
      "relationships" => Enum.map(object_ids, &%{"objectId" => &1, "qualifier" => "resource"})
    }
  end

  # -- EventRegistry ---------------------------------------------------------

  test "closed vocabulary matches the ontology-projected event types" do
    # Projected-source provenance: `affidavit.seal` added by ggen-marketplace
    # packs/smalt-substrate-pack/ontology.ttl:485 (`smalt:et-affidavit-seal
    # a smalt:OcelEventType ; smalt:name "affidavit.seal"`); registry
    # regenerated via `mix smalt.gen`, test expectation reconciled to match.
    assert EventRegistry.event_types() |> Enum.sort() == ~w(
             affidavit.seal
             amqp.delivery.settled
             arm.resource.transition
             blob.custody.transition
             cosmos.doc.crud
             court.run
             doctor.receipt
             enclave.lifecycle.stage
             ledger.append
             skr.release
             spc.drift
           )
  end

  test "registry gate admits known types and rejects unknown without raising" do
    assert EventRegistry.event_type?("arm.resource.transition")
    refute EventRegistry.event_type?("made.up.type")
    refute EventRegistry.event_type?(nil)
    refute EventRegistry.event_type?(42)
  end

  # -- OcelEmitter -----------------------------------------------------------

  test "emit builds an OCEL 2.0 event and appends through the sink" do
    dir = @tmp_dir

    assert {:ok, path} =
             OcelEmitter.emit("arm.resource.transition", [obj("arm/res-1", "resource")], %{
               "phase" => "create",
               "status" => "Succeeded"
             })

    assert path == Path.join(dir, "events.ndjson")
    assert {:ok, doc} = path |> File.read!() |> String.trim() |> Jason.decode()

    assert %{
             "ocel:eventTypes" => [%{"name" => "arm.resource.transition"}],
             "ocel:events" => [event]
           } = doc

    assert [%{"objectId" => "arm/res-1", "qualifier" => "resource"}] = event["relationships"]
    assert event["attributes"]["phase"] == "create"
  end

  test "emit drops unknown event types (log-and-drop, never raise)" do
    assert {:ok, :dropped} = OcelEmitter.emit("made.up.type", [obj("x", "resource")], %{})
  end

  test "emit drops malformed object entries (matter-isolation)" do
    assert {:ok, path} =
             OcelEmitter.emit("skr.release", [%{"payload" => "secret"}, obj("skr-1", "skr")], %{})

    {:ok, doc} = path |> File.read!() |> String.trim() |> Jason.decode()
    assert [%{"id" => "skr-1"}] = doc["ocel:objects"]
    refute File.read!(path) =~ "secret"
  end

  test "bandit handler reshapes [:bandit, :request, :stop] into a conformant event" do
    # The handler appends through OcelNdjson, whose dir this setup has
    # pointed at @tmp_dir via Application env.
    conn = %Plug.Conn{request_path: "/dbs/db/colls/c/docs/1", status: 200, method: "GET"}

    assert :ok =
             OcelEmitter.handle_event(
               [:bandit, :request, :stop],
               %{duration: 1_000_000},
               %{conn: conn},
               :ok
             )

    path = Path.join(@tmp_dir, "events.ndjson")
    assert File.exists?(path)

    {:ok, doc} =
      path |> File.read!() |> String.split("\n", trim: true) |> List.last() |> Jason.decode()

    assert [%{"type" => "cosmos.doc.crud", "attributes" => %{"method" => "GET", "status" => 200}}] =
             doc["ocel:events"]

    assert [%{"id" => "/dbs/db/colls/c/docs/1", "type" => "resource"}] = doc["ocel:objects"]
  end

  # -- OcelNdjson assembler --------------------------------------------------

  test "sink assembler dedups objects and unions declared+used types" do
    first = %{"id" => "led-1", "type" => "ledger", "attributes" => %{"generation" => 1}}

    line1 =
      Jason.encode!(%{
        "ocel:eventTypes" => [%{"name" => "ledger.append"}],
        "ocel:objectTypes" => [%{"name" => "ledger"}],
        "ocel:events" => [ev("e1", "ledger.append", "2026-10-14T00:00:00Z", ["led-1"])],
        "ocel:objects" => [first]
      })

    line2 =
      Jason.encode!(%{
        "ocel:eventTypes" => [],
        "ocel:objectTypes" => [],
        "ocel:events" => [ev("e2", "ledger.append", "2026-10-14T00:00:01Z", ["led-1"])],
        "ocel:objects" => [
          %{"id" => "led-1", "type" => "ledger", "attributes" => %{"generation" => 2}}
        ]
      })

    assert {:ok, doc} = OcelNdjson.assemble_document([line1, line2])
    assert length(doc["ocel:objects"]) == 1
    # Dedup is first-occurrence-wins: the FIRST statement survives verbatim.
    assert doc["ocel:objects"] == [first]
    assert doc["ocel:eventTypes"] == [%{"name" => "ledger.append"}]
    assert doc["ocel:objectTypes"] == [%{"name" => "ledger"}]
    assert length(doc["ocel:events"]) == 2
  end

  test "sink assembler fails closed on a non-OCEL line" do
    assert {:error, violations} = OcelNdjson.assemble_document(["{\"not\":\"ocel\"}"])
    assert length(violations) == 4
    assert Enum.all?(violations, &(&1.reason =~ "must be an array"))

    assert {:error, _} = OcelNdjson.assemble_document(["not json at all"])
  end

  test "sink append gates unknown event types" do
    assert {:ok, :dropped} =
             OcelNdjson.append(
               %{
                 "id" => "e9",
                 "type" => "nope",
                 "time" => "t",
                 "attributes" => %{},
                 "relationships" => []
               },
               [],
               dir: @tmp_dir
             )
  end

  # -- Smalt.Ocel queries ----------------------------------------------------

  test "object_trace returns time-ordered events touching an object" do
    events = [
      ev("e1", "ledger.append", "2026-01-02T00:00:00Z", ["led-1"]),
      ev("e2", "skr.release", "2026-01-01T00:00:00Z", ["led-1"]),
      ev("e3", "ledger.append", "2026-01-03T00:00:00Z", ["led-2"])
    ]

    trace = Ocel.object_trace(events, "led-1")
    assert Enum.map(trace, & &1["id"]) == ["e2", "e1"]
  end

  test "attribute_history sorts by recordedAt" do
    records = [
      %{
        "objectId" => "o",
        "attribute" => "state",
        "value" => "b",
        "recordedAt" => "2026-01-02T00:00:00Z"
      },
      %{
        "objectId" => "o",
        "attribute" => "state",
        "value" => "a",
        "recordedAt" => "2026-01-01T00:00:00Z"
      }
    ]

    assert Enum.map(Ocel.attribute_history(records), & &1["value"]) == ["a", "b"]
  end

  test "validate_envelope detects dangling relationships" do
    assert :ok =
             Ocel.validate_envelope([ev("e1", "ledger.append", "t", ["led-1"])], [
               obj("led-1", "ledger")
             ])

    assert {:error, {:dangling_relationships, [{"e1", "ghost"}]}} =
             Ocel.validate_envelope([ev("e1", "ledger.append", "t", ["ghost"])], [
               obj("led-1", "ledger")
             ])
  end

  test "encode/decode round-trips an OCEL 2.0 envelope" do
    events = [ev("e1", "ledger.append", "2026-01-01T00:00:00Z", ["led-1"])]
    objects = [obj("led-1", "ledger")]

    {:ok, json} = Ocel.encode(events: events, objects: objects)
    assert json =~ "ocel:eventTypes"
    assert {:ok, %{events: ^events, objects: ^objects}} = Ocel.decode(json)

    assert {:error, _} = Ocel.decode("{}")
    assert {:error, _} = Ocel.decode("not json")
  end

  test "encode fails closed on a type-less event or object (no nil declaration manufactured)" do
    typeless_event = %{"id" => "e1", "time" => "t", "attributes" => %{}, "relationships" => []}

    assert {:error, {:missing_type, "e1"}} = Ocel.encode(events: [typeless_event], objects: [])

    assert {:error, {:missing_type, "o1"}} =
             Ocel.encode(
               events: [],
               objects: [%{"id" => "o1", "attributes" => %{}}]
             )

    # The laundered {"name": null} declaration can never be produced.
    {:ok, json} = Ocel.encode(events: [ev("e2", "ledger.append", "t", [])], objects: [])
    refute json =~ "null"
  end

  test "decode refuses a used-but-undeclared type (closure law holds inbound)" do
    good =
      Jason.encode!(%{
        "ocel:eventTypes" => [%{"name" => "ledger.append"}],
        "ocel:objectTypes" => [%{"name" => "ledger"}],
        "ocel:events" => [ev("e1", "ledger.append", "t", ["led-1"])],
        "ocel:objects" => [obj("led-1", "ledger")]
      })

    assert {:ok, _} = Ocel.decode(good)

    undeclared_event_type =
      Jason.encode!(%{
        "ocel:eventTypes" => [],
        "ocel:objectTypes" => [%{"name" => "ledger"}],
        "ocel:events" => [ev("e1", "ledger.append", "t", [])],
        "ocel:objects" => []
      })

    assert {:error, {:invalid_envelope, {:used_type_not_declared, "event", "ledger.append"}}} =
             Ocel.decode(undeclared_event_type)

    undeclared_object_type =
      Jason.encode!(%{
        "ocel:eventTypes" => [%{"name" => "ledger.append"}],
        "ocel:objectTypes" => [],
        "ocel:events" => [],
        "ocel:objects" => [obj("led-1", "ledger")]
      })

    assert {:error, {:invalid_envelope, {:used_type_not_declared, "object", "ledger"}}} =
             Ocel.decode(undeclared_object_type)
  end

  # -- Conformance ------------------------------------------------------------

  test "happy-path trace has fitness 1.0 and conforms" do
    net = Conformance.happy_path_net()
    result = Conformance.check_trace(net, Conformance.happy_path_trace())
    assert result.conforms
    assert result.fitness == 1.0
    assert result.deviations == []
  end

  test "a deliberately broken trace has fitness < 1.0 and does not conform" do
    net = Conformance.happy_path_net()
    # Skips the settle: custody fires underfed, final marking deficient.
    broken = ~w(arm.resource.transition blob.custody.transition)
    result = Conformance.check_trace(net, broken)
    refute result.conforms
    assert result.fitness < 1.0
    assert result.deviations != []
  end

  # -- DeviationAdmission ------------------------------------------------------

  test "conforming result admits nothing" do
    assert {:ok, :conforms} =
             DeviationAdmission.admit(%{conforms: true, fitness: 1.0, deviations: []},
               path: Path.join(@tmp_dir, "dev.jsonl")
             )
  end

  test "conforms:false with empty deviations is refused" do
    assert {:error, :no_deviation} =
             DeviationAdmission.admit(%{conforms: false, fitness: 0.5, deviations: []},
               path: Path.join(@tmp_dir, "dev.jsonl")
             )
  end

  test "conforms:false appends a durable, replayable deviation record" do
    net = Conformance.happy_path_net()
    broken = ~w(arm.resource.transition blob.custody.transition)
    result = Conformance.check_trace(net, broken)
    refute result.conforms

    path = Path.join(@tmp_dir, "dev.jsonl")

    assert {:ok, record_id} =
             DeviationAdmission.admit(result,
               path: path,
               trace: broken,
               reference_trace_id: "happy",
               candidate_trace_id: "broken"
             )

    assert {:ok, [record]} = DeviationAdmission.read_all(path)
    assert record["id"] == record_id
    assert record["deviatingMove"] == "blob.custody.transition/missing_tokens"
    assert record["referenceTraceId"] == "happy"
    assert record["candidateTraceId"] == "broken"
    assert record["fitness"] < 1.0
    # Replayable as a court fixture: the recorded trace reproduces the verdict.
    replay = Conformance.check_trace(net, record["trace"])
    assert replay.fitness == record["fitness"]
    refute replay.conforms
  end

  # -- Full pipeline ------------------------------------------------------------

  test "end-to-end: emitter -> sink file -> assembled document validates" do
    dir = @tmp_dir

    {:ok, _} =
      OcelEmitter.emit("arm.resource.transition", [obj("r-1", "resource")], %{"phase" => "create"})

    {:ok, _} =
      OcelEmitter.emit("amqp.delivery.settled", [obj("r-1", "resource"), obj("q-1", "queue")], %{
        "settlement" => "accepted"
      })

    path = Path.join(dir, "events.ndjson")
    {:ok, doc} = OcelNdjson.read_document(path)
    assert length(doc["ocel:events"]) == 2

    assert Enum.sort(Enum.map(doc["ocel:eventTypes"], & &1["name"])) ==
             ~w(amqp.delivery.settled arm.resource.transition)

    # The shared object is stated once after dedup.
    assert length(doc["ocel:objects"]) == 2
    assert :ok = Ocel.validate_envelope(doc["ocel:events"], doc["ocel:objects"])
  end

  # -- Object-reference closure (dangling-relationship refusal) ---------------

  test "assembly refuses a relationship referencing an unknown object id" do
    line =
      Jason.encode!(%{
        "ocel:eventTypes" => [%{"name" => "cosmos.doc.crud"}],
        "ocel:objectTypes" => [],
        "ocel:events" => [
          %{
            "id" => "e-dangle",
            "type" => "cosmos.doc.crud",
            "time" => "2026-10-15T00:00:00Z",
            "attributes" => %{},
            "relationships" => [%{"objectId" => "ghost-obj", "qualifier" => "resource"}]
          }
        ],
        "ocel:objects" => []
      })

    path = Path.join(@tmp_dir, "dangle.ndjson")
    File.write!(path, line <> "\n")

    assert {:error, [%{path: path_v, reason: reason}]} = OcelNdjson.read_document(path)
    assert path_v =~ "relationships"
    assert reason =~ "ghost-obj"
  end

  test "a dangling reference from an EARLIER line is refused even when a later line exists" do
    # The closure check is document-global: an adjacent line cannot
    # launder a reference to an object that appears NOWHERE in the file.
    line1 =
      Jason.encode!(%{
        "ocel:eventTypes" => [%{"name" => "cosmos.doc.crud"}],
        "ocel:objectTypes" => [],
        "ocel:events" => [
          %{
            "id" => "e-1",
            "type" => "cosmos.doc.crud",
            "time" => "2026-10-15T00:00:00Z",
            "attributes" => %{},
            "relationships" => [%{"objectId" => "ghost-cross-line", "qualifier" => "resource"}]
          }
        ],
        "ocel:objects" => []
      })

    line2 =
      Jason.encode!(%{
        "ocel:eventTypes" => [%{"name" => "cosmos.doc.crud"}],
        "ocel:objectTypes" => [%{"name" => "resource"}],
        "ocel:events" => [
          %{
            "id" => "e-2",
            "type" => "cosmos.doc.crud",
            "time" => "2026-10-15T00:01:00Z",
            "attributes" => %{},
            "relationships" => []
          }
        ],
        "ocel:objects" => [obj("real-obj", "resource")]
      })

    path = Path.join(@tmp_dir, "dangle-cross-line.ndjson")
    File.write!(path, line1 <> "\n" <> line2 <> "\n")

    assert {:error, [%{reason: reason}]} = OcelNdjson.read_document(path)
    assert reason =~ "ghost-cross-line"
  end

  test "cross-line object references close (object in an earlier line admits the later reference)" do
    line1 =
      Jason.encode!(%{
        "ocel:eventTypes" => [%{"name" => "cosmos.doc.crud"}],
        "ocel:objectTypes" => [%{"name" => "resource"}],
        "ocel:events" => [
          %{
            "id" => "e-1",
            "type" => "cosmos.doc.crud",
            "time" => "2026-10-15T00:00:00Z",
            "attributes" => %{},
            "relationships" => []
          }
        ],
        "ocel:objects" => [obj("res-9", "resource")]
      })

    line2 =
      Jason.encode!(%{
        "ocel:eventTypes" => [%{"name" => "cosmos.doc.crud"}],
        "ocel:objectTypes" => [],
        "ocel:events" => [
          %{
            "id" => "e-2",
            "type" => "cosmos.doc.crud",
            "time" => "2026-10-15T00:01:00Z",
            "attributes" => %{},
            "relationships" => [%{"objectId" => "res-9", "qualifier" => "resource"}]
          }
        ],
        "ocel:objects" => []
      })

    path = Path.join(@tmp_dir, "crossline.ndjson")
    File.write!(path, line1 <> "\n" <> line2 <> "\n")

    assert {:ok, doc} = OcelNdjson.read_document(path)
    assert length(doc["ocel:events"]) == 2
  end
end
