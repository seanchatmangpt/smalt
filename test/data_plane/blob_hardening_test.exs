defmodule Smalt.DataPlane.BlobHardeningTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.DataPlane.BlobStorage
  alias Smalt.EgressRouter
  alias Smalt.Store

  setup do
    if Process.whereis(Smalt.Store) == nil, do: SmaltTest.Lifecycle.restore_app()
    Store.clear()
    BlobStorage.ensure_policy_table()
    :ets.delete_all_objects(:smalt_blob_policy)
    :ok
  end

  defp container(account \\ "acc1", name \\ "cont1", opts \\ %{}) do
    {:ok, _} =
      BlobStorage.create_container(account, name, Map.put_new(opts, "immutable", false))

    {account, name}
  end

  describe "put_blob If-Match" do
    test "overwrite with mismatched If-Match -> 412 precondition_failed" do
      container()
      {:ok, _blob} = BlobStorage.put_blob("acc1", "cont1", "b1", "v1")

      assert {:error, :precondition_failed, _} =
               BlobStorage.put_blob("acc1", "cont1", "b1", "v2", %{"if-match" => "\"dead\""})

      # Mismatch must not have modified the blob
      assert {:ok, unchanged} = BlobStorage.get_blob("acc1", "cont1", "b1")
      assert unchanged["content"] == "v1"
    end

    test "overwrite with matching If-Match succeeds" do
      container()
      {:ok, blob} = BlobStorage.put_blob("acc1", "cont1", "b1", "v1")

      assert {:ok, updated} =
               BlobStorage.put_blob("acc1", "cont1", "b1", "v2", %{"if-match" => blob["etag"]})

      assert updated["etag"] != blob["etag"]
      assert updated["content"] == "v2"
    end

    test "no If-Match on overwrite proceeds (legacy behaviour)" do
      container()
      BlobStorage.put_blob("acc1", "cont1", "b1", "v1")

      assert {:ok, _} = BlobStorage.put_blob("acc1", "cont1", "b1", "v2")
    end
  end

  describe "delete_blob/4" do
    test "success -> 202 with x-ms-request-id, blob removed" do
      container()
      BlobStorage.put_blob("acc1", "cont1", "b1", "data")

      assert {:ok, 202, headers, nil} = BlobStorage.delete_blob("acc1", "cont1", "b1")
      assert is_binary(headers["x-ms-request-id"])
      assert headers["x-ms-version"]
      assert :error = BlobStorage.get_blob("acc1", "cont1", "b1")
    end

    test "missing blob -> 404 BlobNotFound" do
      container()

      assert {:error, 404, "BlobNotFound", _} = BlobStorage.delete_blob("acc1", "cont1", "ghost")
    end

    test "missing container -> 404 ContainerNotFound" do
      assert {:error, 404, "ContainerNotFound", _} = BlobStorage.delete_blob("acc1", "nope", "b1")
    end

    test "legal hold -> 409 ContainerLocked naming legal hold" do
      container()
      BlobStorage.put_blob("acc1", "cont1", "b1", "data")
      assert {:ok, 200, _, _} = BlobStorage.set_legal_hold("acc1", "cont1", true)

      assert {:error, 409, "ContainerLocked", msg} = BlobStorage.delete_blob("acc1", "cont1", "b1")
      assert msg =~ "legal hold"

      # Clearing the hold unblocks delete
      assert {:ok, 200, _, _} = BlobStorage.set_legal_hold("acc1", "cont1", false)
      assert {:ok, 202, _, _} = BlobStorage.delete_blob("acc1", "cont1", "b1")
    end

    test "locked immutability policy -> 409 ContainerLocked naming locked policy" do
      container()
      BlobStorage.put_blob("acc1", "cont1", "b1", "data")
      assert {:ok, 200, _, _} =
               BlobStorage.set_immutability_policy("acc1", "cont1", %{"locked" => true},
                 %{"if-match" => "*"})

      assert {:error, 409, "ContainerLocked", msg} = BlobStorage.delete_blob("acc1", "cont1", "b1")
      assert msg =~ "immutability policy is locked"
    end

    test "If-Match mismatch on delete -> 412 PreconditionFailed" do
      container()
      {:ok, blob} = BlobStorage.put_blob("acc1", "cont1", "b1", "data")

      assert {:error, 412, "PreconditionFailed", _} =
               BlobStorage.delete_blob("acc1", "cont1", "b1", %{"if-match" => "\"dead\""})

      assert {:ok, 202, _, _} =
               BlobStorage.delete_blob("acc1", "cont1", "b1", %{"if-match" => blob["etag"]})
    end
  end

  describe "immutability policy + legal hold API" do
    test "set policy returns until header, stored in :smalt_blob_policy" do
      container()
      {:ok, 200, headers, body} =
        BlobStorage.set_immutability_policy("acc1", "cont1", %{"period_days" => 30})

      assert headers["immutability-policy-until"]
      assert body["period_days"] == 30

      policy = BlobStorage.get_policy("acc1", "cont1")
      assert policy["immutability_policy"]["period_days"] == 30
      assert policy["immutability_policy"]["locked"] == false
    end

    test "lock requires If-Match: \"*\" -> 412 otherwise" do
      container()

      assert {:error, 412, "PreconditionFailed", _} =
               BlobStorage.set_immutability_policy("acc1", "cont1", %{"locked" => true})
    end

    test "locked policy refuses change -> 409 ContainerLocked" do
      container()
      {:ok, 200, _, _} =
        BlobStorage.set_immutability_policy("acc1", "cont1", %{"locked" => true},
          %{"if-match" => "*"})

      assert {:error, 409, "ContainerLocked", _} =
               BlobStorage.set_immutability_policy("acc1", "cont1", %{"period_days" => 60})
    end

    test "legal hold blocks overwrite with 409 ContainerLocked naming legal hold" do
      container()
      BlobStorage.put_blob("acc1", "cont1", "b1", "v1")
      {:ok, 200, _, _} = BlobStorage.set_legal_hold("acc1", "cont1", true)

      assert {:error, :worm_locked, msg} =
               BlobStorage.put_blob("acc1", "cont1", "b1", "v2")

      assert msg =~ "legal hold"
    end

    test "legal hold round-trip in :smalt_blob_policy" do
      container()
      {:ok, 200, _, _} = BlobStorage.set_legal_hold("acc1", "cont1", true)
      assert %{"legal_hold" => true} = BlobStorage.get_policy("acc1", "cont1")

      {:ok, 200, _, _} = BlobStorage.set_legal_hold("acc1", "cont1", false)
      assert %{"legal_hold" => false} = BlobStorage.get_policy("acc1", "cont1")
    end
  end

  # ---------------------------------------------------------------------------
  # Ranged GET (python azure-storage-blob download; lane 91 blocker)
  # ---------------------------------------------------------------------------

  describe "ranged GET" do
    @content :crypto.strong_rand_bytes(256)

    setup :put_blob

    test "mid-slice byte-exact: bytes=50-99 -> 206 slice" do
      {:ok, blob, {first, last}} =
        BlobStorage.get_blob_range("acc1", "cont1", "ranged.bin", ["bytes=50-99"])

      assert {first, last} == {50, 99}
      assert binary_part(blob["content"], first, last - first + 1) ==
               binary_part(@content, 50, 50)
    end

    test "router emits 206 + Content-Range + exact content-length" do
      conn =
        :get
        |> conn("/acc1/cont1/ranged.bin")
        |> put_req_header("range", "bytes=50-99")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 206
      assert get_resp_header(conn, "content-range") == ["bytes 50-99/256"]
      assert get_resp_header(conn, "content-length") == ["50"]
      assert byte_size(conn.resp_body) == 50
      assert conn.resp_body == binary_part(@content, 50, 50)
    end

    test "suffix range bytes=-10 -> last 10 bytes" do
      conn =
        :get
        |> conn("/acc1/cont1/ranged.bin")
        |> put_req_header("range", "bytes=-10")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 206
      assert get_resp_header(conn, "content-range") == ["bytes 246-255/256"]
      assert conn.resp_body == binary_part(@content, 246, 10)
    end

    test "x-ms-range header (python SDK form) also honored" do
      conn =
        :get
        |> conn("/acc1/cont1/ranged.bin")
        |> put_req_header("x-ms-range", "bytes=10-19")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 206
      assert get_resp_header(conn, "content-range") == ["bytes 10-19/256"]
      assert conn.resp_body == binary_part(@content, 10, 10)
    end

    test "unsatisfiable range -> 416 with bytes */total" do
      conn =
        :get
        |> conn("/acc1/cont1/ranged.bin")
        |> put_req_header("range", "bytes=1000-")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 416
      assert get_resp_header(conn, "content-range") == ["bytes */256"]
    end

    test "full GET without Range -> 200 with content-length of whole blob" do
      conn =
        :get
        |> conn("/acc1/cont1/ranged.bin")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 200
      assert get_resp_header(conn, "content-length") == ["256"]
      assert conn.resp_body == @content
    end

    test "missing blob -> 404; engine returns :error" do
      assert BlobStorage.get_blob_range("acc1", "cont1", "nope", ["bytes=0-1"]) == :error

      conn =
        :get
        |> conn("/acc1/cont1/nope")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 404
    end
  end

  defp put_blob(_ctx) do
    container("acc1", "cont1")
    {:ok, _} = BlobStorage.put_blob("acc1", "cont1", "ranged.bin", @content)
    :ok
  end

  defp router_call(conn) do
    if Process.whereis(Smalt.Store) == nil, do: SmaltTest.Lifecycle.restore_app()
    EgressRouter.call(conn, EgressRouter.init([]))
  end

  test "XML list format preserved" do
    container()
    BlobStorage.put_blob("acc1", "cont1", "b1", "data")

    {xml, nil} = BlobStorage.list_blobs_xml("acc1", "cont1")
    assert xml =~ ~s(<?xml version="1.0" encoding="utf-8"?>)
    assert xml =~ "<Name>b1</Name>"
    assert xml =~ "<EnumerationResults"
    assert xml =~ "<NextMarker />"
  end

  # ---------------------------------------------------------------------------
  # ST6 court regressions: D1 (binary PUT content leak), D2 (cross-container
  # listing leak + marker pagination), B (8MB boundary).
  # ---------------------------------------------------------------------------

  describe "ST6 D1 — binary blob PUT is content-leak-free" do
    test "wire PUT of binary content -> 201 metadata-only body, GET byte-identical" do
      container()

      binary = <<0, 255, 0, 253, 197, 254, 255, 0, 1, 2, 3, 0xFF, 0xFE, 16>>

      conn =
        :put
        |> conn("/acc1/cont1/binary.bin", binary)
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 201
      assert get_resp_header(conn, "etag") != []

      body = Jason.decode!(conn.resp_body)
      assert body["name"] == "binary.bin"
      assert body["content_length"] == byte_size(binary)
      assert is_binary(body["etag"])
      refute Map.has_key?(body, "content")
      refute Map.has_key?(body, "content_b64")

      get =
        :get
        |> conn("/acc1/cont1/binary.bin")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert get.status == 200
      assert get.resp_body == binary
    end

    test "wire PUT with urlencoded content-type stores RAW bytes, not parsed params" do
      container()

      conn =
        :put
        |> conn("/acc1/cont1/form.bin", "hello world")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 201
      assert Jason.decode!(conn.resp_body)["content_length"] == 11

      get =
        :get
        |> conn("/acc1/cont1/form.bin")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert get.status == 200
      assert get.resp_body == "hello world"
    end

    test "engine blob_metadata/1 is total over binary content" do
      container()
      # Not valid UTF-8 in general — encoding the raw map would raise
      binary = :crypto.strong_rand_bytes(64)
      {:ok, blob} = BlobStorage.put_blob("acc1", "cont1", "meta.bin", binary)
      assert {:ok, _} = Jason.encode(BlobStorage.blob_metadata(blob))
      refute Map.has_key?(BlobStorage.blob_metadata(blob), "content")
    end
  end

  describe "ST6 D2 — listing isolation + marker pagination" do
    test "same-named blob in two containers: listing returns exactly its own" do
      container("acc1", "alpha")
      container("acc1", "beta")
      BlobStorage.put_blob("acc1", "alpha", "shared.bin", "alpha-body")
      BlobStorage.put_blob("acc1", "beta", "shared.bin", "beta-body")

      {xml, nil} = BlobStorage.list_blobs_xml("acc1", "alpha")
      refute xml =~ "beta-body"
      assert xml =~ "<Name>shared.bin</Name>"

      # The engine can never emit the other container's stored key
      refute xml =~ "beta/shared.bin"
      {xml_b, nil} = BlobStorage.list_blobs_xml("acc1", "beta")
      assert xml_b =~ ~s(ContainerName="beta")
      assert xml_b =~ "<Name>shared.bin</Name>"
      refute xml_b =~ "alpha-body"
    end

    test "120 blobs paginate across 3 marker pages (50/50/20)" do
      container()
      for i <- 1..120 do
        BlobStorage.put_blob("acc1", "cont1", "blob-#{String.pad_leading(Integer.to_string(i), 4, "0")}", "d#{i}")
      end

      {xml1, m1} = BlobStorage.list_blobs_xml("acc1", "cont1", %{})
      assert m1 == "blob-0050"
      assert xml1 =~ "blob-0001"
      assert xml1 =~ "blob-0050"
      refute xml1 =~ "blob-0051"
      assert xml1 =~ "<NextMarker>blob-0050</NextMarker>"

      {xml2, m2} = BlobStorage.list_blobs_xml("acc1", "cont1", %{"marker" => m1})
      assert m2 == "blob-0100"
      assert xml2 =~ "<Marker>blob-0050</Marker>"
      refute xml2 =~ "<Name>blob-0050</Name>"
      assert xml2 =~ "blob-0100"

      {xml3, nil} = BlobStorage.list_blobs_xml("acc1", "cont1", %{"marker" => m2})
      assert xml3 =~ "blob-0120"
      assert xml3 =~ "<NextMarker />"
      refute String.contains?(xml3, "<NextMarker>blob")
    end

    test "wire comp=list on the container path serves the paginated form" do
      container()
      for i <- 1..3 do
        BlobStorage.put_blob("acc1", "cont1", "wire-#{i}", "w")
      end

      conn =
        :get
        |> conn("/acc1/cont1?restype=container&comp=list&maxresults=2")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 200
      assert conn.resp_body =~ "<Name>wire-1</Name>"
      assert conn.resp_body =~ "<MaxResults>2</MaxResults>"
      assert conn.resp_body =~ "<NextMarker>wire-2</NextMarker>"
    end
  end

  describe "ST6 B — PUT size boundary" do
    @miib 1_048_576

    test "8MB+1 body -> clean 413 RequestBodyTooLarge envelope, no reset" do
      container()

      conn =
        :put
        |> conn("/acc1/cont1/big.bin", String.duplicate("A", 8_000_001))
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 413
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "RequestBodyTooLarge"
    end

    test "engine refuses content over 1 MiB with :too_large; boundary 1 MiB accepted" do
      container()

      assert {:ok, _} = BlobStorage.put_blob("acc1", "cont1", "ok.bin", String.duplicate("A", @miib))

      assert {:error, :too_large, msg} =
               BlobStorage.put_blob("acc1", "cont1", "big.bin", String.duplicate("A", @miib + 1))

      assert msg =~ "RequestBodyTooLarge"
      # the oversized PUT must not have stored anything
      assert :error = BlobStorage.get_blob("acc1", "cont1", "big.bin")
    end

    test "wire PUT of 1 MiB + 1 -> 413 RequestBodyTooLarge (engine fence, below egress cap)" do
      container()

      conn =
        :put
        |> conn("/acc1/cont1/miib.bin", String.duplicate("A", @miib + 1))
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 413
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "RequestBodyTooLarge"
      assert body["error"]["message"] =~ "1,048,576"
    end

    test "wire PUT of exactly 1 MiB -> 201 with content_length 1048576" do
      container()

      conn =
        :put
        |> conn("/acc1/cont1/exact.bin", String.duplicate("A", @miib))
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 201
      assert Jason.decode!(conn.resp_body)["content_length"] == @miib
    end
  end

  # ---------------------------------------------------------------------------
  # Time-aware retention expiry (injected clock)
  # ---------------------------------------------------------------------------

  @day 86_400_000

  defp immutable_container(account, name, opts) do
    base = %{"immutable" => true, "retention_days" => 30, "created_at_ms" => 0}
    {:ok, record} = BlobStorage.create_container(account, name, Map.merge(base, opts))
    {account, name, record}
  end

  describe "retention expiry with injected clock" do
    test "created_at stamped on container record at creation" do
      {:ok, record} = BlobStorage.create_container("acc1", "stamped", %{})
      assert is_integer(record["created_at"])
      assert record["created_at"] <= System.os_time(:millisecond)
    end

    test "locked policy before retention end -> overwrite 409-protected" do
      {"acc1", "cont1", _} = immutable_container("acc1", "cont1", %{})
      BlobStorage.put_blob("acc1", "cont1", "b1", "v1")
      BlobStorage.set_immutability_policy("acc1", "cont1", %{"locked" => true},
        %{"if-match" => "*"}, now_ms: 0)

      assert {:error, :worm_locked, msg} =
               BlobStorage.put_blob("acc1", "cont1", "b1", "v2", %{}, now_ms: @day)
      assert msg =~ "locked"

      assert %{"expired" => false} = BlobStorage.policy_state("acc1", "cont1", now_ms: @day)
    end

    test "post-expiry overwrite -> 201-class success and policy reports expired: true" do
      {"acc1", "cont1", _} = immutable_container("acc1", "cont1", %{})
      BlobStorage.put_blob("acc1", "cont1", "b1", "v1", %{}, now_ms: 0)
      BlobStorage.set_immutability_policy("acc1", "cont1", %{"locked" => true},
        %{"if-match" => "*"}, now_ms: 0)

      # 30-day retention: day 31 is past the end
      assert {:ok, updated} =
               BlobStorage.put_blob("acc1", "cont1", "b1", "v2", %{}, now_ms: 31 * @day)
      assert updated["content"] == "v2"

      state = BlobStorage.policy_state("acc1", "cont1", now_ms: 31 * @day)
      assert state["expired"] == true
      assert state["expires_at"] == 30 * @day

      # boundary: exactly at retention end is not yet expired (strict >)
      assert %{"expired" => false} =
               BlobStorage.policy_state("acc1", "cont1", now_ms: 30 * @day)
    end

    test "post-expiry delete succeeds" do
      {"acc1", "cont1", _} = immutable_container("acc1", "cont1", %{})
      BlobStorage.put_blob("acc1", "cont1", "b1", "data", %{}, now_ms: 0)
      BlobStorage.set_immutability_policy("acc1", "cont1", %{"locked" => true},
        %{"if-match" => "*"}, now_ms: 0)

      assert {:error, 409, "ContainerLocked", _} =
               BlobStorage.delete_blob("acc1", "cont1", "b1", %{}, now_ms: @day)

      assert {:ok, 202, _, _} =
               BlobStorage.delete_blob("acc1", "cont1", "b1", %{}, now_ms: 31 * @day)
    end

    test "expired locked policy may be changed (container unlocked)" do
      {"acc1", "cont1", _} = immutable_container("acc1", "cont1", %{})
      BlobStorage.set_immutability_policy("acc1", "cont1", %{"locked" => true},
        %{"if-match" => "*"}, now_ms: 0)

      assert {:ok, 200, _, _} =
               BlobStorage.set_immutability_policy("acc1", "cont1", %{"period_days" => 60},
                 %{}, now_ms: 31 * @day)
    end

    test "legal hold still blocks post-expiry (never auto-expires)" do
      {"acc1", "cont1", _} = immutable_container("acc1", "cont1", %{})
      BlobStorage.put_blob("acc1", "cont1", "b1", "v1", %{}, now_ms: 0)
      BlobStorage.set_immutability_policy("acc1", "cont1", %{"locked" => true},
        %{"if-match" => "*"}, now_ms: 0)
      {:ok, 200, _, _} = BlobStorage.set_legal_hold("acc1", "cont1", true)

      assert {:error, :worm_locked, msg} =
               BlobStorage.put_blob("acc1", "cont1", "b1", "v2", %{}, now_ms: 365 * @day)
      assert msg =~ "legal hold"

      assert {:error, 409, "ContainerLocked", msg} =
               BlobStorage.delete_blob("acc1", "cont1", "b1", %{}, now_ms: 365 * @day)
      assert msg =~ "legal hold"

      state = BlobStorage.policy_state("acc1", "cont1", now_ms: 365 * @day)
      assert state["expired"] == true
      assert state["legal_hold"] == true

      # explicit release lifts the block even post-expiry
      {:ok, 200, _, _} = BlobStorage.set_legal_hold("acc1", "cont1", false)
      assert {:ok, _} =
               BlobStorage.put_blob("acc1", "cont1", "b1", "v2", %{}, now_ms: 365 * @day)
    end

    test "legacy container without created_at treated as not expired (conservative)" do
      container()
      # Simulate a legacy row: strip created_at
      {:ok, legacy} = Store.get(:smalt_blob_containers, "acc1/cont1")
      Store.put(:smalt_blob_containers, "acc1/cont1", Map.delete(legacy, "created_at"))
      BlobStorage.put_blob("acc1", "cont1", "b1", "v1")
      BlobStorage.set_immutability_policy("acc1", "cont1", %{"locked" => true},
        %{"if-match" => "*"}, now_ms: 0)

      far_future = System.os_time(:millisecond) + 100 * 365 * @day

      assert {:error, :worm_locked, _} =
               BlobStorage.put_blob("acc1", "cont1", "b1", "v2", %{}, now_ms: far_future)

      assert %{"expired" => false, "expires_at" => nil} =
               BlobStorage.policy_state("acc1", "cont1", now_ms: far_future)
    end
  end
end
