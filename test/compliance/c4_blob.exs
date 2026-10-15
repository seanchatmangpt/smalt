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
    assert hdrs["x-ms-has-immutability-policy"] in ["true", "false"]
    assert hdrs["x-ms-has-legal-hold"] in ["true", "false"]
    assert is_binary(hdrs["x-ms-request-id"])
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
    assert is_binary(hdrs["x-ms-request-id"])
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
