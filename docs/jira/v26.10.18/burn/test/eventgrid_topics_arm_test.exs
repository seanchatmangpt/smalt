defmodule Smalt.EventGridTopicsArmTest do
  @moduledoc """
  ARM control-plane CRUD + per-topic inputSchema gating for
  `Microsoft.EventGrid/topics` / `systemTopics` (80/20 Event Grid expansion).

  Boots the REAL supervision-tree children (Smalt.Store + Bandit hosting
  Smalt.ArmGateway.Router on an ephemeral port + Bandit hosting
  Smalt.EgressRouter on a second ephemeral port) and drives real HTTP/1.1 over
  raw :gen_tcp. No mocks — every assertion is against real router dispatch and
  the real `:smalt_eg_topics` Store table.

  Contract:
  - PUT/GET/LIST/DELETE `.../providers/Microsoft.EventGrid/topics(/:name)`
    (+ systemTopics) store {name, location, endpoint (loopback ingest URL),
    inputSchema (CloudEvents default | EventGrid)} into `:smalt_eg_topics`
    (dedicated table — `:smalt_resources` stays untouched, so the ETS-identity
    baseline test is unaffected).
  - `properties.inputSchema` invalid value → 400 InvalidResourceShape (typed).
  - Ingest gate: a topic declared `inputSchema: "EventGrid"` admits the EG1
    envelope {id, subject, eventType, eventTime, data} with 200 + empty body;
    an un-declared topic refuses the same envelope with 400 InvalidCloudEvent
    (the refusal is the default — GAP(eventgrid-eg1-schema-absent) closes for
    DECLARED topics only).
  - EG1 admission is all-or-nothing: an invalid envelope stores nothing
    (typed 400 InvalidEventGridEvent).
  - GET `/topics/:topic/events` readback merges CloudEvents and EG1 events by
    stored seq.
  """

  use ExUnit.Case, async: false

  import SmaltTest.Wire, only: [get_free_port: 0, http_request: 3, http_request: 4]

  @rg_api Smalt.Registry.latest_version("Microsoft.Resources/resourceGroups") || "2021-04-01"
  @topic_api Smalt.Registry.latest_version("Microsoft.EventGrid/topics") || "2021-04-01"

  setup do
    arm = SmaltTest.Wire.get_free_port()
    egress = SmaltTest.Wire.get_free_port()

    # Stop the shared app tree before booting the private one (same contract
    # as the old stop_existing_tree/0, normalized to the superset name list).
    SmaltTest.Wire.stop_existing_tree()
    SmaltTest.Wire.pin_ports!(arm, egress)
    SmaltTest.Wire.start_wire_tree(arm_port: arm, egress_port: egress)

    ExUnit.Callbacks.on_exit(fn ->
      # Teardown repair (same contract as the conformance suite): this suite
      # stops the main app tree and runs a private Store child. Restore the
      # shared app on the shifted ports so downstream modules always see a
      # live Store, whatever the module run order.
      SmaltTest.Lifecycle.restore_app()
      SmaltTest.Lifecycle.ensure_store_up()
    end)

    {:ok, arm: arm, egress: egress}
  end

  # ---------------------------------------------------------------------------
  # (1) Topic CRUD
  # ---------------------------------------------------------------------------

  @tag :wire
  test "topic lifecycle: PUT 201, GET 200 shape, re-PUT 200, LIST, DELETE, 404, LIST empty", %{
    arm: arm
  } do
    base = "/subscriptions/sub-1/resourceGroups/rg-eg1/providers/Microsoft.EventGrid/topics"

    # RG must exist? These routes do not require a parent RG record (topic rows
    # live in their own table), so a bare PUT works — real ARM would 404 a
    # missing RG; the emulator's dedicated routes are self-standing.
    resp =
      http_request(arm, "PUT", "#{base}/crud-topic?api-version=#{@topic_api}",
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(%{"location" => "westus"})
      )

    assert resp.status == 201, resp.body

    record = Jason.decode!(resp.body)
    assert record["name"] == "crud-topic"
    assert record["type"] == "Microsoft.EventGrid/topics"
    assert record["location"] == "westus"
    assert record["properties"]["provisioningState"] == "Succeeded"
    assert record["properties"]["inputSchema"] == "CloudEvents"

    assert record["properties"]["endpoint"] ==
             "http://localhost:#{egress_port()}/topics/crud-topic/events"

    # GET
    resp = http_request(arm, "GET", "#{base}/crud-topic?api-version=#{@topic_api}")
    assert resp.status == 200
    assert Jason.decode!(resp.body)["properties"]["inputSchema"] == "CloudEvents"

    # Re-PUT = update → 200
    resp =
      http_request(arm, "PUT", "#{base}/crud-topic?api-version=#{@topic_api}",
        headers: [{"content-type", "application/json"}],
        body:
          Jason.encode!(%{
            "location" => "westus",
            "properties" => %{"inputSchema" => "EventGrid"}
          })
      )

    assert resp.status == 200, resp.body
    assert Jason.decode!(resp.body)["properties"]["inputSchema"] == "EventGrid"

    # LIST contains the topic
    resp = http_request(arm, "GET", "#{base}?api-version=#{@topic_api}")
    assert resp.status == 200
    names = Enum.map(Jason.decode!(resp.body)["value"], & &1["name"])
    assert "crud-topic" in names

    # DELETE
    resp = http_request(arm, "DELETE", "#{base}/crud-topic?api-version=#{@topic_api}")
    assert resp.status == 200

    # GET → 404, LIST no longer contains it
    resp = http_request(arm, "GET", "#{base}/crud-topic?api-version=#{@topic_api}")
    assert resp.status == 404
    assert resp.body =~ "ResourceNotFound"

    resp = http_request(arm, "GET", "#{base}?api-version=#{@topic_api}")
    refute "crud-topic" in Enum.map(Jason.decode!(resp.body)["value"], & &1["name"])
  end

  test "systemTopics lifecycle mirrors topics", %{arm: arm} do
    base = "/subscriptions/sub-1/resourceGroups/rg-eg1/providers/Microsoft.EventGrid/systemTopics"

    resp =
      http_request(arm, "PUT", "#{base}/sys-topic?api-version=#{@topic_api}",
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(%{"location" => "eastus"})
      )

    assert resp.status == 201, resp.body
    record = Jason.decode!(resp.body)
    assert record["type"] == "Microsoft.EventGrid/systemTopics"
    assert record["properties"]["inputSchema"] == "CloudEvents"

    resp = http_request(arm, "GET", "#{base}?api-version=#{@topic_api}")
    assert resp.status == 200
    assert "sys-topic" in Enum.map(Jason.decode!(resp.body)["value"], & &1["name"])

    resp = http_request(arm, "DELETE", "#{base}/sys-topic?api-version=#{@topic_api}")
    assert resp.status == 200

    resp = http_request(arm, "GET", "#{base}/sys-topic?api-version=#{@topic_api}")
    assert resp.status == 404
  end

  test "invalid inputSchema value is a typed 400 InvalidResourceShape", %{arm: arm} do
    base = "/subscriptions/sub-1/resourceGroups/rg-eg1/providers/Microsoft.EventGrid/topics"

    resp =
      http_request(arm, "PUT", "#{base}/bad-schema?api-version=#{@topic_api}",
        headers: [{"content-type", "application/json"}],
        body:
          Jason.encode!(%{"location" => "eastus", "properties" => %{"inputSchema" => "Fancy"}})
      )

    assert resp.status == 400, resp.body
    assert resp.body =~ "InvalidResourceShape"

    # The refused topic must not exist (no partial record).
    resp = http_request(arm, "GET", "#{base}/bad-schema?api-version=#{@topic_api}")
    assert resp.status == 404
  end

  # ---------------------------------------------------------------------------
  # (2) Ingest schema gate
  # ---------------------------------------------------------------------------

  test "EG1 envelope on a topic declared inputSchema EventGrid is admitted (200 + empty)", %{
    egress: egress
  } do
    create_topic(arm_port(), "eg1-topic", "EventGrid")

    resp =
      http_request(egress, "POST", "/topics/eg1-topic/events",
        headers: [{"content-type", "application/json"}],
        body:
          Jason.encode!(%{
            "id" => "eg1-1",
            "subject" => "smalt/ingest",
            "eventType" => "Smalt.Eg1.Created",
            "eventTime" => "2026-10-16T00:00:00Z",
            "data" => %{"k" => 1}
          })
      )

    assert resp.status == 200, resp.body
    assert resp.body == ""

    # Readback: the EG1 event is stored and listed.
    resp = http_request(egress, "GET", "/topics/eg1-topic/events")
    assert resp.status == 200
    events = Jason.decode!(resp.body)
    assert Enum.map(events, & &1["id"]) == ["eg1-1"]
    assert hd(events)["eventType"] == "Smalt.Eg1.Created"
    assert hd(events)["seq"] >= 1
  end

  test "EG1 batch of two on a declared topic stores both in order", %{egress: egress} do
    create_topic(arm_port(), "eg1-batch", "EventGrid")

    resp =
      http_request(egress, "POST", "/topics/eg1-batch/events",
        headers: [{"content-type", "application/json"}],
        body:
          Jason.encode!([
            %{
              "id" => "eg1-b1",
              "subject" => "s",
              "eventType" => "Smalt.Eg1.B",
              "eventTime" => "2026-10-16T00:00:00Z",
              "data" => 1
            },
            %{
              "id" => "eg1-b2",
              "subject" => "s",
              "eventType" => "Smalt.Eg1.B",
              "eventTime" => "2026-10-16T00:00:00Z",
              "data" => 2
            }
          ])
      )

    assert resp.status == 200, resp.body

    resp = http_request(egress, "GET", "/topics/eg1-batch/events")
    assert Enum.map(Jason.decode!(resp.body), & &1["id"]) == ["eg1-b1", "eg1-b2"]
  end

  test "EG1 envelope with a missing member is a typed 400 InvalidEventGridEvent, nothing stored",
       %{
         egress: egress
       } do
    create_topic(arm_port(), "eg1-invalid", "EventGrid")

    resp =
      http_request(egress, "POST", "/topics/eg1-invalid/events",
        headers: [{"content-type", "application/json"}],
        body:
          Jason.encode!(%{
            "id" => "eg1-x",
            "eventType" => "Smalt.Eg1.X",
            "eventTime" => "2026-10-16T00:00:00Z",
            "data" => %{}
          })
      )

    assert resp.status == 400, resp.body
    assert resp.body =~ "InvalidEventGridEvent"

    resp = http_request(egress, "GET", "/topics/eg1-invalid/events")
    assert Jason.decode!(resp.body) == []
  end

  test "EG1 envelope on an UNdeclared topic keeps the 400 InvalidCloudEvent refusal", %{
    egress: egress
  } do
    create_topic(arm_port(), "eg1-undeclared", "CloudEvents")

    resp =
      http_request(egress, "POST", "/topics/eg1-undeclared/events",
        headers: [{"content-type", "application/json"}],
        body:
          Jason.encode!(%{
            "id" => "eg1-u",
            "subject" => "s",
            "eventType" => "Smalt.Eg1.U",
            "eventTime" => "2026-10-16T00:00:00Z",
            "data" => %{}
          })
      )

    assert resp.status == 400, resp.body
    assert resp.body =~ "InvalidCloudEvent"
  end

  test "CloudEvents ingest stays green on a default (CloudEvents) topic", %{egress: egress} do
    create_topic(arm_port(), "ce-topic", "CloudEvents")

    resp =
      http_request(egress, "POST", "/topics/ce-topic/events",
        headers: [{"content-type", "application/cloudevents+json"}],
        body:
          Jason.encode!(%{
            "specversion" => "1.0",
            "id" => "ce-1",
            "source" => "/smalt/test",
            "type" => "Smalt.Ce.Test"
          })
      )

    assert resp.status == 200, resp.body

    resp = http_request(egress, "GET", "/topics/ce-topic/events")
    assert Enum.map(Jason.decode!(resp.body), & &1["id"]) == ["ce-1"]
  end

  test "readback merges CloudEvents and EG1 events of one topic by seq", %{egress: egress} do
    arm = arm_port()
    create_topic(arm, "mixed-topic", "CloudEvents")

    http_request(egress, "POST", "/topics/mixed-topic/events",
      headers: [{"content-type", "application/cloudevents+json"}],
      body:
        Jason.encode!(%{
          "specversion" => "1.0",
          "id" => "mix-ce",
          "source" => "/s",
          "type" => "T.Ce"
        })
    )

    # Flip the topic's declared schema to EventGrid and publish an EG1 event.
    http_request(
      arm,
      "PUT",
      "/subscriptions/sub-1/resourceGroups/rg-eg1/providers/Microsoft.EventGrid/topics/mixed-topic?api-version=#{@topic_api}",
      headers: [{"content-type", "application/json"}],
      body:
        Jason.encode!(%{"location" => "eastus", "properties" => %{"inputSchema" => "EventGrid"}})
    )

    http_request(egress, "POST", "/topics/mixed-topic/events",
      headers: [{"content-type", "application/json"}],
      body:
        Jason.encode!(%{
          "id" => "mix-eg1",
          "subject" => "s",
          "eventType" => "T.Eg1",
          "eventTime" => "2026-10-16T00:00:00Z",
          "data" => nil
        })
    )

    resp = http_request(egress, "GET", "/topics/mixed-topic/events")
    assert resp.status == 200
    assert Enum.map(Jason.decode!(resp.body), & &1["id"]) == ["mix-ce", "mix-eg1"]
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp create_topic(arm, name, schema) do
    resp =
      http_request(
        arm,
        "PUT",
        "/subscriptions/sub-1/resourceGroups/rg-eg1/providers/Microsoft.EventGrid/topics/#{name}?api-version=#{@topic_api}",
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(%{"location" => "eastus", "properties" => %{"inputSchema" => schema}})
      )

    assert resp.status in [200, 201], resp.body
    :ok
  end

  defp arm_port, do: Application.get_env(:smalt, :arm_port)
  defp egress_port, do: Application.get_env(:smalt, :egress_port)
end
