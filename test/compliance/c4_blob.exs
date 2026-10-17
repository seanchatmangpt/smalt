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
  # Lens-9: hoisted above first use — reads before assignment compile to nil
  # (three new std-header pins hit exactly that and the failures were the
  # authoring bug, not a wire regression).
  @v4_guid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

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
    # courts pin — every 400 gate names its prose exactly). Copy updated to the
    # LANDED gate prose (GAP-AUD1-03 SAS admission widened the gate: the 400
    # names SAS tokens and the allowlist, not just the header) — v26.10.16
    # sdk-results receipts pin this exact wire copy on appconfig/kv surfaces.
    assert Jason.decode!(resp.body)["error"]["message"] ==
             "Missing required x-ms-version header, SAS token, or allowlisted host."
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

    # F1 LANDED (compliance lens-7 routing, this lane): request_id/0 now emits
    # the dashed-36 RFC 4122 v4 GUID real Azure emits — unified with the ARM
    # gateway (c1) and LA surface (c7). Previously a 32-hex dialect pin
    # (lens-2 cycle-1 finding, honestly graded, now closed).
    assert is_binary(hdrs["x-ms-request-id"]) and hdrs["x-ms-request-id"] =~ @v4_guid
  end

  test "container metadata round-trips via x-ms-meta-* headers (PUT + GET)" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    put =
      req!(port(), :put, "/#{acct()}/#{cont()}?restype=container&comp=metadata", @v ++ [
        {"x-ms-meta-owner", "c4"},
        {"x-ms-meta-purpose", "fence"}
      ])

    assert put.status == 200
    put_hdrs = header_map(put)
    # Lens-9: comp=metadata rides blob_std_headers/1 at the wire (egress
    # router site 922) — pin the full std-header law on this surface too.
    assert is_binary(put_hdrs["x-ms-request-id"]) and put_hdrs["x-ms-request-id"] =~ @v4_guid
    assert put_hdrs["x-ms-version"] == @version
    assert is_binary(put_hdrs["etag"])

    get = req!(port(), :get, "/#{acct()}/#{cont()}?restype=container&comp=metadata", @v)
    assert get.status == 200
    hdrs = header_map(get)
    assert is_binary(hdrs["x-ms-request-id"]) and hdrs["x-ms-request-id"] =~ @v4_guid
    assert hdrs["x-ms-version"] == @version
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

    # F1 LANDED (compliance lens-7 routing, this lane): request_id/0 now emits
    # the dashed-36 RFC 4122 v4 GUID real Azure emits — unified with the ARM
    # gateway (c1) and LA surface (c7). Previously a 32-hex dialect pin
    # (lens-2 cycle-1 finding, honestly graded, now closed).
    assert is_binary(hdrs["x-ms-request-id"]) and hdrs["x-ms-request-id"] =~ @v4_guid

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
    assert is_binary(header_map(put)["x-ms-request-id"]) and header_map(put)["x-ms-request-id"] =~ @v4_guid
    assert header_map(put)["x-ms-version"] == @version
    assert Jason.decode!(put.body)["has_legal_hold"] == true

    get = req!(port(), :get, "/#{acct()}/#{cont()}?comp=legalhold", @v)
    assert get.status == 200
    assert header_map(get)["x-ms-legal-hold"] == "true"
    assert is_binary(header_map(get)["x-ms-request-id"]) and header_map(get)["x-ms-request-id"] =~ @v4_guid
    assert header_map(get)["x-ms-version"] == @version
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
    assert is_binary(hdrs["x-ms-request-id"]) and hdrs["x-ms-request-id"] =~ @v4_guid
    assert hdrs["x-ms-version"] == @version
    assert is_binary(hdrs["immutability-policy-until"])

    get = req!(port(), :get, "/#{acct()}/#{cont()}?comp=immutabilityPolicy", @v)
    assert get.status == 200
    assert is_binary(header_map(get)["x-ms-request-id"]) and header_map(get)["x-ms-request-id"] =~ @v4_guid
    assert header_map(get)["x-ms-version"] == @version
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

  test "list blobs emitted marker round-trips: emit -> resume -> terminate" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    names = for i <- 1..7, do: "b#{i}"
    Enum.each(names, fn name ->
      req!(port(), :put, "/#{acct()}/#{cont()}/#{name}",
        headers: @v ++ [{"content-type", "application/octet-stream"}],
        body: name
      )
    end)

    # SDK-style loop: consume the server's OWN emitted NextMarker until absent.
    # Pins the emission/parse PAIR end to end: exact partition of the name
    # space (no repeats, no skips) and loop termination on the final page.
    {pages, seen, _marker_end, hops} =
      Enum.reduce_while(1..10, {[], [], nil, 0}, fn _hop, {pages, seen, marker, n} ->
        q = if marker, do: "comp=list&restype=container&maxresults=3&marker=#{marker}", else: "comp=list&restype=container&maxresults=3"

        resp = req!(port(), :get, "/#{acct()}/#{cont()}?#{q}", @v)
        assert resp.status == 200

        got =
          resp.body
          |> String.split("<Name>")
          |> tl()
          |> Enum.map(&(&1 |> String.split("</Name>") |> hd()))

        next =
          case Regex.run(~r/<NextMarker>([^<]*)<\/NextMarker>/, resp.body) do
            [_, m] -> m
            nil -> nil
          end

        # an intermediate page MUST emit a marker; the final page MUST NOT
        if marker == nil or got != [] do
          assert is_binary(next) == (length(seen) + length(got) < length(names)),
                 "expected marker presence=#{length(seen) + length(got) < length(names)} " <>
                   "but got #{inspect(next)} on page with #{inspect(got)}"
        end

        if next == nil do
          {:halt, {pages ++ [got], seen ++ got, next, n + 1}}
        else
          {:cont, {pages ++ [got], seen ++ got, next, n + 1}}
        end
      end)

    assert hops <= 10
    assert seen == names, "round-trip partition mismatch: #{inspect(pages)}"
    assert length(pages) == 3
  end

  test "list containers emitted marker round-trips: emit -> resume -> terminate" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    Enum.each(for(i <- 1..7, do: "tc#{i}"), fn name ->
      assert req!(port(), :put, "/#{acct()}/#{name}?restype=container", @v).status == 201
    end)

    # Account-level List Containers: same emit->resume->terminate contract
    # as the blob listing, different emission site (blob_service.ex).
    # The emitted marker MUST be the page's last container name (Azure
    # resumes AFTER it); resume yields EXACTLY the remainder, no repeats,
    # and the final page emits NO marker.
    {pages, seen, hops} =
      Enum.reduce_while(1..10, {[], [], 0}, fn _hop, {pages, seen, n} ->
        marker = Enum.take(seen, -1)

        q =
          case marker do
            ["tc" <> _ = m] -> "comp=list&maxresults=3&marker=#{m}"
            _ -> "comp=list&maxresults=3"
          end

        resp = req!(port(), :get, "/#{acct()}?#{q}", @v)
        assert resp.status == 200

        got =
          resp.body
          |> String.split("<Name>")
          |> tl()
          |> Enum.map(&(&1 |> String.split("</Name>") |> hd()))

        next =
          case Regex.run(~r/<NextMarker>([^<]*)<\/NextMarker>/, resp.body) do
            [_, m] -> m
            nil -> nil
          end

        # full page => marker present; short page => absent
        assert is_binary(next) == (length(got) == 3),
               "marker presence mismatch: next=#{inspect(next)} got=#{inspect(got)}"

        case next do
          nil ->
            {:halt, {pages ++ [got], seen ++ got, n + 1}}

          _ ->
            # emitted marker MUST be the page's last name
            assert next == List.last(got),
                   "emitted marker not last-of-page: #{inspect(next)} vs #{inspect(got)}"

            {:cont, {pages ++ [got], seen ++ got, n + 1}}
        end
      end)

    assert hops <= 10
    assert seen == Enum.sort(["fencecont", "tc1", "tc2", "tc3", "tc4", "tc5", "tc6", "tc7"]),
           "partition mismatch: #{inspect(pages)}"
    assert length(pages) == 3
  end

  test "delimiter listing emitted marker round-trips: emit -> resume -> terminate" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    # Lexicographic space: r00, r01, then rollups s/ (s/a, s/b) and t/ (t/c).
    Enum.each(["r00", "r01", "s/a", "s/b", "t/c"], fn name ->
      req!(port(), :put, "/#{acct()}/#{cont()}/#{name}",
        headers: @v ++ [{"content-type", "application/octet-stream"}],
        body: name
      )
    end)

    # SDK-style loop over the DELIMITER path (composition branch, distinct
    # from cycle-1's fast path): the emitted NextMarker continues from the
    # last ELEMENT (blob name or BlobPrefix); the union of pages must
    # partition the element space with no repeats and no skips, and the
    # last page emits no marker.
    {pages, elements, hops} =
      Enum.reduce_while(1..10, {[], [], 0}, fn _hop, {pages, elements, n} ->
        marker = Enum.take(elements, -1)

        q =
          case marker do
            [m] -> "comp=list&restype=container&delimiter=/&maxresults=2&marker=#{m}"
            _ -> "comp=list&restype=container&delimiter=/&maxresults=2"
          end

        resp = req!(port(), :get, "/#{acct()}/#{cont()}?#{q}", @v)
        assert resp.status == 200

        # BlobPrefix blocks CONTAIN <Name> children — strip them first so
        # the Name scan only sees top-level blob names.
        stripped =
          Regex.replace(~r/<BlobPrefix>.*?<\/BlobPrefix>/s, resp.body, "")

        names =
          stripped
          |> String.split("<Name>")
          |> tl()
          |> Enum.map(&(&1 |> String.split("</Name>") |> hd()))

        prefixes =
          Regex.scan(~r/<BlobPrefix>\s*<Name>([^<]+)<\/Name>\s*<\/BlobPrefix>/s, resp.body)
          |> Enum.map(&Enum.at(&1, 1))

        next =
          case Regex.run(~r/<NextMarker>([^<]*)<\/NextMarker>/, resp.body) do
            [_, m] -> m
            nil -> nil
          end

        page_elements = names ++ prefixes
        assert length(page_elements) > 0, "empty page with next=#{inspect(next)}"

        # emission: the marker, when present, IS the page's last element
        if is_binary(next) do
          assert next == List.last(page_elements),
                 "emitted marker not last-of-page: #{inspect(next)} vs #{inspect(page_elements)}"
        end

        case next do
          nil ->
            {:halt, {pages ++ [page_elements], elements ++ page_elements, n + 1}}

          _ ->
            {:cont, {pages ++ [page_elements], elements ++ page_elements, n + 1}}
        end
      end)

    assert hops <= 10
    # Exact element-space partition: visible blobs r00, r01 plus the two
    # rollups s/ and t/ (t/c hidden under t/). No repeats, no skips.
    assert elements == Enum.sort(["r00", "r01", "s/", "t/"]),
           "delimiter round-trip partition mismatch: #{inspect(pages)}"
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
    # lens-5: conditional-write 412 legs carry the full std-header fence.
    assert_std_blob_headers(resp)

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
    assert_std_blob_headers(del)

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

  test "duplicate PUT container -> idempotent 200 on identical metadata, 409 ContainerAlreadyExists on drift" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/duplec1?restype=container", unlocked).status == 201

    # Landed semantics (lens-5 cycle-33 "Idempotent Put Container", pinned by
    # test/egress_dispatch_test.exs:1597 + test/corpus/blob_container_reput.exs):
    # real Azure answers 200 + std headers when the x-ms-meta-* set is
    # IDENTICAL, 409 ContainerAlreadyExists only when it differs. The
    # compliance copy predates that landing and pinned blanket 409.
    dup = req!(port(), :put, "/#{acct()}/duplec1?restype=container", unlocked)

    assert dup.status == 200
    assert_std_blob_headers(dup)

    drifted =
      req!(port(), :put, "/#{acct()}/duplec1?restype=container",
        headers: unlocked ++ [{"x-ms-meta-owner", "other"}]
      )

    assert drifted.status == 409
    assert Jason.decode!(drifted.body)["error"]["code"] == "ContainerAlreadyExists"
  end

  test "list blobs with junk maxresults -> 400 InvalidQueryParameterValue (Azure XML envelope)" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/mxresults?restype=container", unlocked).status == 201

    resp = req!(port(), :get, "/#{acct()}/mxresults?comp=list&maxresults=abc", @v)

    assert resp.status == 400

    # comp=list-class errors deliberately render the Azure XML <Error> envelope
    # (application/xml), NOT JSON — lane 06 defect 3 landed that wire shape and
    # the blob_error_xml arm owns it. The compliance copy predated the landing
    # and JSON-decoded; fence the XML envelope instead.
    assert resp.body =~ ~r/<Error>/
    assert resp.body =~
             ~r/<Code>InvalidQueryParameterValue<\/Code>/

    assert String.contains?(header_map(resp)["content-type"], "application/xml")
  end

  test "list blobs with delimiter rolls directories into BlobPrefix at the wire" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/delimtest?restype=container", unlocked).status == 201

    # Comment re-graded (docs lens-7 routing, lens-9): the old text claimed
    # slash-names were a "router-lane gap" — STALE since the egress splat
    # landed: virtual directories (slash-names) are wire-live, pinned by the
    # delimiter BlobPrefix court below (blob lens-2) and WIRE_PARITY rows in
    # C4_BLOB.md. This court still uses a "-" delimiter as an equivalent
    # composition surface (no engine dependence on the separator).
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
    assert is_binary(hdrs["x-ms-request-id"]) and hdrs["x-ms-request-id"] =~ @v4_guid
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
    # lens-5: the 412 leg is pinned to the full v4-GUID + version fence, not
    # just "some request-id string is present" (component-level mutation bait).
    assert_std_blob_headers(wrong)

    # If-Match match -> 200 + exact bytes
    ok = req!(port(), :get, "/#{acct()}/condread/cb", @v ++ [{"if-match", etag}])
    assert ok.status == 200
    assert ok.body == "payload"

    # If-None-Match match -> 304, empty body, etag echoed, error headers present
    inm = req!(port(), :get, "/#{acct()}/condread/cb", @v ++ [{"if-none-match", etag}])
    assert inm.status == 304
    assert inm.body == ""
    assert header_map(inm)["etag"] == etag
    # F5 error-header contract also applies to the 304 path — lens-5: pinned
    # to the full fence (v4-GUID request-id + exact version), not is_binary.
    assert_std_blob_headers(inm)

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
    # lens-5: the precedence winner carries the full std-header fence too.
    assert_std_blob_headers(both)
  end

  # Lens-3 cycle-2: conditional x range precedence at the wire (RFC 7232 —
  # conditional evaluation precedes the range branch). A 412 must win over a
  # satisfiable Range (no 206/bytes leak); a 304 must win over a Range; and
  # the x-ms-range header dialect must behave identically to `Range`.
  test "conditional x range precedence at the wire (lens-3)" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/condrange?restype=container", unlocked).status == 201

    put =
      req!(port(), :put, "/#{acct()}/condrange/pr.bin",
        headers: @v ++ [{"content-type", "application/octet-stream"}],
        body: "payload"
      )

    assert put.status == 201
    etag = header_map(put)["etag"]

    # plain satisfiable Range -> 206 with exact bytes + content-range
    r = req!(port(), :get, "/#{acct()}/condrange/pr.bin", @v ++ [{"range", "bytes=0-2"}])
    assert r.status == 206
    assert r.body == "pay"
    assert header_map(r)["content-range"] == "bytes 0-2/7"

    # x-ms-range dialect: identical behavior
    xr = req!(port(), :get, "/#{acct()}/condrange/pr.bin", @v ++ [{"x-ms-range", "bytes=0-2"}])
    assert xr.status == 206
    assert xr.body == "pay"

    # mismatching If-Match + Range -> 412 (NOT 206 — no bytes leak past a
    # failed precondition even when a range is requested)
    m = req!(port(), :get, "/#{acct()}/condrange/pr.bin", @v ++ [{"if-match", "\"dead\""}, {"range", "bytes=0-2"}])
    assert m.status == 412
    assert m.body =~ "PreconditionFailed"
    assert_std_blob_headers(m)

    # matching If-None-Match + Range -> 304 (NOT 206)
    n = req!(port(), :get, "/#{acct()}/condrange/pr.bin", @v ++ [{"if-none-match", etag}, {"range", "bytes=0-2"}])
    assert n.status == 304
    assert n.body == ""
    # lens-5: 304 carries the full fence even when it wins over a Range.
    assert_std_blob_headers(n)

    # matching If-Match + Range -> 206 (precondition passes, range applies)
    p =
      req!(port(), :get, "/#{acct()}/condrange/pr.bin",
        @v ++ [{"if-match", etag}, {"range", "bytes=0-2"}]
      )

    assert p.status == 206
    assert p.body == "pay"
    assert_std_blob_headers(p)

    # lens-4 cycle-3: If-None-Match: * + Range -> 304 (the star matches any
    # current entity; a range cannot leak bytes past a matched INM).
    star =
      req!(port(), :get, "/#{acct()}/condrange/pr.bin",
        @v ++ [{"if-none-match", "*"}, {"range", "bytes=0-2"}]
      )

    assert star.status == 304
    assert star.body == ""
    assert_std_blob_headers(star)

    # lens-4 cycle-3: Range on a MISSING blob -> 404 BlobNotFound (existence
    # precedes the range branch — never 416, never a content-range header).
    missing =
      req!(port(), :get, "/#{acct()}/condrange/no-such-blob",
        @v ++ [{"range", "bytes=0-2"}]
      )

    assert missing.status == 404
    assert Jason.decode!(missing.body)["error"]["code"] == "BlobNotFound"
    refute header_map(missing)["content-range"]
    assert_std_blob_headers(missing)
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
  # Lens-4 cycle-1: header-presence fences at the WIRE tier on every blob
  # return-header surface (mutant-Z generalization). Every surface whose
  # service headers were previously emitted only engine-side (or not at all)
  # is fenced here: list containers, list blobs, PUT blob 201, GET blob 200,
  # ranged 206, 416, HEAD blob, GET metadata / legalhold / immutabilityPolicy.
  # Real Azure emits x-ms-request-id (dashed-36 v4 GUID) + x-ms-version on all
  # of them. Mutant Z (lens-3) showed engine-only coverage is a gap class.
  # ---------------------------------------------------------------------------

  @v4_guid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  defp assert_std_blob_headers(resp) do
    hdrs = header_map(resp)

    # Defensive (lens-4/5 wave, :1002 class): a MISSING header used to
    # FunctionClauseError inside Kernel.=~/2, burying the real failure. Assert
    # presence first so the wire gap reads as a typed assertion, never a
    # clause crash.
    assert is_binary(hdrs["x-ms-request-id"]), "x-ms-request-id header missing"
    assert is_binary(hdrs["x-ms-request-id"]) and hdrs["x-ms-request-id"] =~ @v4_guid, "x-ms-request-id missing/not v4"
    assert hdrs["x-ms-version"] == @version
    hdrs
  end

  test "lens-4: list containers carries x-ms-request-id (v4) + x-ms-version at the wire" do
    assert req!(port(), :put, "/#{acct()}/#{cont()}?restype=container", @v).status == 201

    resp = req!(port(), :get, "/#{acct()}?comp=list", @v)
    assert resp.status == 200
    assert resp.body =~ "<Containers>"
    assert_std_blob_headers(resp)
  end

  test "lens-4: list blobs carries x-ms-request-id (v4) + x-ms-version at the wire" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/hdrlist?restype=container", unlocked).status == 201

    req!(port(), :put, "/#{acct()}/hdrlist/x",
      headers: @v ++ [{"content-type", "application/octet-stream"}],
      body: "x"
    )

    comp_list = req!(port(), :get, "/#{acct()}/hdrlist?comp=list&restype=container", @v)
    assert comp_list.status == 200
    assert_std_blob_headers(comp_list)

    plain = req!(port(), :get, "/#{acct()}/hdrlist", @v)
    assert plain.status == 200
    assert_std_blob_headers(plain)
  end

  test "lens-4: PUT blob 201 / GET 200 / 206 / 416 / HEAD carry the service headers" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/hdrblob?restype=container", unlocked).status == 201

    put =
      req!(port(), :put, "/#{acct()}/hdrblob/h.bin",
        headers: @v ++ [{"content-type", "application/octet-stream"}],
        body: "0123456789"
      )

    assert put.status == 201
    assert_std_blob_headers(put)

    get = req!(port(), :get, "/#{acct()}/hdrblob/h.bin", @v)
    assert get.status == 200
    assert_std_blob_headers(get)

    ranged = req!(port(), :get, "/#{acct()}/hdrblob/h.bin", @v ++ [{"range", "bytes=0-2"}])
    assert ranged.status == 206
    assert_std_blob_headers(ranged)

    bad = req!(port(), :get, "/#{acct()}/hdrblob/h.bin", @v ++ [{"range", "bytes=99-"}])
    assert bad.status == 416
    assert_std_blob_headers(bad)

    head = req!(port(), :head, "/#{acct()}/hdrblob/h.bin", @v)
    assert head.status == 200
    assert_std_blob_headers(head)
  end

  # ---------------------------------------------------------------------------
  # Lens-6 (blob custody): escalated frontier items.
  #
  # 1. x-ms-range precedence: Get Blob REST spec — "If both Range and
  #    x-ms-range are specified, the service uses the value of x-ms-range."
  #    smalt previously let the plain `Range` header win (range ++ x-ms-range
  #    fed to List.first). Now fenced: conflicting headers → x-ms-range wins.
  # 2. Ranged HEAD: HEAD is Get Blob without a response body; Azure honors
  #    Range/x-ms-range on it (206 + Content-Range + range-length
  #    Content-Length; unsatisfiable → header-only 416 with bytes */total).
  #    smalt previously ignored ranges on HEAD entirely.
  # 3. 416 envelope: DOCUMENTED DIVERGENCE — Azure renders blob error bodies
  #    as XML (application/xml); smalt renders every blob-class error as JSON.
  #    Fenced as JSON (envelope + content-type) so it cannot drift silently.
  # ---------------------------------------------------------------------------
  test "lens-6: x-ms-range wins over Range when both are present (Azure parity)" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/rangeprec?restype=container", unlocked).status == 201

    assert req!(port(), :put, "/#{acct()}/rangeprec/p.bin",
             headers: @v ++ [{"content-type", "application/octet-stream"}],
             body: "0123456789"
           ).status == 201

    resp =
      req!(port(), :get, "/#{acct()}/rangeprec/p.bin", @v ++ [
        {"range", "bytes=99-"},
        {"x-ms-range", "bytes=0-2"}
      ])

    assert resp.status == 206
    hdrs = assert_std_blob_headers(resp)
    assert hdrs["content-range"] == "bytes 0-2/10"
    assert resp.body == "012"
  end

  test "lens-6: ranged HEAD returns 206 + Content-Range + range-length Content-Length" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/rangedhead?restype=container", unlocked).status == 201

    assert req!(port(), :put, "/#{acct()}/rangedhead/r.bin",
             headers: @v ++ [{"content-type", "application/octet-stream"}],
             body: "0123456789"
           ).status == 201

    head =
      req!(port(), :head, "/#{acct()}/rangedhead/r.bin", @v ++ [{"x-ms-range", "bytes=0-2"}])

    assert head.status == 206
    hdrs = assert_std_blob_headers(head)
    assert hdrs["content-range"] == "bytes 0-2/10"
    assert hdrs["content-length"] == "3"
    assert head.body == ""
  end

  test "lens-6: HEAD with unsatisfiable range returns header-only 416 with bytes */total" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/head416?restype=container", unlocked).status == 201

    assert req!(port(), :put, "/#{acct()}/head416/u.bin",
             headers: @v ++ [{"content-type", "application/octet-stream"}],
             body: "0123456789"
           ).status == 201

    head = req!(port(), :head, "/#{acct()}/head416/u.bin", @v ++ [{"x-ms-range", "bytes=99-"}])
    assert head.status == 416
    hdrs = assert_std_blob_headers(head)
    assert hdrs["content-range"] == "bytes */10"
    assert head.body == ""
  end

  test "lens-6: 416 envelope divergence fence (JSON envelope + content-type + std headers)" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/env416?restype=container", unlocked).status == 201

    assert req!(port(), :put, "/#{acct()}/env416/e.bin",
             headers: @v ++ [{"content-type", "application/octet-stream"}],
             body: "0123456789"
           ).status == 201

    resp = req!(port(), :get, "/#{acct()}/env416/e.bin", @v ++ [{"range", "bytes=99-"}])
    assert resp.status == 416
    hdrs = assert_std_blob_headers(resp)
    assert hdrs["content-range"] == "bytes */10"
    assert hdrs["content-type"] == "application/json; charset=utf-8"

    body = Jason.decode!(resp.body)
    assert body["error"]["code"] == "InvalidRange"
    assert body["error"]["message"] =~ "10 bytes"
  end

  # Lens-6 cycle 2: conditional HEAD. HEAD is Get Blob, so If-Match/
  # If-None-Match evaluate exactly as on GET — 412 precedence, then 304.
  # Previously HEAD ignored conditional headers entirely.
  test "lens-6: conditional HEAD — If-Match miss is 412 with std headers" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/condhead?restype=container", unlocked).status == 201

    assert req!(port(), :put, "/#{acct()}/condhead/c.bin",
             headers: @v ++ [{"content-type", "application/octet-stream"}],
             body: "0123456789"
           ).status == 201

    head =
      req!(port(), :head, "/#{acct()}/condhead/c.bin", @v ++ [{"if-match", "\"0xDEADBEEF\""}])

    assert head.status == 412
    hdrs = assert_std_blob_headers(head)
    assert hdrs["content-type"] == "application/json; charset=utf-8"
  end

  test "lens-6: conditional HEAD — If-None-Match hit is 304 with etag echo + std headers" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/condhead2?restype=container", unlocked).status == 201

    assert req!(port(), :put, "/#{acct()}/condhead2/c.bin",
             headers: @v ++ [{"content-type", "application/octet-stream"}],
             body: "0123456789"
           ).status == 201

    get = req!(port(), :get, "/#{acct()}/condhead2/c.bin", @v)
    etag = header_map(get)["etag"]

    head =
      req!(port(), :head, "/#{acct()}/condhead2/c.bin", @v ++ [{"if-none-match", etag}])

    assert head.status == 304
    hdrs = assert_std_blob_headers(head)
    assert hdrs["etag"] == etag
    assert head.body == ""
  end

  test "lens-6: conditional HEAD — If-Match hit + range evaluates 412 before 206 (RFC 9110)" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/condhead3?restype=container", unlocked).status == 201

    assert req!(port(), :put, "/#{acct()}/condhead3/c.bin",
             headers: @v ++ [{"content-type", "application/octet-stream"}],
             body: "0123456789"
           ).status == 201

    get = req!(port(), :get, "/#{acct()}/condhead3/c.bin", @v)
    etag = header_map(get)["etag"]

    head =
      req!(port(), :head, "/#{acct()}/condhead3/c.bin", @v ++ [
        {"if-match", etag},
        {"x-ms-range", "bytes=0-2"}
      ])

    assert head.status == 206
    hdrs = assert_std_blob_headers(head)
    assert hdrs["content-range"] == "bytes 0-2/10"
  end

  test "lens-4: GET metadata / legalhold / immutabilityPolicy carry request-id (v4)" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/hdrcomp?restype=container", unlocked).status == 201

    assert req!(port(), :put, "/#{acct()}/hdrcomp?comp=metadata", @v ++ [
             {"x-ms-meta-owner", "c4"}
           ]).status == 200

    md = req!(port(), :get, "/#{acct()}/hdrcomp?comp=metadata", @v)
    assert md.status == 200
    assert header_map(md)["x-ms-meta-owner"] == "c4"
    assert_std_blob_headers(md)

    hold = req!(port(), :put, "/#{acct()}/hdrcomp?comp=legalhold", @v ++ [{"x-ms-legal-hold", "true"}])
    assert hold.status == 200

    get_hold = req!(port(), :get, "/#{acct()}/hdrcomp?comp=legalhold", @v)
    assert get_hold.status == 200
    assert header_map(get_hold)["x-ms-legal-hold"] == "true"
    assert_std_blob_headers(get_hold)

    assert req!(port(), :put, "/#{acct()}/hdrcomp?comp=immutabilityPolicy",
             headers: @v ++ [{"content-type", "application/json"}],
             body: Jason.encode!(%{"immutabilityPeriodSinceCreationInDays" => 7})
           ).status == 200

    get_pol = req!(port(), :get, "/#{acct()}/hdrcomp?comp=immutabilityPolicy", @v)
    assert get_pol.status == 200
    assert_std_blob_headers(get_pol)
  end

  # ---------------------------------------------------------------------------
  # Lens-5: the last two blob surfaces whose std headers arrive from the
  # ENGINES (not blob_std_headers/1) — DELETE blob 202 and HEAD container —
  # get the same wire-tier v4-GUID + version fence. Both engine request_id/0
  # generators are the unified dashed-36 v4 dialect (F1 cross-court), so the
  # fence is identical; mutating either engine's generator must kill here.
  # ---------------------------------------------------------------------------

  test "lens-5: DELETE blob 202 carries x-ms-request-id (v4) + x-ms-version at the wire" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/hdrdel?restype=container", unlocked).status == 201

    assert req!(port(), :put, "/#{acct()}/hdrdel/d.bin",
             headers: @v ++ [{"content-type", "application/octet-stream"}],
             body: "d"
           ).status == 201

    del = req!(port(), :delete, "/#{acct()}/hdrdel/d.bin", @v)
    assert del.status == 202
    assert_std_blob_headers(del)

    # the 404 leg (already-deleted blob) is fenced too
    gone = req!(port(), :delete, "/#{acct()}/hdrdel/d.bin", @v)
    assert gone.status == 404
    assert_std_blob_headers(gone)
  end

  test "lens-5: HEAD container (restype=container) carries x-ms-request-id (v4) + x-ms-version" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/hdrhead?restype=container", unlocked).status == 201

    head = req!(port(), :head, "/#{acct()}/hdrhead?restype=container", @v)
    assert head.status == 200
    assert_std_blob_headers(head)

    miss = req!(port(), :head, "/#{acct()}/no-such-container-hd?restype=container", @v)
    assert miss.status == 404
    assert_std_blob_headers(miss)
  end

  test "lens-5: GET container properties carries x-ms-request-id (v4) + x-ms-version" do
    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/hdrgetprop?restype=container", unlocked).status == 201

    prop = req!(port(), :get, "/#{acct()}/hdrgetprop?restype=container", @v)
    assert prop.status == 200
    assert_std_blob_headers(prop)

    miss = req!(port(), :get, "/#{acct()}/no-such-container-gp?restype=container", @v)
    assert miss.status == 404
    assert_std_blob_headers(miss)
  end

  # Lens-5 cycle-4: the store-not-ready 503 on blob routes is a blob response
  # class — it must carry the std headers like every other class (F5 parity).
  # Forces the not-ready state the real way (beam hidden + module purged), a
  # real degraded store, never a mock.
  test "lens-5: blob route 503 RouteNotReady carries x-ms-request-id (v4) + x-ms-version" do
    beam_dir = Mix.Project.compile_path()
    beam = Path.join(beam_dir, "Elixir.Smalt.DataPlane.BlobStorage.beam")
    assert File.exists?(beam)
    hidden = beam <> ".hidden_lens5"
    File.rename!(beam, hidden)

    :code.purge(Smalt.DataPlane.BlobStorage)
    :code.delete(Smalt.DataPlane.BlobStorage)

    resp = req!(port(), :get, "/#{acct()}/#{cont()}", @v)
    assert resp.status == 503
    assert Jason.decode!(resp.body)["error"]["code"] == "RouteNotReady"
    assert_std_blob_headers(resp)
  after
    beam_dir = Mix.Project.compile_path()
    beam = Path.join(beam_dir, "Elixir.Smalt.DataPlane.BlobStorage.beam")
    hidden = beam <> ".hidden_lens5"

    if File.exists?(hidden) do
      File.rename!(hidden, beam)
    end

    Code.ensure_loaded(Smalt.DataPlane.BlobStorage)
  end

  test "lens-5: per-request uniqueness holds across the std-header surfaces" do    unlocked = @v ++ [{"x-ms-immutable-policy", "false"}]
    assert req!(port(), :put, "/#{acct()}/hdruniq?restype=container", unlocked).status == 201

    a = req!(port(), :get, "/#{acct()}/hdruniq", @v)
    b = req!(port(), :get, "/#{acct()}/hdruniq", @v)
    assert header_map(a)["x-ms-request-id"] != header_map(b)["x-ms-request-id"]
    assert header_map(a)["x-ms-request-id"] =~ @v4_guid
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
