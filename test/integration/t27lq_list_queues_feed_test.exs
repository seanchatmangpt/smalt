# T27LQ — KD-155SDK out-of-scope note chase: listQueues paging failure.
#
# Repro (wire, live substrate, tmp/t27lq-listqueues.cjs): the node
# ServiceBusAdministrationClient 7.10.0 listQueues().byPage(...) fails with
# RestError 404 MessageEntityNotFoundError because the server answers
# GET $Resources/Queues with the flat-entry 404 ResourceNotFound ATOM error —
# the bridge has no list route and no ATOM feed renderer.
#
# Real-Azure / SDK 7.10.0 wire contract:
#   GET /$Resources/Queues?api-version=2024-05&$top=N&$skip=M
#   -> 200 application/atom+xml FEED:
#      <feed xmlns="http://www.w3.org/2005/Atom">
#        ...<entry>...</entry>
#        <link rel="next" href="...$skip=K"/>   (only when a next page exists)
#      </feed>
# SDK parseFeedResult requires feed.entry (single or array); continuation is
# read from feed.link[rel="next"][href], whose $skip the SDK extracts as the
# next marker (XML_METADATA_MARKER="$" + "skip" in getMarkerFromNextLinkUrl).
#
# Chicago discipline: real Store + real dispatch tuple; asserts on the
# rendered XML bytes (final state), never interactions.
#
# Context: solo

defmodule Integration.T27lqListQueuesFeedTest do
  use ExUnit.Case, async: false
  alias Smalt.Amqp.AtomBridge
  alias Smalt.Store

  setup do
    case GenServer.start_link(Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  defp create(queue) do
    body = """
    <?xml version="1.0" encoding="utf-8"?>
    <entry xmlns="http://www.w3.org/2005/Atom"><content type="application/xml">
    <QueueDescription xmlns="http://schemas.microsoft.com/netservices/2010/10/servicebus/connect">
    <LockDuration>PT30S</LockDuration><MaxDeliveryCount>7</MaxDeliveryCount>
    </QueueDescription></content></entry>
    """

    {status, _, _} = AtomBridge.handle_request("PUT", "/" <> queue <> "?api-version=2024-05", body)
    status
  end

  defp feed_entries(xml) do
    Regex.scan(~r{<QueueName>([^<]+)</QueueName>}, xml) |> Enum.map(&List.last/1)
  end

  test "list queues returns an ATOM feed in the real-Azure shape" do
    assert create("t27lq1-a") in [200, 201]
    assert create("t27lq1-b") in [200, 201]

    {status, ctype, xml} =
      AtomBridge.handle_request("GET", "/$Resources/Queues?api-version=2024-05&%24top=10&%24skip=0", "")

    assert status == 200
    assert ctype =~ "application/atom+xml"

    # real-Azure feed shape: feed root in the atom namespace, per-queue entries
    assert xml =~ ~r{<feed xmlns="http://www\.w3\.org/2005/Atom">}
    assert xml =~ ~r{<entry[ >]}

    for q <- ["t27lq1-a", "t27lq1-b"] do
      assert xml =~ ~r{<QueueName>#{q}</QueueName>}
    end

    # single page (top >= count): NO next link, so the SDK stops paging
    refute xml =~ ~r{rel="next"}
    # the SDK percent-encodes the query (%24top) — decoded server-side
  end

  test "list queues feed pages with $top/$skip and a link rel=next carrying $skip" do
    for q <- ["t27lq2-a", "t27lq2-b", "t27lq2-c"] do
      assert create(q) in [200, 201]
    end

    page1 = AtomBridge.handle_request("GET", "/$Resources/Queues?api-version=2024-05&$top=2&$skip=0", "")
    assert {200, _, xml1} = page1
    assert xml1 =~ ~r{<feed xmlns="http://www\.w3\.org/2005/Atom">}

    names1 = feed_entries(xml1)
    assert length(names1) == 2
    # continuation: real-Azure link pair. Two <link> elements are REQUIRED:
    # a single link parses as a bare xml2js object, and the SDK's
    # parseLinkInfo only walks arrays. The next href must be ABSOLUTE —
    # the SDK parses it as a URL to extract $skip (getMarkerFromNextLinkUrl).
    assert xml1 =~ ~r{<link rel="self" href="[^"]*\$skip=0}
    assert xml1 =~ ~r{<link rel="next" href="[^"]*\$skip=2}

    assert xml1 =~ ~r{<link rel="next" href="[^"]*\$skip=2}

    # page to exhaustion: pages are disjoint, sort-ordered, and cover every
    # created queue exactly once even with a shared Store
    {200, _, xml2} =
      AtomBridge.handle_request("GET", "/$Resources/Queues?api-version=2024-05&$top=2&$skip=2", "")

    pages = [feed_entries(xml1), feed_entries(xml2)]

    pages =
      case Regex.run(~r{rel="next"}, xml2) do
        nil ->
          pages

        _ ->
          {200, _, xml3} =
            AtomBridge.handle_request("GET", "/$Resources/Queues?api-version=2024-05&$top=2&$skip=4", "")

          pages ++ [feed_entries(xml3)]
      end

    all = List.flatten(pages)

    # no queue appears twice, and every created queue is collected
    assert length(all) == length(Enum.uniq(all))
    for q <- ["t27lq2-a", "t27lq2-b", "t27lq2-c"] do
      assert q in all
    end
  end

  test "empty namespace returns a well-formed empty feed, never 404" do
    # Real-Azure answer for zero queues is a feed with no entries; the bridge
    # must answer 200 with a structural feed regardless of Store contents.
    {status, _, xml} =
      AtomBridge.handle_request("GET", "/$Resources/Queues?api-version=2024-05&$top=10&$skip=0", "")

    assert status == 200
    assert xml =~ ~r{<feed xmlns="http://www\.w3\.org/2005/Atom">}
    assert xml =~ ~s{</feed>}
  end

  # T27LQ-r: the wire defect was ROUTER-level — the node SDK's listQueues rides
  # the HTTPS management face (9443/9444), where only single-segment flat
  # aliases existed and GET /$Resources/Queues fell to the catch-all 404
  # RouteNotFound. Assert the real HTTP face route end to end (real Plug
  # dispatch, real Store), including $top/$skip query preservation.
  defp router_conn(method, path) do
    method
    |> Plug.Test.conn(path)
    |> Smalt.ArmGateway.Router.call(Smalt.ArmGateway.Router.init([]))
  end

  test "GET /$Resources/Queues routes on the HTTPS management face with paging query intact" do
    assert create("t27lq3-a") in [200, 201]
    assert create("t27lq3-b") in [200, 201]

    conn = router_conn("GET", "/$Resources/Queues?api-version=2024-05&%24top=1&%24skip=0")

    assert conn.status == 200
    assert conn.resp_headers |> Enum.any?(fn {k, v} ->
             k == "content-type" and v =~ "application/atom+xml"
           end)

    xml = conn.resp_body
    assert xml =~ ~r{<feed xmlns="http://www\.w3\.org/2005/Atom">}
    assert length(feed_entries(xml)) == 1
    # $top=1 with 2+ queues: continuation link with $skip=1 must survive the
    # router hop (query-string reconstruction)
    assert xml =~ ~r{rel="next"}
  end

  test "router face still answers a flat single-segment queue GET (no alias regression)" do
    assert create("t27lq3-flat") in [200, 201]

    conn = router_conn("GET", "/t27lq3-flat?api-version=2024-05")

    assert conn.status == 200
    assert conn.resp_body =~ ~r{<QueueName>t27lq3-flat</QueueName>}
  end

  test "feed entry ids are single-segment (SDK setName derives the name from the id pathname)" do
    assert create("t27lq4-id") in [200, 201]

    {200, _, xml} =
      AtomBridge.handle_request("GET", "/$Resources/Queues?api-version=2024-05&$top=10&$skip=0", "")

    # T27LQ-r: id `sb://emulator/queues/<name>` made the node SDK's
    # setName report the queue as "queues/<name>" (pathname-derived).
    assert xml =~ ~r{<id>sb://emulator/t27lq4-id</id>}
    refute xml =~ ~r{<id>sb://emulator/queues/}
  end


end
