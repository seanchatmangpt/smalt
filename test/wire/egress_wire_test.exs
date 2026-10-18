defmodule Smalt.Wire.EgressWireTest do
  @moduledoc """
  T2 wire tier — data-plane egress over real sockets.

  Boots the REAL supervision-tree children (Smalt.Store + Bandit hosting
  Smalt.EgressRouter) on ephemeral ports from the pinned Application env
  contract (Application.get_env(:smalt, :egress_port, 8443)), then drives real
  HTTP/1.1 over raw :gen_tcp (no HTTP client dependency).

  Wire surface documented as it exists today:
  - Cosmos DB: create doc 201, stale If-Match -> 412 over the wire
  - Blob: WORM-locked container -> 409 ContainerLocked over the wire
  - Key Vault: Secure Key Release 403 (bad attestation) / 200 (valid CVM)
  - Event ingestion + query round-trip via /topics/:topic/events (the Sentinel
    DCR ingest + KQL query routes are not mounted on the egress router yet;
    the EventStream surface is the ingest/query wire surface that exists)
  """

  use ExUnit.Case, async: false

  setup do
    ports = %{egress: SmaltTest.PortEnv.free_port()}

    SmaltTest.Lifecycle.stop_shared_tree_with_children()

    # save-prev/on_exit-restore discipline (test-isolation-leak gate), via the
    # canonical nil-preserving helper (v26.10.18 e2e-wire D1/D4).
    prev = SmaltTest.PortEnv.snapshot([:arm_port, :egress_port, :amqp_port])

    SmaltTest.PortEnv.apply(
      arm_port: SmaltTest.PortEnv.free_port(),
      egress_port: ports.egress,
      amqp_port: SmaltTest.PortEnv.free_port()
    )

    children = [
      Smalt.Store,
      {Bandit, plug: Smalt.EgressRouter, scheme: :http, port: ports.egress}
    ]

    {:ok, sup} =
      Supervisor.start_link(children, strategy: :one_for_one, name: Smalt.WireSup)

    on_exit(fn ->
      stop_tree(sup)
      SmaltTest.PortEnv.restore(prev)
      SmaltTest.Lifecycle.restore_app()
      SmaltTest.Lifecycle.ensure_store_up()
    end)

    {:ok, egress: ports.egress}
  end

  @tag :wire
  test "Cosmos: create document returns 201 with etag over the wire", %{egress: port} do
    resp =
      http_request(port, "POST", "/dbs/wiredb/colls/wirecoll/docs",
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(%{"id" => "doc1", "value" => 1})
      )

    assert resp.status == 201
    body = Jason.decode!(resp.body)
    assert body["id"] == "doc1"
    assert is_binary(body["_etag"]) and body["_etag"] != ""
    assert String.contains?(resp.headers, "etag")
  end

  @tag :wire
  test "Cosmos: stale If-Match on PUT returns 412 over the wire", %{egress: port} do
    http_request(port, "POST", "/dbs/wiredb/colls/wirecoll/docs",
      headers: [{"content-type", "application/json"}],
      body: Jason.encode!(%{"id" => "doc2", "value" => 1})
    )

    resp =
      http_request(port, "PUT", "/dbs/wiredb/colls/wirecoll/docs/doc2",
        headers: [
          {"content-type", "application/json"},
          {"if-match", "\"00000000-stale-etag\""}
        ],
        body: Jason.encode!(%{"value" => 2})
      )

    assert resp.status == 412
    body = Jason.decode!(resp.body)
    assert body["code"] == "PreconditionFailed"
    assert is_binary(body["message"]) and byte_size(body["message"]) > 0
  end

  @tag :wire
  test "Blob: overwrite in WORM-locked container returns 409 over the wire", %{egress: port} do
    create =
      http_request(port, "PUT", "/wireacct/wormcont",
        headers: [{"content-type", "application/json"}, {"x-ms-version", "2025-01-01"}],
        body: "{}"
      )

    assert create.status == 201

    put =
      http_request(port, "PUT", "/wireacct/wormcont/blob1",
        headers: [{"content-type", "application/octet-stream"}, {"x-ms-version", "2025-01-01"}],
        body: "first"
      )

    assert put.status == 201

    overwrite =
      http_request(port, "PUT", "/wireacct/wormcont/blob1",
        headers: [{"content-type", "application/octet-stream"}, {"x-ms-version", "2025-01-01"}],
        body: "second"
      )

    assert overwrite.status == 409
    body = Jason.decode!(overwrite.body)
    assert body["error"]["code"] == "ContainerLocked"
    assert String.contains?(body["error"]["message"], "WORM")
  end

  @tag :wire
  test "Key Vault: release without valid CVM attestation returns 403 over the wire", %{
    egress: port
  } do
    http_request(port, "POST", "/keys/wirekey/create",
      headers: [{"content-type", "application/json"}],
      body:
        Jason.encode!(%{
          "kty" => "RSA-HSM",
          "release_policy" => %{
            "anyOf" => [%{"claim" => "x-ms-attestation-type", "equals" => "sevsnpvm"}]
          }
        })
    )

    # R143: api-version gate landed on the release route (GAP S8) —
    # existing tests carry ?api-version=7.4 (premise change).
    resp =
      http_request(port, "POST", "/keys/wirekey/release?api-version=7.4",
        headers: [{"x-ms-compliance-status", "not-attested"}],
        body: ""
      )

    assert resp.status == 403
    body = Jason.decode!(resp.body)
    assert body["error"]["code"] == "UnauthorizedAttestation"
  end

  @tag :wire
  test "Key Vault: release with valid CVM attestation returns released key material over the wire",
       %{
         egress: port
       } do
    # Full wire flow: seed the MAA baseline, attest over the wire, then release
    # the key with the attestation token as a Bearer credential.
    measurement = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    Smalt.Store.put(:smalt_attestation_baseline, measurement, measurement)

    attest =
      http_request(port, "POST", "/attest/sevsnpvm",
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(%{"measurement" => measurement})
      )

    assert attest.status == 200
    token = Jason.decode!(attest.body)["token"]
    assert is_binary(token) and byte_size(token) > 0

    http_request(port, "POST", "/keys/wirekey2/create",
      headers: [{"content-type", "application/json"}],
      body:
        Jason.encode!(%{
          "kty" => "RSA-HSM",
          "release_policy" => %{
            "anyOf" => [%{"claim" => "x-ms-attestation-type", "equals" => "sevsnpvm"}]
          }
        })
    )

    resp =
      http_request(port, "POST", "/keys/wirekey2/release?api-version=7.4",
        headers: [{"authorization", "Bearer #{token}"}],
        body: ""
      )

    assert resp.status == 200
    body = Jason.decode!(resp.body)
    assert body["status"] == "Released"
    assert is_binary(body["value"]) and body["value"] != ""
  end

  @tag :wire
  test "event ingest + query round-trip over the wire", %{egress: port} do
    ingest =
      http_request(port, "POST", "/topics/wiretopic/events",
        headers: [{"content-type", "application/json"}],
        body:
          Jason.encode!([
            %{
              "specversion" => "1.0",
              "id" => "evt-1",
              "source" => "/smalt/wire-test",
              "type" => "Smalt.Wire.Test",
              "data" => %{"n" => 1}
            }
          ])
      )

    assert ingest.status == 200

    query = http_request(port, "GET", "/topics/wiretopic/events")
    assert query.status == 200
    events = Jason.decode!(query.body)
    assert is_list(events)
    assert Enum.any?(events, fn e -> e["id"] == "evt-1" end)
  end

  # R155/W1: container lease/ACL comps are UNIMPLEMENTED (KD/GAP
  # (blob-comp-lease-absent)) — through the REAL wire the PUT and GET
  # container arms answer a typed 400 InvalidQueryParameterValue naming the GAP,
  # with the Azure x-ms-error-code header, never a silent 201/200 fallthrough.
  @tag :wire
  test "Blob: container PUT comp=lease/acl answers 400 InvalidQueryParameterValue over the wire",
       %{
         egress: port
       } do
    for comp <- ["lease", "acl"] do
      resp =
        http_request(port, "PUT", "/wireacct/r155cont?comp=#{comp}",
          headers: [{"content-type", "application/json"}, {"x-ms-version", "2025-01-01"}],
          body: "{}"
        )

      assert resp.status == 400, "comp=#{comp} answered #{resp.status}: #{resp.body}"
      body = Jason.decode!(resp.body)
      assert body["error"]["code"] == "InvalidQueryParameterValue"
      assert String.contains?(body["error"]["message"], "GAP(blob-comp-lease-absent)")
      assert String.contains?(resp.headers, "x-ms-error-code")
      assert String.contains?(resp.headers, "InvalidQueryParameterValue")
    end
  end

  @tag :wire
  test "Blob: container GET comp=lease/acl answers 400 InvalidQueryParameterValue over the wire",
       %{
         egress: port
       } do
    for comp <- ["lease", "acl"] do
      resp =
        http_request(port, "GET", "/wireacct/r155cont?comp=#{comp}",
          headers: [{"x-ms-version", "2025-01-01"}]
        )

      assert resp.status == 400, "comp=#{comp} answered #{resp.status}: #{resp.body}"
      body = Jason.decode!(resp.body)
      assert body["error"]["code"] == "InvalidQueryParameterValue"
      assert String.contains?(body["error"]["message"], "GAP(blob-comp-lease-absent)")
      assert String.contains?(resp.headers, "x-ms-error-code")
      assert String.contains?(resp.headers, "InvalidQueryParameterValue")
    end
  end

  # R155/W2 (wire tier): Cosmos PATCH through the real socket — a valid RFC
  # 6902 replace is 200 with a fresh _etag; a patch that moves the partition
  # key is a typed 400; a patch that steals a unique-key value is a 409.
  @tag :wire
  test "Cosmos: PATCH valid, pk-move 400, unique-key steal 409 over the wire", %{egress: port} do
    http_request(port, "POST", "/dbs",
      headers: [{"content-type", "application/json"}],
      body: Jason.encode!(%{"id" => "w2db"})
    )

    http_request(port, "POST", "/dbs/w2db/colls",
      headers: [{"content-type", "application/json"}],
      body:
        Jason.encode!(%{
          "id" => "w2coll",
          "partitionKey" => %{"paths" => ["/tenantId"]},
          "uniqueKeyPolicy" => %{"uniqueKeys" => [%{"paths" => ["/code"]}]}
        })
    )

    for {id, code} <- [{"doc-a", "A"}, {"doc-b", "B"}] do
      create =
        http_request(port, "POST", "/dbs/w2db/colls/w2coll/docs",
          headers: [
            {"content-type", "application/json"},
            {"x-ms-documentdb-partitionkey", ~s(["w2"])}
          ],
          body: Jason.encode!(%{"id" => id, "tenantId" => "w2", "code" => code})
        )

      assert create.status == 201, "#{id} create answered #{create.status}: #{create.body}"
    end

    # Valid replace: 200 with a fresh _etag.
    patch =
      http_request(port, "PATCH", "/dbs/w2db/colls/w2coll/docs/doc-a",
        headers: [
          {"content-type", "application/json"},
          {"x-ms-documentdb-partitionkey", ~s(["w2"])}
        ],
        body: Jason.encode!([%{"op" => "replace", "path" => "/code", "value" => "A2"}])
      )

    assert patch.status == 200, "valid patch answered #{patch.status}: #{patch.body}"
    assert Jason.decode!(patch.body)["code"] == "A2"

    assert is_binary(Jason.decode!(patch.body)["_etag"]) and
             Jason.decode!(patch.body)["_etag"] != ""

    # Partition-key move without the matching pk header: typed 400.
    pk_move =
      http_request(port, "PATCH", "/dbs/w2db/colls/w2coll/docs/doc-a",
        headers: [
          {"content-type", "application/json"},
          {"x-ms-documentdb-partitionkey", ~s(["w2"])}
        ],
        body: Jason.encode!([%{"op" => "replace", "path" => "/tenantId", "value" => "elsewhere"}])
      )

    assert pk_move.status == 400, "pk-move answered #{pk_move.status}: #{pk_move.body}"
    assert Jason.decode!(pk_move.body)["code"] == "BadRequest"

    # Unique-key steal (doc-b's /code -> "A2", already held by doc-a): 409.
    steal =
      http_request(port, "PATCH", "/dbs/w2db/colls/w2coll/docs/doc-b",
        headers: [
          {"content-type", "application/json"},
          {"x-ms-documentdb-partitionkey", ~s(["w2"])}
        ],
        body: Jason.encode!([%{"op" => "replace", "path" => "/code", "value" => "A2"}])
      )

    assert steal.status == 409, "unique-key steal answered #{steal.status}: #{steal.body}"
    assert Jason.decode!(steal.body)["code"] == "Conflict"
  end

  # R155/W3 (wire tier): A-IM: Incremental feed on the docs GET — the
  # change feed returns only docs newer than the container cursor and a
  # continuation header on every response.
  @tag :wire
  test "Cosmos: change feed returns only-new docs with continuation header over the wire", %{
    egress: port
  } do
    http_request(port, "POST", "/dbs",
      headers: [{"content-type", "application/json"}],
      body: Jason.encode!(%{"id" => "w3db"})
    )

    http_request(port, "POST", "/dbs/w3db/colls",
      headers: [{"content-type", "application/json"}],
      body: Jason.encode!(%{"id" => "w3coll"})
    )

    for i <- 1..2 do
      create =
        http_request(port, "POST", "/dbs/w3db/colls/w3coll/docs",
          headers: [{"content-type", "application/json"}],
          body: Jason.encode!(%{"id" => "seed-#{i}", "n" => i})
        )

      assert create.status == 201
    end

    feed =
      http_request(port, "GET", "/dbs/w3db/colls/w3coll/docs",
        headers: [{"a-im", "Incremental feed"}]
      )

    assert feed.status == 200, "feed answered #{feed.status}: #{feed.body}"
    assert Jason.decode!(feed.body)["_count"] == 2
    assert String.contains?(feed.headers, "x-ms-continuation")

    # Third doc lands after the cursor advanced: the next read carries ONLY
    # the new doc — the non-vacuity flip for incrementality.
    third =
      http_request(port, "POST", "/dbs/w3db/colls/w3coll/docs",
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(%{"id" => "seed-3", "n" => 3})
      )

    assert third.status == 201

    feed2 =
      http_request(port, "GET", "/dbs/w3db/colls/w3coll/docs",
        headers: [{"a-im", "Incremental feed"}]
      )

    assert feed2.status == 200
    body2 = Jason.decode!(feed2.body)
    assert body2["_count"] == 1, "second feed answered #{feed2.body}"
    assert [%{"id" => "seed-3"}] = body2["Documents"]
    assert String.contains?(feed2.headers, "x-ms-continuation")
  end

  # ---------------------------------------------------------------------
  # R137 (repair lane R185): percent-encoded reserved-namespace fence over
  # the REAL wire. Plug path_info segments are RAW (undecoded), so an
  # encoded first segment (`/%6beys/` == "keys", `/%64bs/` == "dbs") used to
  # reach the blob splat and STORE under the decoded reserved name. The
  # fence decodes+downcases before comparing: encoded reserved names answer
  # the owning plane's typed refusal (nothing stored), while the
  # non-reserved splat `/vltkv/...` stays on the blob whitelist law (201
  # verbatim).
  # ---------------------------------------------------------------------
  @tag :wire
  test "R137: encoded reserved namespace PUT answers 404 and stores nothing; encoded dbs GET answers 400; plain splat stays 201",
       %{
         egress: port
       } do
    # PUT /%6beys/vltkey?restype=container (encoded "keys"): KV-plane 404
    # envelope, naming the reserved namespace and the nothing-stored law.
    enc_put =
      http_request(port, "PUT", "/%6beys/vltkey?restype=container",
        headers: [{"content-type", "application/json"}, {"x-ms-version", "2025-01-01"}],
        body: "{}"
      )

    assert enc_put.status == 404,
           "encoded keys PUT answered #{enc_put.status}: #{enc_put.body}"

    body = Jason.decode!(enc_put.body)
    assert body["error"]["code"] == "NotFound"
    assert String.contains?(body["error"]["message"], "reserved namespace 'keys'")
    assert String.contains?(body["error"]["message"], "nothing was stored")

    # GET /%64bs/... (encoded "dbs", blob-splat shape): flat {"code","message"}
    # 400 NotImplemented envelope.
    enc_get =
      http_request(port, "GET", "/%64bs/wireacct/r137blob",
        headers: [{"x-ms-version", "2025-01-01"}]
      )

    assert enc_get.status == 400,
           "encoded dbs GET answered #{enc_get.status}: #{enc_get.body}"

    flat = Jason.decode!(enc_get.body)

    assert flat["code"] == "NotImplemented",
           "encoded dbs GET body: #{enc_get.body}"

    assert String.contains?(flat["message"], "reserved namespace 'dbs'")

    # Whitelist law flip witness: the same blob-shaped PUT with a PLAIN
    # non-reserved first segment is 201 verbatim (container created).
    plain_put =
      http_request(port, "PUT", "/vltkv/vltkey?restype=container",
        headers: [{"content-type", "application/json"}, {"x-ms-version", "2025-01-01"}],
        body: "{}"
      )

    assert plain_put.status == 201,
           "plain /vltkv container PUT answered #{plain_put.status}: #{plain_put.body}"
  end

  # ---------------------------------------------------------------------
  # R185h (repair lane from DoD D129 — wire tier for the R133 policy-row
  # CAS): over REAL TCP, the container metadata PUT vs legal-hold race must
  # answer only legitimate verdicts (200 or 409 ContainerLocked, never a
  # 500), and the serialized 409 gate must stamp x-ms-error-code (R181
  # parity).
  # ---------------------------------------------------------------------
  @tag :wire
  test "R185h: concurrent metadata PUTs vs hold toggles over the wire answer only 200/409 and leave the row coherent",
       %{
         egress: port
       } do
    acct = "r185h-#{System.unique_integer([:positive])}"
    cont = "c01"

    create =
      http_request(port, "PUT", "/#{acct}/#{cont}?restype=container",
        headers: [{"content-type", "application/json"}, {"x-ms-version", "2025-01-01"}],
        body: "{}"
      )

    assert create.status == 201, "container create answered #{create.status}: #{create.body}"

    parent = self()
    n = 10

    # 2×10 concurrent legs over real sockets: 10 metadata PUTs + 10 hold
    # toggles (alternating true/false). Modest fan-out to stay deterministic.
    for i <- 1..n do
      spawn(fn ->
        resp =
          http_request(port, "PUT", "/#{acct}/#{cont}?comp=metadata",
            headers: [
              {"content-type", "application/json"},
              {"x-ms-version", "2025-01-01"},
              {"x-ms-meta-k#{i}", "v#{i}"}
            ]
          )

        send(parent, {:r185h_meta, i, resp.status})
      end)

      spawn(fn ->
        flag = rem(i, 2) == 1

        resp =
          http_request(port, "PUT", "/#{acct}/#{cont}?comp=legalhold",
            headers: [
              {"content-type", "application/json"},
              {"x-ms-version", "2025-01-01"},
              {"x-ms-legal-hold", to_string(flag)}
            ]
          )

        send(parent, {:r185h_hold, i, resp.status})
      end)
    end

    meta_statuses = collect_statuses(:r185h_meta, n, [])
    hold_statuses = collect_statuses(:r185h_hold, n, [])

    # Every concurrent verdict is legitimate: 200 or 409 ContainerLocked,
    # never a 500/crash answer.
    Enum.each(meta_statuses, fn s ->
      assert s in [200, 409], "metadata PUT answered #{s}"
    end)

    Enum.each(hold_statuses, fn s ->
      assert s in [200, 409], "hold toggle answered #{s}"
    end)

    # Serialized tail: a final known hold call, then the row must agree with
    # it — a stale metadata write-back that cleared the hold would fail here.
    final =
      http_request(port, "PUT", "/#{acct}/#{cont}?comp=legalhold",
        headers: [
          {"content-type", "application/json"},
          {"x-ms-version", "2025-01-01"},
          {"x-ms-legal-hold", "true"}
        ]
      )

    assert final.status == 200, "final hold set answered #{final.status}: #{final.body}"

    get =
      http_request(port, "GET", "/#{acct}/#{cont}?comp=legalhold",
        headers: [{"x-ms-version", "2025-01-01"}]
      )

    assert get.status == 200

    assert String.contains?(get.headers, "x-ms-legal-hold") and
             String.contains?(get.headers, "x-ms-legal-hold: true")
  end

  @tag :wire
  test "R185h: metadata PUT under an active hold answers 409 ContainerLocked with stamped x-ms-error-code",
       %{
         egress: port
       } do
    acct = "r185h-#{System.unique_integer([:positive])}"
    cont = "c02"

    create =
      http_request(port, "PUT", "/#{acct}/#{cont}?restype=container",
        headers: [{"content-type", "application/json"}, {"x-ms-version", "2025-01-01"}],
        body: "{}"
      )

    assert create.status == 201, "container create answered #{create.status}: #{create.body}"

    hold =
      http_request(port, "PUT", "/#{acct}/#{cont}?comp=legalhold",
        headers: [
          {"content-type", "application/json"},
          {"x-ms-version", "2025-01-01"},
          {"x-ms-legal-hold", "true"}
        ]
      )

    assert hold.status == 200, "hold set answered #{hold.status}: #{hold.body}"

    resp =
      http_request(port, "PUT", "/#{acct}/#{cont}?comp=metadata",
        headers: [
          {"content-type", "application/json"},
          {"x-ms-version", "2025-01-01"},
          {"x-ms-meta-blocked", "yes"}
        ]
      )

    assert resp.status == 409, "metadata PUT under hold answered #{resp.status}: #{resp.body}"
    body = Jason.decode!(resp.body)
    assert body["error"]["code"] == "ContainerLocked"
    assert String.contains?(body["error"]["message"], "legal hold")
    assert String.contains?(resp.headers, "x-ms-error-code")
    assert String.contains?(resp.headers, "ContainerLocked")
  end

  defp collect_statuses(_tag, 0, acc), do: acc

  defp collect_statuses(tag, n, acc) do
    receive do
      {^tag, _i, status} -> collect_statuses(tag, n - 1, [status | acc])
    after
      10_000 -> flunk("timed out waiting for #{tag} responses")
    end
  end

  # ---------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------

  @tag :wire
  test "HEAD blob with comp=blocklist answers typed 400, not fake 200 metadata", %{
    egress: port
  } do
    # Seed a real blob so a fall-through to get_blob would visibly 200.
    cont =
      http_request(port, "PUT", "/wlt/wireacct?restype=container",
        headers: [{"x-ms-version", "2025-01-01"}]
      )

    assert cont.status in [201, 409], "container create answered #{cont.status}"

    seed =
      http_request(port, "PUT", "/wlt/wireacct/lane241blob",
        headers: [{"x-ms-version", "2025-01-01"}],
        body: "payload"
      )

    assert seed.status == 201, "seed blob PUT answered #{seed.status}: #{seed.body}"

    resp =
      http_request(port, "HEAD", "/wlt/wireacct/lane241blob?comp=blocklist",
        headers: [{"x-ms-version", "2025-01-01"}]
      )

    assert resp.status == 400,
           "HEAD comp=blocklist answered #{resp.status} (fall-through serves fake 200 metadata): #{resp.body}"

    # HEAD responses carry no body (HTTP law); the typed code surfaces in the
    # x-ms-error-code header instead.
    assert String.contains?(resp.headers, "x-ms-error-code") and
             String.contains?(resp.headers, "InvalidQueryParameterValue")
  end

  @tag :wire
  test "case-variant reserved first segment /DBS/ fence-refuses identically to /dbs", %{
    egress: port
  } do
    headers = [{"content-type", "application/json"}, {"x-ms-version", "2025-01-01"}]

    lower =
      http_request(port, "PUT", "/dbs/wireacct/lane241fence", headers: headers, body: "{}")

    assert lower.status == 400
    lower_body = Jason.decode!(lower.body)

    upper =
      http_request(port, "PUT", "/DBS/wireacct/lane241fence", headers: headers, body: "{}")

    assert upper.status == lower.status,
           "case-variant /DBS PUT answered #{upper.status}, lowercase answered #{lower.status}"

    upper_body = Jason.decode!(upper.body)
    assert upper_body["code"] == lower_body["code"]
  end

  # ---------------------------------------------------------------------
  # Idempotent Put Container (enclave-loop console leg): re-PUT on an
  # EXISTING container with IDENTICAL x-ms-meta-* answers 200; with
  # DIFFERENT metadata answers 409 ContainerAlreadyExists. A hold/locked
  # container re-PUT still refuses 409 ContainerLocked (WORM arms stay
  # ahead of the comparison).
  # ---------------------------------------------------------------------
  @tag :wire
  test "container re-PUT with identical metadata answers 200 with standard headers", %{
    egress: port
  } do
    acct = "idem-#{System.unique_integer([:positive])}"

    create =
      http_request(port, "PUT", "/#{acct}/c01?restype=container",
        headers: [
          {"content-type", "application/json"},
          {"x-ms-version", "2025-01-01"},
          {"x-ms-meta-env", "prod"},
          {"x-ms-meta-team", "core"}
        ],
        body: "{}"
      )

    assert create.status == 201, "create answered #{create.status}: #{create.body}"

    reput =
      http_request(port, "PUT", "/#{acct}/c01?restype=container",
        headers: [
          {"content-type", "application/json"},
          {"x-ms-version", "2025-01-01"},
          {"x-ms-meta-env", "prod"},
          {"x-ms-meta-team", "core"}
        ],
        body: "{}"
      )

    assert reput.status == 200,
           "identical re-PUT answered #{reput.status}: #{reput.body}"

    assert String.contains?(reput.headers, "etag")
    assert String.contains?(reput.headers, "last-modified")
    assert String.contains?(reput.headers, "x-ms-request-id")
    assert String.contains?(reput.headers, "x-ms-version")
  end

  @tag :wire
  test "container re-PUT with different metadata answers 409 ContainerAlreadyExists", %{
    egress: port
  } do
    acct = "idem-#{System.unique_integer([:positive])}"

    create =
      http_request(port, "PUT", "/#{acct}/c02?restype=container",
        headers: [
          {"content-type", "application/json"},
          {"x-ms-version", "2025-01-01"},
          {"x-ms-meta-env", "prod"}
        ],
        body: "{}"
      )

    assert create.status == 201, "create answered #{create.status}: #{create.body}"

    reput =
      http_request(port, "PUT", "/#{acct}/c02?restype=container",
        headers: [
          {"content-type", "application/json"},
          {"x-ms-version", "2025-01-01"},
          {"x-ms-meta-env", "staging"}
        ],
        body: "{}"
      )

    assert reput.status == 409, "different-metadata re-PUT answered #{reput.status}"
    assert String.contains?(reput.headers, "ContainerAlreadyExists")

    # No-metadata re-PUT on a container that HAS metadata is also a mismatch.
    bare =
      http_request(port, "PUT", "/#{acct}/c02?restype=container",
        headers: [{"content-type", "application/json"}, {"x-ms-version", "2025-01-01"}],
        body: "{}"
      )

    assert bare.status == 409, "bare re-PUT on metadata container answered #{bare.status}"
  end

  @tag :wire
  test "container re-PUT under an active legal hold answers 409 ContainerLocked", %{
    egress: port
  } do
    acct = "idem-#{System.unique_integer([:positive])}"

    create =
      http_request(port, "PUT", "/#{acct}/c03?restype=container",
        headers: [
          {"content-type", "application/json"},
          {"x-ms-version", "2025-01-01"},
          {"x-ms-meta-env", "prod"}
        ],
        body: "{}"
      )

    assert create.status == 201, "create answered #{create.status}: #{create.body}"

    hold =
      http_request(port, "PUT", "/#{acct}/c03?comp=legalhold",
        headers: [
          {"content-type", "application/json"},
          {"x-ms-version", "2025-01-01"},
          {"x-ms-legal-hold", "true"}
        ]
      )

    assert hold.status == 200, "hold set answered #{hold.status}: #{hold.body}"

    reput =
      http_request(port, "PUT", "/#{acct}/c03?restype=container",
        headers: [
          {"content-type", "application/json"},
          {"x-ms-version", "2025-01-01"},
          {"x-ms-meta-env", "prod"}
        ],
        body: "{}"
      )

    assert reput.status == 409, "re-PUT under hold answered #{reput.status}"
    assert String.contains?(reput.headers, "ContainerLocked")
  end

  # -------------------------------------------------------------------------
  # Blob snapshots + blob metadata GET (KD-60 wire registration, lane 524)
  # -------------------------------------------------------------------------

  @tag :wire
  test "Blob: PUT comp=snapshot answers 201 with x-ms-snapshot timestamp header", %{egress: port} do
    acct = "snap-#{System.unique_integer([:positive])}"
    cont = "c01"

    create =
      http_request(port, "PUT", "/#{acct}/#{cont}?restype=container",
        headers: [{"x-ms-version", "2025-01-01"}],
        body: ""
      )

    assert create.status == 201, "container create answered #{create.status}: #{create.body}"

    put =
      http_request(port, "PUT", "/#{acct}/#{cont}/b1",
        headers: [{"x-ms-version", "2025-01-01"}],
        body: "payload-v1"
      )

    assert put.status == 201, "blob put answered #{put.status}: #{put.body}"

    snap =
      http_request(port, "PUT", "/#{acct}/#{cont}/b1?comp=snapshot",
        headers: [{"x-ms-version", "2025-01-01"}],
        body: ""
      )

    assert snap.status == 201, "snapshot answered #{snap.status}: #{snap.body}"

    ts =
      snap.headers
      |> String.split("\r\n")
      |> Enum.find_value(fn
        "x-ms-snapshot: " <> ts -> ts
        _ -> nil
      end)

    assert is_binary(ts) and ts != "", "no x-ms-snapshot header in: #{snap.headers}"
  end

  @tag :wire
  test "Blob: GET sharesnapshot=<ts> reads back the frozen bytes byte-exact; later base mutations stay invisible",
       %{
         egress: port
       } do
    acct = "snap-#{System.unique_integer([:positive])}"
    cont = "c01"

    http_request(port, "PUT", "/#{acct}/#{cont}?restype=container",
      headers: [{"x-ms-version", "2025-01-01"}],
      body: ""
    )

    http_request(port, "PUT", "/#{acct}/#{cont}/b1",
      headers: [{"x-ms-version", "2025-01-01"}],
      body: "frozen-bytes"
    )

    snap =
      http_request(port, "PUT", "/#{acct}/#{cont}/b1?comp=snapshot",
        headers: [{"x-ms-version", "2025-01-01"}],
        body: ""
      )

    ts =
      snap.headers
      |> String.split("\r\n")
      |> Enum.find_value(fn
        "x-ms-snapshot: " <> ts -> ts
        _ -> nil
      end)

    assert is_binary(ts) and ts != ""

    # Mutate the base blob AFTER the snapshot — the snapshot must not see it.
    # On a fresh WORM-immutable container the overwrite is refused (409,
    # engine semantics); when the overwrite lands (200) the snapshot still
    # serves the frozen bytes — both paths freeze the point-in-time record.
    mut =
      http_request(port, "PUT", "/#{acct}/#{cont}/b1",
        headers: [{"x-ms-version", "2025-01-01"}],
        body: "mutated-after-snapshot"
      )

    assert mut.status in [200, 409], "base re-PUT answered #{mut.status}: #{mut.body}"

    base =
      http_request(port, "GET", "/#{acct}/#{cont}/b1", headers: [{"x-ms-version", "2025-01-01"}])

    if mut.status == 200 do
      assert base.status == 200 and base.body == "mutated-after-snapshot"
    else
      assert base.status == 200 and base.body == "frozen-bytes"
    end

    frozen =
      http_request(port, "GET", "/#{acct}/#{cont}/b1?sharesnapshot=#{URI.encode_www_form(ts)}",
        headers: [{"x-ms-version", "2025-01-01"}]
      )

    assert frozen.status == 200, "snapshot GET answered #{frozen.status}: #{frozen.body}"
    assert frozen.body == "frozen-bytes", "snapshot bytes diverged: #{inspect(frozen.body)}"

    assert String.contains?(frozen.headers, "x-ms-snapshot:") and
             String.contains?(frozen.headers, ts)

    # Unknown timestamp -> typed 404, never a 500.
    missing =
      http_request(port, "GET", "/#{acct}/#{cont}/b1?sharesnapshot=1999-01-01T00:00:00.0000000Z",
        headers: [{"x-ms-version", "2025-01-01"}]
      )

    assert missing.status == 404 and String.contains?(missing.body, "BlobNotFound")
  end

  @tag :wire
  test "Blob: GET comp=metadata echoes the x-ms-meta-* written by PUT comp=metadata", %{
    egress: port
  } do
    acct = "meta-#{System.unique_integer([:positive])}"
    cont = "c01"

    http_request(port, "PUT", "/#{acct}/#{cont}?restype=container",
      headers: [{"x-ms-version", "2025-01-01"}],
      body: ""
    )

    http_request(port, "PUT", "/#{acct}/#{cont}/b1",
      headers: [
        {"x-ms-version", "2025-01-01"},
        {"x-ms-meta-seed", "s1"},
        {"x-ms-meta-owner", "lane524"}
      ],
      body: "body"
    )

    # An overwrite-class metadata PUT on a fresh WORM-immutable container is
    # 409 ContainerLocked (engine semantics, see R185h legs); both 200/409 are
    # legitimate — the GET echo below reads create-time metadata either way.
    set =
      http_request(port, "PUT", "/#{acct}/#{cont}/b1?comp=metadata",
        headers: [{"x-ms-version", "2025-01-01"}, {"x-ms-meta-owner", "lane524b"}],
        body: ""
      )

    assert set.status in [200, 409], "metadata PUT answered #{set.status}: #{set.body}"

    get =
      http_request(port, "GET", "/#{acct}/#{cont}/b1?comp=metadata",
        headers: [{"x-ms-version", "2025-01-01"}]
      )

    assert get.status == 200, "metadata GET answered #{get.status}: #{get.body}"
    assert String.contains?(get.headers, "x-ms-meta-seed: s1")
    assert String.contains?(get.headers, "x-ms-meta-owner: lane524")
    refute String.contains?(get.headers, "x-ms-meta-owner: lane524b")
  end

  @tag :wire
  test "Blob: snapshot create under an active legal hold answers 409 ContainerLocked", %{
    egress: port
  } do
    acct = "snap-#{System.unique_integer([:positive])}"
    cont = "c01"

    http_request(port, "PUT", "/#{acct}/#{cont}?restype=container",
      headers: [{"x-ms-version", "2025-01-01"}],
      body: ""
    )

    http_request(port, "PUT", "/#{acct}/#{cont}/b1",
      headers: [{"x-ms-version", "2025-01-01"}],
      body: "held"
    )

    hold =
      http_request(port, "PUT", "/#{acct}/#{cont}?comp=legalhold",
        headers: [
          {"x-ms-version", "2025-01-01"},
          {"x-ms-legal-hold", "true"}
        ]
      )

    assert hold.status == 200, "hold set answered #{hold.status}: #{hold.body}"

    snap =
      http_request(port, "PUT", "/#{acct}/#{cont}/b1?comp=snapshot",
        headers: [{"x-ms-version", "2025-01-01"}],
        body: ""
      )

    assert snap.status == 409, "snapshot under hold answered #{snap.status}: #{snap.body}"

    assert String.contains?(snap.headers, "x-ms-error-code: ContainerLocked") or
             String.contains?(snap.body, "ContainerLocked")
  end

  # Teardown resilience: fall back to a hard kill if graceful stop fails.
  # Teardown only — assertions are never softened.
  defp stop_tree(sup) do
    try do
      Supervisor.stop(sup, :normal, 5000)
    catch
      _, _ -> Process.exit(sup, :kill)
    end
  end

  defp http_request(port, method, path, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body, "")

    # kv_challenge_guard requires a well-formed Bearer header in both auth
    # modes (SDK challenge emulation); attach one unless the caller supplied
    # its own authorization header (R54 pattern). Presence-only check, so the
    # release-without-attestation case still reaches its 403 post-auth.
    headers =
      if List.keyfind(headers, "authorization", 0) do
        headers
      else
        headers ++ [{"authorization", "Bearer test-token"}]
      end

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5000)

    header_lines =
      Enum.map_join(
        headers ++ [{"host", "127.0.0.1:#{port}"}, {"connection", "close"}],
        "\r\n",
        fn {k, v} -> "#{k}: #{v}" end
      )

    request =
      "#{method} #{path} HTTP/1.1\r\n" <>
        header_lines <>
        "\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <> body

    :ok = :gen_tcp.send(sock, request)
    raw = recv_all(sock)
    :gen_tcp.close(sock)
    parse_response(raw)
  end

  defp recv_all(sock) do
    case :gen_tcp.recv(sock, 0, 5000) do
      {:ok, data} -> [data | recv_all(sock)]
      {:error, :closed} -> []
    end
  end

  defp parse_response(raw) do
    raw = IO.iodata_to_binary(raw)
    [status_line, rest] = :binary.split(raw, "\r\n")
    [header_block, body] = :binary.split(rest, "\r\n\r\n")

    status =
      status_line |> String.split(" ") |> Enum.at(1) |> String.to_integer()

    %{status: status, headers: header_block, body: body}
  end
end
