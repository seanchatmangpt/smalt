defmodule EgressDispatchTest do
  use ExUnit.Case
  use Plug.Test

  alias Smalt.EgressRouter
  alias Smalt.Store

  @opts EgressRouter.init([])

  setup do
    # Other suites stop the main app tree to run private trees; never assume
    # module run order — restore the shared app if the Store is gone.
    if Process.whereis(Smalt.Store) == nil do
      SmaltTest.Lifecycle.restore_app()
    end

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
      assert [%{"id" => "d1"}] = Jason.decode!(conn.resp_body)

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
        call(:post, "/v1/workspaces/ws-1/query", body: %{"query" => "MyTable | take 10"})

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
        call(:post, "/keys/skr-key/release", headers: [{"authorization", "Bearer " <> token}])

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
      call(:post, "/keys/legacy-key/release",
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
      call(:post, "/keys/legacy-key2/release",
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
      call(:post, "/keys/bogus-key/release", headers: [{"authorization", "Bearer not.a.jwt"}])

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "UnauthorizedAttestation"
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
    conn = call(:get, "/definitely/not/a/route")
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
end
