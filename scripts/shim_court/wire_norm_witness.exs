# S-4 wire-normalization mutation-court witness (KD-01 / KD-03 / KD-07).
#
# Usage: mix run scripts/shim_court/wire_norm_witness.exs <mode>
#
# Modes:
#   kd01_before - OLD blob comp=metadata wire shape: 201 + non-empty JSON debug body
#   kd01_after  - Azure shape: 200, EMPTY body, etag header
#   kd03_before - Get Container Properties last-modified is raw ISO-8601
#   kd03_after  - last-modified is RFC-1123 ("... GMT", no "T")
#   kd07_before - cosmos list docs answers a bare JSON array
#   kd07_after  - SDK ReadFeed envelope {"_rid", "Documents", "_count"}
#
# Real dispatch through the real EgressRouter over the real Store ETS - no mocks.

opts = Smalt.EgressRouter.init([])

# Court runs outside ExUnit: pin anonymous auth mode explicitly (config/test.exs
# is not loaded under `mix run --no-start`).
Application.put_env(:smalt, :auth_mode, :anonymous)

# Run with `mix run --no-start`: the full app tree is not needed and the AMQP
# listener would collide with other lanes; boot ONLY the Store.


if Process.whereis(Smalt.Store) == nil do
  {:ok, _} = Smalt.Store.start_link([])
  Smalt.Store.init([])
end

Smalt.Store.clear()

dispatch = fn method, path, extra_headers, body ->
  conn =
    Plug.Test.conn(method, path, body)
    |> Plug.Conn.put_req_header("x-ms-version", "2021-12-02")
    |> then(fn conn ->
      Enum.reduce(extra_headers, conn, fn {k, v}, c ->
        Plug.Conn.put_req_header(c, k, v)
      end)
    end)

  conn = Smalt.EgressRouter.call(conn, opts)

  %{
    status: conn.status,
    body: conn.resp_body,
    header: fn name ->
      case Plug.Conn.get_resp_header(conn, name) do
        [] -> nil
        [v] -> v
        vs -> vs
      end
    end
  }
end

# Shared fixture: MUTABLE container (x-ms-immutable-policy opt-out — the old
# comp=metadata path fell into put_blob, which 409s on a WORM container),
# blob, and cosmos doc.
{:ok, _} = Smalt.DataPlane.BlobStorage.create_container("courtacct", "courtcont", %{"immutable" => false})

{:ok, _} =
  Smalt.DataPlane.BlobStorage.put_blob("courtacct", "courtcont", "c.bin", "0123456789", %{
    "content-type" => "application/octet-stream",
    "x-ms-meta-old" => "legacy"
  })

{:ok, _status, _headers, _db} = Smalt.DataPlane.Cosmos.create_db("court_db")
{:ok, _status, _headers, _coll} = Smalt.DataPlane.Cosmos.create_collection("court_db", "court_coll", %{"id" => "pk"})

{:ok, 201, _, _} =
  Smalt.DataPlane.Cosmos.create_doc("court_db", "court_coll", %{"id" => "d1", "v" => 1}, %{})

mode = List.first(System.argv())

case mode do
  "kd01_before" ->
    r = dispatch.(:put, "/courtacct/courtcont/c.bin?comp=metadata", [
      {"x-ms-meta-court", "before-after"}
    ], "")

    if r.status == 201 and r.body != "" do
      IO.puts("OLD-WIRE-SHAPE 201 body=#{byte_size(r.body)}B non-empty JSON debug body")
    else
      throw({:witness_failed, mode, r.status, r.body})
    end

  "kd01_after" ->
    r = dispatch.(:put, "/courtacct/courtcont/c.bin?comp=metadata", [
      {"x-ms-meta-court", "before-after"}
    ], "")

    if r.status == 200 and r.body == "" do
      IO.puts("AZURE-SHAPE 200 EMPTY body etag=#{r.header.("etag")}")
    else
      throw({:witness_failed, mode, r.status, r.body})
    end

  "kd03_before" ->
    r = dispatch.(:get, "/courtacct/courtcont?restype=container", [], nil)
    lm = r.header.("last-modified")

  "kd03_before" ->
    r = dispatch.(:get, "/courtacct/courtcont?restype=container", [], nil)
    lm = r.header.("last-modified")
    iso = lm =~ ~r/T\d{2}:\d{2}/

    if r.status == 200 and iso do
      IO.puts("OLD-WIRE-SHAPE last-modified=#{lm} (ISO-8601)")
    else
      throw({:witness_failed, mode, r.status, lm})
    end

  "kd03_after" ->
    r = dispatch.(:get, "/courtacct/courtcont?restype=container", [], nil)
    lm = r.header.("last-modified")
    rfc1123 = lm =~ ~r/^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), \d{2} [A-Za-z]{3} \d{4} \d{2}:\d{2}:\d{2} GMT$/

    if r.status == 200 and rfc1123 do
      IO.puts("AZURE-SHAPE last-modified=#{lm} (RFC-1123)")
    else
      throw({:witness_failed, mode, r.status, lm})
    end

  "kd07_before" ->
    r = dispatch.(:get, "/dbs/court_db/colls/court_coll/docs", [], nil)
    parsed = Jason.decode!(r.body)

    if r.status == 200 and is_list(parsed) and length(parsed) == 1 do
      IO.puts("OLD-WIRE-SHAPE bare JSON array of #{length(parsed)} doc(s)")
    else
      throw({:witness_failed, mode, r.status, r.body})
    end

  "kd07_after" ->
    r = dispatch.(:get, "/dbs/court_db/colls/court_coll/docs", [], nil)
    parsed = Jason.decode!(r.body)

    if r.status == 200 and is_map(parsed) do
      docs = parsed["Documents"]
      count = parsed["_count"]
      rid = parsed["_rid"]

      if is_list(docs) and count == length(docs) and is_binary(rid) do
        IO.puts("AZURE-SHAPE ReadFeed envelope _count=#{count} _rid=#{rid}")
      else
        throw({:witness_failed, mode, r.body})
      end
    else
      response = Jason.decode!(r.body)
      throw({:witness_failed, mode, r.status, r.body})
    end

  other ->
    throw({:unknown_mode, other})
end

IO.puts("WITNESS-PASS #{mode}")
