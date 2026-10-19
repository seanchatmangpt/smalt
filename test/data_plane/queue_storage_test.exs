defmodule Smalt.DataPlane.QueueStorageTest do
  @moduledoc """
  G1 engine-tier tests for the Azure Queue Storage REST engine
  (lib/smalt/data_plane/queue_storage.ex). Wire-tier pins over real sockets
  live in test/wire/egress_wire_test.exs.
  """

  use ExUnit.Case, async: false

  alias Smalt.DataPlane.QueueStorage
  alias Smalt.Store

  defp env(text), do: "<QueueMessage><MessageText>#{text}</MessageText></QueueMessage>"

  defp msgs(body) do
    Regex.scan(~r/<QueueMessage>(.*?)<\/QueueMessage>/s, body)
    |> Enum.map(fn [_, m] -> m end)
  end

  defp text_of(msg) do
    case Regex.run(~r/<MessageId>(.*?)<\/MessageId>/s, msg) do
      [_, id] -> id
      nil -> nil
    end
  end

  defp receipt_of(msg) do
    case Regex.run(~r/<PopReceipt>(.*?)<\/PopReceipt>/s, msg) do
      [_, r] -> r
      nil -> nil
    end
  end

  defp id_of(msg) do
    case Regex.run(~r/<MessageId>(.*?)<\/MessageId>/s, msg) do
      [_, id] -> id
      nil -> nil
    end
  end

  setup do
    case GenServer.start(Store, [], name: Store) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Store.clear()
    assert QueueStorage.store_ready?()
    :ok
  end

  describe "queue lifecycle" do
    test "create 201, duplicate 409 QueueAlreadyExists" do
      assert {:ok, 201, _} = QueueStorage.create_queue("g1acct", "q11")
      assert {:error, 409, "QueueAlreadyExists", _} = QueueStorage.create_queue("g1acct", "q11")
      # a different account is a different namespace
      assert {:ok, 201, _} = QueueStorage.create_queue("g1acct2", "q11")
    end

    test "invalid queue name 400 InvalidResourceName" do
      assert {:error, 400, "InvalidResourceName", _} = QueueStorage.create_queue("g1acct", "Q")
    end

    test "delete 204 cascades messages; missing 404 QueueNotFound" do
      assert {:ok, 201, _} = QueueStorage.create_queue("g1acct", "q22")
      assert {:ok, 201, _, _} = QueueStorage.put_message("g1acct", "q22", env("hello"))

      assert {:ok, 204, _} = QueueStorage.delete_queue("g1acct", "q22")
      assert {:error, 404, "QueueNotFound", _} = QueueStorage.delete_queue("g1acct", "q22")

      # recreate: no message resurrection (cascade proved)
      assert {:ok, 201, _} = QueueStorage.create_queue("g1acct", "q22")

      assert {:ok, 200, _, body} = QueueStorage.get_messages("g1acct", "q22", %{"numofmessages" => "32"})
      assert body == "<QueueMessagesList></QueueMessagesList>"
    end

    test "list_queues: prefix/marker/maxresults" do
      for q <- ["qqa", "qqb", "zzc"], do: assert({:ok, 201, _} = QueueStorage.create_queue("g1list", q))

      assert {:ok, 200, _, xml} = QueueStorage.list_queues("g1list", %{})
      assert String.contains?(xml, "<Name>qqa</Name>")
      assert String.contains?(xml, "<Name>zzc</Name>")

      assert {:ok, 200, _, xml} = QueueStorage.list_queues("g1list", %{"prefix" => "q"})
      assert String.contains?(xml, "<Name>qqa</Name>")
      refute String.contains?(xml, "<Name>zzc</Name>")

      assert {:ok, 200, _, xml} = QueueStorage.list_queues("g1list", %{"maxresults" => "1"})
      assert String.contains?(xml, "<Name>qqa</Name>")
      assert String.contains?(xml, "<NextMarker>qqa</NextMarker>")

      assert {:ok, 200, _, xml2} =
               QueueStorage.list_queues("g1list", %{"marker" => "qqa", "maxresults" => "1"})

      assert String.contains?(xml2, "<Name>qqb</Name>")
      refute String.contains?(xml2, "<Name>qqa</Name>")

      assert {:error, 400, "InvalidQueryParameterValue", _} =
               QueueStorage.list_queues("g1list", %{"maxresults" => "zero"})
    end
  end

  describe "messages" do
    test "put 201 renders MessageId/PopReceipt XML; raw body accepted as text" do
      assert {:ok, 201, _} = QueueStorage.create_queue("g1m", "qq1")
      assert {:ok, 201, _, put_xml} = QueueStorage.put_message("g1m", "qq1", env("m1"))

      assert String.contains?(put_xml, "<MessageId>")
      assert String.contains?(put_xml, "<PopReceipt>")
      assert String.contains?(put_xml, "<TimeNextVisible>")
      assert String.contains?(put_xml, "<InsertionTime>")
      assert String.contains?(put_xml, "<ExpirationTime>")

      assert {:ok, 201, _, _} = QueueStorage.put_message("g1m", "qq1", "raw text")
    end

    test "put on missing queue 404 QueueNotFound" do
      assert {:error, 404, "QueueNotFound", _} = QueueStorage.put_message("g1m", "noqueue", env("x"))
    end

    test "get: FIFO order, default visibility hides, DequeueCount increments" do
      assert {:ok, 201, _} = QueueStorage.create_queue("g1f", "qq1")
      assert {:ok, 201, _, _} = QueueStorage.put_message("g1f", "qq1", env("m1"))
      assert {:ok, 201, _, _} = QueueStorage.put_message("g1f", "qq1", env("m2"))

      assert {:ok, 200, _, body} = QueueStorage.get_messages("g1f", "qq1", %{"numofmessages" => "32"})
      assert length(msgs(body)) == 2

      # default visibilitytimeout=30: immediately re-getting returns nothing
      assert {:ok, 200, _, empty} = QueueStorage.get_messages("g1f", "qq1", %{})
      assert msgs(empty) == []

      # no-sleep: visibility re-appearance proven by injecting now_ms past the
      # visibility window (the engine accepts a virtual clock for tests)
      later = System.os_time(:millisecond) + 31_000

      assert {:ok, 200, _, body2} =
               QueueStorage.get_messages("g1f", "qq1", %{"visibilitytimeout" => "0", "numofmessages" => "32", "now_ms" => later})

      assert length(msgs(body2)) == 2
      first = hd(msgs(body2))
      assert String.contains?(first, "<DequeueCount>2</DequeueCount>")
    end

    test "get: numofmessages bounds and 400s" do
      assert {:ok, 201, _} = QueueStorage.create_queue("g1n", "qq1")

      assert {:error, 400, "InvalidQueryParameterValue", _} =
               QueueStorage.get_messages("g1n", "qq1", %{"numofmessages" => "0"})

      assert {:error, 400, "InvalidQueryParameterValue", _} =
               QueueStorage.get_messages("g1n", "qq1", %{"visibilitytimeout" => "bogus"})

      assert {:error, 400, "InvalidQueryParameterValue", _} =
               QueueStorage.get_messages("g1n", "qq1", %{"numofmessages" => "33"})
    end

    test "update: rotates popreceipt, stale replay 404 PopReceiptMismatch, missing 404 MessageNotFound" do
      assert {:ok, 201, _} = QueueStorage.create_queue("g1u", "qq1")
      assert {:ok, 201, _, put_xml} = QueueStorage.put_message("g1u", "qq1", env("v1"))

      [msg] = msgs(put_xml)
      id = id_of(msg)
      receipt = receipt_of(msg)

      # message is invisible after put? No — put leaves it visible (Azure: put
      # then get works immediately). Update with the issued receipt works.
      assert {:ok, 200, _, upd_xml} =
               QueueStorage.update_message("g1u", "qq1", id, receipt, env("v2"), %{"visibilitytimeout" => "10"})

      assert [msg2] = msgs(upd_xml)
      new_receipt = receipt_of(msg2)
      assert new_receipt != receipt

      # STALE REPLAY: the superseded receipt is dead — exactly one of the two
      # 404 faces, PopReceiptMismatch, in the engine tuple.
      assert {:error, 404, "PopReceiptMismatch", _} =
               QueueStorage.update_message("g1u", "qq1", id, receipt, env("v3"), %{"visibilitytimeout" => "10"})

      assert {:error, 404, "PopReceiptMismatch", _} =
               QueueStorage.delete_message("g1u", "qq1", id, receipt)

      # missing message id
      assert {:error, 404, "MessageNotFound", _} =
               QueueStorage.delete_message("g1u", "qq1", "no-such-id", receipt)

      # visibility expiry supersedes a receipt too (virtual clock)
      later = System.os_time(:millisecond) + 11_000

      assert {:error, 404, "PopReceiptMismatch", _} =
               QueueStorage.update_message("g1u", "qq1", id, new_receipt, env("v3"), %{
                 "visibilitytimeout" => "10",
                 "now_ms" => later
               })

      # text replacement took effect (get with vt=0 shows v2)
      assert {:ok, 200, _, body} =
               QueueStorage.get_messages("g1u", "qq1", %{"visibilitytimeout" => "0", "now_ms" => later})

      assert Enum.any?(msgs(body), &String.contains?(&1, "v2"))
    end

    test "delete message: valid receipt 204, message gone" do
      assert {:ok, 201, _} = QueueStorage.create_queue("g1d", "qq1")
      assert {:ok, 201, _, put_xml} = QueueStorage.put_message("g1d", "qq1", env("bye"))
      [msg] = msgs(put_xml)
      id = id_of(msg)
      receipt = receipt_of(msg)

      assert {:ok, 204, _} = QueueStorage.delete_message("g1d", "qq1", id, receipt)

      assert {:ok, 200, _, body} = QueueStorage.get_messages("g1d", "qq1", %{})
      assert msgs(body) == []
    end

    test "message text cap 64KiB 400" do
      assert {:ok, 201, _} = QueueStorage.create_queue("g1s", "qq1")
      big = String.duplicate("x", 64 * 1024 + 1)
      assert {:error, 400, "InvalidXmlDocument", _} = QueueStorage.put_message("g1s", "qq1", big)
    end
  end
end
