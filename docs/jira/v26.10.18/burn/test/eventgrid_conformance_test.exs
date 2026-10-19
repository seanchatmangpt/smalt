defmodule Smalt.EventGridConformanceTest do
  @moduledoc """
  CloudEvents 1.0 HTTP protocol binding conformance tier against the live
  `/topics/:topic/events` surface of `Smalt.EgressRouter`.

  Boots the REAL supervision-tree children (Smalt.Store + Bandit hosting
  Smalt.EgressRouter) on an ephemeral port and drives real HTTP/1.1 over raw
  :gen_tcp, mirroring the wire-tier pattern in test/wire/egress_wire_test.exs.
  No mocks, no Plug.Test shortcut — every assertion is against real router
  dispatch.

  Contract (CORRECTED — fixes the lane-37 findings, previously pinned as
  divergences):

  - A single JSON OBJECT body (canonical CloudEvents structured-mode POST) is
    validated and stored; the router answers `200` with an EMPTY body (real
    Event Grid publish shape). The legacy `{"status":"Published",...}` envelope
    survives only behind `:smalt, :eventgrid_response_mode == "per-event"`.
  - Admission is ALL-OR-NOTHING: every event is validated before any store
    write; an invalid event (missing source, wrong specversion, ...) fails the
    whole batch with `400 {"error":{"code":"InvalidCloudEvent",...}}` and
    nothing is stored.
  - A JSON content-type gate guards the POST route: non-JSON content-types
    (text/plain, application/xml, ...) get
    `415 {"error":{"code":"UnsupportedMediaType"}}`.
  - Malformed (non-JSON) bodies with a JSON content-type still surface as a
    bare `400` with an EMPTY body via Plug.Parsers.ParseError (parser-tier,
    not router-tier).
  - Binary-mode CloudEvents (`ce-*` headers + JSON body without in-body
    specversion) construct the event from headers + body-as-data, store, and
    round-trip.
  """

  use ExUnit.Case, async: false

  import SmaltTest.Wire, only: [http_request: 3, http_request: 4]

  setup do
    port = SmaltTest.Wire.get_free_port()

    # Stop the shared app tree before booting the private one (same contract
    # as the old stop_existing_tree/0, normalized to the superset name list).
    SmaltTest.Wire.stop_existing_tree()
    SmaltTest.Wire.pin_ports!(nil, port)
    SmaltTest.Wire.start_wire_tree(arm_port: nil, egress_port: port)

    ExUnit.Callbacks.on_exit(fn ->
      # Teardown repair: this suite stops the main app tree and runs a private
      # Store child. Restore the shared app on the shifted ports so downstream
      # modules always see a live Store, whatever the module run order.
      SmaltTest.Lifecycle.restore_app()
      SmaltTest.Lifecycle.ensure_store_up()
    end)

    {:ok, egress: port}
  end

  # ---------------------------------------------------------------------------
  # (1) Single-event POST — application/cloudevents+json
  # ---------------------------------------------------------------------------

  @tag :wire
  test "single-event structured POST (JSON object) stores the event and returns 200 with its id",
       %{
         egress: port
       } do
    resp =
      http_request(port, "POST", "/topics/conf-topic/events",
        headers: [{"content-type", "application/cloudevents+json"}],
        body:
          Jason.encode!(%{
            "specversion" => "1.0",
            "id" => "conf-1",
            "source" => "/smalt/conformance",
            "type" => "Smalt.Conformance.Single"
          })
      )

    # CORRECTED: a top-level JSON object is the canonical CloudEvents
    # structured-mode POST. It is validated as one event, stored, and
    # acknowledged with 200 and an EMPTY body (real Event Grid shape).
    assert resp.status == 200
    assert resp.body == ""

    query = http_request(port, "GET", "/topics/conf-topic/events")
    assert query.status == 200
    events = Jason.decode!(query.body)
    assert Enum.map(events, & &1["id"]) == ["conf-1"]
    assert hd(events)["type"] == "Smalt.Conformance.Single"
  end

  test "single event wrapped in a JSON array (batch of one) is stored and retrievable", %{
    egress: port
  } do
    resp =
      http_request(port, "POST", "/topics/conf-single-array/events",
        headers: [{"content-type", "application/cloudevents+json"}],
        body:
          Jason.encode!([
            %{
              "specversion" => "1.0",
              "id" => "conf-1a",
              "source" => "/smalt/conformance",
              "type" => "Smalt.Conformance.Single"
            }
          ])
      )

    # PINNED: array-wrapped events (the shape wire-tier already exercises) are
    # the only storing path; full round-trip over real HTTP.
    assert resp.status == 200
    assert resp.body == ""

    query = http_request(port, "GET", "/topics/conf-single-array/events")
    assert query.status == 200
    events = Jason.decode!(query.body)
    assert Enum.map(events, & &1["id"]) == ["conf-1a"]
    assert hd(events)["specversion"] == "1.0"
    assert hd(events)["type"] == "Smalt.Conformance.Single"
    assert hd(events)["topic"] == "conf-single-array"
  end

  # ---------------------------------------------------------------------------
  # (2) Batch POST — application/cloudevents-batch+json
  # ---------------------------------------------------------------------------

  @tag :wire
  test "batch POST with application/cloudevents-batch+json stores the full batch", %{
    egress: port
  } do
    resp =
      http_request(port, "POST", "/topics/conf-batch/events",
        headers: [{"content-type", "application/cloudevents-batch+json"}],
        body:
          Jason.encode!([
            %{
              "specversion" => "1.0",
              "id" => "conf-b-1",
              "source" => "/smalt/conformance",
              "type" => "Smalt.Conformance.Batch"
            },
            %{
              "specversion" => "1.0",
              "id" => "conf-b-2",
              "source" => "/smalt/conformance",
              "type" => "Smalt.Conformance.Batch"
            }
          ])
      )

    # PINNED: batch content-type is accepted and the full batch is stored;
    # the publish response is 200 with an EMPTY body (real Event Grid shape).
    assert resp.status == 200
    assert resp.body == ""

    query = http_request(port, "GET", "/topics/conf-batch/events")
    assert query.status == 200
    events = Jason.decode!(query.body)
    assert Enum.map(events, & &1["id"]) |> Enum.sort() == ["conf-b-1", "conf-b-2"]
  end

  # ---------------------------------------------------------------------------
  # (3) Missing required attributes → 4xx with error body (DIVERGENCE PINNED)
  # ---------------------------------------------------------------------------

  @tag :wire
  test "event missing required source returns 400 InvalidCloudEvent and stores nothing (all-or-nothing)",
       %{
         egress: port
       } do
    resp =
      http_request(port, "POST", "/topics/conf-invalid/events",
        headers: [{"content-type", "application/cloudevents-batch+json"}],
        body:
          Jason.encode!([
            %{
              "specversion" => "1.0",
              "id" => "conf-valid-before",
              "source" => "/smalt/conformance",
              "type" => "Smalt.Conformance.Invalid"
            },
            %{
              "specversion" => "1.0",
              "id" => "conf-no-source",
              "type" => "Smalt.Conformance.Invalid"
            }
          ])
      )

    # CORRECTED: publish_events/2's {:error, :invalid_cloudevent} is honored.
    # Admission is all-or-nothing — even the VALID event ahead of the invalid
    # one is not stored.
    assert resp.status == 400
    error = Jason.decode!(resp.body)
    assert error["error"]["code"] == "InvalidCloudEvent"
    assert is_binary(error["error"]["message"]) and error["error"]["message"] != ""

    query = http_request(port, "GET", "/topics/conf-invalid/events")
    assert query.status == 200
    assert Jason.decode!(query.body) == []
  end

  @tag :wire
  test "event with wrong specversion returns 400 InvalidCloudEvent and stores nothing", %{
    egress: port
  } do
    resp =
      http_request(port, "POST", "/topics/conf-invalid3/events",
        headers: [{"content-type", "application/cloudevents-batch+json"}],
        body:
          Jason.encode!([
            %{
              "specversion" => "0.3",
              "id" => "conf-wrong-spec",
              "source" => "/smalt/conformance",
              "type" => "Smalt.Conformance.Invalid"
            }
          ])
      )

    # CORRECTED: specversion "0.3" is refused with 400 + error body.
    assert resp.status == 400
    assert Jason.decode!(resp.body)["error"]["code"] == "InvalidCloudEvent"

    query = http_request(port, "GET", "/topics/conf-invalid3/events")
    assert Jason.decode!(query.body) == []
  end

  @tag :wire
  test "valid event with missing id gets a generated UUID and is stored", %{egress: port} do
    resp =
      http_request(port, "POST", "/topics/conf-uuid/events",
        headers: [{"content-type", "application/cloudevents-batch+json"}],
        body:
          Jason.encode!([
            %{
              "specversion" => "1.0",
              "source" => "/smalt/conformance",
              "type" => "Smalt.Conformance.Uuid"
            }
          ])
      )

    # PINNED: id is a required attribute, but the emulator surface generates a
    # UUID when absent (EventStream contract) and stores the event.
    assert resp.status == 200
    assert resp.body == ""

    query = http_request(port, "GET", "/topics/conf-uuid/events")
    events = Jason.decode!(query.body)
    assert length(events) == 1
    id = hd(events)["id"]
    assert is_binary(id) and byte_size(id) == 36
  end

  # ---------------------------------------------------------------------------
  # (4) Wrong content-type → 415/400 expected (NO GATE — DIVERGENCE PINNED)
  # ---------------------------------------------------------------------------

  @tag :wire
  test "wrong content-type (text/plain) is refused 415 UnsupportedMediaType", %{
    egress: port
  } do
    resp =
      http_request(port, "POST", "/topics/conf-ct/events",
        headers: [{"content-type", "text/plain"}],
        body:
          Jason.encode!([
            %{
              "specversion" => "1.0",
              "id" => "conf-ct-1",
              "source" => "/smalt/conformance",
              "type" => "Smalt.Conformance.ContentType"
            }
          ])
      )

    # CORRECTED: a JSON content-type gate guards the POST route. Non-JSON
    # content-types get 415 with an error body — never the previous
    # BadMapError 500.
    assert resp.status == 415
    assert Jason.decode!(resp.body)["error"]["code"] == "UnsupportedMediaType"

    query = http_request(port, "GET", "/topics/conf-ct/events")
    assert Jason.decode!(query.body) == []
  end

  @tag :wire
  test "wrong content-type (application/xml) is refused 415 UnsupportedMediaType", %{
    egress: port
  } do
    resp =
      http_request(port, "POST", "/topics/conf-ct2/events",
        headers: [{"content-type", "application/xml"}],
        body:
          Jason.encode!([
            %{
              "specversion" => "1.0",
              "id" => "conf-ct-2",
              "source" => "/smalt/conformance",
              "type" => "Smalt.Conformance.ContentType"
            }
          ])
      )

    assert resp.status == 415
    assert Jason.decode!(resp.body)["error"]["code"] == "UnsupportedMediaType"
  end

  @tag :wire
  test "malformed (non-JSON) body with application/json is a bare 400 with empty body (DIVERGENCE)",
       %{
         egress: port
       } do
    resp =
      http_request(port, "POST", "/topics/conf-garbage/events",
        headers: [{"content-type", "application/json"}],
        body: "this is not json"
      )

    # PINNED ACTUAL BEHAVIOR (regression fence): a non-JSON body raises
    # Plug.Parsers.ParseError inside the router pipeline, surfacing as a bare
    # 400 with an EMPTY body — not the CloudEvents-binding error body.
    # Reported as a lane-10 finding.
    assert resp.status == 400
    assert resp.body == ""
  end

  # ---------------------------------------------------------------------------
  # (5) Binary-mode CloudEvents (ce-* headers) — behavior pinned honestly
  # ---------------------------------------------------------------------------

  @tag :wire
  test "binary-mode event (ce-* headers + JSON body) is constructed, stored, and round-trips", %{
    egress: port
  } do
    resp =
      http_request(port, "POST", "/topics/conf-binary/events",
        headers: [
          {"content-type", "application/json"},
          {"ce-specversion", "1.0"},
          {"ce-id", "conf-bin-1"},
          {"ce-source", "/smalt/conformance"},
          {"ce-type", "Smalt.Conformance.Binary"}
        ],
        body: Jason.encode!(%{"n" => 42})
      )

    # CORRECTED: the body has no in-body specversion and ce-* headers are
    # present, so the event is constructed from the headers with the body as
    # `data`, stored, and acknowledged with 200 and an EMPTY body.
    assert resp.status == 200
    assert resp.body == ""

    query = http_request(port, "GET", "/topics/conf-binary/events")
    assert query.status == 200
    events = Jason.decode!(query.body)
    assert Enum.map(events, & &1["id"]) == ["conf-bin-1"]
    assert hd(events)["specversion"] == "1.0"
    assert hd(events)["source"] == "/smalt/conformance"
    assert hd(events)["type"] == "Smalt.Conformance.Binary"
    assert hd(events)["data"] == %{"n" => 42}
  end

  # ---------------------------------------------------------------------------
  # (6) GET list returns stored events in order
  # ---------------------------------------------------------------------------

  @tag :wire
  test "GET list returns stored events in insertion order", %{egress: port} do
    ids = ["conf-o-1", "conf-o-2", "conf-o-3"]

    for id <- ids do
      resp =
        http_request(port, "POST", "/topics/conf-order/events",
          headers: [{"content-type", "application/cloudevents-batch+json"}],
          body:
            Jason.encode!([
              %{
                "specversion" => "1.0",
                "id" => id,
                "source" => "/smalt/conformance",
                "type" => "Smalt.Conformance.Order"
              }
            ])
        )

      assert resp.status == 200
    end

    # Non-lexicographic tail id proves seq-based ordering, not key ordering.
    resp =
      http_request(port, "POST", "/topics/conf-order/events",
        headers: [{"content-type", "application/cloudevents-batch+json"}],
        body:
          Jason.encode!([
            %{
              "specversion" => "1.0",
              "id" => "conf-o-z-last",
              "source" => "/smalt/conformance",
              "type" => "Smalt.Conformance.Order"
            }
          ])
      )

    assert resp.status == 200

    query = http_request(port, "GET", "/topics/conf-order/events")
    assert query.status == 200
    events = Jason.decode!(query.body)
    assert Enum.map(events, & &1["id"]) == ids ++ ["conf-o-z-last"]
  end

  @tag :wire
  test "GET list is topic-scoped", %{egress: port} do
    for {topic, id} <- [{"conf-scope-a", "scope-a-1"}, {"conf-scope-b", "scope-b-1"}] do
      resp =
        http_request(port, "POST", "/topics/#{topic}/events",
          headers: [{"content-type", "application/cloudevents-batch+json"}],
          body:
            Jason.encode!([
              %{
                "specversion" => "1.0",
                "id" => id,
                "source" => "/smalt/conformance",
                "type" => "Smalt.Conformance.Scope"
              }
            ])
        )

      assert resp.status == 200
    end

    a = http_request(port, "GET", "/topics/conf-scope-a/events")
    assert a.status == 200
    assert Enum.map(Jason.decode!(a.body), & &1["id"]) == ["scope-a-1"]

    b = http_request(port, "GET", "/topics/conf-scope-b/events")
    assert Enum.map(Jason.decode!(b.body), & &1["id"]) == ["scope-b-1"]
  end

  # ---------------------------------------------------------------------------
  # helpers — transport/lifecycle live in SmaltTest.Wire (shared harness)
  # ---------------------------------------------------------------------------
end
