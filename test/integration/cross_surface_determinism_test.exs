# T34DET lane (v26.10.20): CTQ-3 determinism court on the host substrate.
# Claim under pin: an identical operation sequence applied to two fresh
# stores produces structurally identical state. Two full rounds are run per
# surface with unique-per-round names (fresh ETS rows, never reusing keys),
# the same op sequence is replayed, and the normalized state is deep-compared.
#
# Chicago discipline: real ETS stores (Smalt.Store), real plug face for blob
# (EgressRouter), real engine functions for cosmos + queue. No mocks, no
# sleeps. Etags are random per-write, so the court asserts structural
# equality: same keys, same bodies, same etag FORMAT — invariants, never
# etag values.
defmodule Smalt.Test.Integration.CrossSurfaceDeterminismTest do
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.BlobStorage
  alias Smalt.DataPlane.Cosmos
  alias Smalt.DataPlane.QueueStorage

  @moduletag :t34det

  @pk_hdr %{
    Smalt.DataPlane.PartitionKey.header_name() => ~s(["a"])
  }

  # ---------------------------------------------------------------------------
  # Round harness: apply the identical op sequence to a per-round namespace.
  # ---------------------------------------------------------------------------

  defp run_round(round) do
    ts = System.system_time(:millisecond)
    ns = "t34det-r#{round}-#{ts}"
    %{cosmos: run_cosmos_round(ns), blob: run_blob_round(ns), queue: run_queue_round(ns)}
  end

  # ---- Cosmos: create db/coll, put N docs, list feed -------------------------

  defp run_cosmos_round(ns) do
    db = "#{ns}-db"
    coll = "#{ns}-coll"

    assert {:ok, 201, _, _} =
             Cosmos.create_collection(db, coll, %{"partitionKey" => %{"paths" => ["/pk"]}})

    {docs, etags} =
      Enum.map_reduce(1..5, [], fn i, acc ->
        body = %{"id" => "doc-#{i}", "pk" => "a", "v" => i * 10, "tag" => ns}

        assert {:ok, 201, hdr, created} = Cosmos.create_doc(db, coll, body, @pk_hdr)
        # Real cosmos shape: the etag rides the response header, quoted.
        {created, [hdr["etag"] | acc]}
      end)

    assert {:ok, 200, _, feed} = Cosmos.list_docs(db, coll, "", %{})

    on_exit(fn ->
      Cosmos.drop_container(db, coll)
      Cosmos.drop_db(db)
    end)

    %{
      doc_ids: docs |> Enum.map(& &1["id"]) |> Enum.sort(),
      # Structural state: normalized docs sorted by id (order-stable compare).
      state:
        feed
        |> Enum.map(&normalize_cosmos_doc/1)
        |> Enum.sort_by(& &1["id"]),
      etag_format: format_of(Enum.reverse(etags))
    }
  end

  # Etag (and _ts) are random per-write — strip them, keep everything else.
  # The etag FORMAT (quoted hash / guid) must be identical across rounds.
  defp normalize_cosmos_doc(doc), do: Map.drop(doc, ["_etag", "_ts", "_rid", "_self", "_gen", "tag"])

  defp format_of(etags) do
    Enum.map(etags, fn
      e when is_binary(e) ->
        cond do
          e =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i -> :guid
          e =~ ~r/^\"[0-9A-Fa-f]{64}\"$/ -> :quoted_sha256
          e =~ ~r/^\".*\"$/s -> :quoted_other
          e =~ ~r/^[0-9A-Fa-f]{64}$/ -> :sha256
          true -> :other
        end

      nil ->
        :absent
    end)
    |> Enum.uniq()
  end

  # ---- Blob: container + PUT/GET byte-equal per round -----------------------

  defp run_blob_round(ns) do
    account = "t34det"
    container = "#{ns}-blob"
    payloads = %{
      "alpha.bin" => ns <> ":0123456789",
      "beta.bin" => :crypto.strong_rand_bytes(256),
      "gamma.bin" => String.duplicate(ns, 40)
    }

    assert {:ok, _} = BlobStorage.create_container(account, container)

    state =
      Map.new(payloads, fn {name, content} ->
        assert {:ok, _} =
                 BlobStorage.put_blob(account, container, name, content, %{
                   "x-ms-blob-type" => "BlockBlob"
                 })

        assert {:ok, got} = BlobStorage.get_blob(account, container, name)

        # Per-round invariant: what came back is byte-equal to what went in.
        assert got["content"] == content,
               "blob #{name} not byte-equal in round #{ns}"

        # Etag format invariant (never the value).
        assert format_of([got["etag"]]) in [[:guid], [:quoted_sha256], [:quoted_other], [:sha256], [:other]]

        {name, %{"content" => got["content"], "etag_format" => format_of([got["etag"]])}}
      end)

    on_exit(fn -> BlobStorage.drop_account_data(account) end)

    %{"container" => container, "blobs" => state}
  end

  # ---- Service Bus: FIFO per-queue ordering ---------------------------------

  defp run_queue_round(ns) do
    account = "t34det"
    queue = "#{ns}-q"
    bodies = for i <- 1..8, do: "msg-#{i}"

    assert {:ok, 201, _h} = QueueStorage.create_queue(account, queue)

    for b <- bodies do
      assert {:ok, 201, _, _} = QueueStorage.put_message(account, queue, b)
    end

    # Peek is read-only: the observed FIFO order IS the queue state.
    assert {:ok, 200, _, xml} =
             QueueStorage.peek_messages(account, queue, %{"numofmessages" => "32"})

    order =
      Regex.scan(~r/<MessageText>(.*?)<\/MessageText>/s, xml, capture: :all_but_first)
      |> List.flatten()

    # Per-round invariant: FIFO order matches send order exactly.
    assert order == bodies, "queue #{queue} FIFO order diverged from send order"

    on_exit(fn -> QueueStorage.drop_account_data(account) end)

    %{"queue" => queue, "order" => order, "count" => length(order)}
  end

  # ---------------------------------------------------------------------------
  # The court: two rounds, deep compare of normalized state.
  # ---------------------------------------------------------------------------

  test "CTQ-3: identical op sequences on fresh stores produce structurally identical state" do
    r1 = run_round(1)
    r2 = run_round(2)

    # Cosmos: same doc keys, same bodies (etag/ts stripped), same etag format.
    assert r1.cosmos.doc_ids == r2.cosmos.doc_ids
    assert r1.cosmos.state == r2.cosmos.state
    assert r1.cosmos.etag_format == r2.cosmos.etag_format
    assert r1.cosmos.etag_format != [:absent]

    # Blob: byte-equal content per round; cross-round structural identity.
    assert r1.blob["container"] != r2.blob["container"]
    assert MapSet.new(Map.keys(r1.blob["blobs"])) == MapSet.new(Map.keys(r2.blob["blobs"]))

    for name <- Map.keys(r1.blob["blobs"]) do
      b1 = r1.blob["blobs"][name]
      b2 = r2.blob["blobs"][name]
      assert byte_size(b1["content"]) == byte_size(b2["content"])
      assert b1["etag_format"] == b2["etag_format"]
    end

    # SB: identical per-queue FIFO ordering across rounds (bodies are
    # namespace-free, so the orders compare directly).
    assert r1.queue["order"] != []
    assert r1.queue["order"] == r2.queue["order"]
    assert r1.queue["count"] == 8
    assert r2.queue["count"] == 8
  end

  test "CTQ-3: a third independent round reproduces the pinned invariants" do
    # An independent replay (third round) with a fresh namespace/fresh stores,
    # guarding against round-1/round-2 accidental coupling via timestamps.
    r = run_round(3)
    assert length(r.cosmos.doc_ids) == 5
    assert r.cosmos.doc_ids == Enum.sort(r.cosmos.doc_ids)
    assert Enum.all?(r.cosmos.state, &is_map/1)
    assert r.queue["count"] == 8
    assert r.cosmos.etag_format in [[:guid], [:quoted_sha256], [:quoted_other], [:sha256], [:other]]
    assert Enum.all?(Map.values(r.blob["blobs"]), &(&1["etag_format"] in [[:guid], [:quoted_sha256], [:quoted_other], [:sha256], [:other]]))
  end
end
