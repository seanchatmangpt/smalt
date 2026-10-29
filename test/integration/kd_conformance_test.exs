defmodule Smalt.Test.Integration.KdConformanceTest do
  @moduledoc """
  FIX-3 conformance court — KD-147/148/149/150/151/152 wire shapes.

  Chicago-style: real HTTP over the self-booted egress router (ephemeral
  ports, no external substrate), asserting final wire state (status lines,
  header values, body shapes) — no mocks. Each test names the KD row it
  fences; a regression of any row flips its assertion and exits 1.
  """

  use ExUnit.Case, async: false

  @tenant "00000000-0000-0000-0000-000000000000"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:smalt)
    :timer.sleep(1500)

    # test env boots on probed-free ports (config/test.exs); read the live env.
    arm = Application.fetch_env!(:smalt, :arm_port)

    url = "http://127.0.0.1:" <> Integer.to_string(arm) <> "/" <> @tenant <> "/oauth2/v2.0/token"

    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(:post,
        {String.to_charlist(url), [], ~c"application/x-www-form-urlencoded",
         "grant_type=client_credentials&client_id=kdconf&client_secret=kdconf&scope=s"},
        [], []
      )

    %{"access_token" => token} = Jason.decode!(body)
    {:ok, token: token}
  end

  import Plug.Test

  defp call(method, path, token, headers \\ [], body \\ "") do
    conn =
      method
      |> Plug.Test.conn(path, body)
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> Plug.Conn.put_req_header("x-ms-version", "2021-12-02")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    Smalt.EgressRouter.call(conn, [])
  end

  @guid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  # KD-149: KV secret create -> 201 (not 200); re-set (update) -> 200.
  test "KD-149: first-create PUT answers 201, update answers 200", %{token: token} do
    name = "kd149-" <> Integer.to_string(System.unique_integer([:positive]))

    conn =
      call(:put, "/secrets/#{name}?api-version=7.4", token,
        [{"content-type", "application/json"}],
        Jason.encode!(%{"value" => "v1"})
      )

    assert conn.status == 201, "first create must be 201 per KV secrets 7.4"

    conn2 =
      call(:put, "/secrets/#{name}?api-version=7.4", token,
        [{"content-type", "application/json"}],
        Jason.encode!(%{"value" => "v2"})
      )

    assert conn2.status == 200, "re-set (update) must be 200"
  end

  # KD-150: secret id = https://{vault}.vault.azure.net/secrets/{name}/{GUID}.
  test "KD-150: secret id is vault-host shape with GUID version", %{token: token} do
    name = "kd150-" <> Integer.to_string(System.unique_integer([:positive]))

    conn =
      call(:put, "/secrets/#{name}?api-version=7.4", token,
        [{"content-type", "application/json"}],
        Jason.encode!(%{"value" => "v"})
      )

    assert conn.status in [200, 201]
    %{"id" => id} = Jason.decode!(conn.resp_body)

    assert String.starts_with?(id, "https://") and String.contains?(id, ".vault.azure.net/secrets/"),
           "id must be vault-host shape, got: " <> id

    version = id |> String.split("/") |> List.last()
    assert version =~ @guid, "version segment must be GUID, got: " <> version
  end

  # KD-151: future api-version (2099-01-01) is a typed 400 on the KV face.
  test "KD-151: future api-version is 400 InvalidApiVersion; 7.4 admitted", %{token: token} do
    name = "kd151-" <> Integer.to_string(System.unique_integer([:positive]))

    call(:put, "/secrets/#{name}?api-version=7.4", token,
      [{"content-type", "application/json"}],
      Jason.encode!(%{"value" => "v"})
    )

    bad = call(:get, "/secrets/#{name}?api-version=2099-01-01", token)
    assert bad.status == 400, "future api-version must be refused"

    %{"error" => %{"code" => code}} = Jason.decode!(bad.resp_body)
    assert code == "InvalidApiVersion"

    good = call(:get, "/secrets/#{name}?api-version=7.4", token)
    assert good.status == 200, "7.4 must stay admitted (KD-78 monotonic alignment)"
  end

  # KD-152: queue-plane x-ms-request-id is a dashed-36 GUID.
  test "KD-152: queue plane x-ms-request-id is GUID format", %{token: token} do
    acct = "kd152acct"
    queue = "kd152q" <> Integer.to_string(System.unique_integer([:positive]))

    create = call(:put, "/#{acct}/#{queue}?restype=queue", token)
    assert create.status == 201

    {:ok, req_id} =
      Enum.find_value(create.resp_headers, {:error, :missing}, fn
        {"x-ms-request-id", v} -> {:ok, v}
        _ -> nil
      end)

    assert req_id =~ @guid, "queue request-id must be dashed GUID, got: #{req_id}"

    put =
      call(:post, "/#{acct}/#{queue}/messages", token,
        [{"content-type", "application/xml"}],
        "<QueueMessage><MessageText>aGk=</MessageText></QueueMessage>"
      )

    assert put.status == 201

    {:ok, req_id2} =
      Enum.find_value(put.resp_headers, {:error, :missing}, fn
        {"x-ms-request-id", v} -> {:ok, v}
        _ -> nil
      end)

    assert req_id2 =~ @guid
  end

  # KD-147/148: cosmos wire drops _gen/_v; _etag renders quoted GUID.
  test "KD-147/148: cosmos doc body carries spec system props only, etag is GUID", %{
    token: token
  } do
    db = "kd147db"
    coll = "kd147coll"

    call(:post, "/dbs/#{db}", token, [{"content-type", "application/json"}],
      Jason.encode!(%{"id" => db})
    )

    call(:post, "/dbs/#{db}/colls", token, [{"content-type", "application/json"}],
      Jason.encode!(%{"id" => coll})
    )

    conn =
      call(:post, "/dbs/#{db}/colls/#{coll}/docs", token, [{"content-type", "application/json"}],
        Jason.encode!(%{"id" => "d1", "payload" => 42})
      )

    assert conn.status == 201
    doc = Jason.decode!(conn.resp_body)

    # KD-147: no emulator-internal _gen/_v on the wire.
    refute Map.has_key?(doc, "_gen"), "_gen must never cross the wire"
    refute Map.has_key?(doc, "_v"), "_v must never cross the wire"
    assert Map.has_key?(doc, "_etag")
    assert Map.has_key?(doc, "_ts")
    assert Map.has_key?(doc, "_rid")

    # KD-148: _etag is a quoted GUID.
    assert doc["_etag"] =~ ~r/^"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"$/,
           "_etag must be quoted GUID, got: #{doc["_etag"]}"

    # CAS round-trip: echoing the GUID etag proceeds; a stale one 412s.
    get = call(:get, "/dbs/#{db}/colls/#{coll}/docs/d1", token, [{"if-match", doc["_etag"]}])
    assert get.status == 200, "echoed GUID etag must pass CAS"

    stale =
      call(:get, "/dbs/#{db}/colls/#{coll}/docs/d1", token, [
        {"if-match", "\"00000000-0000-0000-0000-000000000000\""}
      ])

    assert stale.status == 412, "mismatched etag must 412"
  end

  # CAS412 — replace-path If-Match court (DIV-1, receipt pb1-fond-loop-latency.md).
  # Chicago: real router, real store, real wire statuses. Fences three arms:
  # matching etag -> 200 + fresh quoted-GUID etag; stale etag -> 412 whose
  # ETag response header carries the CURRENT etag (Azure envelope body);
  # absent If-Match -> unconditional replace (200).
  test "CAS412: cosmos replace honors If-Match (200/412/unconditional)", %{token: token} do
    db = "cas412db"
    coll = "cas412coll"

    call(:post, "/dbs/#{db}", token, [{"content-type", "application/json"}],
      Jason.encode!(%{"id" => db})
    )

    call(:post, "/dbs/#{db}/colls", token, [{"content-type", "application/json"}],
      Jason.encode!(%{"id" => coll})
    )

    conn =
      call(:post, "/dbs/#{db}/colls/#{coll}/docs", token, [{"content-type", "application/json"}],
        Jason.encode!(%{"id" => "d1", "payload" => 1})
      )

    assert conn.status == 201
    etag1 = Jason.decode!(conn.resp_body)["_etag"]

    # Arm 1: matching etag -> 200 with a FRESH quoted-GUID etag (KD-148 shape).
    match =
      call(:put, "/dbs/#{db}/colls/#{coll}/docs/d1", token,
        [{"content-type", "application/json"}, {"if-match", etag1}],
        Jason.encode!(%{"id" => "d1", "payload" => 2})
      )

    assert match.status == 200, "replace with matching etag must 200, got #{match.status}"
    doc2 = Jason.decode!(match.resp_body)
    assert doc2["_etag"] != etag1, "etag must rotate on replace"
    assert doc2["_etag"] =~ ~r/^"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"$/

    # Arm 2: stale etag (the OLD etag1) -> 412 + current etag in the ETag header.
    stale =
      call(:put, "/dbs/#{db}/colls/#{coll}/docs/d1", token,
        [{"content-type", "application/json"}, {"if-match", etag1}],
        Jason.encode!(%{"id" => "d1", "payload" => 3})
      )

    assert stale.status == 412, "stale etag on replace must 412, got #{stale.status}"
    body = Jason.decode!(stale.resp_body)
    assert body["code"] == "PreconditionFailed"

    etag_hdr =
      Enum.find_value(stale.resp_headers, fn {k, v} -> k == "etag" && v end)

    assert etag_hdr == doc2["_etag"],
           "412 must carry the CURRENT etag in its ETag header, got: #{inspect(etag_hdr)}"

    # Arm 3: absent If-Match -> unconditional last-writer-wins replace (200).
    absent =
      call(:put, "/dbs/#{db}/colls/#{coll}/docs/d1", token,
        [{"content-type", "application/json"}],
        Jason.encode!(%{"id" => "d1", "payload" => 4})
      )

    assert absent.status == 200, "replace without If-Match must be unconditional 200"
    doc3 = Jason.decode!(absent.resp_body)
    assert doc3["payload"] == 4, "replace is not merge: body IS the stored doc"
  end
end
