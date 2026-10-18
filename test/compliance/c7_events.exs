defmodule Smalt.Compliance.C7EventsTest do
  @moduledoc """
  C7 event-plane compliance fences (docs/compliance/C7_EVENT_PLANES.md).

  Boots the REAL supervision-tree children (Smalt.Store + Bandit hosting
  Smalt.EgressRouter) on an ephemeral port and drives real HTTP/1.1 over raw
  :gen_tcp against the live router — no mocks (Chicago discipline). Module-tier
  probes go through the real `Smalt.Messaging.EventHubs` ETS machinery.

  Each test names the doc row it fences (`[row: "..."]` tag) so a failure maps
  1:1 back to the CONFORMANT/PARTIAL/GAP table.
  """

  use ExUnit.Case, async: false

  @moduletag :c7

  setup do
    port = get_free_port()

    SmaltTest.Lifecycle.stop_shared_tree()

    # save-prev (leak-court): carry across the on_exit seam via the process
    # dictionary (try/on_exit bodies are separate scopes — i21-leak-batch2).
    prev_arm = Application.get_env(:smalt, :arm_port)
    prev_egress = Application.get_env(:smalt, :egress_port)
    prev_amqp = Application.get_env(:smalt, :amqp_port)
    Process.put({__MODULE__, :ports_prev}, {prev_arm, prev_egress, prev_amqp})

    Application.put_env(:smalt, :arm_port, get_free_port())
    Application.put_env(:smalt, :egress_port, port)
    Application.put_env(:smalt, :amqp_port, get_free_port())

    children = [
      Smalt.Store,
      {Bandit, plug: Smalt.EgressRouter, scheme: :http, port: port}
    ]

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one, name: Smalt.C7WireSup)

    on_exit(fn ->
      stop_tree(sup)

      # conditional restore of the port-config keys saved in setup
      case Process.get({__MODULE__, :ports_prev}) do
        {arm, egress, amqp} ->
          if is_nil(arm),
            do: Application.delete_env(:smalt, :arm_port),
            else: Application.put_env(:smalt, :arm_port, arm)

          if is_nil(egress),
            do: Application.delete_env(:smalt, :egress_port),
            else: Application.put_env(:smalt, :egress_port, egress)

          if is_nil(amqp),
            do: Application.delete_env(:smalt, :amqp_port),
            else: Application.put_env(:smalt, :amqp_port, amqp)

        _ ->
          :ok
      end

      SmaltTest.Lifecycle.restore_app()
      SmaltTest.Lifecycle.ensure_store_up()
    end)

    {:ok, egress: port}
  end

  # ---------------------------------------------------------------------------
  # (1) CloudEvents 1.0 HTTP protocol binding
  # ---------------------------------------------------------------------------

  test "[binding] structured mode: content-type application/cloudevents+json, single object", %{
    egress: port
  } do
    resp =
      http_request(port, "POST", "/topics/c7-structured/events",
        headers: [{"content-type", "application/cloudevents+json"}],
        body:
          Jason.encode!(%{
            "specversion" => "1.0",
            "id" => "c7-bind-1",
            "source" => "/c7/binding",
            "type" => "C7.Binding.Structured"
          })
      )

    assert resp.status == 200
    # CONFORMANT vs real Event Grid: publish answers 200 with an EMPTY body.
    assert resp.body == ""

    stored = fetch_events(port, "c7-structured")
    assert Enum.map(stored, & &1["id"]) == ["c7-bind-1"]
  end

  test "[binding] batch mode: content-type application/cloudevents-batch+json", %{
    egress: port
  } do
    batch = [
      %{"specversion" => "1.0", "id" => "c7-b1", "source" => "/c7/batch", "type" => "C7.Batch"},
      %{"specversion" => "1.0", "id" => "c7-b2", "source" => "/c7/batch", "type" => "C7.Batch"}
    ]

    resp =
      http_request(port, "POST", "/topics/c7-batch/events",
        headers: [{"content-type", "application/cloudevents-batch+json"}],
        body: Jason.encode!(batch)
      )

    assert resp.status == 200
    # CONFORMANT vs real Event Grid: publish answers 200 with an EMPTY body.
    # The legacy envelope is reachable only via
    # :smalt, :eventgrid_response_mode == "per-event" (compat mode).
    assert resp.body == ""

    stored = fetch_events(port, "c7-batch")
    assert Enum.map(stored, & &1["id"]) == ["c7-b1", "c7-b2"]
  end

  test "[binding] binary mode: ce-* headers carry context attributes, body is data", %{
    egress: port
  } do
    resp =
      http_request(port, "POST", "/topics/c7-binary/events",
        headers: [
          {"content-type", "application/json"},
          {"ce-specversion", "1.0"},
          {"ce-id", "c7-bin-1"},
          {"ce-source", "/c7/binary"},
          {"ce-type", "C7.Binary"}
        ],
        body: Jason.encode!(%{"temp" => 42})
      )

    assert resp.status == 200

    stored = fetch_events(port, "c7-binary")
    assert is_map(hd(stored))
    ev = hd(stored)
    assert ev["id"] == "c7-bin-1"
    assert ev["source"] == "/c7/binary"
    assert ev["type"] == "C7.Binary"
    # datacontenttype is the OPTIONAL attribute the spec names for this role.
    assert ev["datacontenttype"] == "application/json"
    assert ev["data"] == %{"temp" => 42}
  end

  test "[binding] REQUIRED attributes: id absent -> UUID stamped, event still admitted", %{
    egress: port
  } do
    resp =
      http_request(port, "POST", "/topics/c7-uuid/events",
        headers: [{"content-type", "application/cloudevents+json"}],
        body:
          Jason.encode!(%{"specversion" => "1.0", "source" => "/c7/uuid", "type" => "C7.Uuid"})
      )

    assert resp.status == 200

    stored = fetch_events(port, "c7-uuid")
    assert is_map(hd(stored))
    ev = hd(stored)
    uuid = ev["id"]
    assert is_binary(uuid) and byte_size(uuid) == 36
    assert [a, b, c, d, e] = String.split(uuid, "-")
    assert byte_size(a) == 8 and byte_size(b) == 4 and byte_size(c) == 4 and byte_size(d) == 4
    assert byte_size(e) == 12
  end

  test "[binding] REQUIRED attributes: missing specversion / source / type -> 400 InvalidCloudEvent, nothing stored",
       %{
         egress: port
       } do
    for bad <- [
          %{"specversion" => "0.3", "id" => "x", "source" => "/c7", "type" => "C7.Bad"},
          %{"specversion" => "1.0", "id" => "x", "type" => "C7.Bad"},
          %{"specversion" => "1.0", "id" => "x", "source" => "/c7"}
        ] do
      resp =
        http_request(port, "POST", "/topics/c7-invalid/events",
          headers: [{"content-type", "application/cloudevents+json"}],
          body: Jason.encode!(bad)
        )

      assert resp.status == 400
      err = Jason.decode!(resp.body)
      assert err["error"]["code"] == "InvalidCloudEvent"
    end

    # All-or-nothing admission: the batch containing one invalid event must not
    # have stored anything.
    resp =
      http_request(port, "POST", "/topics/c7-atomic/events",
        headers: [{"content-type", "application/cloudevents-batch+json"}],
        body:
          Jason.encode!([
            %{"specversion" => "1.0", "id" => "good", "source" => "/c7", "type" => "C7.Ok"},
            %{"specversion" => "1.0", "id" => "bad", "type" => "C7.MissingSource"}
          ])
      )

    assert resp.status == 400
    assert fetch_events(port, "c7-atomic") == []
  end

  test "[binding] non-JSON content-type -> 415 UnsupportedMediaType", %{egress: port} do
    resp =
      http_request(port, "POST", "/topics/c7-415/events",
        headers: [{"content-type", "text/plain"}],
        body: "hello"
      )

    assert resp.status == 415
    assert Jason.decode!(resp.body)["error"]["code"] == "UnsupportedMediaType"
  end

  # ---------------------------------------------------------------------------
  # (2) Event Hubs
  # ---------------------------------------------------------------------------

  test "[eh] strictly monotonic per-partition sequence from 1 (module tier)" do
    part = "c7-ns/c7-hub/0"
    :ok = Smalt.Messaging.EventHubs.ensure_tables()

    assert {:ok, 1} = Smalt.Messaging.EventHubs.next_sequence(part)
    assert {:ok, 2} = Smalt.Messaging.EventHubs.next_sequence(part)
    assert {:ok, 3} = Smalt.Messaging.EventHubs.next_sequence(part)
  end

  test "[eh] send/receive in sequence order; reconcile exposes broker truth vs checkpoint" do
    part = "c7-ns/c7-hub/1"
    group = "$default"

    {:ok, 1, _} = Smalt.Messaging.EventHubs.send_event(part, "e1")
    {:ok, 2, _} = Smalt.Messaging.EventHubs.send_event(part, "e2")

    events = Smalt.Messaging.EventHubs.receive_events(part)
    assert Enum.map(events, & &1["seq"]) == [1, 2]

    {:ok, rec} = Smalt.Messaging.EventHubs.reconcile(group, part)
    assert rec["group"] == "$default"
    assert rec["seq"] == 2

    # CAS checkpoint: one winner, one conflict.
    :ok =
      Smalt.Messaging.EventHubs.compare_and_swap(
        group,
        part,
        %{"seq" => 0, "offset" => 0, "etag" => 0},
        %{
          "seq" => 2,
          "offset" => 2,
          "etag" => 1
        }
      )

    {:ok, rec2} = Smalt.Messaging.EventHubs.reconcile(group, part)
    assert rec2["checkpoint"]["seq"] == 2
  end

  test "[eh] partitions are free-form names — no 0..N fan-out structure is enforced (PARTIAL fence)" do
    # Real Event Hubs pre-provisions partitions 0..N-1; smalt has no partition
    # count / metadata surface (getEventHubProperties) at the module tier, so
    # any partition key is accepted. This fence pins the honest PARTIAL row.
    # Unique never-before-used partition ids: EH seq counters are per-partition
    # in the immortal Smalt.Messaging.EventHubs.Server GenServer and survive the
    # per-test Store restart, so freshness (s == 1) needs a fresh partition key.
    p1 = "c7-ns/c7-hub/fresh-#{System.unique_integer([:positive])}"
    p2 = "c7-ns/c7-hub/fresh-#{System.unique_integer([:positive])}"

    {:ok, s1, _} = Smalt.Messaging.EventHubs.send_event(p1, "a")
    {:ok, s2, _} = Smalt.Messaging.EventHubs.send_event(p2, "b")
    assert s1 == 1 and s2 == 1
  end

  # ---------------------------------------------------------------------------
  # (3) Log Analytics / Sentinel
  # ---------------------------------------------------------------------------

  test "[la] DCR ingest api-version gate: 2023-01-01 accepted with 204 (real shape), other rejected 400" do
    assert {:ok, 204, ""} =
             Smalt.DataPlane.Sentinel.ingest(
               "c7-dcr",
               "Custom-Logs",
               [%{"a" => "1"}],
               "2023-01-01"
             )

    assert {:error, 400, err} =
             Smalt.DataPlane.Sentinel.ingest(
               "c7-dcr",
               "Custom-Logs",
               [%{"a" => "1"}],
               "2022-01-01"
             )

    assert err["error"]["code"] == "InvalidApiVersion"

    # Lens-3 cross-court round 2: byte-exact message pin for the LA surface
    # (ARM's api-version 400s carry their own prose; the envelopes are
    # deliberately NOT unified across planes).
    assert err["error"]["message"] == "api-version must be 2023-01-01"
  end

  test "[la] DCR ingest over the wire answers 204 with x-ms-request-id", %{egress: port} do
    resp =
      http_request(
        port,
        "POST",
        "/dataCollectionRules/c7-wire-dcr/streams/Custom-Logs?api-version=2023-01-01",
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!([%{"a" => "1"}])
      )

    assert resp.status == 204

    # Pin CURRENT wire bytes (re-fenced 2026-10-15 after the data-plane lane
    # replaced the 32-hex form with a v4 dashed GUID — F3 unification, drift
    # watch cycle 11 caught the change by FAILING this fence first):
    # exactly one x-ms-request-id, GUID form matching the ARM surface c1 pins.
    assert [{_, req_id}] =
             Enum.filter(resp.headers, fn {name, _} -> name == "x-ms-request-id" end)

    assert is_binary(req_id) and byte_size(req_id) == 36

    assert Regex.match?(
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
             req_id
           ),
           "x-ms-request-id must be a v4 GUID, got: #{inspect(req_id)}"
  end

  test "[la] query PrimaryResult envelope: projected column order + value-shaped types (CONFORMANT)" do
    {:ok, 204, ""} =
      Smalt.DataPlane.Sentinel.ingest(
        "c7-dcr-q",
        "Custom-Logs",
        [%{"count" => 7, "at" => "2026-01-01T00:00:00Z"}],
        "2023-01-01"
      )

    {:ok, 200, env} =
      Smalt.DataPlane.Sentinel.query("c7-dcr-q", %{"query" => "| project count, at"})

    assert [%{"name" => "PrimaryResult", "columns" => cols, "rows" => rows}] = env["tables"]

    # CONFORMANT vs real Log Analytics: columns follow the `project` order and
    # types honor the value shape (integer -> "long").
    assert Enum.map(cols, & &1["name"]) == ["count", "at"]
    colmap = Map.new(cols, fn c -> {c["name"], c["type"]} end)
    assert colmap["count"] == "long"
    assert colmap["at"] == "string"

    row = hd(rows)
    assert Enum.at(row, Enum.find_index(cols, &(&1["name"] == "count"))) == "7"
    assert Enum.at(row, Enum.find_index(cols, &(&1["name"] == "at"))) == "2026-01-01T00:00:00Z"
  end

  # ---------------------------------------------------------------------------
  # (4) Azure Resource Graph
  # ---------------------------------------------------------------------------

  # Lens-8 cycle-9: token-scope binding + forged-token fallback pinned at
  # CURRENT bytes (fences-only: the lenient fallback is a documented
  # deviation from real ARG, which 400s on an invalid skipToken — real
  # behavior change is engine-lane-owned).
  test "[rg] skipToken scope binding + forged-token fallback (current bytes)" do
    for i <- 1..5 do
      Smalt.Store.put(
        :smalt_resources,
        "/subscriptions/rg8subA/providers/Microsoft.Storage/storageAccounts/a#{i}",
        %{
          "id" => "/subscriptions/rg8subA/providers/Microsoft.Storage/storageAccounts/a#{i}",
          "name" => "a#{i}",
          "type" => "microsoft.storage/storageaccounts",
          "location" => "eastus",
          "subscriptionId" => "rg8subA"
        }
      )
    end

    for i <- 1..2 do
      Smalt.Store.put(
        :smalt_resources,
        "/subscriptions/rg8subB/providers/Microsoft.Storage/storageAccounts/b#{i}",
        %{
          "id" => "/subscriptions/rg8subB/providers/Microsoft.Storage/storageAccounts/b#{i}",
          "name" => "b#{i}",
          "type" => "microsoft.storage/storageaccounts",
          "location" => "eastus",
          "subscriptionId" => "rg8subB"
        }
      )
    end

    # Page 1 over subA only, $top=2 -> token T carries scope [rg8subA].
    {:ok, 200, page1} =
      Smalt.DataPlane.ResourceGraph.query(
        ["rg8subA"],
        %{"$top" => 2, "query" => "Resources"},
        "2022-10-01"
      )

    assert page1["count"] == 2
    tok = page1["$skipToken"]
    assert is_binary(tok)

    # Resume presented under a DIFFERENT subscription scope: the TOKEN's
    # stored scope wins (current bytes) — page 2 continues over subA's
    # name space, not subB's. Real ARG 400s a scope-mismatched token;
    # smalt's emulated behavior is pinned here as the deviation.
    {:ok, 200, page2} =
      Smalt.DataPlane.ResourceGraph.query(
        ["rg8subB"],
        %{"options" => %{"$skipToken" => tok, "$top" => 2}},
        "2022-10-01"
      )

    names2 = Enum.map(page2["data"], & &1["name"])
    assert names2 == ["a3", "a4"]

    # Forged token: unknown token falls back to a FRESH query honoring
    # $skip (current bytes; real ARG: 400 invalid token — deviation pinned).
    {:ok, 200, forged} =
      Smalt.DataPlane.ResourceGraph.query(
        ["rg8subA"],
        %{"options" => %{"$skipToken" => "deadbeefdeadbeefdeadbeef", "$top" => 2, "$skip" => 3}},
        "2022-10-01"
      )

    assert forged["count"] == 2
    assert Enum.map(forged["data"], & &1["name"]) == ["a4", "a5"]
  end

  test "[rg] response contract: count/totalRecords/resultTruncated/$skipToken pagination" do
    resources =
      for i <- 1..5 do
        %{
          "id" =>
            "/subscriptions/c7-sub/resourcegroups/c7rg/providers/Microsoft.Storage/storageAccounts/c7sa#{i}",
          "name" => "c7sa#{i}",
          "type" => "microsoft.storage/storageaccounts",
          "location" => "eastus",
          "subscriptionId" => "c7-sub"
        }
      end

    Enum.each(resources, &Smalt.Store.put(:smalt_resources, &1["id"], &1))

    {:ok, 200, page1} =
      Smalt.DataPlane.ResourceGraph.query(
        ["c7-sub"],
        %{"$top" => 2, "query" => "Resources"},
        "2022-10-01"
      )

    assert page1["count"] == 2
    assert page1["totalRecords"] == 5
    assert page1["resultTruncated"] == false
    token = page1["$skipToken"]
    assert is_binary(token)

    {:ok, 200, page2} =
      Smalt.DataPlane.ResourceGraph.query(
        ["c7-sub"],
        %{"options" => %{"$skipToken" => token, "$top" => 2}},
        "2022-10-01"
      )

    assert page2["count"] == 2
    names = Enum.map(page2["data"], & &1["name"])
    assert names == ["c7sa3", "c7sa4"]

    # CONFORMANT: the real API carries the token in options.$skipToken (the
    # flat top-level form is honored only as a fallback).
    {:ok, 200, page3} =
      Smalt.DataPlane.ResourceGraph.query(
        ["c7-sub"],
        %{"options" => %{"$skipToken" => page2["$skipToken"], "$top" => 2}},
        "2022-10-01"
      )

    assert page3["count"] == 1
    assert page3["$skipToken"] == nil
    assert page3["resultTruncated"] == false

    # Normal pagination never truncates; only a hit on the hard server cap
    # (1000 records) sets resultTruncated=true.
    assert page1["resultTruncated"] == false
  end

  # ---------------------------------------------------------------------------
  # (5) Purview Atlas v2
  # ---------------------------------------------------------------------------

  test "[atlas] entity POST accepts the {referredEntities, entity} envelope; bare map also accepted" do
    body = %{
      "referredEntities" => %{},
      "entity" => %{"typeName" => "c7_table", "attributes" => %{"name" => "t1"}, "guid" => "-100"}
    }

    assert {:ok, 201, entity} = Smalt.DataPlane.Purview.create_entity(body)
    assert entity["guid"] == "-100"

    # Real Atlas returns the created entity with MutationInfo; smalt returns
    # the bare entity — fenced as the named divergence.
    assert is_map(entity)

    # bare-map shape
    assert {:ok, 201, %{"guid" => g2}} =
             Smalt.DataPlane.Purview.create_entity(%{"typeName" => "c7_table"})

    assert is_binary(g2)
  end

  test "[atlas] bulk <= 100; over-limit -> 400 with no partial insert" do
    batch = for i <- 1..100, do: %{"typeName" => "c7_bulk", "guid" => "g#{i}"}
    assert {:ok, 201, resp} = Smalt.DataPlane.Purview.bulk_entities(%{"entities" => batch})

    # Mutant-kill: the assignments must cover EXACTLY the batch's 100 guids,
    # identity-mapped, and mutatedEntities.CREATE must carry the same 100
    # entity bodies — a stub returning empty maps passes has_key?/is_map.
    assert map_size(resp["guidAssignments"]) == 100
    assert Map.new(batch, fn e -> {e["guid"], e["guid"]} end) == resp["guidAssignments"]

    assert %{"CREATE" => created} = resp["mutatedEntities"]
    assert length(created) == 100
    assert MapSet.new(created, & &1["guid"]) == MapSet.new(batch, & &1["guid"])

    over = for i <- 1..101, do: %{"typeName" => "c7_over", "guid" => "o#{i}"}
    assert {:error, 400, err} = Smalt.DataPlane.Purview.bulk_entities(%{"entities" => over})
    assert err["error"]["code"] == "ATLAS-400-00-001"

    # No partial insert on the over-limit call.
    assert {:error, 404, _} = Smalt.DataPlane.Purview.get_entity("o101")
  end

  test "[atlas] lineage: relationship edge -> guidEntityMap + relations in lineage response" do
    {:ok, 201, a} =
      Smalt.DataPlane.Purview.create_entity(%{"typeName" => "c7_src", "guid" => "c7-lin-a"})

    {:ok, 201, b} =
      Smalt.DataPlane.Purview.create_entity(%{"typeName" => "c7_dst", "guid" => "c7-lin-b"})

    assert a["guid"] == "c7-lin-a" and b["guid"] == "c7-lin-b"

    edge =
      Smalt.DataPlane.Purview.put_edge("c7-lin-a", "c7-lin-b", "c7_process", %{
        "relationshipId" => "rel-1"
      })

    assert edge["relationshipId"] == "rel-1"

    {:ok, 200, lin} = Smalt.DataPlane.Purview.lineage("c7-lin-b", "input", 1)
    assert lin["baseEntityGuid"] == "c7-lin-b"
    assert Map.has_key?(lin["guidEntityMap"], "c7-lin-a")
    # CONFORMANT vs real Atlas v2: lineage relations carry the stored
    # relationship guid, not a recomputed "from->to" string.
    assert [
             %{
               "fromEntityId" => "c7-lin-a",
               "toEntityId" => "c7-lin-b",
               "relationshipId" => "rel-1"
             }
           ] = lin["relations"]
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp fetch_events(port, topic) do
    resp = http_request(port, "GET", "/topics/#{topic}/events")
    assert resp.status == 200
    Jason.decode!(resp.body)
  end

  defp stop_tree(sup) do
    Supervisor.stop(sup, :normal, 10_000)
  catch
    _, _ -> Process.exit(sup, :kill)
  end

  defp get_free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp http_request(port, method, path, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body, "")

    req =
      IO.iodata_to_binary([
        method,
        " ",
        path,
        " HTTP/1.1\r\n",
        "host: localhost:#{port}\r\n",
        "content-length: #{byte_size(body)}\r\n",
        Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end),
        "connection: close\r\n\r\n",
        body
      ])

    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5_000)
    :ok = :gen_tcp.send(sock, req)
    raw = recv_all(sock, "")
    :gen_tcp.close(sock)
    parse_response(raw)
  end

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} -> recv_all(sock, IO.iodata_to_binary([acc, data]))
      {:error, :closed} -> acc
    end
  end

  defp parse_response(raw) do
    [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")

    status =
      status_line
      |> String.split(" ")
      |> Enum.at(1)
      |> String.to_integer()

    %{
      status: status,
      headers:
        Enum.map(header_lines, fn h -> String.split(h, ": ", parts: 2) |> List.to_tuple() end),
      body: body
    }
  end
end
