# Integration-tier witness (egress router dispatch, integration tier):
# the v26.10.28 parity lane's implemented tickets, asserted at the same
# wire faces the official SDKs use.
#
# Chicago discipline: real Store rows, real egress dispatch (Plug.Router.call
# in-process, auth :anonymous in the test env). No mocks.
#
# Covered (tickets in docs/jira/v26.10.28/tickets/):
#   T-17: snapshot -> delete plain 409 SnapshotsPresent -> include 202 -> gone
#   T-18: Set Blob HTTP Headers (comp=properties) -> HEAD serves the content type
#   8a6ce57 batch: blob lease acquire/release, Append Block, Put Page,
#        stage-block base64 gate, commit-blocklist
#   queue SDK wire shapes: bare PUT/GET/DELETE 2-segment routing, metadata
#        204 + persistence, message lifecycle, update 204, UA-disambiguated
#        comp=list (parity receipts: parity/reports/mvstqgag-fee2fd)
#
# Context: solo (integration tier, in-process dispatch).

defmodule Smalt.Internal.ParityLaneWireTest do
  use ExUnit.Case, async: false

  import Plug.Test

  @version "2021-12-02"
  @account "parityit"
  @container "parity-it-cont"
  @queue "parityitq"

  defp egress(method, url, body \\ nil, headers \\ []) do
    conn =
      if body do
        conn(method, url, body)
      else
        conn(method, url)
      end

    conn =
      conn
      |> Plug.Conn.put_req_header("x-ms-version", @version)
      |> then(fn c ->
        Enum.reduce(headers, c, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)
      end)

    Smalt.EgressRouter.call(Plug.Conn.fetch_query_params(conn), [])
  end

  setup do
    # Real container row for the blob faces (restype=container PUT, the
    # official blob-SDK create shape).
    egress(:put, "/#{@account}/#{@container}?restype=container")
    egress(:put, "/#{@account}/#{@queue}?timeout=30")

    on_exit(fn ->
      egress(:delete, "/#{@account}/#{@queue}?timeout=30")
      egress(:delete, "/#{@account}/#{@container}?restype=container")
    end)

    :ok
  end

  # -- T-17: snapshot-delete gate ------------------------------------------------

  test "snapshot present: plain delete 409 SnapshotsPresent, include 202, gone after" do
    assert egress(:put, "/#{@account}/#{@container}/snap.txt", "v1").status == 201
    assert egress(:put, "/#{@account}/#{@container}/snap.txt?comp=snapshot").status == 201

    plain = egress(:delete, "/#{@account}/#{@container}/snap.txt")
    assert plain.status == 409
    assert plain.resp_body =~ "SnapshotsPresent"

    included = egress(:delete, "/#{@account}/#{@container}/snap.txt", nil, [
      {"x-ms-delete-snapshots", "include"}
    ])

    assert included.status == 202
    assert egress(:get, "/#{@account}/#{@container}/snap.txt").status == 404
  end

  # -- T-18: content-type serving ------------------------------------------------

  test "Set Blob HTTP Headers -> HEAD serves the stored content type" do
    assert egress(:put, "/#{@account}/#{@container}/ct.txt", "ct-body").status == 201

    assert egress(:put, "/#{@account}/#{@container}/ct.txt?comp=properties", nil, [
             {"x-ms-blob-content-type", "text/plain"}
           ]).status == 200

    head = egress(:head, "/#{@account}/#{@container}/ct.txt")
    assert head.status == 200
    assert Plug.Conn.get_resp_header(head, "content-type") == ["text/plain; charset=utf-8"]

    # GET download serves it too.
    get = egress(:get, "/#{@account}/#{@container}/ct.txt")
    assert get.status == 200
    [ct | _] = Plug.Conn.get_resp_header(get, "content-type")
    assert String.starts_with?(ct, "text/plain")
  end

  # -- 8a6ce57 batch: blob comp surfaces -----------------------------------------

  test "blob lease acquire -> 201 with lease id -> release 200" do
    assert egress(:put, "/#{@account}/#{@container}/lease.txt", "lv1").status == 201

    acq =
      egress(:put, "/#{@account}/#{@container}/lease.txt?comp=lease", nil, [
        {"x-ms-lease-action", "acquire"},
        {"x-ms-lease-duration", "15"}
      ])

    assert acq.status == 201
    [lease_id] = Plug.Conn.get_resp_header(acq, "x-ms-lease-id")
    assert is_binary(lease_id) and lease_id != ""

    rel =
      egress(:put, "/#{@account}/#{@container}/lease.txt?comp=lease", nil, [
        {"x-ms-lease-action", "release"},
        {"x-ms-lease-id", lease_id}
      ])

    assert rel.status == 200
  end

  test "append blob: create -> appendBlock -> content grows" do
    assert egress(:put, "/#{@account}/#{@container}/app.bin", "a").status == 201

    app =
      egress(:put, "/#{@account}/#{@container}/app.bin?comp=appendblock", "b")

    assert app.status == 201
    assert [offset] = Plug.Conn.get_resp_header(app, "x-ms-append-offset")

    got = egress(:get, "/#{@account}/#{@container}/app.bin")
    assert got.resp_body == "ab"
  end

  test "page blob: create -> aligned Put Page 201 -> 512-byte content" do
    assert egress(:put, "/#{@account}/#{@container}/page.bin", "\0").status == 201

    page =
      egress(:put, "/#{@account}/#{@container}/page.bin?comp=page", String.duplicate("x", 512), [
        {"x-ms-range", "bytes=0-511"},
        {"x-ms-page-write", "update"}
      ])

    assert page.status == 201

    got = egress(:get, "/#{@account}/#{@container}/page.bin")
    assert byte_size(got.resp_body) == 512
  end

  test "stage block: base64 id ok, non-base64 refused 400" do
    assert egress(:put, "/#{@account}/#{@container}/staged.bin?comp=block&blockid=YjE=", "s1").status == 201

    bad = egress(:put, "/#{@account}/#{@container}/staged.bin?comp=block&blockid=not-base64!!", "x")
    assert bad.status == 400
    assert bad.resp_body =~ "InvalidQueryParameterValue"

    assert egress(:put, "/#{@account}/#{@container}/staged.bin?comp=blocklist", "<BlockList><Latest>YjE=</Latest></BlockList>").status == 201
  end

  # -- queue SDK wire shapes (parity receipts mvstqgag-fee2fd) --------------------

  test "queue: bare GET props 200, comp=metadata PUT 204 + read-back, messages, update 204, delete" do
    # v12 SDK getProperties shape: comp=metadata with NO restype.
    props = egress(:get, "/#{@account}/#{@queue}?comp=metadata&timeout=30")
    assert props.status == 200

    # v12 SDK setMetadata shape: comp=metadata PUT, no restype -> 204.
    set =
      egress(:put, "/#{@account}/#{@queue}?comp=metadata&timeout=30", nil, [
        {"x-ms-meta-parity", "it"}
      ])

    assert set.status == 204

    back = egress(:get, "/#{@account}/#{@queue}?comp=metadata&timeout=30")
    assert Plug.Conn.get_resp_header(back, "x-ms-meta-parity") == ["it"]

    # Message lifecycle through the queue plane.
    send_xml = "<QueueMessage><MessageText>it-body</MessageText></QueueMessage>"

    send = egress(:post, "/#{@account}/#{@queue}/messages?timeout=30", send_xml)
    assert send.status == 201

    recv = egress(:get, "/#{@account}/#{@queue}/messages?visibilitytimeout=60&timeout=30")
    assert recv.status == 200
    assert recv.resp_body =~ "it-body"
    assert recv.resp_body =~ "<PopReceipt>"

    # Extract the receipt for the update leg (204 on the wire).
    [receipt] = Regex.run(~r/<PopReceipt>([^<]+)<\/PopReceipt>/, recv.resp_body, capture: :all_but_first)
    [msg_id] = Regex.run(~r/<MessageId>([^<]+)<\/MessageId>/, recv.resp_body, capture: :all_but_first)

    upd =
      egress(
        :put,
        "/#{@account}/#{@queue}/messages/#{msg_id}?popreceipt=#{URI.encode_www_form(receipt)}&visibilitytimeout=30",
        "<QueueMessage><MessageText>updated</MessageText></QueueMessage>"
      )

    assert upd.status == 204

    assert egress(:delete, "/#{@account}/#{@queue}/messages?timeout=30").status == 204
    assert egress(:delete, "/#{@account}/#{@queue}?timeout=30").status == 204
    assert egress(:post, "/#{@account}/#{@queue}/messages?timeout=30", send_xml).status == 404
  end

  test "list disambiguation: comp=list with queue UA -> queue XML; blob UA -> container XML" do
    qconn =
      egress(:get, "/#{@account}?comp=list&timeout=30", nil, [
        {"user-agent", "azsdk-js-azure-storage-queue/12.32.0 core-rest-pipeline/1.25.0 Node/24"}
      ])

    assert qconn.status == 200
    assert qconn.resp_body =~ "<Queues>"
    assert qconn.resp_body =~ @queue

    bconn =
      egress(:get, "/#{@account}?comp=list&timeout=30", nil, [
        {"user-agent", "azsdk-js-azure-storage-blob/12.34.0 core-rest-pipeline/1.25.0 Node/24"}
      ])

    assert bconn.status == 200
    assert bconn.resp_body =~ "<Containers>"
    assert bconn.resp_body =~ @container
  end
end
