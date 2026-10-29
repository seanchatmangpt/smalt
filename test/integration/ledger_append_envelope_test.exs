# W2 (CLOSURE lane) — ledger/append@key-extra closure court.
#
# Divergence: the egress :8443 `POST /app/transactions` 201 body previously
# echoed the full substrate receipt (data_hash/prev_hash/merkle_root/
# signature) beyond the real Azure Confidential Ledger documented envelope
# {transactionId, contents, subLedgerId, timestamp}.
#
# Closure: the 201 body is exactly the four documented members; the chain
# members stay OFF the append wire face but remain on the GET list/get faces
# (the audit path the athena s17 append-only court reads) and in the sealed
# receipt.
#
# Chicago discipline: real ConfidentialLedger ETS store, real EgressRouter
# plug chain, assertions on actual wire state — no mocks.
#
# Run: MIX_BUILD_ROOT=_build-w2 mix test test/integration/ledger_append_envelope_test.exs

defmodule Smalt.Test.Integration.LedgerAppendEnvelopeTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.EgressRouter

  @run "w2-envelope-" <> Integer.to_string(System.unique_integer([:positive]))

  # The egress ledger face admits the body object itself as the ledger
  # contents (the athena clients POST the raw object, not a {"contents": ...}
  # wrapper).
  defp post_append(contents) do
    conn =
      conn(:post, "/app/transactions", Jason.encode!(contents))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> EgressRouter.call([])

    {conn.status, Jason.decode!(conn.resp_body), conn}
  end

  defp list_receipts do
    conn = conn(:get, "/app/transactions") |> EgressRouter.call([])
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp resp_header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  test "201 body is exactly the documented four-member envelope" do
    contents = %{"run" => @run, "lane" => "W2"}

    {status, body, _conn} = post_append(contents)

    assert status == 201
    # Exactly the documented members — no substrate extension members.
    assert MapSet.new(Map.keys(body)) ==
             MapSet.new(["transactionId", "contents", "subLedgerId", "timestamp"])

    assert body["contents"] == contents
    assert body["subLedgerId"] == "default_ledger"
    assert Regex.match?(~r/^\d+\.\d+$/, body["transactionId"])
    assert Regex.match?(~r/^\d{4}-\d{2}-\d{2}T/, body["timestamp"])

    for member <- ["data_hash", "prev_hash", "merkle_root", "signature"] do
      refute Map.has_key?(body, member), "#{member} leaked onto the append wire body"
    end
  end

  test "chain integrity stays verifiable via the GET audit path (s17's data source)" do
    contents = %{"run" => @run, "lane" => "W2-audit", "nonce" => 1}

    {201, body, _conn} = post_append(contents)
    tx_id = body["transactionId"]

    # a second append gives the pairwise link audit two W2 receipts
    {201, _b2, _conn} = post_append(%{"run" => @run, "lane" => "W2-audit", "nonce" => 2})

    # GET by id returns the full receipt: the chain members survive on the
    # audit face, linked to the previous entry's merkle root.
    conn = conn(:get, "/app/transactions/#{tx_id}") |> EgressRouter.call([])
    assert conn.status == 200
    receipt = Jason.decode!(conn.resp_body)

    for member <- ["transactionId", "subLedgerId", "data_hash", "prev_hash", "merkle_root", "contents", "timestamp", "signature"] do
      assert Map.has_key?(receipt, member), "audit face lost #{member}"
    end

    assert receipt["contents"] == contents

    # Chain math over the list face (s17 reads the list), pairwise exactly like
    # the athena auditReceipt: data_hash is the sha256 of the canonical
    # (key-sorted) JSON encoding of contents; merkle_root = sha256(prev_hash <>
    # data_hash); the second append's prev_hash equals the first's merkle_root.
    receipts = list_receipts()
    assert is_list(receipts) and receipts != []

    mine =
      receipts
      |> Enum.filter(&(&1["contents"]["run"] == @run))
      |> Enum.take(-2)

    assert length(mine) == 2, "both W2 appends present in the list"

    [r1, r2] = mine

    assert Base.encode16(
             :crypto.hash(:sha256, canonical_ish(r1["contents"])),
             case: :lower
           ) == r1["data_hash"]

    assert Base.encode16(
             :crypto.hash(:sha256, r1["prev_hash"] <> r1["data_hash"]),
             case: :lower
           ) == r1["merkle_root"]

    assert r2["prev_hash"] == r1["merkle_root"], "second append links to the first's merkle root"

    assert Base.encode16(
             :crypto.hash(:sha256, r2["prev_hash"] <> r2["data_hash"]),
             case: :lower
           ) == r2["merkle_root"]

    # list order is monotonic tx order (s17's own invariant) — not
    # "mine is last", which would race concurrent/shuffled tests
    seqs = Enum.map(receipts, &tx_seq(&1["transactionId"]))

    assert seqs == Enum.sort(seqs), "list is not in monotonic tx order"
  end

  defp tx_seq(tx_id) do
    [seq, _] = String.split(tx_id, ".", parts: 2)
    String.to_integer(seq)
  end

  # Mirrors Smalt.Security.LedgerWriter.canonical/1 + Jason encoding: values
  # are encoded by Jason directly (no double-encode); keys stringified.
  defp canonical_ish(term) when is_map(term) do
    term
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
    |> Jason.encode!()
  end

  defp canonical_ish(term), do: Jason.encode!(term)
end
