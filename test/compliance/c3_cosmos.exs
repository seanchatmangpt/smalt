defmodule Smalt.Compliance.C3CosmosTest do
  @moduledoc """
  C3 — Azure Cosmos DB NoSQL wire-protocol compliance fence (live wire tier).

  Boots `Smalt.EgressRouter` under Bandit on an ephemeral port per test and
  makes real HTTP requests (inets `:httpc`). Fences the CONFORMANT rows of
  `docs/compliance/C3_COSMOS.md`. GAP rows are never fenced as passing; the
  two most load-bearing GAPs (x-ms-retry-after-ms on 429, master-key
  Authorization validation) are pinned as currently-absent with explicit
  comments. Spec basis: Azure Cosmos DB NoSQL REST API — required response
  headers, `_etag` quoting, system properties, partition-key header semantics,
  `application/query+json` envelope, status-code semantics.
  """

  use ExUnit.Case, async: false

  alias Smalt.DataPlane.Cosmos
  alias Smalt.Store

  @db "c3fence"
  @coll "fencecoll"
  @pk_hdr {"x-ms-documentdb-partitionkey", ~s(["acme"])}
  @json {"content-type", "application/json"}

  setup do
    ensure_store()
    Store.clear()

    prev_auth = Application.get_env(:smalt, :auth_mode)
    Application.put_env(:smalt, :auth_mode, :anonymous)

    port = free_port()
    :persistent_term.put({__MODULE__, :port}, port)
    {:ok, server} = Bandit.start_link(plug: Smalt.EgressRouter, port: port)

    on_exit(fn ->
      stop_server(server)
      Application.put_env(:smalt, :auth_mode, prev_auth || :anonymous)
    end)

    {:ok, port: port}
  end

  # ---------------------------------------------------------------------------
  # Required response headers on success AND error responses
  # ---------------------------------------------------------------------------

  test "201 create carries the required Cosmos header set + alt-content-path" do
    create_db()
    create_coll()

    resp =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [@pk_hdr, @json],
        body: ~s({"id":"d1","tenantId":"acme"})
      )

    assert resp.status == 201
    hm = header_map(resp)

    for h <- ["x-ms-request-charge", "x-ms-session-token", "x-ms-lsn", "x-ms-alt-content-path"] do
      assert Map.has_key?(hm, h), "missing required header #{h}"
    end

    assert hm["x-ms-alt-content-path"] == "dbs/#{@db}/colls/#{@coll}"
    assert hm["x-ms-session-token"] =~ ~r/^\d+#\d+$/
    assert String.to_integer(hm["x-ms-lsn"]) >= 0

    # Lens-3 cross-court round 2: the response content-type fact is pinned
    # byte-identical on the ARM surface (c1: `application/json; charset=utf-8`);
    # the Cosmos plane emits through the same send_json seam — pin it here too.
    assert hm["content-type"] == "application/json; charset=utf-8"

    # Lens-2 cycle 2 doc-parity: C3_COSMOS.md row 1 claims the request-charge
    # CONSTANT is "fenced as such" — now it actually is. Real Cosmos computes
    # per-request RU; the constant is the registered KNOWN divergence.
    assert hm["x-ms-request-charge"] == "1.0"
  end

  test "404 NotFound carries request-charge / session-token / lsn too" do
    create_db()
    create_coll()

    resp = req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs/nope")

    assert resp.status == 404
    hm = header_map(resp)

    for h <- ["x-ms-request-charge", "x-ms-session-token", "x-ms-lsn"] do
      assert Map.has_key?(hm, h), "missing required header #{h}"
    end

    body = Jason.decode!(resp.body)
    assert body["code"] == "NotFound"
    assert body["message"] == "Entity with the specified id does not exist in the system."

    # Lens-3: error envelopes carry the same content-type as successes.
    assert hm["content-type"] == "application/json; charset=utf-8"
  end

  # ---------------------------------------------------------------------------
  # _etag: quoted, stable across read, refreshed on write
  # ---------------------------------------------------------------------------

  test "_etag is a quoted JSON string; stable on read; changes on replace" do
    create_db()
    create_coll()
    create_doc("d1")

    read = req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs/d1", headers: [@pk_hdr])
    assert read.status == 200

    doc = Jason.decode!(read.body)
    assert doc["_etag"] =~ ~r/^"[0-9a-f]{64}"$/

    assert header_map(read)["etag"] == doc["_etag"]

    put =
      req!(port(), :put, "/dbs/#{@db}/colls/#{@coll}/docs/d1",
        headers: [@pk_hdr, @json],
        body: ~s({"id":"d1","tenantId":"acme","v":2})
      )

    assert put.status == 200
    new_doc = Jason.decode!(put.body)
    assert new_doc["_etag"] =~ ~r/^"/ and new_doc["_etag"] != doc["_etag"]
    assert new_doc["_ts"] >= doc["_ts"]
  end

  # ---------------------------------------------------------------------------
  # System properties: _rid present, _self path grammar, _ts integer seconds
  # ---------------------------------------------------------------------------

  test "document system properties: _rid, _self grammar, _ts" do
    create_db()
    create_coll()
    create_doc("d1")

    doc = get_doc("d1")

    # composite resource id: coll rid (12) + doc segment (8), base64url alphabet
    assert doc["_rid"] == Cosmos.coll_rid(@db, @coll) <> Cosmos.rid_segment("d1", 8)
    assert doc["_rid"] =~ ~r/^[A-Za-z0-9_-]{20}$/
    assert doc["_self"] == "/dbs/#{@db}/colls/#{@coll}/docs/d1"
    assert is_integer(doc["_ts"])
  end

  test "db and container records expose id/_rid/_self and container pk kind" do
    create_db()
    create_coll()

    db =
      req!(port(), :get, "/dbs/#{@db}")
      |> Map.fetch!(:body)
      |> Jason.decode!()

    assert db["id"] == @db and db["_self"] == "/dbs/#{@db}"
    # db rid: 8-char base64url segment
    assert db["_rid"] == Cosmos.db_rid(@db)
    assert db["_rid"] =~ ~r/^[A-Za-z0-9_-]{8}$/

    coll =
      req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}")
      |> Map.fetch!(:body)
      |> Jason.decode!()

    # container rid: db rid + 4-char segment
    assert coll["_rid"] == Cosmos.coll_rid(@db, @coll)
    assert coll["_rid"] =~ ~r/^[A-Za-z0-9_-]{12}$/
    assert coll["partitionKey"]["paths"] == ["/tenantId"]
    assert coll["partitionKey"]["kind"] == "Hash"
  end

  # ---------------------------------------------------------------------------
  # Status-code semantics: 201/200/204/400/404/412
  # ---------------------------------------------------------------------------

  test "create/replace/delete status semantics incl. conditional delete" do
    create_db()
    create_coll()

    assert create_doc("d1").status == 201

    # conditional delete: matching If-Match -> 204, second delete -> 404
    etag = get_doc("d1")["_etag"]

    assert req!(port(), :delete, "/dbs/#{@db}/colls/#{@coll}/docs/d1",
             headers: [{"if-match", etag}, @pk_hdr]
           ).status ==
             204

    assert req!(port(), :delete, "/dbs/#{@db}/colls/#{@coll}/docs/d1").status == 404
  end

  test "PUT with stale If-Match -> 412 PreconditionFailed envelope" do
    create_db()
    create_coll()
    create_doc("d1")

    resp =
      req!(port(), :put, "/dbs/#{@db}/colls/#{@coll}/docs/d1",
        headers: [{"if-match", ~s("stale")}, @pk_hdr, @json],
        body: ~s({"id":"d1","tenantId":"acme","v":2})
      )

    assert resp.status == 412
    assert Jason.decode!(resp.body)["code"] == "PreconditionFailed"
  end

  test "GET with If-None-Match matching -> 304" do
    create_db()
    create_coll()
    create_doc("d1")
    etag = get_doc("d1")["_etag"]

    resp =
      req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs/d1",
        headers: [{"if-none-match", etag}, @pk_hdr]
      )

    assert resp.status == 304
  end

  # ---------------------------------------------------------------------------
  # Partition-key semantics (json array header, extraction, 400s)
  # ---------------------------------------------------------------------------

  test "413 RequestEntityTooLarge envelope on a > 2MB doc create (row 16)" do
    create_db()
    create_coll()

    body = ~s({"id":"toobig","blob":"#{String.duplicate("x", 2 * 1024 * 1024)}"})

    resp =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [@pk_hdr, @json],
        body: body
      )

    assert resp.status == 413
    assert Jason.decode!(resp.body)["code"] == "RequestEntityTooLarge"

    for h <- ["x-ms-request-charge", "x-ms-session-token", "x-ms-lsn"] do
      assert Map.has_key?(header_map(resp), h), "missing required header #{h}"
    end

    # the oversized doc was not persisted
    assert req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs/toobig").status == 404
  end

  test "pk header required: missing / non-array / mismatched all 400 BadRequest" do
    create_db()
    create_coll()

    bodies = [
      {[], ~s({"id":"d9","tenantId":"acme"})},
      {[{"x-ms-documentdb-partitionkey", "acme"}], ~s({"id":"d9","tenantId":"acme"})},
      {[@pk_hdr], ~s({"id":"d9","tenantId":"other"})}
    ]

    for {hdrs, body} <- bodies do
      resp =
        req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
          headers: [@json | hdrs],
          body: body
        )

      assert resp.status == 400, "expected 400 for headers=#{inspect(hdrs)}"
      assert Jason.decode!(resp.body)["code"] == "BadRequest"
    end
  end

  test "query POST with pk header filters to the partition" do
    create_db()
    create_coll()
    create_doc("d1")
    create_doc("d2")

    resp =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [{"content-type", "application/query+json"}, @pk_hdr],
        body: ~s({"query":"SELECT * FROM c","parameters":[]})
      )

    assert resp.status == 200

    body = Jason.decode!(resp.body)

    assert MapSet.new(Map.keys(body)) == MapSet.new(["_rid", "Documents", "_count"])
    assert body["_count"] == 2
    assert Enum.all?(body["Documents"], &(&1["tenantId"] == "acme"))
  end

  test "cross-partition query POST (enablecrosspartition) returns 200 feed" do
    create_db()
    create_coll()
    create_doc("d1")
    create_doc("d2", "globex")

    resp =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [
          {"content-type", "application/query+json"},
          {"x-ms-documentdb-query-enablecrosspartition", "true"}
        ],
        body: ~s({"query":"SELECT * FROM c"})
      )

    assert resp.status == 200
    feed = Jason.decode!(resp.body)

    # Mutant-kill: not a bare count. Cross-partition SELECT * must return BOTH
    # partitions' documents, identified by id — a query engine that ignores the
    # query text and returns an arbitrary subset (or a single partition) fails.
    assert feed["_count"] == 2
    assert MapSet.new(feed["Documents"], & &1["id"]) == MapSet.new(["d1", "d2"])

    # Partition-scoped query (no enablecrosspartition, pk header set) must
    # return ONLY the acme-partition document — kills the "scan everything"
    # mutant on the scoped path.
    scoped =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [{"content-type", "application/query+json"}, @pk_hdr],
        body: ~s({"query":"SELECT * FROM c"})
      )

    assert scoped.status == 200
    scoped_feed = Jason.decode!(scoped.body)
    assert scoped_feed["_count"] == 1
    assert Enum.map(scoped_feed["Documents"], & &1["id"]) == ["d1"]
  end

  test "a query POST never creates a document" do
    create_db()
    create_coll()

    resp =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [{"content-type", "application/query+json"}, @pk_hdr],
        body: ~s({"query":"SELECT * FROM c"})
      )

    assert resp.status == 200

    # the only documents visible are the ones created by real create POSTs
    assert Jason.decode!(resp.body)["_count"] == 0

    resp2 =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [{"content-type", "application/query+json"}, @pk_hdr],
        body: "not json at all"
      )

    assert resp2.status == 400
  end

  # Lens-4: cosmos-lens3's authorized RAISE landed (row 18 x-ms-continuation,
  # cosmos.ex:557/590/602). Court: the token is an ORDER-based resume cursor
  # (id > last_id), it rides the response ONLY on truncation, a forged token
  # (ledger position ahead of this container's ledger) is a 400, and a
  # malformed token is a 400. A query engine that ignores the header on
  # resume, emits a token on the last page, or admits forged tokens fails.
  test "continuation token: honored on resume, absent on last page, forged/malformed -> 400" do
    create_db()
    create_coll()

    for id <- ["d0", "d1", "d2", "d3"], do: create_doc(id)

    q_headers = [
      {"content-type", "application/query+json"},
      {"x-ms-documentdb-query-enablecrosspartition", "true"}
    ]

    q_body = ~s({"query":"SELECT * FROM c"})

    # Page 1 (untruncated): 200, all four docs, NO continuation header —
    # a token on the last page would hang an SDK paging loop.
    page1 =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: q_headers,
        body: q_body
      )

    assert page1.status == 200
    feed1 = Jason.decode!(page1.body)
    assert feed1["_count"] == 4
    assert MapSet.new(feed1["Documents"], & &1["id"]) == MapSet.new(["d0", "d1", "d2", "d3"])
    hm1 = header_map(page1)
    refute Map.has_key?(hm1, "x-ms-continuation")

    # Resume with a well-formed token cursoring past d1: the ORDER-based
    # cursor must return ONLY d2, d3 (a resume that ignores the token
    # returns all four and fails).
    lsn = String.to_integer(hm1["x-ms-lsn"])

    resume =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: q_headers ++ [{"x-ms-continuation", "1##{lsn}:" <> Base.url_encode64("#{@db}/#{@coll}", padding: false) <> ":d1"}],
        body: q_body
      )

    assert resume.status == 200
    feed2 = Jason.decode!(resume.body)
    assert Enum.map(feed2["Documents"], & &1["id"]) == ["d2", "d3"]
    assert feed2["_count"] == 2

    # Forged token: ledger position (999999) ahead of this container's
    # ledger — 400 BadRequest, never a silent resume.
    forged =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: q_headers ++ [{"x-ms-continuation", "1#999999:d1"}],
        body: q_body
      )

    assert forged.status == 400

    # Malformed token (no colon cursor): 400.
    malformed =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: q_headers ++ [{"x-ms-continuation", "garbage"}],
        body: q_body
      )

    assert malformed.status == 400
  end

  # Lens-4 (cosmos): the LIST feed paginates too. The token is a version-2
  # namespace cursor — a v1 query token fed to the list surface is a typed
  # 400 (real Cosmos: tokens are bound to their feed; a foreign/logically
  # invalid token is rejected — see docs + sources in
  # tmp/errc/cosmos-lens4/cycle-1.md).
  test "list feed continuation: truncation token, resume, cross-namespace 400" do
    create_db()
    create_coll()

    for i <- 1..4, do: create_doc("d#{i}")

    page1 = req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs")
    assert page1.status == 200
    # Untruncated feed: no token (loop-termination contract).
    refute Map.has_key?(header_map(page1), "x-ms-continuation")

    # A forged v1 (query-namespace) token on the list surface: 400.
    forged =
      req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [{"x-ms-continuation", "1#1:d1"}]
      )

    assert forged.status == 400

    # A well-formed v2 token bound to a DIFFERENT feed (foreign db/coll
    # prefix) is a 400 — tokens are feed-bound, not just namespace-bound.
    # LSN is valid for this container's ledger, so only the prefix check
    # can refuse it.
    lsn = String.to_integer(header_map(page1)["x-ms-lsn"])

    foreign =
      req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [{"x-ms-continuation", "2##{lsn}:otherdb/othercoll/d1"}]
      )

    assert foreign.status == 400

    # Lens-8 cycle-8 (M5 kill leg): forged LEDGER position on an
    # otherwise-perfect SAME-container list token — correct container
    # binding, valid cursor grammar, but the embedded lsn is AHEAD of
    # this container's ledger. Typed 400, never a silent resume
    # (ledger crash-class totality: the resume must not run ahead of
    # the durable log).
    forged_lsn =
      req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [
          {"x-ms-continuation",
           "2#999999:" <> Base.url_encode64("#{@db}/#{@coll}", padding: false) <> ":d4"}
        ]
      )

    assert forged_lsn.status == 400

    # Control: the same shape at the CURRENT ledger position resumes 200
    # — the refusal is the ledger conjunct, not the token shape.
    control =
      req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [
          {"x-ms-continuation",
           "2##{lsn}:" <> Base.url_encode64("#{@db}/#{@coll}", padding: false) <> ":d4"}
        ]
      )

    assert control.status == 200
  end

  # Lens-7 cycle-1: emit-then-resume ROUND-TRIP. The existing courts
  # hand-build tokens from the observed x-ms-lsn; none feeds the server's
  # own emitted token back. This pins the emission/parse pair end to end:
  # emission format (v2 namespace, cursor = last id of the page), the
  # ORDER-based resume (no skip, no repeat), and loop termination
  # (last page carries no token).
  test "list feed emitted token round-trips: emit -> resume -> terminate" do
    create_db()
    create_coll()

    # 101 docs so the feed truncates at @query_limit (100).
    for i <- 1..101, do: create_doc(String.pad_leading(Integer.to_string(i), 4, "0"))

    page1 = req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs")
    assert page1.status == 200
    hm1 = header_map(page1)
    tok = hm1["x-ms-continuation"]
    assert is_binary(tok)
    # v2 namespace + numeric ledger position + cursor tail.
    assert tok =~ ~r/^2#\d+:[A-Za-z0-9_-]+:\d{4}$/
    feed1 = Jason.decode!(page1.body)
    assert feed1["_count"] == 100
    assert hd(feed1["Documents"])["id"] == "0001"
    assert List.last(feed1["Documents"])["id"] == "0100"

    # Resume with the server's OWN token: exactly the remainder, no
    # repeats, and the last page carries no token (SDK loop terminates).
    resume =
      req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [{"x-ms-continuation", tok}]
      )

    assert resume.status == 200
    feed2 = Jason.decode!(resume.body)
    assert Enum.map(feed2["Documents"], & &1["id"]) == ["0101"]
    refute Map.has_key?(header_map(resume), "x-ms-continuation")
  end

  # ---------------------------------------------------------------------------
  # Session token monotonicity, trailing slash, database account
  # ---------------------------------------------------------------------------

  test "x-ms-session-token advances monotonically on writes" do
    create_db()
    create_coll()
    create_doc("d1")

    t1 = session_token_for("d1")
    create_doc("d2")
    t2 = session_token_for("d1")

    assert token_lsn(t2) > token_lsn(t1)
  end

  test "trailing slash tolerated on the /dbs surface" do
    assert req!(port(), :get, "/dbs/").status == 200
  end

  test "database account GET / returns 200 DatabaseAccount envelope" do
    resp = req!(port(), :get, "/")
    assert resp.status == 200

    body = Jason.decode!(resp.body)
    assert body["kind"] == "DatabaseAccount"
    # Mutant-kill: pin the full location contract, not just "is a list" — the
    # SDK reads `name` + `databaseAccountEndpoint` and must be pointed back at
    # THIS egress plane (conn.scheme://host:port/).
    base = "http://127.0.0.1:#{port()}/"
    location = %{"name" => "East US", "databaseAccountEndpoint" => base}

    assert body["writableLocations"] == [location]
    assert body["readableLocations"] == [location]
    assert body["enableMultipleWriteLocations"] == false
    assert body["id"] == "smalt"
    assert body["userConsistencyPolicy"]["defaultConsistencyLevel"] == "Session"
  end

  # ---------------------------------------------------------------------------
  # Former GAP rows, now fixed and fenced CONFORMANT
  # ---------------------------------------------------------------------------

  # Lens-7 cycle-3: QUERY-feed emit-then-resume ROUND-TRIP (pairs with the
  # cycle-1 list-feed court). The query courts hand-build tokens from the
  # observed x-ms-lsn; the server's own emitted v1 token was never fed
  # back. Pins: emission format (~r/^1#\d+:[A-Za-z0-9_-]+:\d{4}$/), ORDER-based resume
  # with no repeats/skips, and loop termination (last page, no token).
  test "query feed emitted token round-trips: emit -> resume -> terminate" do
    create_db()
    create_coll()

    for i <- 1..101, do: create_doc(String.pad_leading(Integer.to_string(i), 4, "0"))

    q_headers = [
      {"content-type", "application/query+json"},
      {"x-ms-documentdb-query-enablecrosspartition", "true"}
    ]

    q_body = ~s({"query":"SELECT * FROM c"})

    page1 =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: q_headers,
        body: q_body
      )

    assert page1.status == 200
    hm1 = header_map(page1)
    tok = hm1["x-ms-continuation"]
    assert is_binary(tok)
    assert tok =~ ~r/^1#\d+:[A-Za-z0-9_-]+:\d{4}$/
    feed1 = Jason.decode!(page1.body)
    assert feed1["_count"] == 100
    assert hd(feed1["Documents"])["id"] == "0001"
    assert List.last(feed1["Documents"])["id"] == "0100"

    resume =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: q_headers ++ [{"x-ms-continuation", tok}],
        body: q_body
      )

    assert resume.status == 200
    feed2 = Jason.decode!(resume.body)
    assert Enum.map(feed2["Documents"], & &1["id"]) == ["0101"]
    assert feed2["_count"] == 1
    refute Map.has_key?(header_map(resume), "x-ms-continuation")
  end

  # Lens-7 cycle-6 (routed from cosmos lens-5): reverse-direction and
  # scope/prefix-binding pins at the real HTTP surface.
  # 1) A v2 (list-namespace) token fed to the QUERY POST is a 400 — the
  #    namespace gate refuses both directions at the wire (the v1-on-list
  #    direction was already fenced; this is the mirror).
  # 2) A query token whose embedded pk SCOPE differs from the request's
  #    partition-key header is a 400 — tokens are scope-bound; accepting
  #    a cross-scope resume silently drops docs (measured silent data
  #    drop, cosmos lens-5).
  # 3) The v2 LIST cross-prefix 400 is already fenced at this wire
  #    (foreign db/coll leg in the list-feed court, lens-6); re-affirmed
  #    here by the round-trip + foreign legs together.
  test "query token namespace + pk-scope bindings refuse at the wire" do
    create_db()
    create_coll()

    for i <- 1..101, do: create_doc(String.pad_leading(Integer.to_string(i), 4, "0"))

    q_headers = [
      {"content-type", "application/query+json"},
      {"x-ms-documentdb-query-enablecrosspartition", "true"},
      @pk_hdr
    ]

    q_body = ~s({"query":"SELECT * FROM c"})

    page1 =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: q_headers,
        body: q_body
      )

    assert page1.status == 200
    hm1 = header_map(page1)
    tok = hm1["x-ms-continuation"]
    assert is_binary(tok)
    # Scoped emission: the token embeds the raw pk header as its scope.
    assert tok =~ ~r/^1#\d+:[A-Za-z0-9_-]+:\["acme"\]\/\d{4}$/
    lsn = String.to_integer(hm1["x-ms-lsn"])

    # Mirror-direction namespace gate: v2 token on the query surface —
    # scope-shaped so ONLY the version conjunct can refuse it (a scope-
    # less v2 token would be refused by the scope check instead).
    v2_on_query =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers:
          q_headers ++ [{"x-ms-continuation", ~s(2##{lsn}:["acme"]/0100)}],
        body: q_body
      )

    assert v2_on_query.status == 400

    # Cross-scope: same shape, but the embedded scope names a different
    # partition — ONLY the scope conjunct can refuse it.
    cross_scope =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers:
          q_headers ++ [{"x-ms-continuation", "1##{lsn}:[\"other\"]/0100"}],
        body: q_body
      )

    assert cross_scope.status == 400
  end

  # Lens-8 cycle-5 (routed from cosmos lens-6): CROSS-CONTAINER token
  # reuse is a typed 400. Tokens embed base64url("db/coll") (lens-6
  # container binding); a token minted on container A must refuse on
  # container B even when B's OWN ledger position is valid — i.e. ONLY
  # the container-binding conjunct can refuse it (vacuity closed: B has
  # >= as many docs, so the lsn check passes).
  test "list token cross-container reuse is a typed 400 (container binding)" do
    create_db()
    create_coll()
    create_coll("collB")

    for i <- 1..101 do
      create_doc(String.pad_leading(Integer.to_string(i), 4, "0"))
    end

    for i <- 1..101 do
      create_doc_in("collB", String.pad_leading(Integer.to_string(i), 4, "0"))
    end

    page_a = req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs")
    assert page_a.status == 200
    tok = header_map(page_a)["x-ms-continuation"]
    assert is_binary(tok)
    assert tok =~ ~r/^2#\d+:[A-Za-z0-9_-]+:\d{4}$/

    # Same request shape on container B, with A's token. B's ledger is at
    # least as far (101 docs), prefix matches (""), cursor grammar valid —
    # ONLY the container binding can refuse.
    resume_b =
      req!(port(), :get, "/dbs/#{@db}/colls/collB/docs",
        headers: [{"x-ms-continuation", tok}]
      )

    assert resume_b.status == 400

    # Control: the same token on its OWN container still resumes (200) —
    # the refusal is the binding, not the token bytes going stale.
    resume_a =
      req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [{"x-ms-continuation", tok}]
      )

    assert resume_a.status == 200
    feed = Jason.decode!(resume_a.body)
    assert Enum.map(feed["Documents"], & &1["id"]) == ["0101"]
  end

  test "throttle: default :infinity keeps the surface unthrottled (regression row)" do
    create_db()
    create_coll()

    statuses =
      for i <- 1..30 do
        req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
          headers: [@pk_hdr, @json],
          body: ~s({"id":"bulk#{i}","tenantId":"acme"})
        ).status
      end

    assert statuses |> Enum.uniq() == [201]
  end

  test "throttle: :cosmos_ru_limit set -> 429 + x-ms-retry-after-ms after the limit (row 13)" do
    create_db()
    create_coll()

    Application.put_env(:smalt, :cosmos_ru_limit, 5)
    if :ets.info(:smalt_cosmos_ru) != :undefined, do: :ets.delete_all_objects(:smalt_cosmos_ru)

    responses =
      for i <- 1..8 do
        req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
          headers: [@pk_hdr, @json],
          body: ~s({"id":"th#{i}","tenantId":"acme"})
        )
      end

    statuses = Enum.map(responses, & &1.status)

    assert Enum.take(statuses, 5) |> Enum.uniq() == [201]
    assert Enum.drop(statuses, 5) |> Enum.uniq() == [429]

    # the first throttled response carries the retry-after header + envelope
    throttled = Enum.at(responses, 5)
    assert header_map(throttled)["x-ms-retry-after-ms"] == "1"
    assert Jason.decode!(throttled.body)["code"] == "TooManyRequests"
  after
    Application.delete_env(:smalt, :cosmos_ru_limit)

    if :ets.info(:smalt_cosmos_ru) != :undefined, do: :ets.delete_all_objects(:smalt_cosmos_ru)
  end

  test "master-key: anonymous mode admits an invalid master-key Authorization unchanged (regression row)" do
    create_db()

    resp =
      req!(port(), :get, "/dbs",
        headers: [{"authorization", "type%3dmaster%26ver%3d1.0%26sig%3dinvalid"}]
      )

    assert resp.status == 200
  end

  test "master-key: :enforce mode validates the HMAC signature (row 14)" do
    create_db()
    create_coll()
    create_doc("d1")

    key = "c3fence-master-key-0123456789abcdef"
    Application.put_env(:smalt, :cosmos_master_key, key)
    Application.put_env(:smalt, :auth_mode, :enforce)

    # Engine-level probe (real store, real HMAC, no HTTP doubles): the wire
    # surface's :enforce gate is the Bearer plug (a master-key Authorization
    # header is refused there as MalformedBearerHeader before the engine is
    # reached), so the engine gate is probed in-process like auth_enforce_test.
    date = "mon, 14 oct 2026 00:00:00 gmt"

    link = "dbs/#{@db}/colls/#{@coll}/docs/d1"

    valid_auth =
      URI.encode(
        "type=master&ver=1.0&sig=#{Base.encode64(:crypto.mac(:hmac, :sha256, key, "get\ndocs\n#{link}\n#{date}\n\n"))}"
      )

    headers = %{
      "authorization" => valid_auth,
      "x-ms-date" => date,
      "x-ms-documentdb-partitionkey" => ~s(["acme"])
    }

    assert {:ok, 200, resp_headers, doc} =
             Smalt.DataPlane.Cosmos.get_doc(@db, @coll, "d1", headers)

    assert doc["id"] == "d1"

    bad_auth = URI.encode("type=master&ver=1.0&sig=#{Base.encode64("invalid-signature-bytes")}")

    assert {:ok, 401, _h, err} =
             Smalt.DataPlane.Cosmos.get_doc(
               @db,
               @coll,
               "d1",
               Map.put(headers, "authorization", bad_auth)
             )

    assert err["code"] == "Unauthorized"
  after
    Application.delete_env(:smalt, :cosmos_master_key)
    Application.put_env(:smalt, :auth_mode, :anonymous)
  end

  test "x-ms-consistency-level is echoed on responses (row 15)" do
    create_db()
    create_coll()
    create_doc("d1")

    resp =
      req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs/d1",
        headers: [@pk_hdr, {"x-ms-consistency-level", "Session"}]
      )

    assert resp.status == 200
    assert header_map(resp)["x-ms-consistency-level"] == "Session"

    plain = req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs/d1", headers: [@pk_hdr])
    assert plain.status == 200
    refute Map.has_key?(header_map(plain), "x-ms-consistency-level")
  end

  # ---------------------------------------------------------------------------
  # Lens-2 cycle 3: doc-id grammar at the wire tier (real HTTP)
  # ---------------------------------------------------------------------------

  test "doc-id grammar at the wire tier: invalid body id -> 400 BadRequest envelope" do
    create_db()
    create_coll()

    for bad <- ["a/b", "", String.duplicate("d", 256)] do
      resp =
        req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
          headers: [@pk_hdr, @json],
          body: Jason.encode!(%{"id" => bad, "tenantId" => "acme"})
        )

      assert resp.status == 400, "expected 400 for id #{inspect(bad)}, got #{resp.status}"
      body = Jason.decode!(resp.body)

      assert body["code"] == "BadRequest"
    end

    # nothing stored under poisoned keys
    {:ok, 200, _, docs} = Cosmos.list_docs(@db, @coll)
    assert docs == []

    # valid id still creates at the wire tier
    resp =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [@pk_hdr, @json],
        body: ~s({"id":"good","tenantId":"acme"})
      )

    assert resp.status == 201
  end

  # ---------------------------------------------------------------------------
  # Helpers (mirrors test/compliance/c4_blob.exs)
  # ---------------------------------------------------------------------------

  defp create_db do
    assert req!(port(), :post, "/dbs", headers: [@json], body: ~s({"id":"#{@db}"})).status == 201
  end

  defp create_coll do
    assert req!(port(), :post, "/dbs/#{@db}/colls",
             headers: [@json],
             body: ~s({"id":"#{@coll}","partitionKey":{"paths":["/tenantId"]}})
           ).status == 201
  end

  defp create_coll(name) do
    assert req!(port(), :post, "/dbs/#{@db}/colls",
             headers: [@json],
             body: ~s({"id":"#{name}","partitionKey":{"paths":["/tenantId"]}})
           ).status == 201
  end

  defp create_doc_in(coll, id) do
    resp =
      req!(port(), :post, "/dbs/#{@db}/colls/#{coll}/docs",
        headers: [{"x-ms-documentdb-partitionkey", ~s(["acme"])}, @json],
        body: ~s({"id":"#{id}","tenantId":"acme"})
      )

    assert resp.status == 201, "create_doc_in(#{coll},#{id}) returned #{resp.status}: #{inspect(resp.body)}"
    resp
  end

  defp create_doc(id, tenant \\ "acme") do
    pk_hdr = {"x-ms-documentdb-partitionkey", ~s(["#{tenant}"])}

    resp =
      req!(port(), :post, "/dbs/#{@db}/colls/#{@coll}/docs",
        headers: [pk_hdr, @json],
        body: ~s({"id":"#{id}","tenantId":"#{tenant}"})
      )

    assert resp.status == 201, "create_doc(#{id}) returned #{resp.status}: #{inspect(resp.body)}"
    resp
  end

  defp get_doc(id) do
    req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs/#{id}", headers: [@pk_hdr])
    |> Map.fetch!(:body)
    |> Jason.decode!()
  end

  defp session_token_for(id) do
    req!(port(), :get, "/dbs/#{@db}/colls/#{@coll}/docs/#{id}", headers: [@pk_hdr])
    |> header_map()
    |> Map.fetch!("x-ms-session-token")
  end

  defp port, do: :persistent_term.get({__MODULE__, :port})

  defp req(port, method, path, opts \\ [], body \\ nil) do
    {hdrs, kw_body} =
      if opts == [] or match?([{k, _} | _] when is_atom(k), opts),
        do: {Keyword.get(opts, :headers, []), Keyword.get(opts, :body)},
        else: {opts, nil}

    body = body || kw_body
    url = to_charlist("http://127.0.0.1:#{port}#{path}")

    header_lc = Map.new(hdrs, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

    ctype =
      case Map.get(header_lc, "content-type") do
        nil -> ~c"application/json"
        ct -> to_charlist(ct)
      end

    remaining =
      hdrs
      |> Enum.reject(fn {k, v} -> String.downcase(to_string(k)) == "content-type" end)
      |> Enum.map(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    request =
      if body do
        {url, remaining, ctype, body}
      else
        {url, remaining}
      end

    :httpc.request(method, request, [timeout: 5_000, connect_timeout: 5_000, autoredirect: false],
      body_format: :binary
    )
  end

  defp req!(port, method, path, opts \\ [], body \\ nil) do
    case req(port, method, path, opts, body) do
      {:ok, {{_ver, status, _phrase}, resp_headers, resp_body}} ->
        %{status: status, headers: resp_headers, body: to_string(resp_body)}

      {:error, reason} ->
        flunk("httpc request failed: #{inspect(reason)}")
    end
  end

  defp header_map(%{headers: headers}) do
    Map.new(headers, fn {k, v} ->
      {k |> to_string() |> String.downcase(), to_string(v)}
    end)
  end

  defp stop_server(server) do
    try do
      Supervisor.stop(server, :normal, 1_000)
    catch
      _, _ -> Process.exit(server, :kill)
    end

    :ok
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp ensure_store do
    case Store.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp token_lsn(token), do: token |> String.split("#") |> List.last() |> String.to_integer()
end
