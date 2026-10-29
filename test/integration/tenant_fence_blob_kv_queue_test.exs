defmodule Smalt.Integration.TenantFenceBlobKvQueueTest do
  # G5 GAP-CLOSURE lane: extends the G4 tenant law (Smalt.Auth.TenantLaw) to
  # the KV-secrets, blob (containers/blobs) and queue-storage planes.
  #
  # Fence contract per plane — a foreign-`tid` bearer addressing a name that
  # exists only under another tenant's namespace gets:
  #   read   -> typed 403 Forbidden (never a 404 lie, never a silent leak)
  #   delete -> 403 AND the owner's row survives
  #   list   -> the caller's namespace only (no foreign rows)
  # Same-tenant round trips and no-tid (legacy home) traffic keep the
  # pre-fence wire (home tenant => tenant_scoped_key(t, key) == key).
  #
  # Chicago discipline: real transport (curl subprocess over the test boot's
  # real TLS twin), real STS mints per tenant (`/{tid}/oauth2/v2.0/token` —
  # the mint binds the path tenant into the token's `tid` claim), real vault/
  # blob/queue ETS. No mocks.
  #
  # Context: solo (integration tier, in-process app boot + real TLS twin).
  use ExUnit.Case, async: false

  @api_version "7.4"
  @ms_version "2021-12-02"
  @acct "az5g5"
  @token_cache :g5_tenant_tokens

  # ---------------------------------------------------------------------------
  # KV secrets plane
  # ---------------------------------------------------------------------------

  test "KV secrets: cross-tenant read/delete 403 + survives, list isolated, home + foreign round trips intact" do
    {base, cert} = twin()
    t1 = "t1g5"
    t2 = "t2g5"
    stamp = System.system_time(:millisecond)
    s1 = "g5-s1-#{stamp}"
    s2 = "g5-s2-#{stamp}"
    home_secret = "g5-home-#{stamp}"

    # Same-tenant round trip: t1 PUT -> 201, t1 GET -> 200 with the value.
    {st, body} = authed(:put, base, cert, "/secrets/#{s1}?api-version=#{@api_version}", ~s({"value":"v1"}), bearer: t1)
    assert st in [200, 201], "t1 PUT secret: #{inspect(body)}"

    {st, body} = authed(:get, base, cert, "/secrets/#{s1}?api-version=#{@api_version}", "", bearer: t1)
    assert st == 200, "t1 GET own secret: #{inspect(body)}"
    assert body["value"] == "v1"

    # Second PUT mints a new version; the version-addressed GET (the
    # s10/s19 falsifier surface) must resolve INSIDE the caller's namespace —
    # 200 with the retained v2 value for the owner, typed 403 for a foreign
    # tid (never a scoped-write/legacy-read 404 mismatch).
    {st, body} = authed(:put, base, cert, "/secrets/#{s1}?api-version=#{@api_version}", ~s({"value":"v2"}), bearer: t1)
    assert st == 200, "t1 PUT v2: #{st} #{inspect(body)}"

    v2 = body["id"] |> to_string() |> String.split("/") |> List.last()
    assert is_binary(v2) and v2 != "", "PUT v2 response missing versioned id: #{inspect(body)}"

    {st, body} = authed(:get, base, cert, "/secrets/#{s1}/#{v2}?api-version=#{@api_version}", "", bearer: t1)
    assert st == 200, "t1 version-addressed GET: #{st} #{inspect(body)}"
    assert body["value"] == "v2", "version GET returned wrong value: #{inspect(body)}"

    {st, body} = authed(:get, base, cert, "/secrets/#{s1}/#{v2}?api-version=#{@api_version}", "", bearer: t2)
    assert st == 403, "t2 version-addressed GET expected 403: #{st} #{inspect(body)}"
    assert forbidden?(body)

    # Cross-tenant read -> typed 403 Forbidden.
    {st, body} = authed(:get, base, cert, "/secrets/#{s1}?api-version=#{@api_version}", "", bearer: t2)
    assert st == 403, "t2 GET foreign secret expected 403: #{st} #{inspect(body)}"
    assert forbidden?(body)

    # Cross-tenant delete -> 403 and the owner's row survives.
    {st, body} = authed(:delete, base, cert, "/secrets/#{s1}?api-version=#{@api_version}", "", bearer: t2)
    assert st == 403, "t2 DELETE foreign secret expected 403: #{st} #{inspect(body)}"
    assert forbidden?(body)

    {st, body} = authed(:get, base, cert, "/secrets/#{s1}?api-version=#{@api_version}", "", bearer: t1)
    assert st == 200 and body["value"] == "v2", "secret did not survive foreign delete"

    # List: t1 sees s1, t2 does not.
    {st, body} = authed(:get, base, cert, "/secrets?api-version=#{@api_version}", "", bearer: t1)
    assert st == 200
    assert Enum.any?(body["value"] || [], &(&1["id"] && String.contains?(&1["id"], "/#{s1}")))

    {st, body} = authed(:get, base, cert, "/secrets?api-version=#{@api_version}", "", bearer: t2)
    assert st == 200
    refute Enum.any?(body["value"] || [], &(&1["id"] && String.contains?(&1["id"], "/#{s1}")))

    # Second tenant creates its own same-named namespace entry: isolated.
    {st, body} = authed(:put, base, cert, "/secrets/#{s2}?api-version=#{@api_version}", ~s({"value":"t2"}), bearer: t2)
    assert st in [200, 201], "t2 PUT own secret: #{inspect(body)}"

    {st, body} = authed(:get, base, cert, "/secrets/#{s2}?api-version=#{@api_version}", "", bearer: t2)
    assert st == 200 and body["value"] == "t2"

    # No-tid caller resolves to the legacy home tenant: full round trip on
    # the legacy (unprefixed) keys, and foreign rows are fenced from home.
    {st, body} = authed(:put, base, cert, "/secrets/#{home_secret}?api-version=#{@api_version}", ~s({"value":"home"}), [])
    assert st in [200, 201], "no-tid PUT secret: #{inspect(body)}"

    {st, body} = authed(:get, base, cert, "/secrets/#{home_secret}?api-version=#{@api_version}", "", [])
    assert st == 200 and body["value"] == "home"

    {st, _} = authed(:get, base, cert, "/secrets/#{s1}?api-version=#{@api_version}", "", [])
    assert st == 403, "no-tid GET foreign secret expected 403: #{st}"
  end

  test "KV versions-list under the fence: home + foreign scoped lists, newest-first, byte-exact, cross-tenant 403" do
    {base, cert} = twin()
    t1 = "t1g5"
    stamp = System.system_time(:millisecond)
    s1 = "g5-vs-#{stamp}"

    vals = ["vs-v1", "vs-v2", "vs-v3"]

    for v <- vals do
      {st, body} = authed(:put, base, cert, "/secrets/#{s1}?api-version=#{@api_version}", ~s({"value":"#{v}"}), bearer: t1)
      assert st in [200, 201], "t1 PUT #{v}: #{st} #{inspect(body)}"
    end

    # Owner list: 3 bundles, newest-first, byte-exact values, documented
    # SecretBundle members on every entry (incl. the "version" member the
    # athena s19/s10 courts read — the V20a fix; never the internal
    # versions/created_seq/is_version_row bookkeeping).
    {st, body} = authed(:get, base, cert, "/secrets/#{s1}/versions?api-version=#{@api_version}", "", bearer: t1)
    assert st == 200, "t1 versions list: #{st} #{inspect(body)}"
    assert %{"value" => value} = body
    assert length(value) == 3, "3 retained versions listed, got #{length(value)}"
    assert Enum.map(value, & &1["value"]) == Enum.reverse(vals), "newest-first byte-exact values"

    for bundle <- value do
      # V20b: the wire id is the DOCUMENTED SecretBundle shape
      # https://{host}/secrets/{name}/{version} — the internal
      # "{tid}/{name}" storage key never leaks onto the wire path.
      assert is_binary(bundle["id"])
      assert String.contains?(bundle["id"], "/secrets/#{s1}/"),
        "bad bundle id: #{inspect(bundle)}"

      refute String.contains?(bundle["id"], "/#{t1}/"),
        "wire id leaks the scoped storage key: #{inspect(bundle)}"

      assert is_binary(bundle["version"]) and bundle["version"] != "", "bundle carries the version member"
      assert is_integer(bundle["attributes"]["created"])
      refute Map.has_key?(bundle, "versions")
      refute Map.has_key?(bundle, "created_seq")
      refute Map.has_key?(bundle, "is_version_row")
    end

    # List head == the unnamed latest read (last-write agreement).
    {st, latest} = authed(:get, base, cert, "/secrets/#{s1}?api-version=#{@api_version}", "", bearer: t1)
    assert st == 200
    assert hd(value)["id"] == latest["id"], "index head is the last-write version"
    assert hd(value)["version"] == latest_id(latest["id"])

    # A foreign tenant listing the same name gets a 403 lie-free refusal
    # while the owner's history survives untouched.
    {st, body} = authed(:get, base, cert, "/secrets/#{s1}/versions?api-version=#{@api_version}", "", bearer: "t2g5")
    assert st == 403, "t2 versions list on foreign name expected 403: #{st} #{inspect(body)}"
    assert forbidden?(body)

    {st, body} = authed(:get, base, cert, "/secrets/#{s1}/versions?api-version=#{@api_version}", "", bearer: t1)
    assert st == 200 and length(body["value"]) == 3, "owner history did not survive the foreign probe"

    # No-tid (legacy home) caller: full versions round trip on the legacy
    # byte-identical keys; foreign rows stay fenced from home.
    home_secret = "g5-vs-home-#{stamp}"

    for v <- ["h1", "h2", "h3"] do
      {st, body} = authed(:put, base, cert, "/secrets/#{home_secret}?api-version=#{@api_version}", ~s({"value":"#{v}"}), [])
      assert st in [200, 201], "home PUT #{v}: #{st} #{inspect(body)}"
    end

    {st, body} = authed(:get, base, cert, "/secrets/#{home_secret}/versions?api-version=#{@api_version}", "", [])
    assert st == 200, "home versions list: #{st} #{inspect(body)}"
    assert Enum.map(body["value"], & &1["value"]) == ["h3", "h2", "h1"], "home list newest-first byte-exact"

    {st, _} = authed(:get, base, cert, "/secrets/#{s1}/versions?api-version=#{@api_version}", "", [])
    assert st == 403, "no-tid versions list of t1's secret expected 403: #{st}"
  end

  defp latest_id(id) when is_binary(id), do: id |> String.split("/") |> List.last()

  # ---------------------------------------------------------------------------
  # Blob plane (containers + blobs)
  # ---------------------------------------------------------------------------

  test "blob plane: cross-tenant read/delete 403 + survives, list isolated, legacy home traffic intact" do
    {base, cert} = twin()
    t1 = "t1g5"
    t2 = "t2g5"
    container = "c1-#{System.system_time(:millisecond)}"

    # t1 creates a container and a blob in it.
    {st, body} = blob_authed(:put, base, cert, "/#{@acct}/#{container}?restype=container", "", t1)
    assert st in [200, 201], "t1 create container: #{st} #{inspect(body)}"

    {st, body} = put_blob(base, cert, "/#{@acct}/#{container}/b1.txt", "hello-g5", t1)
    assert st in [200, 201], "t1 put blob: #{st} #{inspect(body)}"

    {st, body} = blob_authed(:get, base, cert, "/#{@acct}/#{container}/b1.txt", "", t1)
    assert st == 200 and body == "hello-g5", "t1 get blob: #{st} #{inspect(body)}"

    # Cross-tenant read -> typed 403 (blob and container faces).
    {st, body} = blob_authed(:get, base, cert, "/#{@acct}/#{container}/b1.txt", "", t2)
    assert st == 403, "t2 GET foreign blob expected 403: #{st} #{inspect(body)}"
    assert forbidden?(body)

    {st, body} = blob_authed(:get, base, cert, "/#{@acct}/#{container}?restype=container", "", t2)
    assert st == 403, "t2 GET foreign container expected 403: #{st} #{inspect(body)}"

    # Cross-tenant delete -> 403 and the container survives for its owner.
    {st, body} = blob_authed(:delete, base, cert, "/#{@acct}/#{container}?restype=container", "", t2)
    assert st == 403, "t2 DELETE foreign container expected 403: #{st} #{inspect(body)}"

    {st, _} = blob_authed(:get, base, cert, "/#{@acct}/#{container}?restype=container", "", t1)
    assert st in [200, 201], "container did not survive foreign delete"

    # List containers: t1 sees the container, t2's feed is empty of it.
    {st, body} = blob_authed(:get, base, cert, "/#{@acct}?comp=list", "", t1)
    assert st == 200 and String.contains?(body, container), "t1 list containers missing own container"

    {st, body} = blob_authed(:get, base, cert, "/#{@acct}?comp=list", "", t2)
    assert st == 200 and not String.contains?(body, container), "t2 list containers leaked foreign container"

    # t2 can still create its OWN namespace entry (isolation, not denial).
    {st, body} = blob_authed(:put, base, cert, "/#{@acct}/c2-t2?restype=container", "", t2)
    assert st in [200, 201], "t2 create own container: #{st} #{inspect(body)}"

    # No-tid (legacy home) caller: create + read on legacy keys, foreign
    # rows fenced.
    {st, body} = blob_authed(:put, base, cert, "/#{@acct}/c0-home?restype=container", "", [])
    assert st in [200, 201], "no-tid create container: #{st} #{inspect(body)}"

    {st, _} = blob_authed(:get, base, cert, "/#{@acct}/c0-home?restype=container", "", [])
    assert st in [200, 201], "no-tid GET own container"

    {st, _} = blob_authed(:get, base, cert, "/#{@acct}/#{container}?restype=container", "", [])
    assert st == 403, "no-tid GET foreign container expected 403: #{st}"
  end

  # ---------------------------------------------------------------------------
  # Queue storage plane
  # ---------------------------------------------------------------------------

  test "queue plane: cross-tenant read/delete 403 + survives, list isolated, legacy home traffic intact" do
    {base, cert} = twin()
    t1 = "t1g5"
    t2 = "t2g5"
    queue = "q1-#{System.system_time(:millisecond)}"
    msg_body = "g5-message"

    # t1 creates a queue and posts a message.
    {st, body} = blob_authed(:put, base, cert, "/#{@acct}/#{queue}?restype=queue", "", t1)
    assert st in [200, 201, 204], "t1 create queue: #{st} #{inspect(body)}"

    {st, body} = blob_authed(:post, base, cert, "/#{@acct}/#{queue}/messages", msg_body, t1)
    assert st in [200, 201], "t1 put message: #{st} #{inspect(body)}"

    {st, body} = blob_authed(:get, base, cert, "/#{@acct}/#{queue}/messages", "", t1)
    assert st == 200 and String.contains?(body, msg_body), "t1 get messages: #{st} #{inspect(body)}"

    # Cross-tenant read -> typed 403.
    {st, body} = blob_authed(:get, base, cert, "/#{@acct}/#{queue}/messages", "", t2)
    assert st == 403, "t2 GET foreign messages expected 403: #{st} #{inspect(body)}"
    assert forbidden?(body)

    # Cross-tenant delete -> 403 and the queue survives for its owner.
    {st, body} = blob_authed(:delete, base, cert, "/#{@acct}/#{queue}?restype=queue", "", t2)
    assert st == 403, "t2 DELETE foreign queue expected 403: #{st} #{inspect(body)}"

    {st, body} = blob_authed(:get, base, cert, "/#{@acct}?restype=queue&comp=list", "", t1)
    assert st == 200 and String.contains?(body, queue), "t1 list queues lost own queue after foreign delete"

    # List queues: t2's feed does not contain the foreign queue.
    {st, body} = blob_authed(:get, base, cert, "/#{@acct}?restype=queue&comp=list", "", t2)
    assert st == 200 and not String.contains?(body, queue), "t2 list queues leaked foreign queue"

    # No-tid (legacy home) caller: create + read, foreign rows fenced.
    {st, body} = blob_authed(:put, base, cert, "/#{@acct}/q0-home?restype=queue", "", [])
    assert st in [200, 201, 204], "no-tid create queue: #{st} #{inspect(body)}"

    {st, _} = blob_authed(:get, base, cert, "/#{@acct}/q0-home/messages", "", [])
    assert st == 200, "no-tid GET own (empty) messages"

    {st, _} = blob_authed(:get, base, cert, "/#{@acct}/#{queue}/messages", "", [])
    assert st == 403, "no-tid GET foreign messages expected 403: #{st}"
  end

  # ---------------------------------------------------------------------------
  # Transport helpers
  # ---------------------------------------------------------------------------

  defp twin do
    port = Application.fetch_env!(:smalt, :arm_tls_port)
    {cert, _key} = Smalt.TLS.dev_cert_paths(port)
    {"https://127.0.0.1:#{port}", cert}
  end

  # bearer tid nil -> non-JWT bearer (legacy home tenant, no tid claim)
  # bearer tid     -> real STS mint for that tenant path (cached per test run)
  @home_probe "Bearer g5-legacy-home-probe"

  defp authed(method, base, cert, path, body, opts) do
    tok = token_for(base, cert, Keyword.get(opts, :bearer))
    headers = if tok, do: [{"authorization", "Bearer #{tok}"}], else: []
    request(method, base, cert, path, body, headers, :json)
  end

  defp blob_authed(method, base, cert, path, body, tid) do
    tok = token_for(base, cert, tid)
    headers = if tok, do: [{"authorization", "Bearer #{tok}"}], else: []
    request(method, base, cert, path, body, headers, :raw)
  end

  defp token_for(_base, _cert, nil), do: @home_probe

  defp token_for(base, cert, tid) do
    key = {@token_cache, tid}

    case :persistent_term.get(key, nil) do
      nil ->
        tok = fetch_sts_token(base, cert, tid)
        :persistent_term.put(key, tok)
        tok

      tok ->
        tok
    end
  end

  # Put Blob requires x-ms-blob-type (KD-139 wire guard).
  defp put_blob(base, cert, path, body, tid) do
    tok = token_for(base, cert, tid)

    headers =
      if tok do
        [{"authorization", "Bearer #{tok}"}, {"x-ms-blob-type", "BlockBlob"}]
      else
        [{"authorization", @home_probe}, {"x-ms-blob-type", "BlockBlob"}]
      end

    request(:put, base, cert, path, body, headers, :raw)
  end

  defp fetch_sts_token(base, cert, tid) do
    args = [
      "-s",
      "--cacert",
      cert,
      "-X",
      "POST",
      "-d",
      "grant_type=client_credentials&client_id=g5-lane&client_secret=g5-lane&scope=https://management.azure.com/.default",
      "#{base}/#{tid}/oauth2/v2.0/token"
    ]

    {out, 0} = System.cmd("curl", args)
    Jason.decode(out)
    |> case do
      {:ok, %{"access_token" => tok}} when is_binary(tok) -> tok
      other -> flunk("STS mint for #{tid} failed: #{inspect(other)}")
    end
  end

  defp request(method, base, cert, path, body, headers, :json) do
    header_args =
      Enum.flat_map(headers, fn {k, v} -> ["-H", "#{k}: #{v}"] end)

    args =
      ["-s", "--cacert", cert, "-X", String.upcase(Atom.to_string(method))] ++
        header_args ++
        ["-H", "Content-Type: application/json", "-d", body, "-w", "\n%{http_code}", "#{base}#{path}"]

    {out, 0} = System.cmd("curl", args, stderr_to_stdout: true)
    {code, raw} = split_resp(out)
    decoded = if raw == "", do: %{}, else: Jason.decode!(raw)
    {code, decoded}
  end

  defp request(method, base, cert, path, body, headers, :raw) do
    header_args =
      Enum.flat_map(headers, fn {k, v} -> ["-H", "#{k}: #{v}"] end) ++
        ["-H", "x-ms-version: #{@ms_version}", "-H", "x-ms-date: #{application_date()}"]

    args =
      ["-s", "--cacert", cert, "-X", String.upcase(Atom.to_string(method))] ++
        header_args ++
        ["--data-binary", body, "-w", "\n%{http_code}", "#{base}#{path}"]

    {out, 0} = System.cmd("curl", args, stderr_to_stdout: true)
    split_resp(out)
  end

  defp split_resp(out) do
    parts = String.split(String.trim_trailing(out), "\n")
    code = List.last(parts) |> String.to_integer()
    raw = parts |> Enum.drop(-1) |> Enum.join("\n")
    {code, raw}
  end

  # RFC 7231 IMF-fixdate for x-ms-date.
  defp application_date do
    now = System.system_time(:second) |> DateTime.from_unix!()

    Calendar.strftime(now, "%a, %d %b %Y %H:%M:%S GMT")
  end

  defp forbidden?(%{"code" => "Forbidden"}), do: true
  defp forbidden?(%{"error" => %{"code" => "Forbidden"}}), do: true
  defp forbidden?(body) when is_binary(body), do: String.contains?(body, "Forbidden")
  defp forbidden?(_), do: false
end
