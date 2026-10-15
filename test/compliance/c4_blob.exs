defmodule Smalt.Compliance.C4BlobTest do
  @moduledoc """
  C4 — Azure Blob Storage REST compliance fence (live wire tier).

  Boots `Smalt.EgressRouter` under Bandit on an ephemeral port per test and
  makes real HTTP requests (inets `:httpc`). Fences the CONFORMANT rows of
  `docs/compliance/C4_BLOB.md`. Known GAP/DEV-MODE rows are NOT fenced — they
  must not be pinned as passing. A silent change on a fenced row fails here;
  a silent fill of a GAP row is caught by the md contract.

  Spec basis: Azure Blob Service REST API (Put/Get/Delete Blob, Get Container
  Properties/Metadata, List Containers/Blobs XML schema, error code strings,
  409-vs-412 selection).
  """

  use ExUnit.Case, async: false

  alias Smalt.Store

  @acct "c4fence"
  @cont "fencecont"
  @version "2021-12-02"
  @v [{"x-ms-version", @version}]

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
  # x-ms-version guard (egress_router.ex:1005-1026)
  # ---------------------------------------------------------------------------

  test "blob routes without x-ms-version are refused with 400 MissingXMsVersion" do
    resp = req!(port(), :get, "/#{acct()}/#{cont()}", [])

    assert resp.status == 400
    assert Jason.decode!(resp.body)["error"]["code"] == "MissingXMsVersion"

    # Lens-3 cycle 4: message-byte pin (same fact family the c1/c7 api-version
    # courts pin — every 400 gate names its prose exactly).
    assert Jason.decode!(resp.body)["error"]["message"] ==
             "x-ms-version header is required for blob storage routes."
  end

  # ---------------------------------------------------------------------------
  # Container surface
  # ---------------------------------------------------------------------------

  test "container PUT creates; GET properties returns the full header contract" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    resp = req!(port(), :get, "/#{acct()}/#{cont()}?restype=container", @v)

    assert resp.status == 200
    hdrs = header_map(resp)
    assert is_binary(hdrs["etag"]) and String.starts_with?(hdrs["etag"], "\"")
    assert is_binary(hdrs["last-modified"])
    assert hdrs["x-ms-version"] == @version

    # Mutant-kill: a FRESH container has no WORM state — both flags must be the
    # exact "false" bytes, not merely one of {true,false}. (Post-policy "true"
    # is fenced separately below in the immutabilityPolicy / legal-hold tests.)
    assert hdrs["x-ms-has-immutability-policy"] == "false"
    assert hdrs["x-ms-has-legal-hold"] == "false"

    # FINDING (lens-2 cycle 1, cross-court divergence): the blob data plane
    # (BlobStorage.request_id/0, blob_storage.ex:731) emits 32-hex lowercase,
    # NOT the RFC 4122 v4 GUID the ARM gateway (c1) and LA surface (c7) pin.
    # Real Azure Storage answers with a GUID — this is an Azurite-parity gap
    # owned by the data-plane lane. Fenced here at CURRENT wire bytes so the
    # divergence is visible, not papered over by an is_binary fence.
    assert is_binary(hdrs["x-ms-request-id"]) and byte_size(hdrs["x-ms-request-id"]) == 32

    assert Regex.match?(~r/^[0-9a-f]{32}$/, hdrs["x-ms-request-id"])
  end

  test "container metadata round-trips via x-ms-meta-* headers (PUT + GET)" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    put =
      req!(port(), :put, "/#{acct()}/#{cont()}?restype=container&comp=metadata", @v ++ [
        {"x-ms-meta-owner", "c4"},
        {"x-ms-meta-purpose", "fence"}
      ])

    assert put.status == 200
    assert is_binary(header_map(put)["etag"])

    get = req!(port(), :get, "/#{acct()}/#{cont()}?restype=container&comp=metadata", @v)
    assert get.status == 200
    hdrs = header_map(get)
    assert hdrs["x-ms-meta-owner"] == "c4"
    assert hdrs["x-ms-meta-purpose"] == "fence"
  end

  test "GET properties on missing container returns 404 ContainerNotFound" do
    resp = req!(port(), :get, "/#{acct()}/nosuch?restype=container", @v)

    assert resp.status == 404
    assert Jason.decode!(resp.body)["error"]["code"] == "ContainerNotFound"
  end

  test "container list XML has EnumerationResults/Containers schema with WORM flags" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    resp = req!(port(), :get, "/#{acct()}?comp=list", @v)
    assert resp.status == 200
    assert resp.body =~ ~r/<EnumerationResults[^>]*>/
    assert resp.body =~ "<Containers>"
    assert resp.body =~ "<Name>#{cont()}</Name>"
    assert resp.body =~ "<HasImmutabilityPolicy>false</HasImmutabilityPolicy>"
    assert resp.body =~ "<HasLegalHold>false</HasLegalHold>"
  end

  # ---------------------------------------------------------------------------
  # Blob surface
  # ---------------------------------------------------------------------------

  test "blob PUT then GET returns exact bytes with matching ETag" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    put =
      req!(port(), :put, "/#{acct()}/#{cont()}/blob1",
        headers: @v ++ [{"content-type", "application/octet-stream"}],
        body: "smalt c4 fence bytes"
      )

    assert put.status == 201
    assert is_binary(header_map(put)["etag"])

    get = req!(port(), :get, "/#{acct()}/#{cont()}/blob1", @v)
    assert get.status == 200
    assert get.body == "smalt c4 fence bytes"
    assert header_map(get)["etag"] == header_map(put)["etag"]
    assert header_map(get)["content-length"] == "20"
  end

  test "ranged GET returns 206 + Content-Range; unsatisfiable range returns 416 + bytes */total" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    req!(port(), :put, "/#{acct()}/#{cont()}/blob2",
      headers: @v ++ [{"content-type", "application/octet-stream"}],
      body: "0123456789"
    )

    ranged =
      req!(port(), :get, "/#{acct()}/#{cont()}/blob2", @v ++ [{"x-ms-range", "bytes=2-5"}])

    assert ranged.status == 200 or ranged.status == 206
    # Fence the 206 shape only when the range header is honored.
    if header_map(ranged)["content-range"] do
      assert ranged.status == 206
      assert ranged.body == "2345"
      assert header_map(ranged)["content-range"] == "bytes 2-5/10"
    else
      flunk("x-ms-range was not honored over the wire")
    end

    bad = req!(port(), :get, "/#{acct()}/#{cont()}/blob2", @v ++ [{"x-ms-range", "bytes=99-"}])
    assert bad.status == 416
    assert header_map(bad)["content-range"] == "bytes */10"
    assert Jason.decode!(bad.body)["error"]["code"] == "InvalidRange"
  end

  test "GET missing blob returns 404 BlobNotFound" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    resp = req!(port(), :get, "/#{acct()}/#{cont()}/nope", @v)
    assert resp.status == 404
    assert Jason.decode!(resp.body)["error"]["code"] == "BlobNotFound"

    # F5 falsifier (lens-5 cycle 1): the blob error renderer (blob_error/3,
    # egress_router.ex) must carry x-ms-request-id + x-ms-version on ERROR
    # responses too, per the lens-4 typed work order. Pinned at current wire
    # bytes: error-path request-id comes from generate_request_id/0 (v4 GUID),
    # NOT the success-path 32-hex — divergence fenced separately above.
    hdrs = header_map(resp)
    assert is_binary(hdrs["x-ms-request-id"]) and byte_size(hdrs["x-ms-request-id"]) > 0
    assert hdrs["x-ms-version"] == @version
  end

  test "blob DELETE on an unlocked container returns 202 with request-id headers" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    req!(port(), :put, "/#{acct()}/#{cont()}/doomed",
      headers: @v ++ [{"content-type", "application/octet-stream"}],
      body: "payload"
    )

    # Container default is immutable WORM (1095d) — release the default lock
    # by moving retention to zero via a fresh unlocked container.
    assert req!(port(), :put, "/#{acct()}/unlocked?restype=container", @v ++ [
             {"x-ms-immutable-policy", "false"}
           ]).status == 201

    req!(port(), :put, "/#{acct()}/unlocked/doomed",
      headers: @v ++ [{"content-type", "application/octet-stream"}],
      body: "payload"
    )

    del = req!(port(), :delete, "/#{acct()}/unlocked/doomed", @v)
    assert del.status == 202
    hdrs = header_map(del)

    # FINDING (lens-2 cycle 1, cross-court divergence): the blob data plane
    # (BlobStorage.request_id/0, blob_storage.ex:731) emits 32-hex lowercase,
    # NOT the RFC 4122 v4 GUID the ARM gateway (c1) and LA surface (c7) pin.
    # Real Azure Storage answers with a GUID — this is an Azurite-parity gap
    # owned by the data-plane lane. Fenced here at CURRENT wire bytes so the
    # divergence is visible, not papered over by an is_binary fence.
    assert is_binary(hdrs["x-ms-request-id"]) and byte_size(hdrs["x-ms-request-id"]) == 32

    assert Regex.match?(~r/^[0-9a-f]{32}$/, hdrs["x-ms-request-id"])

    assert hdrs["x-ms-version"] == @version
  end

  test "If-Match mismatch on overwrite returns 412 PreconditionFailed" do
    assert req!(port(), :put, "/#{acct()}/unlocked?restype=container", @v ++ [
             {"x-ms-immutable-policy", "false"}
           ]).status == 201

    put =
      req!(port(), :put, "/#{acct()}/unlocked/etag",
        headers: @v ++ [{"content-type", "application/octet-stream"}],
        body: "v1"
      )

    etag = header_map(put)["etag"]

    stale =
      req!(port(), :put, "/#{acct()}/unlocked/etag",
        headers: @v ++ [{"content-type", "application/octet-stream"}, {"if-match", "\"stale\""}],
        body: "v2"
      )

    assert stale.status == 412
    assert Jason.decode!(stale.body)["error"]["code"] == "PreconditionFailed"

    match =
      req!(port(), :put, "/#{acct()}/unlocked/etag",
        headers: @v ++ [{"content-type", "application/octet-stream"}, {"if-match", etag}],
        body: "v3"
      )

    assert match.status == 201
  end

  test "WORM: delete/overwrite on default-immutable container returns 409 ContainerLocked" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    req!(port(), :put, "/#{acct()}/#{cont()}/wormed",
      headers: @v ++ [{"content-type", "application/octet-stream"}],
      body: "keep"
    )

    del = req!(port(), :delete, "/#{acct()}/#{cont()}/wormed", @v)
    assert del.status == 409
    assert Jason.decode!(del.body)["error"]["code"] == "ContainerLocked"
  end

  test "legal hold PUT returns x-ms-has-legal-hold header; GET reflects it" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    put =
      req!(port(), :put, "/#{acct()}/#{cont()}?comp=legalhold", @v ++ [{"x-ms-legal-hold", "true"}])

    assert put.status == 200
    assert header_map(put)["x-ms-has-legal-hold"] == "true"
    assert Jason.decode!(put.body)["has_legal_hold"] == true

    get = req!(port(), :get, "/#{acct()}/#{cont()}?comp=legalhold", @v)
    assert get.status == 200
    assert header_map(get)["x-ms-legal-hold"] == "true"
  end

  test "immutabilityPolicy PUT with JSON body returns 200 + immutability-policy-until (C4 fix)" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    put =
      req!(port(), :put, "/#{acct()}/#{cont()}?comp=immutabilityPolicy",
        headers: @v ++ [{"content-type", "application/json"}],
        body: Jason.encode!(%{"immutabilityPeriodSinceCreationInDays" => 30})
      )

    assert put.status == 200
    hdrs = header_map(put)
    assert hdrs["x-ms-has-immutability-policy"] == "true"
    assert is_binary(hdrs["immutability-policy-until"])

    get = req!(port(), :get, "/#{acct()}/#{cont()}?comp=immutabilityPolicy", @v)
    assert get.status == 200
    policy = Jason.decode!(get.body)
    assert policy["period_days"] == 30
  end

  test "immutabilityPolicy PUT with empty body returns 200 with no until header" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    put =
      req!(port(), :put, "/#{acct()}/#{cont()}?comp=immutabilityPolicy",
        headers: @v ++ [{"content-type", "application/json"}],
        body: ""
      )

    assert put.status == 200
    refute header_map(put)["immutability-policy-until"]
  end

  test "immutabilityPolicy PUT with malformed body returns 400 InvalidXmlOrJson (not 500)" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    put =
      req!(port(), :put, "/#{acct()}/#{cont()}?comp=immutabilityPolicy",
        headers: @v ++ [{"content-type", "text/plain"}],
        body: "{not json"
      )

    assert put.status == 400
    assert Jason.decode!(put.body)["error"]["code"] == "InvalidXmlOrJson"
  end

  test "blob PUT with urlencoded content-type stores the RAW body; GET byte-identical" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    put =
      req!(port(), :put, "/#{acct()}/#{cont()}/urlencoded.bin",
        headers: @v ++ [{"content-type", "application/x-www-form-urlencoded"}],
        body: "hello world"
      )

    assert put.status == 200 or put.status == 201

    get = req!(port(), :get, "/#{acct()}/#{cont()}/urlencoded.bin", @v)
    assert get.status == 200
    assert get.body == "hello world"
    assert header_map(get)["content-length"] == "11"
  end

  test "list blobs XML schema: EnumerationResults/Blobs/Blob with Content-Length/Etag/Last-Modified" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    req!(port(), :put, "/#{acct()}/#{cont()}/a.txt",
      headers: @v ++ [{"content-type", "application/octet-stream"}],
      body: "aaa"
    )

    req!(port(), :put, "/#{acct()}/#{cont()}/b.txt",
      headers: @v ++ [{"content-type", "application/octet-stream"}],
      body: "bbb"
    )

    resp = req!(port(), :get, "/#{acct()}/#{cont()}?comp=list&restype=container", @v)
    assert resp.status == 200
    assert resp.body =~ ~r/<EnumerationResults[^>]*ContainerName="#{cont()}"/
    assert resp.body =~ "<Blobs>"
    assert resp.body =~ "<Name>a.txt</Name>"
    assert resp.body =~ "<Content-Length>3</Content-Length>"
    assert resp.body =~ "<Etag>"
    assert resp.body =~ "<Last-Modified>"
    assert resp.body =~ ~r/<NextMarker\s*\/>/
  end

  test "list blobs pagination: marker pages in lexicographic order with NextMarker" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    Enum.each(["p1", "p2", "p3"], fn name ->
      req!(port(), :put, "/#{acct()}/#{cont()}/#{name}",
        headers: @v ++ [{"content-type", "application/octet-stream"}],
        body: name
      )
    end)

    page1 = req!(port(), :get, "/#{acct()}/#{cont()}?comp=list&maxresults=2", @v)
    assert page1.status == 200
    assert page1.body =~ "<Name>p1</Name>"
    assert page1.body =~ "<Name>p2</Name>"
    refute page1.body =~ "<Name>p3</Name>"
    assert page1.body =~ "<NextMarker>p2</NextMarker>"

    page2 =
      req!(port(), :get, "/#{acct()}/#{cont()}?comp=list&marker=p2&restype=container", @v)

    assert page2.status == 200
    assert page2.body =~ "<Name>p3</Name>"
    refute page2.body =~ "<Name>p1</Name>"
  end

  # ---------------------------------------------------------------------------
  # Cycle-21/22 parity: conditional-write fences at the wire
  # ---------------------------------------------------------------------------

  test "PUT blob with If-None-Match: * refuses overwrite at the wire with 412" do
    # WORM-free container (router defaults immutable=true without the header)
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", unlocked).status == 201

    assert req!(port(), :put, "/#{acct()}/#{cont()}/inm",
             headers: @v ++ [{"content-type", "application/octet-stream"}],
             body: "v1"
           ).status == 201

    inm = @v ++ [{"if-none-match", "*"}, {"content-type", "application/octet-stream"}]
    resp = req!(port(), :put, "/#{acct()}/#{cont()}/inm", headers: inm, body: "v2")

    assert resp.status == 412
    assert Jason.decode!(resp.body)["error"]["code"] == "PreconditionFailed"

    # blob survived with original bytes
    get = req!(port(), :get, "/#{acct()}/#{cont()}/inm", @v)
    assert get.status == 200
    assert get.body == "v1"
  end

  test "DELETE blob with If-None-Match: * refuses at the wire with 412" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", unlocked).status == 201

    assert req!(port(), :put, "/#{acct()}/#{cont()}/inm-del",
             headers: @v ++ [{"content-type", "application/octet-stream"}],
             body: "v1"
           ).status == 201

    del = req!(port(), :delete, "/#{acct()}/#{cont()}/inm-del",
      headers: @v ++ [{"if-none-match", "*"}]
    )

    assert del.status == 412

    get = req!(port(), :get, "/#{acct()}/#{cont()}/inm-del", @v)
    assert get.status == 200
  end

  # ---------------------------------------------------------------------------
  # Cycle-25 parity: container grammar, duplicate 409, maxresults 400 at wire
  # ---------------------------------------------------------------------------

  test "PUT container with invalid name -> 400 InvalidResourceName" do
    resp = req!(port(), :put, "/#{acct()}/BadName?restype=container", @v)

    assert resp.status == 400
    assert Jason.decode!(resp.body)["error"]["code"] == "InvalidResourceName"
  end

  test "duplicate PUT container -> 409 ContainerAlreadyExists" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/duplec1?restype=container", unlocked).status == 201

    dup = req!(port(), :put, "/#{acct()}/duplec1?restype=container", unlocked)

    assert dup.status == 409
    assert Jason.decode!(dup.body)["error"]["code"] == "ContainerAlreadyExists"
  end

  test "list blobs with junk maxresults -> 400 InvalidQueryParameter" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/mxresults?restype=container", unlocked).status == 201

    resp = req!(port(), :get, "/#{acct()}/mxresults?comp=list&maxresults=abc", @v)

    assert resp.status == 400
    assert Jason.decode!(resp.body)["error"]["code"] == "InvalidQueryParameter"
  end

  test "list blobs with delimiter rolls directories into BlobPrefix at the wire" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/delimtest?restype=container", unlocked).status == 201

    # router routes :blob_name as a single path segment (slash-names are a
    # router-lane gap) — the wire fence uses a "-" delimiter equivalently
    for name <- ["w-1", "w-2", "top"] do
      assert req!(port(), :put, "/#{acct()}/delimtest/#{name}",
               headers: @v ++ [{"content-type", "application/octet-stream"}],
               body: "x"
             ).status == 201
    end

    resp = req!(port(), :get, "/#{acct()}/delimtest?comp=list&delimiter=-", @v)

    assert resp.status == 200
    assert resp.body =~ "<Delimiter>-</Delimiter>"
    assert resp.body =~ "<Name>w-</Name>"
    assert resp.body =~ "<Name>top</Name>"
    refute resp.body =~ "<Name>w-1</Name>"
  end

  # ---------------------------------------------------------------------------
  # F5 (compliance lens-4): blob ERROR responses carry x-ms-request-id (v4)
  # and x-ms-version — real Azure emits both on errors too.
  # ---------------------------------------------------------------------------

  test "blob error responses carry x-ms-request-id (v4 GUID) and x-ms-version" do
    resp = req!(port(), :get, "/#{acct()}/#{cont()}/missing-blob", @v)

    assert resp.status == 404
    hdrs = header_map(resp)
    assert is_binary(hdrs["x-ms-request-id"])

    # v4 GUID shape: 8-4-4-4-12 hex with version nibble 4
    assert hdrs["x-ms-request-id"] =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    assert hdrs["x-ms-version"] == "2021-12-02"

    # per-request ids (not a shared constant)
    resp2 = req!(port(), :get, "/#{acct()}/#{cont()}/missing-blob-2", @v)
    assert header_map(resp2)["x-ms-request-id"] != hdrs["x-ms-request-id"]
  end

  # ---------------------------------------------------------------------------
  # Cycle-30: conditional reads at the wire (If-Match 412 / If-None-Match 304)
  # ---------------------------------------------------------------------------

  test "GET blob honors If-Match (412) and If-None-Match (304) at the wire" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/condread?restype=container", unlocked).status == 201

    put =
      req!(port(), :put, "/#{acct()}/condread/cb",
        headers: @v ++ [{"content-type", "application/octet-stream"}],
        body: "payload"
      )

    assert put.status == 201
    etag = header_map(put)["etag"]

    # If-Match mismatch -> 412 with the F5 error headers
    wrong = req!(port(), :get, "/#{acct()}/condread/cb", @v ++ [{"if-match", "\"dead\""}])
    assert wrong.status == 412
    assert is_binary(header_map(wrong)["x-ms-request-id"])

    # If-Match match -> 200 + exact bytes
    ok = req!(port(), :get, "/#{acct()}/condread/cb", @v ++ [{"if-match", etag}])
    assert ok.status == 200
    assert ok.body == "payload"

    # If-None-Match match -> 304, empty body, etag echoed, error headers present
    inm = req!(port(), :get, "/#{acct()}/condread/cb", @v ++ [{"if-none-match", etag}])
    assert inm.status == 304
    assert inm.body == ""
    assert header_map(inm)["etag"] == etag
    # F5 error-header contract also applies to the 304 path
    assert is_binary(header_map(inm)["x-ms-request-id"])
    assert header_map(inm)["x-ms-version"] == "2021-12-02"

    # unconditioned read unaffected
    plain = req!(port(), :get, "/#{acct()}/condread/cb", @v)
    assert plain.status == 200

    # Lens-6: RFC 7232 precedence — when both headers are present, If-Match
    # is evaluated FIRST: a mismatching If-Match yields 412 even though the
    # If-None-Match matches (a swap would answer 304 and leak stale reads).
    both =
      req!(port(), :get, "/#{acct()}/condread/cb",
        @v ++ [{"if-match", "\"dead\""}, {"if-none-match", etag}]
      )

    assert both.status == 412
  end

  test "slash-named blobs (virtual directories) round-trip at the wire" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/vdirs?restype=container", unlocked).status == 201

    put =
      req!(port(), :put, "/#{acct()}/vdirs/w/1",
        headers: @v ++ [{"content-type", "application/octet-stream"}],
        body: "deep"
      )

    assert put.status == 201

    get = req!(port(), :get, "/#{acct()}/vdirs/w/1", @v)
    assert get.status == 200
    assert get.body == "deep"

    # Lens-7 (auth-lens7 bodycache law, wire pin): a slash-named blob PUT
    # with a parseable-looking body (JSON content-type) stores the body
    # VERBATIM — no content-type-triggered parsing, rewriting, or
    # trimming on the storage path. Round-trip must be byte-exact,
    # trailing newline included.
    json_body = ~s({"k": "v", "n": 1}\n\n)
    putj =
      req!(port(), :put, "/#{acct()}/vdirs/w/2",
        headers: @v ++ [{"content-type", "application/json"}],
        body: json_body
      )

    assert putj.status == 201
    getj = req!(port(), :get, "/#{acct()}/vdirs/w/2", @v)
    assert getj.status == 200
    assert getj.body == json_body

    # slash delimiter now wire-exercisable too
    list = req!(port(), :get, "/#{acct()}/vdirs?comp=list&delimiter=/", @v)
    assert list.status == 200
    assert list.body =~ "<Name>w/</Name>"
    refute list.body =~ "<Name>w/1</Name>"
  end

  # ---------------------------------------------------------------------------
  # Cycle-33 (lens-5): Put Container 201 carries ETag/Last-Modified/empty body
  # ---------------------------------------------------------------------------

  test "container PUT create -> 201 with quoted etag, RFC1123 last-modified, empty body" do
    resp = req!(port(), :put, "/#{acct()}/hdrcreate?restype=container", @v)

    assert resp.status == 201
    assert resp.body == ""

    hdrs = header_map(resp)
    assert hdrs["etag"] =~ ~r/^"[0-9A-F]{32}"$/
    assert is_binary(hdrs["x-ms-request-id"])
    assert hdrs["x-ms-version"] == "2021-12-02"

    # RFC 1123: "Tue, 15 Oct 2026 12:00:00 GMT"
    assert hdrs["last-modified"] =~
             ~r/^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), \d{2} (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4} \d{2}:\d{2}:\d{2} GMT$/

    # etag is stable per container identity (deterministic seed), distinct per container
    assert req!(port(), :put, "/#{acct()}/hdrcreate2?restype=container", @v).status == 201
    e1 = header_map(req!(port(), :get, "/#{acct()}/hdrcreate?restype=container", @v))
    e2 = header_map(req!(port(), :get, "/#{acct()}/hdrcreate2?restype=container", @v))
    assert e1["etag"] != e2["etag"]
  end

  # ---------------------------------------------------------------------------
  # Cycle-34: List Blobs include=metadata at the wire
  # ---------------------------------------------------------------------------

  test "list blobs include=metadata rides the wire opt-in with escaped values" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/incmeta?restype=container", unlocked).status == 201

    for {n, v} <- [{"meta-blob", "platform"}, {"esc-blob", "a&<b>"}] do
      assert req!(port(), :put, "/#{acct()}/incmeta/#{n}",
               headers: @v ++ [{"content-type", "application/octet-stream"}, {"x-ms-meta-owner", v}],
               body: "x"
             ).status == 201
    end

    with_meta = req!(port(), :get, "/#{acct()}/incmeta?comp=list&include=metadata", @v)
    assert with_meta.status == 200
    assert with_meta.body =~ "<Metadata>"
    assert with_meta.body =~ "<owner>platform</owner>"
    assert with_meta.body =~ "<owner>a&amp;&lt;b&gt;</owner>"

    without_meta = req!(port(), :get, "/#{acct()}/incmeta?comp=list", @v)
    assert without_meta.status == 200
    refute without_meta.body =~ "<Metadata>"

    # unknown include values inert
    unknown = req!(port(), :get, "/#{acct()}/incmeta?comp=list&include=snapshots,versions", @v)
    assert unknown.status == 200
    refute unknown.body =~ "<Metadata>"
  end

  # ---------------------------------------------------------------------------
  # Helpers (mirrors test/compliance/c1_arm.exs)
  # ---------------------------------------------------------------------------

  defp acct, do: @acct
  defp cont, do: @cont
  defp port, do: :persistent_term.get({__MODULE__, :port})

  # opts may be either a bare header list or keyword opts (headers:/body:).
  defp normalize_opts(opts) do
    if opts == [] or match?([{k, _} | _] when is_atom(k), opts) do
      {Keyword.get(opts, :headers, []), Keyword.get(opts, :body, nil)}
    else
      {opts, nil}
    end
  end

  defp req(port, method, path, opts, body \\ nil) do
    {hdrs, kw_body} = normalize_opts(opts)
    body = body || kw_body
    url = to_charlist("http://127.0.0.1:#{port}#{path}")

    request =
      if body do
        {url, Enum.map(hdrs, fn {k, v} -> {to_charlist(k), to_charlist(v)} end),
         ~c"application/octet-stream", body}
      else
        {url, Enum.map(hdrs, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}
      end

    :httpc.request(method, request, [timeout: 5_000, connect_timeout: 5_000, autoredirect: false],
      body_format: :binary
    )
  end

  defp req!(port, method, path, opts, body \\ nil) do
    case req(port, method, path, opts, body) do
      {:ok, {{_ver, status, _phrase}, resp_headers, resp_body}} ->
        %{
          status: status,
          headers: resp_headers,
          body: resp_body
        }

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
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        if :ets.info(:smalt_subscriptions) == :undefined do
          pid = Process.whereis(Store)
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> ensure_store()
          after
            500 -> :ok
          end
        else
          :ok
        end
    end
  end
end
