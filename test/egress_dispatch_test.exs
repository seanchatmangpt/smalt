defmodule EgressDispatchTest do
  use ExUnit.Case
  use Plug.Test

  alias Smalt.DataPlane.Cosmos
  alias Smalt.EgressRouter
  alias Smalt.Store

  @opts EgressRouter.init([])

  setup do
    # Other suites stop the main app tree to run private trees; never assume
    # module run order — restore the shared app if the Store is gone.
          SmaltTest.Lifecycle.ensure_store_up()

    Store.clear()
    :ok
  end

  defp call(method, path, opts \\ []) do
    body = opts[:body] || %{}

    headers =
      if is_list(body) do
        [{"content-type", "application/json"} | opts[:headers] || []]
      else
        opts[:headers] || []
      end

    # KD-15 (v26.10.15): /keys is challenge-guarded mode-blind — a tokenless
    # request now 401s with the enriched WWW-Authenticate BEFORE dispatch.
    # This harness speaks for an already-challenged client: attach a
    # placeholder token on /keys calls unless the test supplies its own
    # Authorization header (the KD-15 courts below pass headers explicitly).
    headers =
      if String.starts_with?(path, "/keys") and
           not Enum.any?(headers, fn {k, _} -> k == "authorization" end) and
           # X-10 integration unblock (cross-lane merge artifact with the SKR
           # legacy-header lane): a call carrying the legacy SKR attestation
           # header speaks for the legacy path — do NOT overwrite it with the
           # placeholder bearer, or the legacy-header court 403s in the SKR
           # release handler.
           not Enum.any?(headers, fn {k, _} -> k == "x-ms-compliance-status" end) do
        [{"authorization", "Bearer egress-harness-challenged-client"} | headers]
      else
        headers
      end

    body = if is_list(body), do: Jason.encode!(body), else: body

    conn = conn(method, path, body)

    conn =
      Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

    EgressRouter.call(conn, @opts)
  end

  defp loaded?(mod), do: Code.ensure_loaded?(mod)

  # ---------------------------------------------------------------------------
  # Dispatch table hits real modules where compiled
  # ---------------------------------------------------------------------------

  test "attestation dispatch hits Smalt.Security.Attestation" do
    if loaded?(Smalt.Security.Attestation) do
      measurement = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

      Store.put(:smalt_attestation_baseline, measurement, measurement)

      conn = call(:post, "/attest/sevsnpvm", body: %{"measurement" => measurement})

      assert conn.status == 200
      %{"token" => token, "claims" => claims} = Jason.decode!(conn.resp_body)
      assert is_binary(token)
      assert claims["x-ms-compliance-status"] == "azure-compliant-cvm"
    end
  end

  test "ledger append/get/list/latest hits Smalt.Security.ConfidentialLedger" do
    if loaded?(Smalt.Security.ConfidentialLedger) do
      # ledger_enforce_existence fence: pinned explicitly (the security
      # suite's restore deletes the env, order-masking config/test.exs).
      prior = Application.get_env(:smalt, :ledger_enforce_existence)
      Application.put_env(:smalt, :ledger_enforce_existence, true)

      # A cold append answers the typed 404-class envelope (dispatch fence
      # for the ledger-writer lane's {:error, 400/404, code} tuples); an
      # explicit creation marker then admits the append.
      cold = call(:post, "/app/transactions", body: %{"data" => "a"})
      assert cold.status == 404
      assert Jason.decode!(cold.resp_body)["error"]["code"] == "LedgerNotFound"

      Store.put(:smalt_ledger_meta, {:created, "default_ledger"}, true)
      if prior == nil, do: Application.delete_env(:smalt, :ledger_enforce_existence),
        else: Application.put_env(:smalt, :ledger_enforce_existence, prior)

      conn = call(:post, "/app/transactions", body: %{"data" => "a"})

      assert conn.status == 201
      receipt = Jason.decode!(conn.resp_body)
      assert %{"transactionId" => tx_id} = receipt

      conn = call(:get, "/app/transactions/#{tx_id}")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["transactionId"] == tx_id

      conn = call(:get, "/app/transactions/latest")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["transactionId"] == tx_id

      conn = call(:get, "/app/transactions")
      assert conn.status == 200
      assert [%{"transactionId" => ^tx_id}] = Jason.decode!(conn.resp_body)
    end
  end

  test "cosmos dispatch hits Smalt.DataPlane.Cosmos" do
    if loaded?(Smalt.DataPlane.Cosmos) do
      conn =
        call(:post, "/dbs/db1/colls/c1/docs", body: %{"id" => "d1", "v" => 1})
        |> then(fn c ->
          assert c.status == 201
          assert get_resp_header(c, "x-ms-request-charge") != []
          c
        end)

      doc = Jason.decode!(conn.resp_body)
      assert doc["id"] == "d1"

      conn = call(:get, "/dbs/db1/colls/c1/docs/d1")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["_etag"] == doc["_etag"]

      conn = call(:get, "/dbs/db1/colls/c1/docs")
      assert conn.status == 200
      assert %{"Documents" => [%{"id" => "d1"}], "_count" => 1} = Jason.decode!(conn.resp_body)

      etag = doc["_etag"]

      conn = call(:put, "/dbs/db1/colls/c1/docs/d1", body: %{"v" => 2}, headers: [{"if-match", etag}])
      assert conn.status == 200

      etag2 = Jason.decode!(conn.resp_body)["_etag"]

      conn =
        call(:delete, "/dbs/db1/colls/c1/docs/d1", headers: [{"if-match", etag2}])

      assert conn.status == 204
    end
  end

  test "sentinel ingest + query dispatch hits Smalt.DataPlane.Sentinel" do
    if loaded?(Smalt.DataPlane.Sentinel) do
      conn =
        call(:post, "/dataCollectionRules/dcr-1/streams/Custom-Table?api-version=2023-01-01",
          body: [%{"msg" => "hi"}]
        )

      # Real Logs Ingestion API shape (C7-3a CONFORMANT): 204 No Content with
      # x-ms-request-id; the legacy 200 {"ingestionStatus":"Accepted"} envelope
      # is gone from the wire.
      assert conn.status == 204
      assert conn.resp_body == ""
      assert get_resp_header(conn, "x-ms-request-id") != []

      conn =
        call(:post, "/v1/workspaces/ws-1/query?api-version=2023-01-01", body: %{"query" => "MyTable | take 10"})

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["tables"]
    end
  end

  test "resource graph dispatch hits Smalt.DataPlane.ResourceGraph" do
    if loaded?(Smalt.DataPlane.ResourceGraph) do
      conn =
        call(:post, "/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01",
          body: %{"query" => "Resources"}
        )

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["totalRecords"] == 0
    end
  end

  test "purview dispatch hits Smalt.DataPlane.Purview" do
    if loaded?(Smalt.DataPlane.Purview) do
      conn = call(:post, "/atlas/v2/entity", body: %{"typeName" => "azure_dataset"})

      assert conn.status == 201
      %{"guid" => guid} = Jason.decode!(conn.resp_body)

      conn = call(:get, "/atlas/v2/entity/guid/#{guid}")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["guid"] == guid

      conn = call(:get, "/atlas/v2/lineage/both/#{guid}")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["baseEntityGuid"] == guid
    end
  end

  test "event stream dispatch hits Smalt.Messaging.EventStream" do
    if loaded?(Smalt.Messaging.EventStream) do
      conn =
        call(:post, "/topics/t1/events", body: [
          %{
            "specversion" => "1.0",
            "type" => "smalt.test",
            "source" => "/smalt",
            "id" => "e1",
            "data" => %{}
          }
        ])

      assert conn.status == 200

      conn = call(:get, "/topics/t1/events")
      assert conn.status == 200
      assert length(Jason.decode!(conn.resp_body)) >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # SKR authorization paths
  # ---------------------------------------------------------------------------

  test "SKR: bearer MAA JWT authorizes release" do
    if loaded?(Smalt.Security.Attestation) do
      measurement = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      Store.put(:smalt_attestation_baseline, measurement, measurement)

      {:ok, token, _claims} =
        Smalt.Security.Attestation.attest_enclave(%{"measurement" => measurement})

      call(:post, "/keys/skr-key/create",
        body: %{"kty" => "RSA-HSM", "release_policy" => %{"claim" => "azure-compliant-cvm"}}
      )

      conn =
        call(:post, "/keys/skr-key/release?api-version=7.4", headers: [{"authorization", "Bearer " <> token}])

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["status"] == "Released"
    end
  end

  test "SKR: legacy raw header refused when skr_allow_legacy_header disabled" do
    Application.put_env(:smalt, :skr_allow_legacy_header, false)

    call(:post, "/keys/legacy-key/create",
      body: %{"kty" => "RSA-HSM", "release_policy" => %{"claim" => "azure-compliant-cvm"}}
    )

    conn =
      call(:post, "/keys/legacy-key/release?api-version=7.4",
        headers: [{"x-ms-compliance-status", "azure-compliant-cvm"}]
      )

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "UnauthorizedAttestation"
  after
    Application.put_env(:smalt, :skr_allow_legacy_header, true)
  end

  test "SKR: legacy raw header honored when skr_allow_legacy_header enabled" do
    Application.put_env(:smalt, :skr_allow_legacy_header, true)

    call(:post, "/keys/legacy-key2/create",
      body: %{"kty" => "RSA-HSM", "release_policy" => %{"claim" => "azure-compliant-cvm"}}
    )

    conn =
      call(:post, "/keys/legacy-key2/release?api-version=7.4",
        headers: [{"x-ms-compliance-status", "azure-compliant-cvm"}]
      )

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["status"] == "Released"
  end

  test "SKR: bogus bearer token refused 403" do
    call(:post, "/keys/bogus-key/create",
      body: %{"kty" => "RSA-HSM", "release_policy" => %{"claim" => "azure-compliant-cvm"}}
    )

    conn =
      call(:post, "/keys/bogus-key/release?api-version=7.4", headers: [{"authorization", "Bearer not.a.jwt"}])

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["claim"] == nil
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "UnauthorizedAttestation"
  end

  # ---------------------------------------------------------------------------
  # Lane 19 (v26.10.14) egress-security sweep fences
  # ---------------------------------------------------------------------------

  test "lane 19 item 1: SKR release 200 carries no blob-plane headers" do
    call(:post, "/keys/lane19-key/create",
      body: %{"kty" => "RSA-HSM", "release_policy" => %{"claim" => "azure-compliant-cvm"}}
    )

    conn =
      call(:post, "/keys/lane19-key/release?api-version=7.4",
        headers: [{"x-ms-compliance-status", "azure-compliant-cvm"}]
      )

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["status"] == "Released"
    # F5 law: the KV envelope must not see blob-plane headers. Asserted absent,
    # not merely unpinned.
    assert get_resp_header(conn, "x-ms-request-id") == []
    assert get_resp_header(conn, "x-ms-version") == []
  end

  test "lane 19 item 1b: SKR release error envelope also stays blob-header-free" do
    conn = call(:post, "/keys/lane19-missing-key/release?api-version=7.4")

    assert conn.status == 404
    assert get_resp_header(conn, "x-ms-request-id") == []
    assert get_resp_header(conn, "x-ms-version") == []
  end

  # R143 (GAP S8): real AKV requires ?api-version=7.x on SKR release; a
  # missing/wrong version is a typed 400 InvalidApiVersion, not a 403/404.
  test "R143 S8: SKR release without api-version -> typed 400 InvalidApiVersion" do
    call(:post, "/keys/r143-s8/create",
      body: %{"kty" => "RSA-HSM", "release_policy" => %{"claim" => "azure-compliant-cvm"}}
    )

    conn = call(:post, "/keys/r143-s8/release", headers: [{"x-ms-compliance-status", "azure-compliant-cvm"}])

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidApiVersion"
  end

  # R143 (GAP D8, repaired R173): the real azure-monitor-query client sends
  # /v1/workspaces/:id/query with NO api-version param (v1-in-path is the
  # version discriminator) — absence must be accepted. An explicitly-wrong
  # value is still rejected (typed 400 InvalidApiVersion).
  test "R143 D8: KQL query without api-version accepted; wrong value -> typed 400" do
    # R182 repair (DoD lane D141): the Sentinel module always compiles in this
    # suite, so the gate contract is asserted unconditionally — absence of
    # api-version is ACCEPTED (hard 200), never the soft `in [200, 400]` dodge.
    conn = call(:post, "/v1/workspaces/ws-r143/query", body: %{"query" => "MyTable | take 1"})

    assert conn.status == 200

    bad =
      call(:post, "/v1/workspaces/ws-r143/query?api-version=1999-01-01",
        body: %{"query" => "MyTable | take 1"}
      )

    assert bad.status == 400
    assert Jason.decode!(bad.resp_body)["error"]["code"] == "InvalidApiVersion"
  end

  test "lane 19 item 3: ResourceGraph string subscriptions -> typed 400 InvalidParameter" do
    conn =
      call(:post, "/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01",
        body: %{"subscriptions" => "sub-1"}
      )

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidParameter"
  end

  test "lane 19 item 3: ResourceGraph map subscriptions -> typed 400 InvalidParameter" do
    conn =
      call(:post, "/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01",
        body: %{"subscriptions" => %{"a" => 1}}
      )

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidParameter"
  end

  test "lane 19 item 3: list subscriptions still query normally (no regression)" do
    conn =
      call(:post, "/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01",
        body: %{"subscriptions" => ["sub-a"]}
      )

    assert conn.status == 200
    assert is_map(Jason.decode!(conn.resp_body))
  end

  test "lane 19 item 5: GET /keys 200 shape preserved through the total arms" do
    conn = call(:get, "/keys")

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_map(body)
  end

  test "lane 19 item 6: CORS default answers allow-origin *" do
    conn = call(:get, "/keys", headers: [{"origin", "https://x.example"}])

    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  after
    Application.delete_env(:smalt, :egress_cors_origins)
  end

  test "lane 19 item 6: configured CORS allowlist admits listed, refuses unlisted" do
    Application.put_env(:smalt, :egress_cors_origins, ["https://allowed.example"])

    listed = call(:get, "/keys", headers: [{"origin", "https://allowed.example"}])
    unlisted = call(:get, "/keys", headers: [{"origin", "https://evil.example"}])

    assert get_resp_header(listed, "access-control-allow-origin") == ["https://allowed.example"]
    assert get_resp_header(unlisted, "access-control-allow-origin") == []
  after
    Application.delete_env(:smalt, :egress_cors_origins)
  end

  # ---------------------------------------------------------------------------
  # Lens 3 cycle 1 — fence ledger lens-3's validate_release_policy/1 landing:
  # malformed release_policy bodies through POST /keys/:name/create must reach
  # the wire as typed 400 InvalidParameter, never a 500. Also fences the
  # blob_error/3 F5 helper (x-ms-request-id + x-ms-version on error responses).
  # ---------------------------------------------------------------------------

  test "KV create: release_policy as JSON scalar is a typed 400, never a 500" do
    for scalar <- ["release", 7, true, []] do
      conn =
        call(:post, "/keys/pol-scalar/create",
          body: %{"kty" => "RSA-HSM", "release_policy" => scalar}
        )

      assert conn.status == 400,
             "release_policy #{inspect(scalar)} answered #{conn.status}: #{conn.resp_body}"

      assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidParameter"
    end
  end

  test "KV create: policy map with no claim and no ops list is a typed 400" do
    conn =
      call(:post, "/keys/pol-empty/create",
        body: %{"kty" => "RSA-HSM", "release_policy" => %{"version" => "1.0"}}
      )

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidParameter"
  end

  test "KV create: allowed_operations list admits; nested claim admits" do
    for policy <- [
          %{"allowed_operations" => ["release", "export"]},
          %{"allowedOperations" => ["release"]},
          %{"anyOf" => [%{"claim" => "azure-compliant-cvm", "equals" => "true"}]}
        ] do
      conn =
        call(:post, "/keys/pol-ok/create",
          body: %{"kty" => "RSA-HSM", "release_policy" => policy}
        )

      assert conn.status == 200,
             "policy #{inspect(policy)} answered #{conn.status}: #{conn.resp_body}"

      assert Jason.decode!(conn.resp_body)["release_policy"] == policy
      assert Jason.decode!(conn.resp_body)["attributes"]["exportable"] == true
    end
  end

  test "KV create: nested non-claim policy structure is a typed 400" do
    conn =
      call(:post, "/keys/pol-nested/create",
        body: %{
          "kty" => "RSA-HSM",
          "release_policy" => %{"anyOf" => [%{"version" => "1.0", "contentType" => "SKR"}]}
        }
      )

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidParameter"
  end

  test "KV create: nil release_policy stays admitted with exportable false" do
    conn = call(:post, "/keys/pol-nil/create", body: %{"kty" => "oct-HSM"})

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["release_policy"] == nil
    assert body["attributes"]["exportable"] == false
  end

  test "KV create: non-list allowed_operations is a typed 400" do
    conn =
      call(:post, "/keys/pol-badops/create",
        body: %{"kty" => "RSA-HSM", "release_policy" => %{"allowed_operations" => "release"}}
      )

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidParameter"
  end

  # ---------------------------------------------------------------------------
  # Lens 3 cycle 4 — registry sweep: unfenced dispatch seams (route table vs
  # probe coverage across my three suites). Each gets a wire probe.
  # ---------------------------------------------------------------------------

  test "KV versions route dispatches to list_versions with typed 404" do
    conn = call(:get, "/keys/no-such-key/versions")

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "KeyNotFound"
    assert get_resp_header(conn, "x-ms-version") == ["2021-12-02"]
  end

  test "KV versions: created key lists under /keys/:name/versions" do
    call(:post, "/keys/ver-key/create", body: %{"kty" => "oct-HSM"})
    conn = call(:get, "/keys/ver-key/versions")

    assert conn.status == 200
    assert [%{"kid" => kid}] = Jason.decode!(conn.resp_body)["value"]
    assert kid =~ "/keys/ver-key"

    created = call(:get, "/keys/ver-key")
    assert Jason.decode!(created.resp_body)["kid"] =~ "ver-key"
  end

  test "pkranges feed: first fetch 200 + etag, matching If-None-Match 304" do
    conn = call(:get, "/dbs/db3/colls/c3/pkranges")

    assert conn.status == 200
    assert get_resp_header(conn, "etag") == ["\"smalt-pkranges-v1\""]
    assert Jason.decode!(conn.resp_body)["_count"] == 1

    conn304 = call(:get, "/dbs/db3/colls/c3/pkranges", headers: [{"if-none-match", "\"smalt-pkranges-v1\""}])
    assert conn304.status == 304
  end

  test "atlas relationship: typed 400 when end1/end2 guids missing" do
    conn = call(:post, "/atlas/v2/relationship", body: %{"relationship" => %{"typeName" => "x"}})

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "ATLAS-400-00-001"
  end

  test "atlas relationship: happy path mints a lineage edge (201, guid)" do
    conn =
      call(:post, "/atlas/v2/relationship",
        body: %{
          "relationship" => %{
            "end1" => %{"guid" => "g-from"},
            "end2" => %{"guid" => "g-to"},
            "typeName" => "smalt_lineage"
          }
        }
      )

    assert conn.status == 201
    %{"guid" => guid} = Jason.decode!(conn.resp_body)
    assert is_binary(guid)

    lineage = call(:get, "/atlas/v2/lineage/both/g-from")
    assert lineage.status == 200
  end

  test "atlas entity/bulk dispatches (empty batch admits 201)" do
    conn = call(:post, "/atlas/v2/entity/bulk", body: %{"entities" => []})

    assert conn.status == 201
    assert is_map(Jason.decode!(conn.resp_body))
  end

  test "blob delete: 404 BlobNotFound with F5 headers on unknown blob" do
    conn =
      call(:delete, "/dl/cont/blob-gone",
        headers: [{"x-ms-version", "2021-12-02"}]
      )

    assert conn.status == 404
    # Engine checks the container before the blob: with neither present the
    # refusal names the container (measured, cycle 4).
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "ContainerNotFound"
    assert get_resp_header(conn, "x-ms-version") == ["2021-12-02"]
    [req_id] = get_resp_header(conn, "x-ms-request-id")
    assert req_id =~ ~r/^[0-9a-f]{8}-/
  end

  test "HEAD container tolerates a partial container record (nil header value)" do
    # Partial container record (no "last_modified" key): the engine's
    # properties tuple carries "last-modified" => nil, which crashes
    # Plug.Conn.put_resp_header without the dispatch nil-skip fence.
    Store.put(:smalt_blob_containers, "ph/cont", %{"name" => "cont", "account" => "ph"})

    conn = call(:head, "/ph/cont?restype=container", headers: [{"x-ms-version", "2021-12-02"}])
    assert conn.status == 200
  end

  test "slash-named blob PUT with a parsed content-type stores the raw bytes" do
    # The parse-exemption for raw blob PUTs must cover the multi-segment
    # splat form too: with a json content-type, an exact-3-segment exemption
    # lets Plug.Parsers consume the stream and the blob stores "" instead of
    # the declared bytes (mutant M3 kill witness).
    ver = [{"x-ms-version", "2021-12-02"}, {"content-type", "application/json"}]
    call(:put, "/pc/cont?restype=container", headers: ver)

    put = call(:put, "/pc/cont/w/1", body: "{\"stored\":\"verbatim\"}", headers: ver)
    assert put.status == 201

    get = call(:get, "/pc/cont/w/1", headers: ver)
    assert get.resp_body == "{\"stored\":\"verbatim\"}"
  end

  test "blob HEAD container (restype=container): header-only properties" do
    # Seed through the real engine (raw Store shape is an engine-internal
    # contract; a raw seed went 404 under suite order while passing solo).
    created =
      call(:put, "/hc/cont?restype=container", headers: [{"x-ms-version", "2021-12-02"}])

    assert created.status == 201

    conn =
      call(:head, "/hc/cont?restype=container",
        headers: [{"x-ms-version", "2021-12-02"}]
      )

    assert conn.status == 200
    assert conn.resp_body == ""

    missing = call(:head, "/hc/nope?restype=container", headers: [{"x-ms-version", "2021-12-02"}])
    assert missing.status == 404
    # HEAD is header-only by HTTP semantics: no body to decode; the typed
    # refusal is visible in the F5 headers instead.
    assert get_resp_header(missing, "x-ms-version") == ["2021-12-02"]
    [req_id] = get_resp_header(missing, "x-ms-request-id")
    assert req_id =~ ~r/^[0-9a-f]{8}-/
  end

  test "slash-named blob (Azure virtual directory): PUT/GET/DELETE through the wire" do
    ver = [{"x-ms-version", "2021-12-02"}]

    # x-ms-immutable-policy: false — without it the router defaults the
    # container to immutable and the delete below answers 409 ContainerLocked.
    call(:put, "/vd/cont?restype=container",
      headers: ver ++ [{"x-ms-immutable-policy", "false"}]
    )

    body = "vdir-payload"
    put = call(:put, "/vd/cont/w/1", body: body, headers: ver)
    assert put.status == 201, "PUT /vd/cont/w/1 answered #{put.status}: #{put.resp_body}"

    get = call(:get, "/vd/cont/w/1", headers: ver)
    assert get.status == 200
    assert get.resp_body == body

    head = call(:head, "/vd/cont/w/1", headers: ver)
    assert head.status == 200
    assert get_resp_header(head, "etag") != []

    del = call(:delete, "/vd/cont/w/1", headers: ver)
    assert del.status == 202

    gone = call(:get, "/vd/cont/w/1", headers: ver)
    assert gone.status == 404
    assert Jason.decode!(gone.resp_body)["error"]["code"] == "BlobNotFound"
  end

  test "splat precedence: deep unknown path is blob-guard, literal prefixes unchanged" do
    ver = [{"x-ms-version", "2021-12-02"}]

    # Deep unknown path without x-ms-version: blob guard envelope (same class
    # as flat blob paths), not the router 404.
    guarded = call(:get, "/deep/unknown/path/here")
    assert guarded.status == 400
    assert Jason.decode!(guarded.resp_body)["error"]["code"] == "MissingXMsVersion"

    # With x-ms-version the engine owns the refusal: container-level 404.
    deep = call(:get, "/deep/unknown/path/here", headers: ver)
    assert deep.status == 404
    # get_blob_range reports the missing leaf as BlobNotFound (engine shape).
    assert Jason.decode!(deep.resp_body)["error"]["code"] == "BlobNotFound"

    # Literal prefixes still win over the splat at every depth.
    for path <- ["/dbs", "/atlas/v2/entity/guid/g1", "/keys/k1", "/app/transactions"] do
      c = call(:get, path, headers: ver)
      refute c.status == 404 and Jason.decode!(c.resp_body)["error"]["code"] == "RouteNotFound",
             "#{path} fell through to the catch-all 404"
    end
  end

  test "KV create refusals carry x-ms-request-id and x-ms-version (blob_error F5 fence)" do
    conn =
      call(:post, "/keys/pol-hdr/create",
        body: %{"kty" => "RSA-HSM", "release_policy" => "release"}
      )

    assert conn.status == 400
    [req_id] = get_resp_header(conn, "x-ms-request-id")
    assert req_id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    assert get_resp_header(conn, "x-ms-version") == ["2021-12-02"]
  end

  # ---------------------------------------------------------------------------
  # Blob catch-all guard + 404 shape
  # ---------------------------------------------------------------------------

  test "blob routes without x-ms-version and unlisted host -> 400 MissingXMsVersion" do
    conn = call(:put, "/acct1/container1")
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "MissingXMsVersion"

    conn = call(:get, "/acct1/container1/blob1")
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "MissingXMsVersion"
  end

  test "blob routes with x-ms-version hit BlobStorage" do
    if loaded?(Smalt.DataPlane.BlobStorage) do
      conn = call(:put, "/acct2/container2", headers: [{"x-ms-version", "2021-12-02"}])
      assert conn.status == 201

      conn =
        call(:put, "/acct2/container2/blob2",
          body: "hello",
          headers: [{"x-ms-version", "2021-12-02"}]
        )

      assert conn.status == 201

      conn = call(:get, "/acct2/container2/blob2", headers: [{"x-ms-version", "2021-12-02"}])
      assert conn.status == 200
      assert conn.resp_body == "hello"
    end
  end

  test "unknown route -> 404 with error map shape" do
    # Single-segment unknown path: multi-segment tails belong to the blob
    # catch-all since the splat landing (this file, splat fence) — their
    # no-header answer is the blob guard's 400, not the router 404.
    conn = call(:get, "/definitely")
    assert conn.status == 404

    body = Jason.decode!(conn.resp_body)
    assert %{"error" => error} = body
    assert is_map(error)
    assert error["code"] == "RouteNotFound"
    assert is_binary(error["message"])
  end

  # ---------------------------------------------------------------------------
  # Body-gate mutation court: with_valid_body must refuse EVERY non-object
  # admission class (Unfetched, nil, scalars, empty) with a 400 envelope —
  # never a 500 crash, never silent admission.
  # ---------------------------------------------------------------------------

  test "body gate mutation: Unfetched (non-JSON content-type) refused 400 InvalidBody" do
    conn =
      call(:post, "/app/transactions",
        body: "hello",
        headers: [{"content-type", "text/plain"}]
      )

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidBody"
  end

  test "body gate mutation: empty body with application/json refused 400 InvalidBody" do
    conn =
      call(:post, "/app/transactions", body: "", headers: [{"content-type", "application/json"}])

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidBody"
  end

  test "body gate mutation: scalar JSON bodies (null/int/string/bool) refused 400" do
    for raw <- ["null", "5", "\"str\"", "true"] do
      conn =
        call(:post, "/app/transactions", body: raw, headers: [{"content-type", "application/json"}])

      assert conn.status == 400,
             "body #{inspect(raw)} answered #{conn.status}, expected 400"

      assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidBody"
    end
  end

  test "body gate mutation: top-level JSON array body refused 400, nothing appended" do
    for raw <- ["[1,2]", "[]", "[{\"k\":1}]"] do
      before = ledger_append_probe()

      conn =
        call(:post, "/app/transactions", body: raw, headers: [{"content-type", "application/json"}])

      assert conn.status == 400,
             "body #{inspect(raw)} answered #{conn.status}, expected 400"

      assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidBody"

      # the wrapper map must never reach the ledger engine as contents
      assert ledger_append_probe() == before,
             "array body #{inspect(raw)} mutated the ledger"
    end
  end

  defp ledger_append_probe do
    case Smalt.Security.ConfidentialLedger.get_latest("default_ledger") do
      {:ok, %{"transactionId" => tx}} -> tx
      :error -> :empty
    end
  end

  test "body gate mutation: sentinel ingest scalar body refused 400 InvalidBody" do
    conn =
      call(:post, "/dataCollectionRules/dcr-m/streams/Custom-Logs?api-version=2023-01-01",
        body: "5",
        headers: [{"content-type", "application/json"}]
      )

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidBody"
  end

  # ---------------------------------------------------------------------------
  # Route-precedence fuzz: literal service prefixes must never be shadowed by
  # the blob catch-alls; unclaimed single segments must land on the guarded
  # blob route or the 404 envelope — never a 500.
  # ---------------------------------------------------------------------------

  test "route precedence: GET /keys stays on the Key Vault list route" do
    conn = call(:get, "/keys")

    assert conn.status == 200
    assert is_map(Jason.decode!(conn.resp_body))
  end

  test "route precedence: unclaimed single segment lands on blob guard / 404, never 500" do
    # GET /topics (no /events) -> get "/:account", comp != list -> 404 envelope.
    conn = call(:get, "/topics")

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "RouteNotFound"

    # With x-ms-version, GET /atlas (single segment, no comp) -> 404 RouteNotFound.
    conn = call(:get, "/atlas", headers: [{"x-ms-version", "2021-12-02"}])

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "RouteNotFound"
  end

  test "route precedence: PUT under a service prefix without x-ms-version is guarded 400" do
    # 3-segment PUT over a literal service prefix falls to the blob catch-all;
    # without x-ms-version it must answer the guard 400, never a 500.
    conn = call(:put, "/app/transactions/tx-1", body: "x")

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "MissingXMsVersion"
  end

  test "body gate mutation: events ingest with unparsed body refused 400, never 500" do
    # Empty body + application/json leaves body_params as %Plug.Conn.Unfetched{}
    # (pass: "*/*"). decode_events/1 used to MatchError on the read_body 2-tuple
    # error shape; it must answer the 400 envelope instead.
    conn =
      call(:post, "/topics/t1/events", body: "", headers: [{"content-type", "application/json"}])

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidCloudEvent"
  end

  test "immutability policy with unparsed non-JSON body refused 400 InvalidXmlOrJson" do
    conn =
      call(:put, "/acct3/cont3?comp=immutabilityPolicy",
        body: "not-json",
        headers: [{"x-ms-version", "2021-12-02"}, {"content-type", "text/plain"}]
      )

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidXmlOrJson"
  end

  test "raw blob PUT exemption: urlencoded content-type still stores raw bytes" do
    # The parsers exemption (raw_blob_put?/1) keeps the stream unparsed for
    # PUT /:account/:container/:blob without comp=; an urlencoded content-type
    # must NOT swallow the body as form params — stored bytes must match exactly.
    body = "a=1&b=two+words"

    call(:put, "/acct4/cont4", headers: [{"x-ms-version", "2021-12-02"}])

    conn =
      call(:put, "/acct4/cont4/blob4",
        body: body,
        headers: [{"x-ms-version", "2021-12-02"}, {"content-type", "application/x-www-form-urlencoded"}]
      )

    assert conn.status == 201

    conn = call(:get, "/acct4/cont4/blob4", headers: [{"x-ms-version", "2021-12-02"}])
    assert conn.status == 200
    assert conn.resp_body == body
  end

  test "encoded comp query decodes before routing: ?comp=%6De%74adata hits metadata handler" do
    # Decoded-to-decoded invariant (lane R154): the comp parameter is matched
    # AFTER percent-decoding, so an encoded `comp=%6De%74adata` must reach the
    # same metadata handler as the literal `comp=metadata` — never the plain
    # blob PUT arm, never an unknown-comp refusal.
    call(:put, "/acct4/cont4",
      headers: [{"x-ms-version", "2021-12-02"}, {"x-ms-immutable-policy", "false"}]
    )

    call(:put, "/acct4/cont4/blobenc", body: "payload", headers: [{"x-ms-version", "2021-12-02"}])

    conn =
      call(:put, "/acct4/cont4/blobenc?comp=%6De%74adata",
        headers: [{"x-ms-version", "2021-12-02"}, {"x-ms-meta-r154", "enc"}]
      )

    assert conn.status == 200, "encoded metadata PUT: #{conn.status} #{conn.resp_body}"

    conn = call(:get, "/acct4/cont4/blobenc", headers: [{"x-ms-version", "2021-12-02"}])
    assert conn.status == 200
    assert conn.resp_body == "payload"
    assert {"x-ms-meta-r154", "enc"} in conn.resp_headers
  end

  test "route precedence fuzz: x-ms-version must not pull literal prefixes onto blob catch-alls" do
    # With the blob guard satisfied (x-ms-version present), every literal
    # service route must still answer as itself — never the blob catch-all,
    # never a 500, never an empty 200.
    checks = [
      {:get, "/dbs", fn c ->
         assert c.status == 200
         assert is_map(Jason.decode!(c.resp_body))
         # Blob list-containers would answer XML; Cosmos answers JSON.
         refute String.contains?(c.resp_body, "<")
       end},
      {:get, "/keys", fn c ->
         assert c.status == 200
         assert is_map(Jason.decode!(c.resp_body))
       end},
      {:get, "/topics/lit-t1/events", fn c ->
         assert c.status == 200
         assert is_list(Jason.decode!(c.resp_body))
       end},
      {:get, "/app/transactions", fn c ->
         assert c.status == 200
         assert is_list(Jason.decode!(c.resp_body))
       end},
      {:get, "/atlas", fn c ->
         # Unclaimed single segment: even with x-ms-version, no comp=list ->
         # the guarded 404 envelope, never XML and never a 500.
         assert c.status == 404
         assert Jason.decode!(c.resp_body)["error"]["code"] == "RouteNotFound"
       end},
      {:get, "/atlas/v2/lineage/both/lit-guid", fn c ->
         assert c.status in [200, 404]
         assert is_map(Jason.decode!(c.resp_body))
       end}
    ]

    for {method, path, assert_fn} <- checks do
      conn = call(method, path, headers: [{"x-ms-version", "2021-12-02"}])
      assert_fn.(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # 8MB boundary fence (two-layer cap, measured 2026-10-15 over the real
  # Bandit adapter): the router's read cap engages at the exact boundary byte
  # — 8,000,001 -> 413 {"error":{"code":"RequestBodyTooLarge", "8,000,000-byte
  # request body limit"}}. Beneath it the blob engine enforces a stricter
  # 1,048,576-byte per-PUT limit, so a body inside the router cap can still be
  # refused 413 by the engine (wire test pins that refusal shape). The
  # Plug.Test adapter cannot represent "body length == :length" as :ok (it
  # caps the chunk at :length and answers :more), so the exact-cap admission
  # class is asserted over the real adapter only.
  # ---------------------------------------------------------------------------

  test "blob PUT 8MB boundary: 8_000_001 -> 413 RequestBodyTooLarge" do
    if loaded?(Smalt.DataPlane.BlobStorage) do
      hts = [{"x-ms-version", "2021-12-02"}]

      conn = call(:put, "/bnd/c01", headers: hts)
      assert conn.status == 201

      conn =
        call(:put, "/bnd/c01/edge1", body: String.duplicate("a", 8_000_001), headers: hts)

      assert conn.status == 413
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "RequestBodyTooLarge"
    end
  end

  test "blob PUT 8MB boundary over real Bandit: boundary byte 413, exact-cap refused by engine per-PUT limit" do
    port = get_free_port()
    stop_existing_tree()

    children = [
      Smalt.Store,
      {Bandit, plug: Smalt.EgressRouter, scheme: :http, port: port}
    ]

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

    on_exit(fn ->
      stop_tree(sup)
      SmaltTest.Lifecycle.restore_app()
      SmaltTest.Lifecycle.ensure_store_up()
    end)

    hts = [{"x-ms-version", "2021-12-02"}]
    base = "/wbnd/wc1"

    resp = wire_request(port, "PUT", "#{base}", headers: hts)
    assert resp.status == 201

    # Exact cap: inside the router's read cap but above the engine's
    # 1,048,576-byte per-PUT limit -> engine 413 RequestBodyTooLarge.
    resp = wire_request(port, "PUT", "#{base}/edge", headers: hts, body: String.duplicate("a", 8_000_000))
    assert resp.status == 413
    assert Jason.decode!(resp.body)["error"]["code"] == "RequestBodyTooLarge"
    assert String.contains?(resp.body, "1,048,576")

    # Boundary byte: router read cap -> router 413 envelope.
    resp = wire_request(port, "PUT", "#{base}/edge1", headers: hts, body: String.duplicate("a", 8_000_001))
    assert resp.status == 413
    assert Jason.decode!(resp.body)["error"]["code"] == "RequestBodyTooLarge"
    assert String.contains?(resp.body, "8,000,000")
  end

  # ---------------------------------------------------------------------------
  # Content-type x method x x-ms-version fuzz: wrong content-type on any
  # multi-service route must answer the exact gate envelope (400 InvalidBody /
  # 415 UnsupportedMediaType), never a 5xx crash.
  # ---------------------------------------------------------------------------

  test "content-type fuzz: wrong types on multi-service routes never 5xx" do
    targets = [
      {:post, "/app/transactions"},
      {:post, "/keys/fz-ct/create"},
      {:post, "/dbs/fzdb2/colls/fzc2/docs"},
      {:post, "/dataCollectionRules/fz2/streams/Custom-Logs?api-version=2023-01-01"},
      {:post, "/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01"}
    ]

    wrong = ["text/plain", "application/xml"]

    body = Jason.encode!(%{"id" => "fz", "v" => 1})

    for {method, path} <- targets, ct <- wrong, xms <- [[], [{"x-ms-version", "2021-12-02"}]] do
      conn =
        Plug.Test.conn(method, path, body)
        |> Plug.Conn.put_req_header("authorization", "Bearer egress-harness-challenged-client")
        |> Plug.Conn.put_req_header("content-type", ct)
        |> then(fn c -> Enum.reduce(xms, c, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end) end)
        |> EgressRouter.call(@opts)

      assert conn.status < 500,
             "#{method} #{path} ct=#{ct} -> #{conn.status}: #{conn.resp_body}"

      assert Jason.decode!(conn.resp_body)["error"]["code"] in ["InvalidBody", "UnsupportedMediaType"]
    end
  end

  # ---------------------------------------------------------------------------
  # Auth seam cross-validation (bearer.ex exempt list vs egress routes):
  # /attest/* is prefix-exempt (MAA is its own auth) — it must reach the router
  # without a token; every other service route must 401 before dispatch.
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # KD-15 (v26.10.15) — Key Vault 401-with-params courts (both auth modes):
  # a tokenless /keys request answers 401 + enriched WWW-Authenticate
  # (Bearer authorization="…", resource="…", error="invalid_token",
  # error_description="…") in BOTH modes — anonymous mode no longer passes
  # tokenless /keys through, enforce mode keeps refusing downstream.
  # Grammar: `authorization` (NOT authorization_uri) and `resource` are the
  # @azure keyvault-common parseWWWAuthenticate whitelist entries; resource
  # must echo the request origin (keyVaultAuthenticationPolicy hostname check).
  # ---------------------------------------------------------------------------

  test "KD-15: tokenless GET /keys challenges with 401 + params in anonymous mode" do
    Application.put_env(:smalt, :auth_mode, :anonymous)

    conn = call(:get, "/keys", headers: [{"authorization", ""}])

    assert conn.status == 401
    [wa] = get_resp_header(conn, "www-authenticate")
    assert wa =~ ~s(error="invalid_token")
    assert wa =~ ~s(error_description="MissingBearerToken")
    assert wa =~ ~r/^Bearer authorization="[^"]+\/organizations"/
    assert wa =~ ~r{resource="https?://[^"]+"}

    # whitelist-grammar: the SDK parser keys must all be present, and
    # authorization_uri must NOT appear
    refute wa =~ "authorization_uri"
  end

  test "KD-15: tokenless GET /keys challenges with 401 + params in enforce mode" do
    Application.put_env(:smalt, :auth_mode, :enforce)

    conn = call(:get, "/keys", headers: [{"authorization", ""}])

    assert conn.status == 401
    [wa] = get_resp_header(conn, "www-authenticate")
    assert wa =~ ~s(error="invalid_token")
    assert wa =~ ~s(error_description="MissingBearerToken")
    assert wa =~ ~r/^Bearer authorization="/
    assert wa =~ ~r{resource="https?://[^"]+"}
  after
    Application.put_env(:smalt, :auth_mode, :anonymous)
  end

  test "KD-15: non-/keys tokenless routes keep their prior behavior" do
    conn = call(:get, "/dbs", headers: [{"x-ms-version", "2021-12-02"}])
    assert conn.status != 401
  end

  test "auth seam: /attest exempt, service routes 401 in enforce mode" do
    Application.put_env(:smalt, :auth_mode, :enforce)

    conn = call(:post, "/attest/sevsnpvm", body: %{"measurement" => "x"})
    assert conn.status != 401

    conn = call(:post, "/app/transactions", body: %{"data" => "a"})
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "AuthenticationFailed"

    conn = call(:get, "/dbs", headers: [{"x-ms-version", "2021-12-02"}])
    assert conn.status == 401
  after
    Application.put_env(:smalt, :auth_mode, :anonymous)
  end

  # ---------------------------------------------------------------------------
  # read_body error path: a real (hand-written) Plug adapter whose
  # read_req_body/2 faults — the 400 InvalidRequestBody envelope must fire,
  # never a 500 crash. This is the M4 mutation-kill for the {:error, reason}
  # clause of the blob PUT body read.
  # ---------------------------------------------------------------------------

  defmodule FaultingBodyAdapter do
    @behaviour Plug.Conn.Adapter

    @impl true
    # Plug.Conn.Adapter contract: read_req_body errors are 2-tuples
    # (Plug.Conn.read_body maps them to {:error, reason}).
    def read_req_body(state, _opts), do: {:error, :simulated_transport_fault}

    @impl true
    def send_resp(state, _status, _headers, body), do: {:ok, body, Map.put(state, :body, body)}

    @impl true
    def send_chunked(state, _status, _headers), do: {:ok, self(), state}

    @impl true
    def chunk(_state, _data), do: {:error, "not supported"}

    @impl true
    def send_informational(state, _status, _headers), do: {:ok, nil, state}

    @impl true
    def inform(_state, _status, _headers), do: :ok

    @impl true
    def get_http_protocol(_state), do: :"HTTP/1.1"

    @impl true
    def push(_state, _path, _headers), do: :ok
  end

  test "blob PUT read_body transport fault -> 400 InvalidRequestBody (M4 kill)" do
    if loaded?(Smalt.DataPlane.BlobStorage) do
      test_conn = Plug.Test.conn(:put, "/bnd/c01/m4", "payload")

      conn = %{
        test_conn
        | adapter: {FaultingBodyAdapter, %{}},
          req_headers: [{"x-ms-version", "2021-12-02"} | test_conn.req_headers]
      }

      conn = EgressRouter.call(conn, @opts)

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidRequestBody"
    end
  end

  # ---------------------------------------------------------------------------
  # Batch-list admission boundary (measured classes, cycle-6 probes):
  #  - ledger: EVERY top-level list was appending garbage at 201 (including
  #    [] and scalar lists) -> the dispatch seam now refuses non-object
  #    appends 400 InvalidBody.
  #  - sentinel: batch with a nil element still ingests 204 (engine lane's
  #    surface — flagged, not fenced here).
  #  - events: scalar/null-element lists are refused all-or-nothing 400;
  #    empty list publishes 200 (vacuous batch) — noted boundary.
  # ---------------------------------------------------------------------------

  test "batch-list boundary: ledger refuses non-object append classes 400" do
    if loaded?(Smalt.Security.ConfidentialLedger) do
      for body <- [[], [1, "a", nil, true], [nil, %{"msg" => "x"}], [%{"data" => "ok"}]] do
        conn =
          call(:post, "/app/transactions", body: body)

        assert conn.status == 400,
               "ledger list class #{inspect(body)} answered #{conn.status}"

        assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidBody"
      end
    end
  end

  test "batch-list boundary: events refuses scalar/null lists 400, empty batch 200" do
    for body <- [[1, "a", nil, true], [nil, %{"specversion" => "1.0"}]] do
      conn = call(:post, "/topics/bd2/events", body: body)
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidCloudEvent"
    end

    conn = call(:post, "/topics/bd2/events", body: [])
    assert conn.status == 200
  end

  test "batch-list boundary: sentinel scalar-element list refused, nil-element list flagged" do
    conn =
      call(:post, "/dataCollectionRules/bd3/streams/Custom-Logs?api-version=2023-01-01",
        body: [1, "a", nil, true]
      )

    assert conn.status == 400

    # Handoff class CLOSED by the sentinel engine lane (was 204 with a nil
    # record ingested; engine now refuses): pin the new contract.
    conn =
      call(:post, "/dataCollectionRules/bd4/streams/Custom-Logs?api-version=2023-01-01",
        body: [nil, %{"msg" => "x"}]
      )

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidData"
  end

  # ---------------------------------------------------------------------------
  # Second adapter-fault class (cycle-6): read_req_body/2 timing out — a real
  # Plug.Conn.Adapter whose read returns the contract error {:error, :timeout};
  # the dispatch seam must answer the 400 InvalidRequestBody envelope, never
  # a 500 crash.
  # ---------------------------------------------------------------------------

  defmodule TimingOutBodyAdapter do
    @behaviour Plug.Conn.Adapter

    @impl true
    def read_req_body(_state, _opts), do: {:error, :timeout}

    @impl true
    def send_resp(state, _status, _headers, body), do: {:ok, body, state}

    @impl true
    def send_chunked(state, _status, _headers), do: {:ok, self(), state}

    @impl true
    def chunk(_state, _data), do: {:error, "not supported"}

    @impl true
    def send_informational(state, _status, _headers), do: {:ok, nil, state}

    @impl true
    def inform(_state, _status, _headers), do: :ok

    @impl true
    def get_http_protocol(_state), do: :"HTTP/1.1"

    @impl true
    def push(_state, _path, _headers), do: :ok
  end

  test "blob PUT read_body timeout fault -> 400 InvalidRequestBody (timeout class)" do
    if loaded?(Smalt.DataPlane.BlobStorage) do
      test_conn = Plug.Test.conn(:put, "/bnd/c01/timeout", "payload")

      conn = %{
        test_conn
        | adapter: {TimingOutBodyAdapter, %{}},
          req_headers: [{"x-ms-version", "2021-12-02"} | test_conn.req_headers]
      }

      conn = EgressRouter.call(conn, @opts)

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidRequestBody"
    end
  end

  # ---------------------------------------------------------------------------
  # C3 row-8 cross-surface contract (cosmos lane cycle-6 + egress cycle-7):
  # bad query-POST bodies are refused by the ENGINE with the real Cosmos
  # envelope {"code":"BadRequest","message":"The query is invalid."} — NOT the
  # generic dispatch {"error":{"code":"InvalidBody"}} map. Typed decision: the
  # engine-level fence is the full contract (wire-toward-Azure); the dispatch
  # layer deliberately passes through. This test fences the ENVELOPE SHAPE so
  # a future genericization to the ARM error map is caught.
  # ---------------------------------------------------------------------------

  test "C3 row-8: bad query bodies answer the Cosmos BadRequest envelope, not InvalidBody" do
    for {body, ct} <- [
          {"", "application/query+json"},
          {"{}", "application/query+json"},
          {%{"x" => 1}, "application/query+json"},
          {%{"query" => ""}, "application/query+json"}
        ] do
      conn =
        call(:post, "/dbs/row8/colls/row8c/docs",
          body: body,
          headers: [{"content-type", "application/query+json"}]
        )

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["code"] == "BadRequest"
      assert body["message"] == "The query is invalid."
      # The dispatch generic envelope would be wrong here.
      refute Map.has_key?(body, "error")
    end
  end

  # ---------------------------------------------------------------------------
  # Truncated-body fault class (cycle 8): a real adapter that yields a small
  # {:more, partial, _} — Plug.Conn.read_body is single-shot, so a small
  # partial is a mid-flight truncation and must answer 400 InvalidRequestBody,
  # not the oversize 413. A cap-filling partial stays 413 (boundary test).
  # ---------------------------------------------------------------------------

  defmodule PartialThenErrorAdapter do
    @behaviour Plug.Conn.Adapter

    @impl true
    def read_req_body(%{n: n} = state, _opts) do
      if n == 0 do
        {:more, "partial-data", %{state | n: 1}}
      else
        {:error, :closed}
      end
    end

    @impl true
    def send_resp(state, _status, _headers, body), do: {:ok, body, state}

    @impl true
    def send_chunked(state, _status, _headers), do: {:ok, self(), state}

    @impl true
    def chunk(_state, _data), do: {:error, "not supported"}

    @impl true
    def send_informational(state, _status, _headers), do: {:ok, nil, state}

    @impl true
    def inform(_state, _status, _headers), do: :ok

    @impl true
    def get_http_protocol(_state), do: :"HTTP/1.1"

    @impl true
    def push(_state, _path, _headers), do: :ok
  end

  test "blob PUT truncated partial read -> 400 InvalidRequestBody, not 413" do
    if loaded?(Smalt.DataPlane.BlobStorage) do
      c0 = Plug.Test.conn(:put, "/bnd/c01/trunc", "payload")

      conn = %{
        c0
        | adapter: {PartialThenErrorAdapter, %{n: 0}},
          req_headers: [{"x-ms-version", "2021-12-02"} | c0.req_headers]
      }

      conn = EgressRouter.call(conn, @opts)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "InvalidRequestBody"
      assert String.contains?(body["error"]["message"], "truncated")
    end
  end

  # ---------------------------------------------------------------------------
  # Accept-header pinning (cycle 8, measured once): every egress service
  # answers with its FIXED wire content-type regardless of Accept — JSON
  # routes always application/json, blob content octet-stream, comp=list
  # always XML. Real Azure likewise mostly ignores Accept. Fence: Accept
  # must never change the response content-type or status.
  # ---------------------------------------------------------------------------

  test "Accept header never changes response content-type or status" do
    if loaded?(Smalt.DataPlane.BlobStorage) do
      Smalt.DataPlane.BlobStorage.create_container("acpt", "cont", %{"immutable" => true})
      Smalt.DataPlane.BlobStorage.put_blob("acpt", "cont", "b", "hi", %{})

      for {path, hts, expected_ct} <- [
            {"/app/transactions", [], "application/json"},
            {"/dbs/acpt/colls/acptc/docs", [], "application/json"},
            {"/acpt/cont/b", [{"x-ms-version", "2021-12-02"}], "application/octet-stream"},
            {"/acpt/cont?restype=container&comp=list",
             [{"x-ms-version", "2021-12-02"}], "application/xml"}
          ] do
        for accept <- ["text/xml", "application/json", "*/*"] do
          conn =
            call(:get, path, headers: [{"accept", accept} | hts])

          assert conn.status == 200,
                 "GET #{path} accept=#{accept} -> #{conn.status}"

          ct = get_resp_header(conn, "content-type") |> List.first()
          assert ct =~ expected_ct,
                 "GET #{path} accept=#{accept} answered content-type #{ct}, expected #{expected_ct}"
        end
      end
    end
  end

  test "Accept pinned on ledger tx + KV action routes (round-2 matrix)" do
    if loaded?(Smalt.Security.ConfidentialLedger) and loaded?(Smalt.DataPlane.KeyVaultActions) do
      # ledger_enforce_existence (ledger lane pivot): create the ledger first.
      Store.put(:smalt_ledger_meta, {:created, "default_ledger"}, true)

      call(:post, "/app/transactions", body: %{"data" => "a"})
      call(:post, "/keys/ap2/create", body: %{"kty" => "oct-HSM"})

      for {method, path, body, expected_status} <- [
            {:get, "/app/transactions", "", 200},
            {:get, "/app/transactions/latest", "", 200},
            {:post, "/app/transactions", Jason.encode!(%{"data" => "b"}), 201},
            {:post, "/keys/ap2/encrypt", Jason.encode!(%{"value" => "aGk=", "alg" => "A256GCM"}), :any},
            {:get, "/keys", "", 200},
            {:get, "/topics/ap3/events", "", 200}
          ] do
        for accept <- ["text/xml", "application/json", "*/*"] do
          # Ledger dedups appends (409 on identical contents) — make each
          # iteration's body unique so status stays a pure 201.
          body =
            if path == "/app/transactions" and method == :post,
              do: Jason.encode!(%{"data" => "accept-#{accept}"}),
              else: body

          conn =
            Plug.Test.conn(method, path, body)
            |> Plug.Conn.put_req_header("authorization", "Bearer egress-harness-challenged-client")
            |> Plug.Conn.put_req_header("accept", accept)
            |> then(fn c ->
              if body != "",
                do: Plug.Conn.put_req_header(c, "content-type", "application/json"),
                else: c
            end)
            |> EgressRouter.call(@opts)

          assert conn.status in ([expected_status] ++ if expected_status == :any, do: [200, 201, 400], else: []),
                 "#{method} #{path} accept=#{accept} -> #{conn.status}"

          ct = get_resp_header(conn, "content-type") |> List.first()
          assert ct =~ "application/json",
                 "#{method} #{path} accept=#{accept} answered content-type #{ct}"
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Method-mismatch contract (cycle 10, 168-triple sweep): a method not in a
  # route's pair falls through to the catch-all and answers the ARM-conventional
  # generic envelope — 404 {"error":{"code":"RouteNotFound","message": "No
  # route matches METHOD path"}} — never a 5xx, never a naked 405. The only
  # exception class: a blob-catch-all-shaped path (2-segment PUT) keeps its
  # guard 400 MissingXMsVersion. Zero 5xx across 24 service paths × 7 methods.
  # ---------------------------------------------------------------------------

  test "method mismatch: wrong verb answers 404 RouteNotFound, never 5xx/405" do
    for {method, path} <- [
          {:patch, "/app/transactions"},
          {:delete, "/dbs"},
          {:options, "/keys/k1"},
          {:patch, "/atlas/v2/entity"},
          {:patch, "/v1/workspaces/ws/query"},
          # 2-segment unmatched: PUT /:account/:container blob route grabs any
          # 2-segment PUT, so use a path with no verb-match at this depth.
          {:patch, "/v1/workspaces"}
        ] do
      conn =
        Plug.Test.conn(method, path, "")
        |> EgressRouter.call(@opts)

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "RouteNotFound"
      assert String.contains?(body["error"]["message"], to_string(method) |> String.upcase())
    end
  end

  test "method mismatch: blob-shaped paths keep the guard envelope" do
    # Wrong verbs whose path SHAPE matches a blob catch-all route
    # (3-segment PUT/HEAD) land on the guarded blob routes — the x-ms-version
    # guard envelope fires before any 404 could.
    for {method, path} <- [
          {:put, "/topics/t1/events"},
          {:head, "/topics/t1/events"}
        ] do
      conn =
        Plug.Test.conn(method, path, "")
        |> EgressRouter.call(@opts)

      assert conn.status == 400

      # HEAD answers header-only by HTTP semantics — assert status only.
      if method != :head do
        assert Jason.decode!(conn.resp_body)["error"]["code"] == "MissingXMsVersion"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Empty batch publish: 200-empty is the REAL Event Grid acknowledgment shape
  # (C7-1b: "batches are acknowledged with an empty 200, matching real Event
  # Grid"). All-or-nothing over zero events is vacuously satisfied — this is
  # conformant, not vacuous (typed decision, egress cycle 10; supersedes the
  # cycle-6 "vacuous" note). The non-wire {"events": []} wrapper form is
  # refused 400, as no real Event Grid API accepts it.
  # ---------------------------------------------------------------------------

  test "empty batch publish is conformant 200-empty; {\"events\": []} wrapper refused" do
    conn = call(:post, "/topics/emptybatch/events", body: [])
    assert conn.status == 200
    assert conn.resp_body == ""

    conn =
      call(:post, "/topics/emptybatch/events",
        body: %{"events" => []},
        headers: [{"content-type", "application/cloudevents-batch+json"}]
      )

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidCloudEvent"
  end

  # ---------------------------------------------------------------------------
  # List Blobs `prefix` qparam reaches the engine (lens-2 cycle 1, blob lane
  # cycle-16 wire half). Fence: a prefix-scoped reader must never receive the
  # whole container listing — over-disclosure regression detector.
  # ---------------------------------------------------------------------------

  test "List Blobs prefix qparam filters the wire listing on both call sites" do
    if loaded?(Smalt.DataPlane.BlobStorage) do
      Smalt.DataPlane.BlobStorage.create_container("pf", "cont", %{"immutable" => true})

      for name <- ["a", "pfx-1", "pfx-2", "z"] do
        Smalt.DataPlane.BlobStorage.put_blob("pf", "cont", name, "d", %{})
      end

      ver = [{"x-ms-version", "2021-12-02"}]

      for path <- [
            "/pf/cont?restype=container&comp=list&prefix=pfx-",
            "/pf/cont?prefix=pfx-"
          ] do
        conn = call(:get, path, headers: ver)
        assert conn.status == 200, "GET #{path} -> #{conn.status}"

        assert conn.resp_body =~ "pfx-1"
        assert conn.resp_body =~ "pfx-2"
        refute conn.resp_body =~ "<Name>a</Name>"
        refute conn.resp_body =~ "<Name>z</Name>"
        assert conn.resp_body =~ "<Prefix>pfx-</Prefix>"
      end

      # Unfiltered listing still returns everything (no over-restriction).
      conn = call(:get, "/pf/cont?restype=container&comp=list", headers: ver)
      assert conn.status == 200
      for name <- ["a", "pfx-1", "pfx-2", "z"], do: assert conn.resp_body =~ "<Name>#{name}</Name>"
      refute conn.resp_body =~ "<Prefix>pfx-</Prefix>"
    end
  end

  # ---------------------------------------------------------------------------
  # Typed engine-error mapping (lens-2 cycles 1-2 + joint proof cycle 4):
  # create_container and both list call sites map engine
  # {:error, status, code, msg} tuples at their exact Azure status. Fences
  # exercise the real engine (blob cycle-25 fences) over the wire.
  # ---------------------------------------------------------------------------

  test "typed engine errors reach the wire at exact status (create + list)" do
    if loaded?(Smalt.DataPlane.BlobStorage) do
      ver = [{"x-ms-version", "2021-12-02"}]

      # create_container grammar fence -> 400 InvalidResourceName (exact
      # status, not the blanket 500 catch-all)
      conn = call(:put, "/jx/xy?restype=container", headers: ver)
      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "InvalidResourceName"

      # Idempotent Put Container (lens-5 cycle-33 landing): re-PUT with an
      # IDENTICAL x-ms-meta-* set answers 200; a DIFFERENT set refuses
      # 409 ContainerAlreadyExists at exact status.
      Smalt.DataPlane.BlobStorage.create_container("jx", "dup", %{})

      conn = call(:put, "/jx/dup?restype=container", headers: ver)
      assert conn.status == 200

      conn =
        call(:put, "/jx/dup?restype=container",
          headers: ver ++ [{"x-ms-meta-color", "blue"}]
        )

      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "ContainerAlreadyExists"

      # list maxresults fence -> 400 InvalidQueryParameter on both call sites.
      # comp=list error arms answer the Azure XML envelope (lane-06 landing,
      # 2026-10-15): <Error><Code>…</Code></Error> + x-ms-error-code header;
      # the non-list create arms keep the JSON envelope.
      for path <- [
            "/jx/dup?restype=container&comp=list&maxresults=abc",
            "/jx/dup?maxresults=abc"
          ] do
        conn = call(:get, path, headers: ver)
        assert conn.status == 400, "GET #{path} -> #{conn.status}"
        assert get_resp_header(conn, "x-ms-error-code") == ["InvalidQueryParameter"]
        assert conn.resp_body =~ "<Error>"
        assert conn.resp_body =~ "InvalidQueryParameter"
      end
    end
  end

  test "RouteNotReady 503 when a sibling module is not compiled" do
    beam_dir = Path.join(Mix.Project.compile_path(), "Elixir.Smalt.DataPlane.Purview.beam")
    assert File.exists?(beam_dir)
    hidden = beam_dir <> ".hidden_for_route_test"
    File.rename!(beam_dir, hidden)

    # Purge the loaded module so the loader cannot serve it from memory.
    :code.purge(Smalt.DataPlane.Purview)
    :code.delete(Smalt.DataPlane.Purview)

    conn =
      conn(:get, "/atlas/v2/entity/guid/g1")
      |> EgressRouter.call(@opts)

    assert conn.status == 503
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "RouteNotReady"
  after
    # Restore the beam and reload the module.
    beam_dir = Path.join(Mix.Project.compile_path(), "Elixir.Smalt.DataPlane.Purview.beam")
    hidden = beam_dir <> ".hidden_for_route_test"

    if File.exists?(hidden) do
      File.rename!(hidden, beam_dir)
      :code.purge(Smalt.DataPlane.Purview)
      Code.ensure_loaded(Smalt.DataPlane.Purview)
    end
  end

  # ---------------------------------------------------------------------------
  # Lens 6 cycle 1 — cosmos typed error-tuple classes through the dispatch
  # (per-engine error mapping strata: the cosmos continuation 400s and the
  # store_not_ready fail-closed contract, both witnessed from the wire).
  # ---------------------------------------------------------------------------

  @cosmos_tables [:smalt_cosmos_docs, :smalt_cosmos_pk_meta, :smalt_cosmos_lsn]

  test "cosmos continuation 400s route through dispatch as flat BadRequest envelopes" do
    if loaded?(Smalt.DataPlane.Cosmos) do
      # Seed via the engine (real collaborator); probes below are wire probes.
      {:ok, 201, _, _} = Cosmos.create_doc("k6", "k6c", %{"id" => "d1", "v" => 1}, %{})

      # Malformed token on the LIST surface: not "v#lsn:tail" grammar -> 400.
      conn = call(:get, "/dbs/k6/colls/k6c/docs", headers: [{"x-ms-continuation", "garbage"}])

      assert conn.status == 400,
             "malformed list continuation -> #{conn.status}"

      body = Jason.decode!(conn.resp_body)
      assert body["code"] == "BadRequest"
      assert body["message"] =~ "continuation"

      # Query-namespace token (v1) on the LIST gate (v2-only): typed 400,
      # never a cross-surface silent resume.
      conn =
        call(:get, "/dbs/k6/colls/k6c/docs",
          headers: [{"x-ms-continuation", "1#5:d1"}]
        )

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["code"] == "BadRequest"

      # List-namespace token (v2) on the QUERY gate (v1-only): typed 400.
      conn =
        call(:post, "/dbs/k6/colls/k6c/docs",
          body: Jason.encode!(%{"query" => "SELECT * FROM c"}),
          headers: [
            {"content-type", "application/query+json"},
            {"x-ms-continuation", "2#5:d1"}
          ]
        )

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["code"] == "BadRequest"

      # Valid round-trip: >limit feed emits a v2 token; resuming with it is
      # 200 and the final page carries NO continuation header (row-18 pin).
      for i <- 2..101 do
        {:ok, 201, _, _} = Cosmos.create_doc("k6", "k6c", %{"id" => "d#{i}"}, %{})
      end

      conn = call(:get, "/dbs/k6/colls/k6c/docs")
      assert conn.status == 200
      assert length(Jason.decode!(conn.resp_body)["Documents"]) == 100
      # v2 (list) namespace token; tail format is rid-scoped (cosmos lane
      # landing, 2026-10-15) — pinned only on the namespace prefix here, the
      # resume probe below proves the round-trip behaviorally.
      [token] = get_resp_header(conn, "x-ms-continuation")
      assert token =~ ~r/^2#\d+:/

      conn = call(:get, "/dbs/k6/colls/k6c/docs", headers: [{"x-ms-continuation", token}])
      assert conn.status == 200
      # Lexicographic feed: the one doc past the first page is the lex-last id.
      assert [%{"id" => "d99"}] = Jason.decode!(conn.resp_body)["Documents"]
      assert get_resp_header(conn, "x-ms-continuation") == []
    end
  end

  test "cosmos store_not_ready fails closed at dispatch: 503 RouteNotReady, never a 200-empty feed" do
    if loaded?(Smalt.DataPlane.Cosmos) do
      # Remove the coordinator-owned cosmos tables (Store.init semantics:
      # a missing table IS the not-ready state; the engine never creates them).
      Enum.each(@cosmos_tables, fn t ->
        if :ets.info(t) != :undefined, do: :ets.delete(t)
      end)

      try do
        # Uniform fail-closed across the cosmos surface...
        for path <- [
              "/dbs",
              "/dbs/k6/colls/k6c/docs/d1",
              "/dbs/k6/colls/k6c/docs"
            ] do
          conn = call(:get, path)

          assert conn.status == 503, "GET #{path} -> #{conn.status}"
          assert Jason.decode!(conn.resp_body)["error"]["code"] == "RouteNotReady"
        end
      after
        # Recreate under a DURABLE owner: an ETS public named table dies with
        # its owner process, so restoring inside this test process (or an
        # on_exit task, which also dies) drops the tables again on exit — that
        # collateral 503'd sibling tests at some shuffle seeds. A detached
        # keeper process holds the tables for the rest of the run with the
        # exact Store.init table options.
        ExUnit.Callbacks.on_exit(fn ->
          Enum.each(@cosmos_tables, fn t ->
            if :ets.info(t) == :undefined do
              spawn(fn ->
                :ets.new(t, [
                  :ordered_set,
                  :public,
                  :named_table,
                  read_concurrency: true,
                  write_concurrency: true
                ])

                Process.sleep(:infinity)
              end)
            end
          end)
        end)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Lens 7 cycle 1 — the lens-6 fail-open class GENERALIZED: routes outside the
  # lens-6 strata that answer not-ready/error with a defaulted non-503 (404
  # NotFound / 400 InvalidBody / raw 500) instead of 503 RouteNotReady. The
  # router moduledoc law: the surface fails CLOSED with RouteNotReady — never a
  # success-shaped or client-fault-shaped lie about server state.
  # ---------------------------------------------------------------------------

  @vault_table :smalt_vault_keys

  test "lens7: cosmos db/container READ routes fail closed 503 on store_not_ready, never 404 NotFound" do
    if loaded?(Smalt.DataPlane.Cosmos) do
      Enum.each(@cosmos_tables, fn t ->
        if :ets.info(t) != :undefined, do: :ets.delete(t)
      end)

      try do
        for path <- ["/dbs/l7db", "/dbs/l7db/colls/l7c"] do
          conn = call(:get, path)

          assert conn.status == 503,
                 "GET #{path} -> #{conn.status} (fail-open: not-ready masked as NotFound)"

          assert Jason.decode!(conn.resp_body)["error"]["code"] == "RouteNotReady"
        end
      after
        recreate_cosmos_tables()
      end
    end
  end

  test "lens7: key vault routes fail closed 503 on missing vault table, never 400/500" do
    if loaded?(Smalt.Security.Attestation) do
      if :ets.info(@vault_table) != :undefined, do: :ets.delete(@vault_table)

      try do
        # POST /keys/:name/create: Store.put raises ArgumentError inside
        # safe_dispatch, which rescued it as 400 InvalidBody — blaming the
        # client for a server-side not-ready state.
        conn =
          call(:post, "/keys/l7key/create",
            body: %{"kty" => "oct"},
            headers: [{"x-ms-version", "2021-12-02"}]
          )

        assert conn.status == 503,
               "POST /keys/l7key/create -> #{conn.status} (fail-open: server fault answered 400 InvalidBody)"

        assert Jason.decode!(conn.resp_body)["error"]["code"] == "RouteNotReady"

        # GET /keys/:name: Store.get raises unrescued -> raw 500.
        conn = call(:get, "/keys/l7key")
        assert conn.status == 503, "GET /keys/l7key -> #{conn.status}"
        assert Jason.decode!(conn.resp_body)["error"]["code"] == "RouteNotReady"
      after
        recreate_vault_table()
      end
    end
  end

  defp recreate_cosmos_tables do
    keep_tables(@cosmos_tables)
  end

  defp recreate_vault_table do
    keep_tables([@vault_table])
  end

  @ledger_tables [:smalt_ledger_transactions, :smalt_ledger_meta]
  @events_tables [:smalt_event_messages]
  @blob_tables [:smalt_blobs, :smalt_blob_containers, :smalt_blob_policy]

  test "lens7: ledger/event/blob list surfaces fail closed 503 on missing tables, never raw 500" do
    if loaded?(Smalt.Security.ConfidentialLedger) and loaded?(Smalt.Messaging.EventStream) do
      Enum.each(@ledger_tables ++ @events_tables ++ @blob_tables, fn t ->
        if :ets.info(t) != :undefined, do: :ets.delete(t)
      end)

      try do
        probes = [
          {:get, "/app/transactions", []},
          {:get, "/app/transactions/latest", []},
          {:get, "/topics/t7/events", []},
          # blob catch-all (x-ms-version satisfies the guard)
          {:get, "/l7acct", [{"x-ms-version", "2021-12-02"}], "comp=list"},
          {:get, "/l7acct/l7cont", [{"x-ms-version", "2021-12-02"}], "comp=list&restype=container"}
        ]

        Enum.each(probes, fn
          {method, path, headers} ->
            conn = call(method, path, headers: headers)
            assert conn.status == 503, "#{method} #{path} -> #{conn.status}"
            assert Jason.decode!(conn.resp_body)["error"]["code"] == "RouteNotReady"

          {method, path, headers, query} ->
            conn = call(method, "#{path}?#{query}", headers: headers)
            assert conn.status == 503, "#{method} #{path}?#{query} -> #{conn.status}"
            assert Jason.decode!(conn.resp_body)["error"]["code"] == "RouteNotReady"
        end)
      after
        keep_tables(@ledger_tables ++ @events_tables ++ @blob_tables)
      end
    end
  end

  # Detached-keeper table recreation (lens-6 cycle-1 finding): ETS public
  # named tables die with their owner, so the keeper must be a detached
  # process that never exits.
  defp keep_tables(tables) do
    Enum.each(tables, fn t ->
      if :ets.info(t) == :undefined do
        spawn(fn ->
          :ets.new(t, [
            :ordered_set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])

          Process.sleep(:infinity)
        end)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Lens 6 cycle 2 — ledger typed-tuple mapping through the dispatch (the 409
  # dedup class was only ever AVOIDED by prior tests, never pinned).
  # ---------------------------------------------------------------------------

  test "ledger dedup 409 routes through dispatch as the typed conflict envelope" do
    if loaded?(Smalt.Security.ConfidentialLedger) do
      Store.put(:smalt_ledger_meta, {:created, "default_ledger"}, true)

      body = Jason.encode!(%{"data" => "dup-409-wire"})

      conn =
        Plug.Test.conn(:post, "/app/transactions", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> EgressRouter.call(@opts)

      assert conn.status == 201

      conn =
        Plug.Test.conn(:post, "/app/transactions", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> EgressRouter.call(@opts)

      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "LedgerItemAlreadyExists"
    end
  end

  # ---------------------------------------------------------------------------
  # Lens 6 cycle 2 — KV typed-tuple mapping through the dispatch: an engine
  # typed {:error, 400, body} rides blob_error to the wire with the status and
  # envelope intact (engine-level fences live in data_plane suites; this pins
  # the ROUTER hop).
  # ---------------------------------------------------------------------------

  test "KV typed 400 rides the router: sign on oct key answers the engine envelope at 400" do
    if loaded?(Smalt.DataPlane.KeyVaultActions) do
      conn = call(:post, "/keys/oct-wire/create", body: %{"kty" => "oct-HSM"})
      assert conn.status == 200

      conn =
        call(:post, "/keys/oct-wire/sign",
          body: Jason.encode!(%{"alg" => "RS256", "value" => Base.encode64("x")}),
          headers: [{"content-type", "application/json"}]
        )

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidAlgorithm"
    end
  end

  # -- wire-tier helpers (local; Bandit + raw :gen_tcp, no HTTP client dep) ----

  defp stop_tree(sup) do
    try do
      Supervisor.stop(sup, :normal, 5000)
    catch
      _, _ -> Process.exit(sup, :kill)
    end
  end

  defp stop_existing_tree do
    case Process.whereis(Smalt.Supervisor) do
      nil ->
        for name <- [Smalt.Store, Smalt.AmqpBroker] do
          if pid = Process.whereis(name), do: GenServer.stop(pid)
        end

      _sup ->
        SmaltTest.Lifecycle.stop_shared_tree()
    end
  end

  defp get_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp wire_request(port, method, path, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body, "")

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
        header_lines <> "\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <> body

    :ok = :gen_tcp.send(sock, request)
    raw = recv_all(sock) |> IO.iodata_to_binary()
    :gen_tcp.close(sock)
    parse_response(raw)
  end

  defp recv_all(sock) do
    case :gen_tcp.recv(sock, 0, 15000) do
      {:ok, data} -> [data | recv_all(sock)]
      {:error, :closed} -> []
    end
  end

  defp parse_response(raw) do
    [head, rest] = :binary.split(raw, "\r\n\r\n")
    [status_line | header_lines] = String.split(head, "\r\n")
    [_, status, _reason] = String.split(status_line, " ", parts: 3)
    body = rest

    body =
      if get_header(header_lines, "transfer-encoding") == "chunked" do
        decode_chunked(body)
      else
        body
      end

    %{status: String.to_integer(status), body: body, headers: header_lines}
  end

  defp get_header(lines, name) do
    case Enum.find(lines, fn l -> String.starts_with?(String.downcase(l), name) end) do
      nil -> nil
      l -> l |> String.split(": ", parts: 2) |> Enum.at(1)
    end
  end

  defp decode_chunked(bin, acc \\ [])

  defp decode_chunked("\r\n" <> rest, acc), do: decode_chunked(rest, acc)

  defp decode_chunked(bin, acc) do
    case Integer.parse(bin, 16) do
      {0, _} ->
        IO.iodata_to_binary(Enum.reverse(acc))

      {size, rest} ->
        <<chunk::binary-size(size), "\r\n", rest2::binary>> = rest
        decode_chunked(rest2, [chunk | acc])

      :error ->
        IO.iodata_to_binary(Enum.reverse(acc))
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-4 cycle 1: splat traversal fuzz + auth-exempt x blob-splat composition
  # ---------------------------------------------------------------------------

  describe "splat traversal fuzz (lens-4)" do
    @ver [{"x-ms-version", "2021-12-02"}]

    test "encoded and raw dot-segment traversals refuse fail-closed BEFORE the version guard" do
      for path <- [
            "/fz/cont/..%2f..%2fsecret",
            "/fz/cont/%2e%2e/x",
            "/fz/cont/%2E%2E",
            "/fz/cont/a%2F..%2Fb",
            "/fz/cont/x/y/../../z",
            "/fz/cont/.",
            "/fz/cont/..",
            "/fz/cont//..",
            "/fz/cont/..%2Fkeys%2Fk1"
          ] do
        # No x-ms-version: the traversal refusal must PRECEDE the version
        # guard (fail-closed first), so the answer is 404 BlobNotFound, not
        # the 400 MissingXMsVersion envelope.
        no_ver = call(:get, path)
        assert no_ver.status == 404,
               "#{path} without x-ms-version answered #{no_ver.status}"

        assert Jason.decode!(no_ver.resp_body)["error"]["code"] == "BlobNotFound",
               "#{path} without x-ms-version answered #{no_ver.resp_body}"

        with_ver = call(:get, path, headers: @ver)
        assert with_ver.status == 404
        assert Jason.decode!(with_ver.resp_body)["error"]["code"] == "BlobNotFound"
      end
    end

    test "traversal refusals carry the F5 error headers (x-ms-request-id, x-ms-version)" do
      conn = call(:get, "/fz/cont/..%2f..%2fsecret")
      assert conn.status == 404
      assert get_resp_header(conn, "x-ms-version") == ["2021-12-02"]

      [req_id] = get_resp_header(conn, "x-ms-request-id")
      assert req_id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end

    test "legal dotfile blob names still round-trip through the splat" do
      call(:put, "/dot/cont?restype=container",
        headers: @ver ++ [{"x-ms-immutable-policy", "false"}]
      )

      put = call(:put, "/dot/cont/.well-known/config.json", body: "cfg", headers: @ver)
      assert put.status == 201, "dotfile PUT answered #{put.status}: #{put.resp_body}"

      get = call(:get, "/dot/cont/.well-known/config.json", headers: @ver)
      assert get.status == 200
      assert get.resp_body == "cfg"

      hidden = call(:get, "/dot/cont/.hidden", headers: @ver)
      assert hidden.status == 404
      assert Jason.decode!(hidden.resp_body)["error"]["code"] == "BlobNotFound"
    end

    test "auth-exempt namespace never reaches the blob splat (fail-closed, no bearer)" do
      # Pin :enforce for this probe; restore honestly (the security suite's
      # delete_env order-masking precedent — lens-3 disclosure).
      prev = Application.get_env(:smalt, :auth_mode)
      Application.put_env(:smalt, :auth_mode, :enforce)

      try do
        for path <- [
              "/.well-known/acct/cont/blob",
              "/oauth2/acct/cont/blob",
              "/attest/exacct/excont/exblob",
              # anchored-regex class: refused at the auth plug (401), the
              # router never sees it — also fail-closed.
              "/tid/oauth2/v2.0/token/extra"
            ] do
          conn = call(:get, path, headers: @ver)
          assert conn.status in [401, 404],
                 "exempt-prefix blob path #{path} answered #{conn.status} (bypass reachable)"

          if conn.status == 404 do
            assert Jason.decode!(conn.resp_body)["error"]["code"] == "BlobNotFound"
          end
        end

        # Exact-exempt class: /metadata/endpoints is 2 segments — blob
        # container-route reachable (account="metadata", container="endpoints").
        meta = call(:get, "/metadata/endpoints", headers: @ver)
        assert meta.status == 404
        assert Jason.decode!(meta.resp_body)["error"]["code"] == "BlobNotFound"

        # Control: a NON-exempt blob path still requires the bearer in
        # :enforce mode — proves the pin is live and auth is upstream.
        control = call(:get, "/ctrl/cont/blob", headers: @ver)
        assert control.status == 401
      after
        if prev == nil do
          Application.delete_env(:smalt, :auth_mode)
        else
          Application.put_env(:smalt, :auth_mode, prev)
        end
      end
    end
  end

  describe "lens-4 cycle-2 fresh shapes + mutation-court probes" do
    @ver [{"x-ms-version", "2021-12-02"}]

    test "5-segment slash-blob PUT with a parsed content-type stores raw bytes verbatim" do
      ver_ct = @ver ++ [{"content-type", "application/json"}]
      call(:put, "/pc5/cont?restype=container", headers: ver_ct)

      put = call(:put, "/pc5/cont/w/1/x/y", body: "{\"deep\":true}", headers: ver_ct)
      assert put.status == 201, "answered #{put.status}: #{put.resp_body}"

      get = call(:get, "/pc5/cont/w/1/x/y", headers: ver_ct)
      assert get.status == 200
      assert get.resp_body == "{\"deep\":true}"
    end

    test "HEAD 2-segment without restype answers RouteNotFound, not the splat BlobNotFound" do
      call(:put, "/hn/cont?restype=container", headers: @ver)

      conn = call(:head, "/hn/cont", headers: @ver)
      assert conn.status == 404
      # Route order pin: the container route owns 2-segment HEADs. Without the
      # ordering (splat first) the empty splat tail would answer BlobNotFound.
      [req_id] = get_resp_header(conn, "x-ms-request-id")
      assert req_id != nil
    end

    test "slash-blob ERROR responses carry the F5 headers (error path through the splat)" do
      call(:put, "/f5/cont?restype=container", headers: @ver)

      gone = call(:get, "/f5/cont/w/1", headers: @ver)
      assert gone.status == 404
      assert Jason.decode!(gone.resp_body)["error"]["code"] == "BlobNotFound"
      assert get_resp_header(gone, "x-ms-version") == ["2021-12-02"]

      [req_id] = get_resp_header(gone, "x-ms-request-id")
      assert req_id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

      # DELETE error path through the splat: same F5 fence.
      del = call(:delete, "/f5/cont/w/1", headers: @ver)
      assert del.status == 404
      assert get_resp_header(del, "x-ms-version") == ["2021-12-02"]
      assert get_resp_header(del, "x-ms-request-id") != []
    end
  end

  describe "raw_blob_put? whitelist redesign (lens-4 coordinator item 1)" do
    @ver [{"x-ms-version", "2021-12-02"}]

    test "cosmos doc replace PUT (3+-segment, dbs namespace) is parsed, never exempt" do
      call(:post, "/dbs", body: %{"id" => "wl"})
      # No explicit partitionKey: a pk-less container does not require the
      # x-ms-documentdb-partitionkey header on doc writes (engine semantics,
      # measured — an explicit /id pk demands the matching header).
      call(:post, "/dbs/wl/colls", body: %{"id" => "c1"})
      # Engine contract (measured): replace requires the _etag carried in the
      # create response body (Cosmos wire shape), not a response header.
      created = call(:post, "/dbs/wl/colls/c1/docs", body: %{"id" => "doc-x", "v" => 1})
      assert created.status == 201, "create answered #{created.status}"
      etag = Jason.decode!(created.resp_body)["_etag"]

      # Raw JSON string body + json content-type: a map body would be
      # pre-set by Plug.Test (body_params populated without parsing) and the
      # probe would be BLIND to the parse exemption (measured — the empty-
      # whitelist mutant survived map-body probes). Only a real parse from
      # the wire body kills the mutant.
      put =
        call(:put, "/dbs/wl/colls/c1/docs/doc-x",
          body: Jason.encode!(%{"v" => 7}),
          headers: [{"content-type", "application/json"}, {"if-match", etag}]
        )

      assert put.status == 200, "doc replace answered #{put.status}: #{put.resp_body}"
      assert Jason.decode!(put.resp_body)["v"] == 7
    end

    test "blob shapes (3/4/5 segments, non-listed namespace) stay parse-exempt" do
      ver_ct = @ver ++ [{"content-type", "application/json"}]
      call(:put, "/wlacc/cont?restype=container", headers: ver_ct)

      for blob_path <- ["/wlacc/cont/b", "/wlacc/cont/a/b", "/wlacc/cont/a/b/c"] do
        put = call(:put, blob_path, body: "{\"raw\":1}", headers: ver_ct)
        assert put.status == 201, "#{blob_path} answered #{put.status}"

        get = call(:get, blob_path, headers: ver_ct)
        assert get.resp_body == "{\"raw\":1}", "#{blob_path} did not store verbatim"
      end
    end

    # Lens-5 cycle 2 — the whitelist extension law, probe side. The @modules
    # comment claims: adding a literal 3+-segment PUT route REQUIRES a
    # @non_blob_put_namespaces entry; a MISSED entry fails VISIBLE (parsed
    # body on a blob-shaped PUT => zero-byte store). This fence pins the
    # healthy direction for a namespace that owns NO 3+-segment PUT route
    # (/keys today): its blob-shaped PUTs must stay parse-exempt and store
    # verbatim, and whitelisting can never relax AUTH (the whitelist is a
    # parse seam, orthogonal to the exempt namespace — a mutant that adds
    # "keys" to the whitelist must not create an anonymous bypass).
    # R111 reconcile (V17): /keys left the parse-exempt probe set — R99's
    # reserved-namespace fence supersedes the whitelist law's /keys premise
    # (D70 classifies a 201 blob-store under /keys/<name>/<action> as the
    # wrong-plane defect). The parse-exemption law re-homes on /vltkv, a
    # namespace that owns no 3+-segment PUT route and is in NO reserved set;
    # /keys itself now answers the typed KV 404 (assertion (c)).
    test "whitelist extension law: non-listed service namespace stores verbatim, auth unaffected" do
      ver_ct = @ver ++ [{"content-type", "application/json"}]
      prev = Application.get_env(:smalt, :auth_mode)
      Application.put_env(:smalt, :auth_mode, :enforce)

      try do
        # (a) AUTH unaffected: an anonymous blob-shaped PUT under a service
        # prefix is still 401 in :enforce — the whitelist is a parse seam,
        # not an auth grant.
        anon = call(:put, "/vltkv/vltkey/create", body: "{\"raw\":1}", headers: ver_ct)
        assert anon.status == 401, "anonymous PUT answered #{anon.status} (bypass?)"

        # (b) Parse seam healthy: with auth passing (:anonymous pin), the raw
        # wire body (a JSON string + json content-type — the ONLY probe form
        # that witnesses the parse seam, lens-4 cycle-3 method note) stores
        # verbatim. /vltkv/<name>/<action> is blob-shaped (3 segments, no
        # comp) and parse-exempt because "vltkv" does NOT own a 3+-segment
        # PUT route and is therefore NOT whitelisted.
        Application.put_env(:smalt, :auth_mode, :anonymous)

        call(:put, "/vltkv/vltkey?restype=container",
          headers: ver_ct ++ [{"x-ms-immutable-policy", "false"}]
        )

        put = call(:put, "/vltkv/vltkey/create", body: "{\"raw\":1}", headers: ver_ct)
        assert put.status == 201, "answered #{put.status}: #{put.resp_body}"

        get = call(:get, "/vltkv/vltkey/create", headers: ver_ct)
        assert get.resp_body == "{\"raw\":1}", "did not store verbatim"

        # (c) R99 fence: the same blob-shaped PUT under the RESERVED /keys
        # namespace is refused fail-closed with the typed KV envelope —
        # nothing is stored (D70 wrong-plane class stays closed).
        kv = call(:put, "/keys/vltkey/create", body: "{\"raw\":1}", headers: ver_ct)
        assert kv.status == 404, "reserved /keys answered #{kv.status}: #{kv.resp_body}"

        body = Jason.decode!(kv.resp_body)
        assert body["error"]["code"] == "NotFound"
        assert String.contains?(body["error"]["message"], "reserved namespace 'keys'")
      after
        if prev == nil do
          Application.delete_env(:smalt, :auth_mode)
        else
          Application.put_env(:smalt, :auth_mode, prev)
        end
      end
    end
  end

  test "wire-tier (Bandit): encoded traversal and exempt-prefix blob paths fail closed at the socket" do
    port = get_free_port()
    stop_existing_tree()

    children = [
      Smalt.Store,
      {Bandit, plug: Smalt.EgressRouter, scheme: :http, port: port}
    ]

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

    on_exit(fn ->
      stop_tree(sup)
      SmaltTest.Lifecycle.restore_app()
      SmaltTest.Lifecycle.ensure_store_up()
    end)

    hts = [{"x-ms-version", "2021-12-02"}]

    for {path, want} <- [
          {"/fzw/cont/..%2f..%2fsecret", "BlobNotFound"},
          {"/fzw/cont/%2e%2e", "BlobNotFound"},
          {"/.well-known/acct/cont/blob", "BlobNotFound"},
          {"/oauth2/acct/cont/blob", "BlobNotFound"}
        ] do
      resp = wire_request(port, "GET", path, headers: hts)
      assert resp.status == 404, "#{path} answered #{resp.status} at the wire"
      assert resp.body =~ "#{want}", "#{path} body: #{resp.body}"
    end
  end

  # ---------------------------------------------------------------------------
  # Lens-5 cycle 1: full exempt-prefix x verb x depth x encoding fuzz matrix
  # through the canonical predicate (Smalt.Auth.Bearer.auth_exempt_path?/1).
  # Invariant under fuzz: any request path that the auth plug treats as
  # auth-exempt (no bearer required) must NEVER admit blob CRUD at the splat;
  # every non-exempt shape must require the bearer (401 anonymous). The
  # oracle is the canonical predicate — the router must not carry its own
  # prefix copy (anti O(N^2) drift law, lens-4 cycle 1).
  # ---------------------------------------------------------------------------

  describe "exempt-prefix fuzz matrix through the canonical predicate (lens-5)" do
    @ver [{"x-ms-version", "2021-12-02"}]

    # The full exempt-namespace surface from lib/smalt/auth/bearer.ex:
    # 4 prefix classes + 3 exact matches + the tenant-scoped anchored regex.
    @exempt_prefixes ["/oauth2/", "/.well-known/", "/common/discovery/", "/attest/"]
    @exempt_exact ["/metadata/endpoints", "/tenant", "/tenants"]

    test "canonical predicate agrees with the declared exempt classes (oracle pin)" do
      alias Smalt.Auth.Bearer

      for p <- @exempt_prefixes ++ @exempt_exact do
        assert Bearer.auth_exempt_path?(p), "#{p} must be auth-exempt (oracle pin)"
      end

      for p <- [
            "/tid/oauth2/v2.0/token",
            "/1234-5678/oauth2/v2.0/token",
            "/a-b_c/oauth2/v2.0/token"
          ] do
        assert Bearer.auth_exempt_path?(p), "#{p} (tenant token form) must be exempt"
      end

      # Non-exempt controls: near-miss shapes that must NOT be exempt.
      for p <- [
            "/oauth2x/a/b",
            "/xoauth2/a/b",
            "/.well-knownx/a/b",
            "/metadatA/endpoints",
            "/metadata/endpointsx",
            "/metadata/endpoints/",
            "/tenant/x",
            "/tenants/x",
            "/tenantx"
          ] do
        refute Bearer.auth_exempt_path?(p), "#{p} must NOT be auth-exempt"
      end
    end

    test "every exempt shape x verb x splat depth refuses blob CRUD anonymously" do
      # Pin :enforce; honest restore.
      prev = Application.get_env(:smalt, :auth_mode)
      Application.put_env(:smalt, :auth_mode, :enforce)

      try do
        exempt_shapes =
          for p <- @exempt_prefixes,
              depth <- 1..4 do
            {p <> String.duplicate("seg/", depth) <> "blob", true}
          end ++
            for p <- @exempt_exact,
                suffix <- ["", "/", "/x", "/x/y/z"] do
              # exact-exempt matches ONLY the exact path (no prefix
              # relaxation): any suffix other than "" is NOT exempt.
              {p <> suffix, suffix == ""}
            end ++
            [
              # tenant-scoped token path (anchored regex class) and its
              # near-miss deeper/encoded forms — none may admit blob CRUD.
              {"/tid/oauth2/v2.0/token", true},
              {"/9e6b0e6f-1234-5678-90ab-cdef01234567/oauth2/v2.0/token", true},
              {"/tid/oauth2/v2.0/token/extra", false},
              {"/t1/t2/oauth2/v2.0/token", false},
              {"/tid/oauth2/v2.0/tokens", false},
              {"/tid/oauth2/v2.1/token", false},
              {"/TID/oauth2/v2.0/token", true},
              {"/tid//oauth2/v2.0/token", false},
              {"/tid/oauth2//v2.0/token", false}
            ]

        for {path, must_be_exempt} <- exempt_shapes,
            verb <- [:get, :put, :post, :delete, :head] do
          conn =
            call(verb, path,
              headers: @ver ++ [{"content-type", "application/octet-stream"}],
              body: "x"
            )

          if must_be_exempt do
            # Auth-exempt: the plug passes; the router's blob guard must
            # refuse blob-reachable depths fail-closed (404), never 2xx/3xx.
            assert conn.status in [404, 405],
                   "exempt shape #{verb} #{path} answered #{conn.status} — bypass reachable"

            if conn.status == 404 do
              # HEAD answers empty — decode only a JSON body.
              code =
                if conn.resp_body == "" do
                  nil
                else
                  Jason.decode!(conn.resp_body)["error"]["code"]
                end

              assert code in [nil, "BlobNotFound", "RouteNotFound"], "#{path}: #{conn.resp_body}"
            end
          else
            # Non-exempt: the anonymous request must 401 at the plug.
            assert conn.status == 401,
                   "non-exempt shape #{verb} #{path} answered #{conn.status} (expected 401)"

            assert get_resp_header(conn, "www-authenticate") != []
          end
        end
      after
        if prev == nil do
          Application.delete_env(:smalt, :auth_mode)
        else
          Application.put_env(:smalt, :auth_mode, prev)
        end
      end
    end

    test "encoded-prefix and double-slash forms never land inside the exempt namespace" do
      prev = Application.get_env(:smalt, :auth_mode)
      Application.put_env(:smalt, :auth_mode, :enforce)

      try do
        alias Smalt.Auth.Bearer

        for path <- [
              # percent-encoded dot: NOT the exempt prefix at the plug (401
              # anonymous), and the store namespace it would address
              # ("%2Ewell-known") is a DIFFERENT account than ".well-known".
              "/%2Ewell-known/acct/cont/blob",
              "/%2f.well-known/acct/cont/blob",
              "/oauth%2F2/acct/cont/blob",
              # double-slash forms: leading "" segment, prefix never matches.
              "//.well-known/acct/cont/blob",
              "//oauth2/acct/cont/blob",
              "/.well-known//acct/cont/blob",
              "/oauth2//acct/cont/blob",
              # encoded traversal riding an exempt prefix: refusal precedes
              # the version guard regardless of auth mode.
              "/.well-known/..%2f..%2fsecret",
              "/oauth2/%2e%2e/x"
            ] do
          conn = call(:get, path, headers: @ver)

          # Either the auth plug refuses (401, non-exempt shape) or the
          # router's blob guard refuses (404). Never 2xx, never the 400
          # version envelope (the guard must precede it).
          assert conn.status in [401, 404],
                 "#{path} answered #{conn.status} (body: #{conn.resp_body})"

          if conn.status == 404 do
            code = Jason.decode!(conn.resp_body)["error"]["code"]
            assert code in ["BlobNotFound", "RouteNotFound"], "#{path}: #{conn.resp_body}"
          end

          # One-predicate law: the router's decision must equal the
          # canonical predicate evaluated on the same request_path string.
          exempt = Bearer.auth_exempt_path?(conn.request_path)

          if exempt and conn.status == 404 do
            assert Jason.decode!(conn.resp_body)["error"]["code"] == "BlobNotFound"
          end
        end

        # Encoded-prefix control: the encoded shape is a different STORE
        # namespace — with a bearer-less anonymous request it must not even
        # create state. Negative-control round trip: the exempt namespace
        # itself still serves nothing through the splat.
        refute Bearer.auth_exempt_path?("/%2Ewell-known/acct/cont/blob")
      after
        if prev == nil do
          Application.delete_env(:smalt, :auth_mode)
        else
          Application.put_env(:smalt, :auth_mode, prev)
        end
      end
    end

    test "PUT exempt-namespace depth-3+ refuses BEFORE body read (no blob state created)" do
      # :anonymous mode isolates the ROUTER-side guard: the exempt refusal is
      # auth-independent (blob_route/2 checks the canonical predicate
      # unconditionally, whatever the auth plug decided), so the cleanest
      # measurement pins :anonymous and lets the exempt control store.
      prev = Application.get_env(:smalt, :auth_mode)
      Application.put_env(:smalt, :auth_mode, :anonymous)

      try do
        call(:put, "/wk/cont?restype=container", headers: @ver)

        for path <- [
              "/.well-known/wk/cont/secret",
              "/oauth2/wk/cont/secret",
              "/common/discovery/wk/cont/secret",
              "/attest/wk/cont/secret"
            ] do
          conn =
            call(:put, path,
              headers: @ver ++ [{"content-type", "application/octet-stream"}],
              body: "payload"
            )

          assert conn.status == 404, "#{path} answered #{conn.status}"
          assert Jason.decode!(conn.resp_body)["error"]["code"] == "BlobNotFound"
        end

        # The exact-exempt class (/metadata/endpoints) matches ONLY the exact
        # 2-segment path — a longer path is NOT exempt; in :anonymous the plug
        # passes it and the router answers honestly (404 BlobNotFound through
        # the container route with restype absent).
        meta_put = call(:put, "/metadata/endpoints/wk/cont/secret", headers: @ver)
        assert meta_put.status == 404

        # The control in the NON-exempt namespace stores fine — proves the
        # refusal is namespace-scoped, not global.
        ctrl = call(:put, "/wk/cont/visible", headers: @ver)
        assert ctrl.status == 201, "control answered #{ctrl.status}: #{ctrl.resp_body}"
      after
        if prev == nil do
          Application.delete_env(:smalt, :auth_mode)
        else
          Application.put_env(:smalt, :auth_mode, prev)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # V261014-18 — engine-kill court (work order §3.2): the RouteNotReady 503
  # fail-closed law is proven against the REAL live engine, not the
  # module-not-compiled seam. A real HTTP request over :gen_tcp rides the
  # loaded cosmos engine module to a 2xx BEFORE; the module is then purged
  # and deleted from the code server (:code.purge + :code.delete — for a
  # functional engine, module unload IS the live-engine kill), the same
  # request now genuinely fails Code.ensure_loaded?/1 in not_ready?/2 and
  # must answer 503 RouteNotReady — never 201/200; the module is then
  # restored and a third request must answer 2xx again (AFTER proves the
  # kill was real and the court non-vacuous).
  #
  # Isolation (discipline of the detached-keeper note at :1523): the kill
  # runs against an ISOLATED child tree (private Store + Bandit on an
  # ephemeral port booted inside this test), never the shared tree, so
  # shuffled siblings inherit neither the stopped tree nor the purged module
  # — the module is restored in-test AND again in on_exit.
  # ---------------------------------------------------------------------------
  describe "engine-kill court: real engine unload -> 503 RouteNotReady over real :gen_tcp" do
    @tag :engine_kill_court
    test "BEFORE 2xx / KILL -> 503 RouteNotReady (refute 201/200) / RESTORE -> 2xx" do
      port = boot_isolated_tree()
      cosmos = Smalt.DataPlane.Cosmos
      beam = Path.join(Mix.Project.compile_path(), "#{Atom.to_string(cosmos)}.beam")
      assert File.exists?(beam), "cosmos beam missing at #{beam}"
      hidden = beam <> ".hidden_engine_kill"

      on_exit(fn ->
        # Global code-state hygiene: whatever happened in the body, the cosmos
        # module must be loaded and the beam in place before the next shuffled
        # sibling runs.
        if File.exists?(hidden) do
          File.rename!(hidden, beam)
        end

        :code.purge(cosmos)
        Code.ensure_loaded(cosmos)
        stop_tree_quiet()
        SmaltTest.Lifecycle.restore_app()
      end)

      # BEFORE — real HTTP, real loaded engine.
      assert Code.ensure_loaded?(cosmos)
      before = wire_request(port, "GET", "/dbs", headers: [{"content-type", "application/json"}])
      assert before.status == 200,
             "BEFORE baseline answered #{before.status} (#{before.body}) — court precondition"

      # KILL — for a functional engine, module unload IS the live-engine kill:
      # purge+delete the loaded module AND hide the beam file. Purge+delete
      # alone is NOT a kill — Code.ensure_loaded?/1 reloads from the on-disk
      # beam (measured: the court's own refute caught it on first run) — so
      # the loader must be starved on disk too, same mechanics as the Purview
      # seam test above.
      File.rename!(beam, hidden)
      :code.purge(cosmos)
      :code.delete(cosmos)
      refute Code.ensure_loaded?(cosmos), "engine module still loaded after purge+delete+beam-hide"

      killed = wire_request(port, "GET", "/dbs", headers: [{"content-type", "application/json"}])

      assert killed.status == 503,
             "KILLED engine answered #{killed.status} (#{killed.body}) — expected 503 RouteNotReady"

      assert Jason.decode!(killed.body)["error"]["code"] == "RouteNotReady"

      # The law, stated in the failure message: a not-ready route never
      # answers with a success shape.
      refute killed.status in [200, 201],
             "killed engine answered #{killed.status} — RouteNotReady 503 law violated " <>
               "(fail-open: success-shaped answer about server state)"

      # RESTORE — proves the kill was real and the court non-vacuous.
      File.rename!(hidden, beam)
      assert Code.ensure_loaded(cosmos) == {:module, cosmos}
      assert Code.ensure_loaded?(cosmos)

      after_resp =
        wire_request(port, "GET", "/dbs", headers: [{"content-type", "application/json"}])

      assert after_resp.status == 200,
             "RESTORE answered #{after_resp.status} (#{after_resp.body}) — the kill was real " <>
               "and the court is non-vacuous"
    end
  end

  defp boot_isolated_tree do
    stop_existing_tree()

    port = get_free_port()

    Application.put_env(:smalt, :arm_port, get_free_port())
    Application.put_env(:smalt, :egress_port, port)
    Application.put_env(:smalt, :amqp_port, get_free_port())

    {:ok, sup} =
      Supervisor.start_link(
        [Smalt.Store, {Bandit, plug: Smalt.EgressRouter, scheme: :http, port: port}],
        strategy: :one_for_one,
        name: __MODULE__.EngineKillSup
      )

    Process.put({__MODULE__, :engine_kill_sup}, sup)
    port
  end

  defp stop_tree_quiet do
    case Process.get({__MODULE__, :engine_kill_sup}) do
      nil ->
        :ok

      sup ->
        try do
          Supervisor.stop(sup, :normal, 5000)
        catch
          _, _ -> Process.exit(sup, :kill)
        end

        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # R155 (DoD D87) wire/dispatch-tier fences W1-W3
  # ---------------------------------------------------------------------------

  # W1: container lease/ACL comps are unimplemented (GAP
  # (blob-comp-lease-absent)); the PUT and GET container arms must answer a
  # typed 400 InvalidQueryParameter naming the GAP with the x-ms-error-code
  # header — never a silent 201/200 fallthrough.
  describe "R155 W1 container comp fences" do
    @ver [{"x-ms-version", "2025-01-01"}]

    test "PUT /{acct}/{cont}?comp=lease and ?comp=acl answer 400 InvalidQueryParameter" do
      for comp <- ["lease", "acl"] do
        conn = call(:put, "/r155acct/r155cont?comp=#{comp}", headers: @ver, body: "{}")

        assert conn.status == 400, "comp=#{comp} answered #{conn.status}: #{conn.resp_body}"

        assert %{"error" => %{"code" => "InvalidQueryParameter", "message" => msg}} =
                 Jason.decode!(conn.resp_body)

        assert msg =~ "GAP(blob-comp-lease-absent)"
        assert get_resp_header(conn, "x-ms-error-code") == ["InvalidQueryParameter"]
      end
    end

    test "GET /{acct}/{cont}?comp=lease and ?comp=acl answer 400 InvalidQueryParameter" do
      for comp <- ["lease", "acl"] do
        conn = call(:get, "/r155acct/r155cont?comp=#{comp}", headers: @ver)

        assert conn.status == 400, "comp=#{comp} answered #{conn.status}: #{conn.resp_body}"

        assert %{"error" => %{"code" => "InvalidQueryParameter", "message" => msg}} =
                 Jason.decode!(conn.resp_body)

        assert msg =~ "GAP(blob-comp-lease-absent)"
        assert get_resp_header(conn, "x-ms-error-code") == ["InvalidQueryParameter"]
      end
    end
  end

  # W2: Cosmos PATCH admission gates at the dispatch tier — a valid RFC 6902
  # replace is 200; a pk-move patch is a typed 400; a unique-key steal is 409.
  describe "R155 W2 Cosmos PATCH gates" do
    test "PATCH valid replace is 200, pk-move is 400, unique-key steal is 409" do
      call(:post, "/dbs", body: %{"id" => "r155db"})

      call(:post, "/dbs/r155db/colls",
        body: %{
          "id" => "r155coll",
          "partitionKey" => %{"paths" => ["/tenantId"]},
          "uniqueKeyPolicy" => %{"uniqueKeys" => [%{"paths" => ["/code"]}]}
        }
      )

      pk = [{"x-ms-documentdb-partitionkey", ~s(["r155"])}, {"content-type", "application/json"}]

      for {id, code} <- [{"doc-a", "A"}, {"doc-b", "B"}] do
        create = call(:post, "/dbs/r155db/colls/r155coll/docs", headers: pk, body: %{"id" => id, "tenantId" => "r155", "code" => code})
        assert create.status == 201, "#{id} create answered #{create.status}: #{create.resp_body}"
      end

      # Valid replace: 200 with a fresh _etag.
      patch = call(:patch, "/dbs/r155db/colls/r155coll/docs/doc-a",
        headers: pk,
        body: [%{"op" => "replace", "path" => "/code", "value" => "A2"}]
      )

      assert patch.status == 200, "valid patch answered #{patch.status}: #{patch.resp_body}"
      body = Jason.decode!(patch.resp_body)
      assert body["code"] == "A2"
      assert is_binary(body["_etag"]) and body["_etag"] != ""

      # Partition-key move (patched body pk no longer matches the header): 400.
      pk_move = call(:patch, "/dbs/r155db/colls/r155coll/docs/doc-a",
        headers: pk,
        body: [%{"op" => "replace", "path" => "/tenantId", "value" => "elsewhere"}]
      )

      assert pk_move.status == 400, "pk-move answered #{pk_move.status}: #{pk_move.resp_body}"
      assert Jason.decode!(pk_move.resp_body)["code"] == "BadRequest"

      # Unique-key steal (doc-b's /code -> "A2", already held by doc-a after
      # the valid patch above): 409.
      steal = call(:patch, "/dbs/r155db/colls/r155coll/docs/doc-b",
        headers: pk,
        body: [%{"op" => "replace", "path" => "/code", "value" => "A2"}]
      )

      assert steal.status == 409, "unique-key steal answered #{steal.status}: #{steal.resp_body}"
      assert Jason.decode!(steal.resp_body)["code"] == "Conflict"
    end
  end

  # W3: A-IM: Incremental feed at the dispatch tier — only-new docs on the
  # second read plus the x-ms-continuation header on every feed response.
  describe "R155 W3 change feed" do
    test "feed returns only-new docs with continuation header" do
      call(:post, "/dbs", body: %{"id" => "r155cfdb"})
      call(:post, "/dbs/r155cfdb/colls", body: %{"id" => "r155cfcoll"})

      for i <- 1..2 do
        create = call(:post, "/dbs/r155cfdb/colls/r155cfcoll/docs", body: %{"id" => "seed-#{i}", "n" => i})
        assert create.status == 201, "seed-#{i} answered #{create.status}"
      end

      feed = call(:get, "/dbs/r155cfdb/colls/r155cfcoll/docs", headers: [{"a-im", "Incremental feed"}])

      assert feed.status == 200, "feed answered #{feed.status}: #{feed.resp_body}"
      assert Jason.decode!(feed.resp_body)["_count"] == 2
      assert get_resp_header(feed, "x-ms-continuation") != []

      third = call(:post, "/dbs/r155cfdb/colls/r155cfcoll/docs", body: %{"id" => "seed-3", "n" => 3})
      assert third.status == 201

      feed2 = call(:get, "/dbs/r155cfdb/colls/r155cfcoll/docs", headers: [{"a-im", "Incremental feed"}])

      assert feed2.status == 200
      body2 = Jason.decode!(feed2.resp_body)
      assert body2["_count"] == 1, "second feed answered #{feed2.resp_body}"
      assert [%{"id" => "seed-3"}] = body2["Documents"]
      assert get_resp_header(feed2, "x-ms-continuation") != []
    end
  end
end
