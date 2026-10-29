defmodule Smalt.Integration.QueueMessageCtTest do
  # KD-COVERS: KD-123 — Chicago plug-conn court for the queue-messages raw-body
  # exemption. Real router, real Plug.Parsers, real QueueStorage ETS — no
  # mocks; the assertion is on the dequeued bytes themselves.
  #
  # Divergence (pre-fix): POST /{account}/{queue}/messages with content-type
  # application/x-www-form-urlencoded had its XML body consumed by
  # Plug.Parsers before the queue handler read it, so put_message stored an
  # EMPTY MessageText under a lying 201 (same parser-consumed-body class as
  # KD-108/KD-122). The fix adds a raw_blob_put?/1 clause exempting the
  # put_messages path shape from body parsing.
  use ExUnit.Case, async: false

  @account "acct-kd123"

  defp unique_queue, do: "q-kd123-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

  defp call(method, path, opts \\ []) do
    body = opts[:body]
    ct = opts[:content_type]

    conn =
      Plug.Test.conn(method, path, body)
      |> then(fn c -> if ct, do: Plug.Conn.put_req_header(c, "content-type", ct), else: c end)

    Smalt.EgressRouter.call(conn, [])
  end

  defp create_queue(queue) do
    conn = call(:put, "/#{@account}/#{queue}?restype=queue")
    assert conn.status == 201
  end

  defp post_message(queue, ct, text) do
    xml = "<QueueMessage><MessageText>#{text}</MessageText></QueueMessage>"
    call(:post, "/#{@account}/#{queue}/messages", body: xml, content_type: ct)
  end

  defp dequeue(queue) do
    conn = call(:get, "/#{@account}/#{queue}/messages")
    assert conn.status == 200
    conn.resp_body
  end

  test "urlencoded content-type POST stores the REAL MessageText bytes (KD-123 fix)" do
    queue = unique_queue()
    create_queue(queue)

    conn = post_message(queue, "application/x-www-form-urlencoded", "kd123-payload-#{queue}")
    assert conn.status == 201

    assert dequeue(queue) =~ "kd123-payload-#{queue}"
  end

  test "application/xml content-type POST round-trips unchanged (no behavior change)" do
    queue = unique_queue()
    create_queue(queue)

    conn = post_message(queue, "application/xml", "kd123-xml-#{queue}")
    assert conn.status == 201

    assert dequeue(queue) =~ "kd123-xml-#{queue}"
  end

  test "text/plain body with no MessageText element is taken as raw text" do
    queue = unique_queue()
    create_queue(queue)

    conn = post_message(queue, "text/plain", "kd123-raw-#{queue}")
    assert conn.status == 201

    assert dequeue(queue) =~ "kd123-raw-#{queue}"
  end
end
