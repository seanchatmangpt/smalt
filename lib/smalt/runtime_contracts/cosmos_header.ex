defmodule Smalt.RuntimeContracts.CosmosHeader do
  @moduledoc """
  Cosmos DB NoSQL header contract binding `Smalt.EgressRouter`'s `/dbs`
  surface to its consumers.

  Fences, in-process, the CONFORMANT header invariants pinned by
  `test/compliance/c3_cosmos.exs` and `docs/compliance/C3_COSMOS.md`:

    * required header set on success AND error:
      `x-ms-request-charge`, `x-ms-session-token`, `x-ms-lsn`,
      `x-ms-alt-content-path` (path-echo on success)
    * `_etag` quoted 64-hex, stable across read, refreshed on write
    * system properties `_rid`, `_self` path grammar, `_ts` integer seconds
    * status semantics: 201 create / 200 replace / 204 conditional delete /
      404 NotFound with canonical message
    * partition-key header semantics: missing / non-array / mismatched -> 400
      BadRequest
    * query envelope `application/query+json` -> 200 feed
      `{_rid, Documents, _count}`

  Template source: ash-runtime-integration-contract-pack
  `templates/api_contract.ex.tmpl`, adapted (see
  `docs/PACK_INTEGRATION/runtime-contracts.md`).
  """

  alias Smalt.RuntimeContracts.Support

  @behaviour Smalt.RuntimeContracts.Contract

  @db "rtc-fence"
  @coll "rtc-coll"
  @pk {"x-ms-documentdb-partitionkey", ~s(["acme"])}
  @json {"content-type", "application/json"}

  @impl true
  def name, do: :cosmos_header

  @impl true
  def plane, do: :data_plane

  @impl true
  def consumer, do: "Smalt.EgressRouter (/dbs surface)"

  @impl true
  def source_pack, do: "ash-runtime-integration-contract-pack"

  @impl true
  def check do
    seed()

    Support.contract(:cosmos_header, [
      {:required_header_set_on_create, fn -> check_required_headers(:create) end},
      {:required_header_set_on_404, fn -> check_required_headers(:not_found) end},
      {:etag_quoted_stable_refreshed, fn -> check_etag() end},
      {:system_properties_rid_self_ts, fn -> check_system_properties() end},
      {:status_semantics_create_replace_delete, fn -> check_status_semantics() end},
      {:pk_header_semantics_400, fn -> check_pk_semantics() end},
      {:query_envelope_feed, fn -> check_query_envelope() end},
      {:database_account_envelope, fn -> check_database_account() end}
    ])
  end

  # ===========================================================================
  # checks
  # ===========================================================================

  defp check_required_headers(:create) do
    create_doc("hdr-create")

    resp = get_doc("hdr-create")
    hm = resp.headers

    Enum.each(
      ["x-ms-request-charge", "x-ms-session-token", "x-ms-lsn", "x-ms-alt-content-path"],
      fn h ->
        Support.assert(Map.has_key?(hm, h), "missing required Cosmos header #{h}")
      end
    )

    Support.assert_equal(
      hm["x-ms-alt-content-path"],
      "dbs/#{@db}/colls/#{@coll}",
      "alt-content-path echoes the container path"
    )

    Support.assert(hm["x-ms-session-token"] =~ ~r/^\d+#\d+$/, "session token shape lsn#range")
    Support.assert(String.to_integer(hm["x-ms-lsn"]) >= 0, "x-ms-lsn is a non-negative integer")
  end

  defp check_required_headers(:not_found) do
    resp = get_doc("never-created-404")
    hm = resp.headers

    Enum.each(["x-ms-request-charge", "x-ms-session-token", "x-ms-lsn"], fn h ->
      Support.assert(Map.has_key?(hm, h), "404 missing required header #{h}")
    end)

    body = Jason.decode!(resp.body)
    Support.assert_equal(body["code"], "NotFound", "404 code")
    Support.assert_equal(
      body["message"],
      "Entity with the specified id does not exist in the system.",
      "404 canonical message"
    )
  end

  defp check_etag do
    doc = create_and_read("etag-doc")

    Support.assert(doc["_etag"] =~ ~r/^"[0-9a-f]{64}"$/, "_etag is quoted 64-hex")

    reread = get_doc("etag-doc")
    Support.assert_equal(Jason.decode!(reread.body)["_etag"], doc["_etag"], "_etag stable on read")
    Support.assert_equal(reread.headers["etag"], doc["_etag"], "ETag header equals body _etag")

    put =
      dispatch(:put, "/dbs/#{@db}/colls/#{@coll}/docs/etag-doc",
        headers: [@pk, @json],
        body: ~s({"id":"etag-doc","tenantId":"acme","v":2})
      )

    Support.assert_equal(put.status, 200, "replace -> 200")
    new_doc = Jason.decode!(put.body)
    Support.assert(new_doc["_etag"] != doc["_etag"], "_etag refreshed on write")
    Support.assert(new_doc["_ts"] >= doc["_ts"], "_ts monotone on write")
  end

  defp check_system_properties do
    doc = create_and_read("sysprops-doc")

    Support.assert(is_binary(doc["_rid"]) and doc["_rid"] != "", "_rid present")
    Support.assert_equal(doc["_self"], "/dbs/#{@db}/colls/#{@coll}/docs/sysprops-doc", "_self grammar")
    Support.assert(is_integer(doc["_ts"]), "_ts integer seconds")
  end

  defp check_status_semantics do
    create_doc("sem-doc")
    etag = Jason.decode!(get_doc("sem-doc").body)["_etag"]

    resp = dispatch(:delete, "/dbs/#{@db}/colls/#{@coll}/docs/sem-doc", headers: [{"if-match", etag}, @pk])
    Support.assert_equal(resp.status, 204, "conditional delete with matching If-Match -> 204")

    resp = dispatch(:delete, "/dbs/#{@db}/colls/#{@coll}/docs/sem-doc")
    Support.assert_equal(resp.status, 404, "second delete -> 404")
  end

  defp check_pk_semantics do
    bodies = [
      {[], ~s({"id":"pk1","tenantId":"acme"})},
      {[{"x-ms-documentdb-partitionkey", "acme"}], ~s({"id":"pk2","tenantId":"acme"})},
      {[@pk], ~s({"id":"pk3","tenantId":"other"})}
    ]

    Enum.each(bodies, fn {hdrs, body} ->
      resp =
        dispatch(:post, "/dbs/#{@db}/colls/#{@coll}/docs",
          headers: [@json | hdrs],
          body: body
        )

      Support.assert_equal(resp.status, 400, "bad pk header -> 400 (headers: #{inspect(hdrs)})")
      Support.assert_equal(Jason.decode!(resp.body)["code"], "BadRequest", "bad pk header code")
    end)
  end

  defp check_query_envelope do
    create_doc("q1")
    create_doc("q2")

    resp =
      dispatch(:post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [{"content-type", "application/query+json"}, @pk],
        body: ~s({"query":"SELECT * FROM c","parameters":[]})
      )

    Support.assert_equal(resp.status, 200, "query POST -> 200")
    body = Jason.decode!(resp.body)
    Support.assert_equal(MapSet.new(Map.keys(body)), MapSet.new(["_rid", "Documents", "_count"]), "feed keys")

    Support.assert(body["_count"] >= 2, "feed count includes seeded docs")
    Support.assert(
      Enum.all?(body["Documents"], &(&1["tenantId"] == "acme")),
      "query respects partition filter"
    )
  end

  defp check_database_account do
    resp = dispatch(:get, "/")

    Support.assert_equal(resp.status, 200, "database account GET / -> 200")
    body = Jason.decode!(resp.body)
    Support.assert_equal(body["kind"], "DatabaseAccount", "account kind")
    Support.assert(is_list(body["writableLocations"]), "writableLocations list")
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

  defp seed do
    Support.assert_equal(
      dispatch(:post, "/dbs", headers: [@json], body: ~s({"id":"#{@db}"})).status,
      201,
      "seed db"
    )

    Support.assert_equal(
      dispatch(:post, "/dbs/#{@db}/colls",
        headers: [@json],
        body: ~s({"id":"#{@coll}","partitionKey":{"paths":["/tenantId"]}})
      ).status,
      201,
      "seed container"
    )
  end

  defp create_doc(id) do
    resp =
      dispatch(:post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [@pk, @json],
        body: ~s({"id":"#{id}","tenantId":"acme"})
      )

    Support.assert_equal(resp.status, 201, "create doc #{id} -> 201")
    resp
  end

  defp create_and_read(id) do
    create_doc(id)
    get_doc(id) |> Map.fetch!(:body) |> Jason.decode!()
  end

  defp get_doc(id) do
    dispatch(:get, "/dbs/#{@db}/colls/#{@coll}/docs/#{id}", headers: [@pk])
  end

  defp dispatch(method, path, opts \\ []),
    do: Support.dispatch(Smalt.EgressRouter, method, path, opts)
end
