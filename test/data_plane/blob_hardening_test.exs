defmodule Smalt.DataPlane.BlobHardeningTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.DataPlane.BlobStorage
  alias Smalt.DataPlane.BlobService
  alias Smalt.EgressRouter
  alias Smalt.Store

  setup do
    SmaltTest.Lifecycle.ensure_store_up()
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

    test "policy_state on a missing container -> typed {:error, :container_not_found}" do
      assert {:error, :container_not_found} = BlobStorage.policy_state("acc1", "ghost")
    end

    test "legal hold on a missing container -> 404 ContainerNotFound" do
      assert {:error, 404, "ContainerNotFound", _} =
               BlobStorage.set_legal_hold("acc1", "ghost", true)
    end

    # Azure grammar: immutabilityPeriodSinceCreationInDays ∈ [0, 146000] integer
    # -> else 400 InvalidXmlDocument. Previously ANY value was stored verbatim
    # (negative days, binaries, 10^12 -> "until" in year 2737909033).
    test "malformed immutability period -> 400 InvalidXmlDocument, policy unchanged" do
      container()

      for bad <- [%{"period_days" => -5}, %{"period_days" => "abc"}, %{"period_days" => 10_000_000}] do
        assert {:error, 400, "InvalidXmlDocument", msg} =
                 BlobStorage.set_immutability_policy("acc1", "cont1", bad)

        assert msg =~ "between 0 and 146000"
      end

      # refused writes must not have mutated stored state
      policy = BlobStorage.get_policy("acc1", "cont1")
      refute policy["immutability_policy"]["period_days"] in [-5, "abc", 10_000_000]
    end

    test "period grammar boundaries: 0 and 146000 accepted, 146001 refused" do
      container()

      assert {:ok, 200, _, _} = BlobStorage.set_immutability_policy("acc1", "cont1", %{"period_days" => 0})
      assert {:ok, 200, _, _} =
               BlobStorage.set_immutability_policy("acc1", "cont1", %{"period_days" => 146_000})

      assert {:error, 400, "InvalidXmlDocument", _} =
               BlobStorage.set_immutability_policy("acc1", "cont1", %{"period_days" => 146_001})
    end

    test "wire PUT ?comp=immutabilityPolicy with malformed period -> 400 InvalidXmlDocument" do
      container()

      conn =
        :put
        |> conn("/acc1/cont1?comp=immutabilityPolicy",
          Jason.encode!(%{"immutabilityPeriodSinceCreationInDays" => -5})
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "InvalidXmlDocument"
      assert body["error"]["message"] =~ "between 0 and 146000"
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

    # Deterministic fuzz (Chicago: assert on real returned state, no mocks) —
    # every returned (first, last) must satisfy 0 <= first <= last < total and
    # the returned content slice must be byte-identical to the stored content.
    test "range parser fuzz: 300 seeded specs, slice invariants hold" do
      total = 256
      :rand.seed(:exsss, {77, 101, 226})

      seeds =
        for i <- 1..300 do
          a = :rand.uniform(total + 5) - 1
          b = :rand.uniform(total + 5) - 1

          cond do
            rem(i, 3) == 0 -> "bytes=-#{b}"
            rem(i, 5) == 0 -> "  bytes=#{a}-#{b}  "
            true -> "bytes=#{a}-#{b}"
          end
        end

      results =
        Enum.map(seeds, fn spec ->
          case BlobStorage.get_blob_range("acc1", "cont1", "ranged.bin", [spec]) do
            {:ok, blob, nil} -> {:full, spec, blob["content"]}
            {:ok, blob, {f, l}} -> {:range, spec, f, l, blob["content"]}
            {:error, :range_not_satisfiable, t} -> {:unsat, spec, t}
            :error -> :missing
          end
        end)

      for result <- results do
        case result do
          {:range, spec, f, l, content} ->
            assert f >= 0 and f <= l and l < total, "bad bounds for #{inspect(spec)}: {#{f}, #{l}}"

            assert binary_part(content, f, l - f + 1) ==
                     binary_part(@content, f, l - f + 1)

          {:full, spec, content} ->
            # legal only for malformed specs or last < first (ignored per RFC 9110):
            # the served body must be the FULL content, byte-identical
            assert content == @content, "full-body result for #{inspect(spec)} is not the full blob"

          {:unsat, _spec, t} ->
            assert t == total

          other ->
            flunk("unexpected range result: #{inspect(other)}")
        end
      end
    end

    test "range parser edges: malformed/multi-range/zero-suffix/boundary" do
      total = 256
      range = fn spec -> BlobStorage.get_blob_range("acc1", "cont1", "ranged.bin", [spec]) end

      # syntactically invalid -> ignored -> full body
      assert {:ok, _b, nil} = range.("bytes=abc")
      assert {:ok, _b, nil} = range.("")
      assert {:ok, _b, nil} = range.("bytes=0-1,5-6")

      # last < first -> ignored -> full body (parse_range_spec {:ok, nil})
      assert {:ok, _b, nil} = range.("bytes=5-3")

      # zero suffix -> unsatisfiable
      assert {:error, :range_not_satisfiable, ^total} = range.("bytes=-0")

      # suffix longer than the blob -> whole blob
      assert {:ok, _b, {0, 255}} = range.("bytes=-9999")

      # single-byte boundary
      assert {:ok, _b, {0, 0}} = range.("bytes=0-0")

      # padded spec is trimmed, then parsed
      assert {:ok, _b, {2, 5}} = range.("  bytes=2-5  ")
    end
  end

  defp put_blob(_ctx) do
    container("acc1", "cont1")
    {:ok, _} = BlobStorage.put_blob("acc1", "cont1", "ranged.bin", @content)
    :ok
  end

  defp router_call(conn) do
    SmaltTest.Lifecycle.ensure_store_up()
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
      # Not valid UTF-8 in general — encoding the raw blob map would raise
      binary = :crypto.strong_rand_bytes(64)
      {:ok, blob} = BlobStorage.put_blob("acc1", "cont1", "meta.bin", binary)
      assert {:ok, _} = Jason.encode(BlobStorage.blob_metadata(blob))
      refute Map.has_key?(BlobStorage.blob_metadata(blob), "content")
    end

    # Metadata-key fuzz (unicode / 1 KiB key / empty key / x-ms-* reserved
    # prefix): smalt stores and round-trips these WITHOUT crashing and the
    # metadata projection stays JSON-total. Finding (GAP, feature-banned for
    # this lane): real Azure rejects metadata names violating C#-identifier
    # rules or the x-ms-* reserved prefix with 400 InvalidMetadata — smalt
    # Raw (unprefixed) header keys are not metadata names — they round-trip
    # opaquely. Metadata names ride x-ms-meta-* and are grammar-fenced below
    # (cycle-9: 400 InvalidMetadata, Azure parity).
    test "hostile metadata keys round-trip without crashing; projection stays JSON-total" do
      container()

      hostile = %{
        "metá-🎉" => "v1",
        String.duplicate("k", 1000) => "v2",
        "" => "v3",
        "x-ms-meta-reserved" => "v4"
      }

      assert {:ok, blob} = BlobStorage.put_blob("acc1", "cont1", "metafuzz.bin", "d", hostile)
      assert {:ok, stored} = BlobStorage.get_blob("acc1", "cont1", "metafuzz.bin")

      for {k, v} <- hostile do
        assert stored["headers"][k] == v
      end

      assert {:ok, _} = Jason.encode(BlobStorage.blob_metadata(blob))
    end

    # Azure parity (cycle-9): x-ms-meta-* names must be valid C# identifiers
    # -> else 400 InvalidMetadata. Previously any name was stored verbatim.
    test "invalid x-ms-meta-* name -> 400 InvalidMetadata, nothing stored" do
      container()

      for bad <- ["x-ms-meta-bad name!", "x-ms-meta-9lives", "x-ms-meta-🎉"] do
        assert {:error, 400, "InvalidMetadata", msg} =
                 BlobStorage.put_blob("acc1", "cont1", "meta.bin", "d", %{bad => "v"})

        assert msg =~ "C# identifier"
      end

      # refused writes stored nothing
      assert :error = BlobStorage.get_blob("acc1", "cont1", "meta.bin")
    end

    test "valid x-ms-meta-* names stored; non-meta headers untouched by the rule" do
      container()

      assert {:ok, blob} =
               BlobStorage.put_blob("acc1", "cont1", "okmeta.bin", "d", %{
                 "x-ms-meta-owner" => "sre",
                 "x-ms-meta-_v2" => "ok",
                 "content-type" => "application/octet-stream",
                 "metá-🎉" => "not-a-metadata-name"
               })

      assert blob["headers"]["x-ms-meta-owner"] == "sre"
      assert blob["headers"]["x-ms-meta-_v2"] == "ok"

      get = BlobStorage.get_blob("acc1", "cont1", "okmeta.bin")
      assert {:ok, _} = get
    end

    test "wire PUT blob with invalid metadata name -> 400 InvalidMetadata" do
      container()

      conn =
        :put
        |> conn("/acc1/cont1/badmeta.bin", "d")
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("x-ms-meta-bad name", "v")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "InvalidMetadata"
      assert :error = BlobStorage.get_blob("acc1", "cont1", "badmeta.bin")
    end

    test "container metadata with invalid name -> 400 InvalidMetadata (engine)" do
      container("acc1", "cont1")

      assert {:error, 400, "InvalidMetadata", _} =
               BlobService.set_container_metadata("acc1", "cont1", %{"bad name!" => "v"})

      assert {:ok, %{}} = BlobService.get_container_metadata("acc1", "cont1")
    end

    # Value-side contract (cycle-10): metadata VALUES are re-emitted as
    # x-ms-meta-* response headers on GET properties — they must be valid
    # HTTP header values. Previously binary/unicode values stored fine and
    # then raised Plug.Conn.InvalidHeaderError (a wire 500) on GET properties.
    test "metadata values: printable-ASCII roundtrip; header-hostile values -> 400, nothing stored" do
      container("acc1", "cont1")

      ok = %{"u" => "méta 🎉 值", "pad" => " spaced "}
      assert {:ok, 200, _} = BlobService.set_container_metadata("acc1", "cont1", ok)
      assert {:ok, ^ok} = BlobService.get_container_metadata("acc1", "cont1")

      for bad <- ["line\nbreak", <<0>>, 42] do
        assert {:error, 400, "InvalidMetadata", msg} =
                 BlobService.set_container_metadata("acc1", "cont1", %{"k" => bad})

        assert msg =~ "control characters"
      end

      # the refused writes stored nothing (round-trip intact)
      assert {:ok, ^ok} = BlobService.get_container_metadata("acc1", "cont1")

      # wire GET properties no longer crashes with hostile values refused at PUT
      conn =
        :get
        |> conn("/acc1/cont1?restype=container")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 200
      assert get_resp_header(conn, "x-ms-meta-u") == ["méta 🎉 值"]
    end

    # Case handling: the transport (Bandit/Plug) normalizes request header
    # names to lowercase before the router sees them, so any client casing of
    # X-MS-META-* lands as x-ms-meta-* — engine receives pre-normalized keys.
    # Fenced here: the engine's contract is exact-lowercase x-ms-meta-* keys.
    test "engine stores lowercase-normalized x-ms-meta-* keys; rejects non-lowercase prefix" do
      container("acc1", "cont1")

      assert {:ok, blob} =
               BlobStorage.put_blob("acc1", "cont1", "meta.bin", "d", %{"x-ms-meta-owner" => "sre"})

      assert blob["headers"]["x-ms-meta-owner"] == "sre"

      # mixed-case prefix is NOT a metadata name per engine contract (the
      # transport never delivers one — it would have been normalized)
      assert {:ok, blob2} =
               BlobStorage.put_blob("acc1", "cont1", "meta2.bin", "d", %{"X-MS-META-Owner" => "sre"})

      # stored opaquely as a non-metadata header, never mis-parsed
      assert blob2["headers"]["X-MS-META-Owner"] == "sre"
    end

    # Wire-emission safety: XML 1.0 forbids most C0 control bytes in content.
    # Hostile STORED names and hostile marker/prefix query params must never
    # produce ill-formed enumeration XML (xmerl: "Bad character in content").
    # Control bytes are dropped at emission; & < > " stay entity-escaped.
    test "listing XML stays well-formed under hostile stored names and hostile markers" do
      container()

      # seed a legacy hostile-name row DIRECTLY (put_blob now refuses control
      # chars at PUT — the emission sanitizer defends pre-fence/legacy state)
      hostile = "x" <> <<1>> <> "y"
      key = "acc1/cont1/" <> hostile

      Store.put(:smalt_blobs, key, %{
        "name" => hostile,
        "content" => "d",
        "content_length" => 1,
        "etag" => "\"e\"",
        "last_modified" => "now",
        "headers" => %{}
      })

      {:ok, _} = BlobStorage.put_blob("acc1", "cont1", "clean-after", "d")

      {xml, _} = BlobStorage.list_blobs_xml("acc1", "cont1")
      refute String.contains?(xml, <<1>>)
      assert xml =~ "<Name>xy</Name>"
      assert xml =~ "<Name>clean-after</Name>"

      for hostile <- ["m" <> <<1>> <> "m", "a" <> <<0>> <> "b", <<31>>] do
        {xml_m, _} = BlobStorage.list_blobs_xml("acc1", "cont1", %{"marker" => hostile})
        refute String.contains?(xml_m, <<1>>) and refute String.contains?(xml_m, <<0>>)
        assert xml_m =~ ~s(<?xml version="1.0" encoding="utf-8"?>)
      end

      {xml_p, _} = BlobStorage.list_blobs_xml("acc1", "cont1", %{"marker" => "", "maxresults" => "50"})

      # prefix param rides <Prefix> — control bytes dropped there too
      assert xml_p =~ "<Prefix>acc1/cont1/</Prefix>"
    end

    # Azure parity: x-ms-meta-* on Put Container sets metadata AT CREATE,
    # validated BEFORE the container exists (refused create leaves nothing).
    test "container create with metadata: set at create, replace semantics, hostile 400 pre-create" do
      conn =
        :put
        |> conn("/acc1/create-meta?restype=container")
        |> put_req_header("x-ms-meta-team", "platform")
        |> put_req_header("x-ms-meta-env", "prod")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 201

      assert {:ok, %{"team" => "platform", "env" => "prod"}} =
               BlobService.get_container_metadata("acc1", "create-meta")

      # later Put Metadata REPLACES the whole set (never merges) — Azure
      # Put Metadata semantics
      conn2 =
        :put
        |> conn("/acc1/create-meta?restype=container&comp=metadata")
        |> put_req_header("x-ms-meta-only", "later")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn2.status == 200
      assert {:ok, %{"only" => "later"}} = BlobService.get_container_metadata("acc1", "create-meta")
      refute Map.has_key?(BlobService.get_container_metadata("acc1", "create-meta") |> elem(1), "team")

      # hostile metadata at create -> 400 AND the container is NOT created
      conn3 =
        :put
        |> conn("/acc1/hostile-create?restype=container")
        |> put_req_header("x-ms-meta-bad name", "v")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn3.status == 400
      assert Jason.decode!(conn3.resp_body)["error"]["code"] == "InvalidMetadata"
      assert {:error, 404, "ContainerNotFound", _} =
               BlobService.get_container_metadata("acc1", "hostile-create")
    end

    # Azure parity (cycle-12): control characters in blob names are refused
    # at PUT with 400 InvalidResourceName (naming reference: names are 1..1024
    # characters; control chars are not permitted resource-name bytes).
    # Previously any byte string stored and listings were sanitized at
    # emission only (cycle-11 fix remains for markers/prefix/legacy rows).
    test "blob name grammar: control chars and oversize names -> 400 InvalidResourceName" do
      container()

      for bad <- ["x" <> <<1>> <> "y", "nl\nname", <<0>>, "del" <> <<0x7F>>] do
        assert {:error, 400, "InvalidResourceName", msg} =
                 BlobStorage.put_blob("acc1", "cont1", bad, "d")

        assert msg =~ "blob name is invalid"
      end

      assert {:error, 400, "InvalidResourceName", _} =
               BlobStorage.put_blob("acc1", "cont1", String.duplicate("n", 1_025), "d")

      # boundary: exactly 1024 bytes is legal; nothing hostile stored
      assert {:ok, _} = BlobStorage.put_blob("acc1", "cont1", String.duplicate("n", 1_024), "d")
      assert {:ok, _} = BlobStorage.put_blob("acc1", "cont1", "ok-name", "d")
    end

    # F1 landed (compliance lens-7 routing): BlobStorage.request_id/0 emits
    # the dashed-36 RFC 4122 v4 GUID real Azure emits — unified with the ARM
    # gateway, LA surface, and BlobService (all previously 32-hex pins).
    # Fenced at the module return-header level because the c4 wire fences on
    # container paths are served by BlobService.request_id/0 (mutant Z proved
    # reverting ONLY storage's emitter survives the wire courts).
    @v4_guid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    test "storage-level request ids are v4 GUIDs, unique per call (F1)" do
      container()
      BlobStorage.put_blob("acc1", "cont1", "f1.bin", "d")

      assert {:ok, 202, headers, nil} = BlobStorage.delete_blob("acc1", "cont1", "f1.bin")
      assert headers["x-ms-request-id"] =~ @v4_guid

      assert {:ok, 200, policy_headers, _} =
               BlobStorage.set_immutability_policy("acc1", "cont1", %{"locked" => false},
                 %{"if-match" => "*"}
               )

      assert policy_headers["x-ms-request-id"] =~ @v4_guid
      assert policy_headers["x-ms-request-id"] != headers["x-ms-request-id"]
    end

    # Lens-5 routing (zero-visible class): whitespace-only and
    # invisible-format-only names were stored and projected verbatim into
    # blob.list — unreadable custody keys that collide visually. Now refused
    # at PUT with the same InvalidResourceName vocabulary; the fence mirrors
    # Smalt.Projection.Identity.valid?/1 so the read-side semantic fence and
    # the producer gate agree on the same zero-identity-bits class.
    test "blob name grammar: zero-visible names -> 400 InvalidResourceName (lens-5)" do
      container()

      for bad <-
            ["", "   ", " ", " \u200B ", "﻿", "­",
             String.duplicate("\u200B", 50)] do
        assert {:error, 400, "InvalidResourceName", msg} =
                 BlobStorage.put_blob("acc1", "cont1", bad, "d")

        assert msg =~ "blob name is invalid"
      end

      # visible names containing invisible characters stay legal (charset
      # policy is NOT the fence — the zero-identity-bits class is)
      assert {:ok, _} = BlobStorage.put_blob("acc1", "cont1", "ok\u200Bname", "d")

      # bidi override PFX visible chars: display-hostile but has visible
      # identity bits — legal per the shared Identity.valid? fence
      assert {:ok, _} = BlobStorage.put_blob("acc1", "cont1", "\u202Eok", "d")

      # nothing hostile stored: listing projects only the legal names
      {xml, nil} = BlobStorage.list_blobs_xml("acc1", "cont1")
      names =
        ~r/<Name>([^<]*)<\/Name>/ |> Regex.scan(xml, capture: :all_but_first) |> List.flatten()

      assert Enum.sort(names) == Enum.sort(["\u202Eok", "ok\u200Bname"])
    end
  end

  describe "ST6 D1b — engine totality fences (cycle-14)" do
    # Azure parity: PUT ?comp=immutabilityPolicy on a missing container is a
    # client error — 404 ContainerNotFound, never a 500 WithClauseError
    # (cycle-14: require_container returned a 4-tuple the outer with-else
    # never mapped, so any missing-container call crashed).
    test "immutability policy on missing container -> 404 ContainerNotFound, no raise" do
      assert {:error, 404, "ContainerNotFound", _} =
               BlobStorage.set_immutability_policy("acc1", "hostile-nope", %{"locked" => true},
                 %{"if-match" => "*"})

      assert {:error, 404, "ContainerNotFound", _} =
               BlobStorage.set_immutability_policy("acc1", "hostile-nope", %{"period_days" => 30})
    end

    # Azure parity: invalid retention grammar is 400 InvalidXmlDocument —
    # the inner with had no else, so any invalid period_days raised.
    test "immutability policy with invalid period_days -> 400 InvalidXmlDocument, no raise" do
      container()

      for bad <- [-1, "30", 10.5, 146_001] do
        assert {:error, 400, "InvalidXmlDocument", msg} =
                 BlobStorage.set_immutability_policy("acc1", "cont1", %{"period_days" => bad})

        assert msg =~ "must be an integer"
      end

      # nothing hostile stored
      assert nil == BlobStorage.get_policy("acc1", "cont1")
    end

    # Azure parity: metadata is string:string. A non-binary or control-char
    # VALUE rides x-ms-meta-* → 400 InvalidMetadata, never stored verbatim
    # (cycle-15: tuple/map values stored verbatim made the wire JSON
    # projection raise — 500-class).
    test "put_blob non-binary or control-char metadata value -> 400 InvalidMetadata, no raise" do
      container()

      for bad <- [%{"x-ms-meta-A" => {:t, 1}}, %{"x-ms-meta-A" => %{"deep" => [1, {:x}]}},
                  %{"x-ms-meta-A" => "bad" <> <<1>>}] do
        assert {:error, 400, "InvalidMetadata", msg} =
                 BlobStorage.put_blob("acc1", "cont1", "mv", "d", bad)

        assert msg =~ "Invalid metadata"
      end

      # non-meta headers untouched by the rule (round-trip opaquely)
      assert {:ok, _} = BlobStorage.put_blob("acc1", "cont1", "mv-ok", "d", %{"X-Odd" => {:raw, 1}})
    end

    test "non-meta header values round-trip opaquely (no InvalidMetadata rule)" do
      container()
      {:ok, blob} = BlobStorage.put_blob("acc1", "cont1", "opaque", "d", %{"X-Opaque" => "any bytes " <> <<1>>})
      assert blob["headers"]["X-Opaque"] == "any bytes " <> <<1>>
    end

    # Azure parity (cycle-16): comp=list&prefix=F filters results and rides
    # <Prefix> in the response. Previously the option was accepted and
    # silently ignored end-to-end (over-disclosure to prefix-scoped readers).
    test "list_blobs_xml honors prefix filter and echoes it in <Prefix>" do
      container()
      Enum.each(["alpha-1", "alpha-2", "beta-1"], fn n ->
        BlobStorage.put_blob("acc1", "cont1", n, "d")
      end)

      {xml, nil} = BlobStorage.list_blobs_xml("acc1", "cont1", %{"prefix" => "alpha"})
      assert xml =~ "<Name>alpha-1</Name>"
      assert xml =~ "<Name>alpha-2</Name>"
      refute xml =~ "beta-1"
      assert xml =~ "<Prefix>alpha</Prefix>"

      # empty prefix keeps the legacy container-prefix echo
      {xml_all, nil} = BlobStorage.list_blobs_xml("acc1", "cont1", %{})
      assert xml_all =~ "<Prefix>acc1/cont1/</Prefix>"
      assert xml_all =~ "beta-1"
    end

    test "prefix + marker compose (pagination within a prefix)" do
      container()
      for i <- 1..5, do: BlobStorage.put_blob("acc1", "cont1", "p-#{i}", "d")

      {xml1, m1} = BlobStorage.list_blobs_xml("acc1", "cont1", %{"prefix" => "p-", "maxresults" => "2"})
      assert xml1 =~ "<Name>p-1</Name>"
      refute xml1 =~ "p-3"
      assert is_binary(m1) and m1 == "p-2"

      {xml2, m2} = BlobStorage.list_blobs_xml("acc1", "cont1", %{"prefix" => "p-", "marker" => m1, "maxresults" => "2"})
      assert xml2 =~ "<Name>p-3</Name>"
      assert m2 == "p-4"

      {xml3, nil} = BlobStorage.list_blobs_xml("acc1", "cont1", %{"prefix" => "p-", "marker" => m2, "maxresults" => "2"})
      assert xml3 =~ "<Name>p-5</Name>"
    end

    # Engine totality (cycle-18): nil metadata = empty replace set (Azure Put
    # Metadata with no x-ms-meta-* headers), never a FunctionClauseError 500.
    test "set_container_metadata with nil metadata -> empty replace set, no raise" do
      container()
      {:ok, 200, _} = BlobService.set_container_metadata("acc1", "cont1", %{"Team" => "sre"})

      assert {:ok, 200, _} = BlobService.set_container_metadata("acc1", "cont1", nil)

      # nil replaced the full set, not merged
      assert {:ok, %{}} = BlobService.get_container_metadata("acc1", "cont1")
    end

    # Azure parity (cycle-19): a non-boolean legal-hold flag is a client
    # error — 400 InvalidHeaderValue, never a FunctionClauseError 500.
    test "set_legal_hold non-boolean flag -> 400 InvalidHeaderValue, no raise" do
      container()

      for bad <- ["true", 1, nil, "not-a-bool"] do
        assert {:error, 400, "InvalidHeaderValue", msg} =
                 BlobStorage.set_legal_hold("acc1", "cont1", bad)

        assert msg =~ "must be true or false"
      end

      # no hostile policy row written
      policy = BlobStorage.get_policy("acc1", "cont1")
      assert policy == nil or policy["legal_hold"] != "true"
    end

    # Azure parity (cycle-21): If-Match on a NON-EXISTENT blob fails with 412
    # (precondition on a missing resource), and If-None-Match: * refuses
    # overwrite of an existing blob. Previously both were silently ignored:
    # conditional creates/overwrites raced through unconditionally.
    test "If-Match on create -> 412; If-None-Match: * on overwrite -> 412" do
      container()

      assert {:error, :precondition_failed, _} =
               BlobStorage.put_blob("acc1", "cont1", "ghost", "v", %{"if-match" => "*"})
      assert {:error, :precondition_failed, _} =
               BlobStorage.put_blob("acc1", "cont1", "ghost", "v", %{"if-match" => "\"0x1\""})

      {:ok, _} = BlobStorage.put_blob("acc1", "cont1", "b1", "v1")
      assert {:error, :precondition_failed, _} =
               BlobStorage.put_blob("acc1", "cont1", "b1", "v2", %{"if-none-match" => "*"})
      # if-none-match on a NEW blob proceeds (conditional create allowed)
      assert {:ok, _} = BlobStorage.put_blob("acc1", "cont1", "b2", "v", %{"if-none-match" => "*"})
      # unconditional paths unchanged
      assert {:ok, _} = BlobStorage.put_blob("acc1", "cont1", "b1", "v3")
    end

    # Azure parity (cycle-22): If-None-Match: * refuses deletion of an
    # existing blob with 412 — previously silently ignored (202).
    test "delete with If-None-Match: * on existing blob -> 412, blob survives" do
      container()
      {:ok, _} = BlobStorage.put_blob("acc1", "cont1", "b1", "v1")

      assert {:error, 412, "PreconditionFailed", _} =
               BlobStorage.delete_blob("acc1", "cont1", "b1", %{"if-none-match" => "*"})

      # blob survived
      assert {:ok, _} = BlobStorage.get_blob("acc1", "cont1", "b1")
    end

    # Azure parity (cycle-25, Put Container): names are 3-63 bytes,
    # lowercase/digits/dashes, starting and ending alphanumeric —
    # 400 InvalidResourceName otherwise. Previously ANY byte string was
    # accepted (empty, control chars, uppercase, 1MB).
    test "container name grammar -> 400 InvalidResourceName for violations" do
      for bad <- ["", "ab", "a" <> <<1>>, "-abc", "abc-", "AB-C", "a b", String.duplicate("x", 64),
                  nil, "UPPER"] do
        assert {:error, 400, "InvalidResourceName", msg} =
                 BlobStorage.create_container("acc1", bad, %{})

        assert msg =~ "container name is invalid"
      end

      # grammar-legal names proceed
      assert {:ok, _} = BlobStorage.create_container("acc1", "abc", %{})
      assert {:ok, _} = BlobStorage.create_container("acc1", "a-1", %{})
      assert {:ok, _} = BlobStorage.create_container("acc1", String.duplicate("x", 63), %{})
    end

    # Azure parity (cycle-25): duplicate Put Container -> 409
    # ContainerAlreadyExists (previously silently replaced the record,
    # resetting the WORM clock and flipping policy flags).
    test "duplicate create_container -> 409 ContainerAlreadyExists, record preserved" do
      {:ok, original} = BlobStorage.create_container("acc1", "dupc", %{"immutable" => false})
      assert {:error, 409, "ContainerAlreadyExists", msg} =
               BlobStorage.create_container("acc1", "dupc", %{})

      assert msg =~ "already exists"

      # original record NOT replaced (immutable flag and created_at intact)
      assert {:ok, record} = Smalt.Store.get(:smalt_blob_containers, "acc1/dupc")
      assert record["immutable"] == false
      assert record["created_at"] == original["created_at"]
    end

    # Azure parity (cycle-27): delimiter rolls names containing it into a
    # single synthetic <BlobPrefix> per "directory"; Blob and BlobPrefix
    # elements interleave lexicographically, prefixes count toward
    # maxresults, and pagination continues from the last element name.
    test "delimiter rolls directories into BlobPrefix, interleaves, paginates" do
      container()
      names = ["a.txt", "d/1", "d/2", "d/sub/3", "e.txt"]
      Enum.each(names, fn n -> BlobStorage.put_blob("acc1", "cont1", n, "x") end)

      {xml, nil} = BlobStorage.list_blobs_xml("acc1", "cont1", %{"delimiter" => "/"})
      assert xml =~ "<Delimiter>/</Delimiter>"
      assert xml =~ "<BlobPrefix>\n    <Name>d/</Name>\n  </BlobPrefix>"
      refute xml =~ "<Name>d/1</Name>"
      assert xml =~ "<Name>a.txt</Name>"
      assert xml =~ "<Name>e.txt</Name>"
      # d/sub/3 does NOT double-roll into d/ (first-segment roll only)
      assert xml =~ ~s(<?xml version="1.0" encoding="utf-8"?>)

      # prefix + delimiter compose: within d/, "sub/" rolls again
      {xml2, nil} =
        BlobStorage.list_blobs_xml("acc1", "cont1", %{"delimiter" => "/", "prefix" => "d/"})

      assert xml2 =~ "<BlobPrefix>\n    <Name>d/sub/</Name>\n  </BlobPrefix>"
      assert xml2 =~ "<Name>d/1</Name>"
      assert xml2 =~ "<Name>d/2</Name>"
      refute xml2 =~ "d/sub/3"

      # prefixes count toward maxresults and paginate
      {p1, m1} = BlobStorage.list_blobs_xml("acc1", "cont1", %{"delimiter" => "/", "maxresults" => "2"})
      assert p1 =~ "<Name>a.txt</Name>"
      assert p1 =~ "<BlobPrefix>\n    <Name>d/</Name>\n  </BlobPrefix>"
      assert m1 == "d/"

      {p2, m2} =
        BlobStorage.list_blobs_xml("acc1", "cont1", %{"delimiter" => "/", "marker" => m1, "maxresults" => "2"})

      assert p2 =~ "<Name>e.txt</Name>"
      assert m2 == nil
    end

    # Azure parity (cycle-34, List Blobs include=metadata): <Metadata> elements
    # emitted only when requested; hostile values entity-escaped; unknown
    # include values never emit decoration (UNSUPPORTED(feature-ban)).
    test "list include=metadata emits Metadata elements, escaped, opt-in only" do
      container()
      BlobStorage.put_blob("acc1", "cont1", "m1", "x", %{"x-ms-meta-team" => "sre"})
      BlobStorage.put_blob("acc1", "cont1", "m2", "x", %{"x-ms-meta-note" => "a&<>\"b"})
      BlobStorage.put_blob("acc1", "cont1", "plain", "x")

      # opt-in: metadata present, hostile value escaped, non-meta blob has none
      {xml, _} = BlobStorage.list_blobs_xml("acc1", "cont1", %{"include" => "metadata"})
      assert xml =~ "<Metadata>\n<team>sre</team>\n  </Metadata>"
      assert xml =~ "<note>a&amp;&lt;&gt;&quot;b</note>"
      refute xml =~ "<Name>plain</Name>\n  <Metadata>"

      # opt-out: no Metadata at all
      {xml2, _} = BlobStorage.list_blobs_xml("acc1", "cont1", %{})
      refute xml2 =~ "<Metadata>"

      # unknown include values are inert (no decoration)
      {xml3, _} = BlobStorage.list_blobs_xml("acc1", "cont1", %{"include" => "snapshots,versions,tags"})
      refute xml3 =~ "<Metadata>"
      # metadata+unknown compose (comma list containing metadata)
      {xml4, _} = BlobStorage.list_blobs_xml("acc1", "cont1", %{"include" => "snapshots,metadata"})
      assert xml4 =~ "<Metadata>"
    end

    # Azure parity (cycle-30, Get Blob): If-Match then If-None-Match per
    # RFC 7232 precedence — 412 on IM failure, 304 on INM match, 200
    # otherwise. Previously reads took no conditional surface at all.
    test "get_blob_conditional: 412 / 304 / 200 matrix" do
      container()
      {:ok, b1} = BlobStorage.put_blob("acc1", "cont1", "b1", "v1")
      etag = b1["etag"]

      # no conditionals -> 200 path
      assert {:ok, _} = BlobStorage.get_blob_conditional("acc1", "cont1", "b1", %{})

      # If-Match
      assert {:ok, _} = BlobStorage.get_blob_conditional("acc1", "cont1", "b1", %{"if-match" => etag})
      assert {:ok, _} = BlobStorage.get_blob_conditional("acc1", "cont1", "b1", %{"if-match" => "*"})
      assert {:error, 412, "PreconditionFailed", _} =
               BlobStorage.get_blob_conditional("acc1", "cont1", "b1", %{"if-match" => "\"dead\""})

      # If-None-Match
      assert {:not_modified, ^etag} = BlobStorage.get_blob_conditional("acc1", "cont1", "b1", %{"if-none-match" => etag})
      assert {:not_modified, ^etag} = BlobStorage.get_blob_conditional("acc1", "cont1", "b1", %{"if-none-match" => "*"})
      assert {:ok, _} = BlobStorage.get_blob_conditional("acc1", "cont1", "b1", %{"if-none-match" => "\"other\""})

      # etag list form
      assert {:not_modified, ^etag} =
               BlobStorage.get_blob_conditional("acc1", "cont1", "b1", %{"if-none-match" => "\"x\", #{etag}"})

      # RFC precedence: failing If-Match -> 412 even when INM also present
      assert {:error, 412, _, _} =
               BlobStorage.get_blob_conditional("acc1", "cont1", "b1", %{"if-match" => "\"dead\"", "if-none-match" => etag})

      # missing blob -> :error regardless of conditionals
      assert :error = BlobStorage.get_blob_conditional("acc1", "cont1", "ghost", %{"if-match" => "*"})
    end

    # Engine totality (cycle-14): a non-binary content argument answers 400
    # InvalidInput, never a byte_size/1 BadArg crash.
    test "put_blob non-binary content -> 400 InvalidInput, no raise" do
      container()

      for bad <- [nil, 1234, 1.5, %{"x" => 1}, [104, 105]] do
        assert {:error, 400, "InvalidInput", msg} =
                 BlobStorage.put_blob("acc1", "cont1", "cb", bad)

        assert msg =~ "must be a binary"
      end
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

    test "marker pagination edges: past-end marker, junk/zero/negative/capped maxresults" do
      container()
      for i <- 1..3 do
        BlobStorage.put_blob("acc1", "cont1", "edge-#{i}", "e")
      end

      # marker past every blob -> empty page, no NextMarker
      {xml, nil} = BlobStorage.list_blobs_xml("acc1", "cont1", %{"marker" => "zzz"})
      refute xml =~ "<Name>edge-"
      assert xml =~ "<NextMarker />"

      # Azure parity (cycle-25): junk/zero/negative maxresults -> 400
      # InvalidQueryParameter (previously silently coerced to the default 50)
      for junk <- ["abc", "0", "-5"] do
        assert {:error, 400, "InvalidQueryParameter", msg} =
                 BlobStorage.list_blobs_xml("acc1", "cont1", %{"maxresults" => junk})

        assert msg =~ "maxresults is invalid"
      end

      # maxresults over the cap -> capped at 50
      {xml, nil} = BlobStorage.list_blobs_xml("acc1", "cont1", %{"maxresults" => "5000"})
      assert xml =~ "<MaxResults>50</MaxResults>"
    end

    # Azure continuation semantics: a marker naming a blob deleted between
    # pages must not raise (no MatchError on a vanished row) — pagination
    # resumes after the marker over the SURVIVING blobs and terminates with
    # <NextMarker />. Concurrent deletes may only REMOVE names from the
    # enumeration, never duplicate or crash it.
    test "marker pointing at a blob deleted mid-pagination: no crash, clean continuation" do
      container()

      names = for i <- 1..12, do: "cd-#{String.pad_leading(Integer.to_string(i), 2, "0")}"

      for name <- names do
        BlobStorage.put_blob("acc1", "cont1", name, "d")
      end

      {xml1, m1} = BlobStorage.list_blobs_xml("acc1", "cont1", %{"maxresults" => "3"})
      assert xml1 =~ "<Name>cd-01</Name>"

      # delete every even-numbered blob AFTER the first page is materialized
      for name <- names do
        if rem(String.to_integer(String.slice(name, -2, 2)), 2) == 0 do
          BlobStorage.delete_blob("acc1", "cont1", name)
        end
      end

      # chain pages past the deleted marker region until exhaustion
      {pages_rev, final_marker} =
        Enum.reduce_while(1..10, {[], m1}, fn _i, {acc, marker} ->
          {xml, next} =
            BlobStorage.list_blobs_xml("acc1", "cont1", %{"marker" => marker || "", "maxresults" => "3"})

          if next == nil, do: {:halt, {[xml | acc], nil}}, else: {:cont, {[xml | acc], next}}
        end)

      assert final_marker == nil

      seen =
        [xml1 | Enum.reverse(pages_rev)]
        |> Enum.flat_map(fn xml ->
          xml |> then(&Regex.scan(~r/<Name>([^<]+)<\/Name>/, &1)) |> Enum.map(&List.last/1)
        end)

      survivors = Enum.filter(names, &(rem(String.to_integer(String.slice(&1, -2, 2)), 2) != 0))

      # Azure semantics: pages ALREADY SERVED stand (page 1 returned cd-02
      # before the delete); the continuation yields the surviving names after
      # the marker exactly once, in order; no MatchError class.
      expected = Enum.filter(names, &(&1 in ["cd-01", "cd-02", "cd-03"]) or &1 in survivors)

      assert seen == expected
    end

    # Azure markers are OPAQUE continuation tokens: clients must not parse
    # them, and the service must not crash on any marker value. Real Azure
    # may 400 on a malformed marker for some services; smalt's fence is
    # opaque-string semantics: no crash, well-formed XML, deterministic
    # name-order skip. Exact Azure malformed-marker error shapes: UNKNOWN
    # parity (recorded, not fenced as passing).
    test "marker tampering fuzz: foreign/base64/unicode/xml-hostile markers are safe" do
      container("acc1", "alpha")
      container("acc1", "beta")

      for name <- ["a1", "a2", "a3", "a4"] do
        BlobStorage.put_blob("acc1", "alpha", name, "d")
      end

      foreign = [
        "b2",
        # base64-injected marker
        "YjI=",
        "metá-🎉",
        "a<b>&amp;",
        String.duplicate("m", 4096),
        "<<injected>>",
        "a2\x00nul"
      ]

      for marker <- foreign do
        {xml, next} = BlobStorage.list_blobs_xml("acc1", "alpha", %{"marker" => marker})

        # always well-formed envelope; marker/name output escaped
        assert xml =~ ~s(<?xml version="1.0" encoding="utf-8"?>)

        # opaque skip semantics: only names strictly greater survive
        survivors = Enum.filter(["a1", "a2", "a3", "a4"], &(&1 > marker))
        listed = xml |> then(&Regex.scan(~r/<Name>([^<]*)<\/Name>/, &1)) |> Enum.map(&List.last/1)

        assert listed == survivors,
               "marker #{inspect(marker)}: listed #{inspect(listed)}, expected #{inspect(survivors)}"

        # ≤4 survivors, page cap 50 → never a continuation
        assert next == nil
      end
    end

    # Soft perf contract (cycle-9): keys-only pagination measured 36 ms for a
    # 10-page chain over 8000 blobs x 2 KiB; the reverted full-value
    # materialization measured ~3.3x that. Behavior fences CANNOT catch a
    # revert (pure no-op), so wall-time is the contract. Budget = 80 ms
    # (~2.2x observed, ~1.5x under the measured revert) — a revert trips it.
    @perf_budget_ms 80

    test "pagination perf contract: 10-page chain over 8000x2KiB under budget" do
      container("perf", "acct")
      content = :crypto.strong_rand_bytes(2048)

      for i <- 1..8000 do
        BlobStorage.put_blob("perf", "acct", "blob-" <> String.pad_leading(Integer.to_string(i), 5, "0"), content)
      end

      {ms, _} =
        :timer.tc(fn ->
          marker = ""

          for _ <- 1..10 do
            {_xml, next} = BlobStorage.list_blobs_xml("perf", "acct", %{"marker" => marker})
            marker = next || ""
          end
        end)

      ms = div(ms, 1000)

      if ms > @perf_budget_ms do
        flunk("""
        pagination perf contract violated: #{ms} ms > #{@perf_budget_ms} ms budget.
        Likely regression to full-value materialization (measured ~3.3x slower).
        """)
      end
    end
  end

  describe "ST6 B — PUT size boundary" do
    @miib 1_048_576

    test "8MB+1 body -> 413 from the TRANSPORT cap: message cites 8,000,000, never the engine bound" do
      container()

      conn =
        :put
        |> conn("/acc1/cont1/big.bin", String.duplicate("A", 8_000_001))
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 413
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "RequestBodyTooLarge"
      # source separation: the transport 413 cites its own byte bound
      assert body["error"]["message"] =~ "8,000,000"
      refute body["error"]["message"] =~ "1,048,576"
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
      # source separation: the engine 413 cites its own byte bound
      assert body["error"]["message"] =~ "1,048,576"
      refute body["error"]["message"] =~ "8,000,000"
    end

    test "oversized PUT to a MISSING container -> 404 ContainerNotFound (parity: 404 outranks 413)" do
      conn =
        :put
        |> conn("/acc1/nosuch/big.bin", String.duplicate("A", @miib + 1))
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "ContainerNotFound"
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

      assert {:ok, %{"expired" => false}} = BlobStorage.policy_state("acc1", "cont1", now_ms: @day)
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

      {:ok, state} = BlobStorage.policy_state("acc1", "cont1", now_ms: 31 * @day)
      assert state["expired"] == true
      assert state["expires_at"] == 30 * @day

      # boundary: exactly at retention end is not yet expired (strict >)
      assert {:ok, %{"expired" => false}} =
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

      {:ok, state} = BlobStorage.policy_state("acc1", "cont1", now_ms: 365 * @day)
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

      assert {:ok, %{"expired" => false, "expires_at" => nil}} =
               BlobStorage.policy_state("acc1", "cont1", now_ms: far_future)
    end
  end


  # ===========================================================================
  # Lens 2, cycle-35: listed-vs-stored consistency across ALL listing variants
  # ===========================================================================
  describe "lens2 listed-vs-stored consistency" do
    setup do
      container("l2acc", "l2cont")

      names =
        for i <- 1..12, do: "row-#{String.pad_leading(Integer.to_string(i), 2, "0")}"

      names =
        names ++
          ["dir-a/f1", "dir-a/f2", "dir-b/deep/g1", "top&<>.txt", "uni-🎉-code", "z-last"]

      metas = %{
        "row-01" => %{"x-ms-meta-team" => "sre", "x-ms-meta-note" => "a&<>\"b"},
        "dir-a/f1" => %{"x-ms-meta-owner" => "s<>&"}
      }

      for name <- names do
        headers = Map.get(metas, name, %{})
        BlobStorage.put_blob("l2acc", "l2cont", name, "v", headers)
      end

      stored = Enum.sort(names)
      %{stored: stored, metas: metas}
    end

    test "well-formed XML and exact set projection for every listing variant", %{stored: stored} do
      # expected listed names = stored names through the engine's own escape
      # (Azure lowercases nothing here; entity/NCR forms sort differently than
      # raw, so both sides are sorted after mapping)
      esc = fn raw_names -> raw_names |> Enum.map(&BlobStorage.xml_escape/1) |> Enum.sort() end

      listed_names = fn xml ->
        xml
        |> then(&Regex.scan(~r/<Name>([^<]+)<\/Name>/, &1))
        |> Enum.map(&List.last/1)
      end

      # :xmerl_scan.string returns {{xmlElement, ...}, rest} on success and
      # THROWS on ill-formed input — never {:ok, _}.
      assert_wf = fn xml, opts ->
        parsed =
          try do
            {:parsed, :xmerl_scan.string(String.to_charlist(xml))}
          catch
            :exit, reason -> {:fatal, reason}
          end

        assert {:parsed, {{:xmlElement, :EnumerationResults, _, _, _, _, _, _, _, _, _, _}, _}} =
                 parsed,
               "ill-formed XML for opts #{inspect(opts)}: #{inspect(parsed, limit: 5)}"
      end

      # Variant 1: plain listing — exactly the stored set
      {xml, nil} = BlobStorage.list_blobs_xml("l2acc", "l2cont", %{})
      assert_wf.(xml, %{})
      assert Enum.sort(listed_names.(xml)) == esc.(stored)

      # Variant 2: prefix listings — exactly the stored names under each prefix
      for p <- ["row-", "dir-a/", "dir-b/", "z"] do
        {xml, _} = BlobStorage.list_blobs_xml("l2acc", "l2cont", %{"prefix" => p})
        assert_wf.(xml, %{"prefix" => p})
        assert Enum.sort(listed_names.(xml)) == esc.(Enum.filter(stored, &String.starts_with?(&1, p))),
               "prefix #{inspect(p)} projection inconsistent"
      end

      # Variant 3: delimiter listing — visible blobs ∪ names under prefixes == stored
      {xml, _} = BlobStorage.list_blobs_xml("l2acc", "l2cont", %{"delimiter" => "/"})
      assert_wf.(xml, %{"delimiter" => "/"})

      blob_names = fn xml ->
        Regex.scan(~r/<Blob>.*?<\/Blob>/s, xml)
        |> Enum.flat_map(fn [block] ->
          Regex.scan(~r/<Name>([^<]+)<\/Name>/, block) |> Enum.map(&List.last/1)
        end)
      end

      visible = blob_names.(xml)
      assert Enum.sort(visible) == esc.(Enum.reject(stored, &String.contains?(&1, "/")))

      bps =
        Regex.scan(~r/<BlobPrefix>\s*<Name>([^<]+)<\/Name>/, xml)
        |> Enum.map(&List.last/1)

      hidden =
        bps
        |> Enum.flat_map(fn bp -> Enum.filter(stored, &String.starts_with?(&1, bp)) end)
        |> esc.()

      assert Enum.sort(visible ++ hidden) == esc.(stored),
             "delimiter view inconsistent: visible #{inspect(visible)}, prefixes #{inspect(bps)}"

      assert bps == ["dir-a/", "dir-b/"]

      # Variant 4: include=metadata — same blob set as plain, complete Metadata
      {mxml, _} = BlobStorage.list_blobs_xml("l2acc", "l2cont", %{"include" => "metadata"})
      assert_wf.(mxml, %{"include" => "metadata"})
      assert Enum.sort(listed_names.(mxml)) == esc.(stored)
      assert mxml =~ "<note>a&amp;&lt;&gt;&quot;b</note>"
      assert mxml =~ "<owner>s&lt;&gt;&amp;</owner>"

      # Variant 5: marker-chained listings (plain and delimiter) == stored view
      for opts <- [%{}, %{"delimiter" => "/"}] do
        {xml, _} = BlobStorage.list_blobs_xml("l2acc", "l2cont", %{"maxresults" => "5"})
        _ = xml

        {:ok, pages, final} = chain_pages(opts)
        assert final == nil

        flat_names =
          pages
          |> Enum.flat_map(fn page -> blob_names.(page) end)
          |> Enum.sort()

        if opts == %{} do
          assert flat_names == esc.(stored)
        else
          all_bps =
            Enum.flat_map(pages, fn page ->
              Regex.scan(~r/<BlobPrefix>\s*<Name>([^<]+)<\/Name>/, page)
              |> Enum.map(&List.last/1)
            end)

          hidden =
            all_bps
            |> Enum.flat_map(fn bp -> Enum.filter(stored, &String.starts_with?(&1, bp)) end)
            |> esc.()

          assert Enum.sort(flat_names ++ hidden) == esc.(stored)
          assert all_bps == Enum.uniq(all_bps)
        end
      end
    end

    # Azure parses `include` as an exact comma-token list; a plain substring
    # match (pre-lens2) wrongly enabled metadata for hostile tokens.
    test "include token grammar: exact comma-token membership only", %{stored: stored} do
      for inc <- ["metadata", "snapshots,metadata", "metadata,snapshots", " metadata "] do
        {xml, _} = BlobStorage.list_blobs_xml("l2acc", "l2cont", %{"include" => inc})
        assert String.contains?(xml, "<Metadata>"), "include=#{inspect(inc)} must enable metadata"
      end

      for inc <- ["", "metadatabase", "metadatax", "meta", "Metadata", "SNAPSHOTS", "met adata"] do
        {xml, _} = BlobStorage.list_blobs_xml("l2acc", "l2cont", %{"include" => inc})
        refute String.contains?(xml, "<Metadata>"), "include=#{inspect(inc)} must not enable metadata"
      end

      # and the blob set is unchanged by any include value
      for inc <- ["snapshots", "versions,tags", "metadatabase"] do
        {xml, _} = BlobStorage.list_blobs_xml("l2acc", "l2cont", %{"include" => inc})
        names = Regex.scan(~r/<Name>([^<]+)<\/Name>/, xml) |> Enum.map(&List.last/1)
        assert Enum.sort(names) == stored |> Enum.map(&BlobStorage.xml_escape/1) |> Enum.sort()
      end
    end

    # Stratum 2: metadata path under concurrency. Each blob is one ETS row
    # written atomically; a reader rendering <Metadata> must never observe a
    # torn metadata set (one key without its sibling, or partial value).
    test "concurrent metadata writers vs listing readers: no torn Metadata" do
      container("l2acc", "l2conc")

      for i <- 1..6 do
        BlobStorage.put_blob("l2acc", "l2conc", "c-#{i}", "v", %{"x-ms-meta-gen" => "0"})
      end

      writers =
        for w <- 1..20 do
          Task.async(fn ->
            for i <- 1..6, rem(i, 5) == rem(w, 5) do
              BlobStorage.put_blob("l2acc", "l2conc", "c-#{i}", "v#{w}", %{
                "x-ms-meta-gen" => Integer.to_string(w),
                "x-ms-meta-w" => String.duplicate("x", 200)
              })
            end
          end)
        end

      readers =
        for _ <- 1..10 do
          Task.async(fn ->
            for _ <- 1..20 do
              {xml, _} =
                BlobStorage.list_blobs_xml("l2acc", "l2conc", %{"include" => "metadata"})

              parsed =
                try do
                  {:parsed, :xmerl_scan.string(String.to_charlist(xml))}
                catch
                  :exit, _ -> :fatal
                end

              assert {:parsed, {{:xmlElement, :EnumerationResults, _, _, _, _, _, _, _, _, _, _}, _}} =
                       parsed

              assert xml =~ "<Name>c-1</Name>"

              for [block] <- Regex.scan(~r/<Blob>.*?<\/Blob>/s, xml) do
                has_meta = String.contains?(block, "<Metadata>")
                gen_val = block |> get_in_meta("gen")
                w_val = get_in_meta(block, "w")

                if has_meta do
                  assert gen_val != nil, "torn Metadata: no gen in #{inspect(block)}"

                  # seed state is {gen: "0", no w}; every writer swaps BOTH keys
                  # in one atomic row write — a gen != 0 without its sibling w is
                  # a torn read of a half-swapped row.
                  if gen_val != "0" do
                    assert w_val != nil,
                           "torn Metadata: gen=#{gen_val} without sibling w: #{inspect(block)}"
                  end
                end
              end
            end
          end)
        end

      Task.await_many(writers ++ readers, 60_000)

      assert {:ok, blob} = BlobStorage.get_blob("l2acc", "l2conc", "c-1")
      assert blob["headers"]["x-ms-meta-gen"] in Enum.map(1..20, &Integer.to_string/1)
    end

defp get_in_meta(block, key) do
      case Regex.run(Regex.compile!("<" <> key <> ">([^<]*)</" <> key <> ">"), block) do
        [_, v] -> v
        _ -> nil
      end
    end

        defp chain_pages(opts) do
      do_chain(Map.merge(%{"maxresults" => "5"}, opts), [], 0)
    end

    defp do_chain(opts, acc, n) when n < 20 do
      {xml, next} = BlobStorage.list_blobs_xml("l2acc", "l2cont", opts)
      acc = [xml | acc]

      case next do
        nil -> {:ok, Enum.reverse(acc), nil}
        next -> do_chain(Map.put(opts, "marker", next), acc, n + 1)
      end
    end

    defp do_chain(_opts, acc, _n), do: {:ok, Enum.reverse(acc), :overflow}
  end


  # ===========================================================================
  # Lens 2, cycle-36: delimiter+prefix+marker triple-compose property
  # ===========================================================================
  describe "lens2 triple-compose (prefix x delimiter x marker)" do
    setup :tc_setup

    def tc_setup(context) do
      SmaltTest.Lifecycle.ensure_store_up()
      Store.clear()
      BlobStorage.ensure_policy_table()
      :ets.delete_all_objects(:smalt_blob_policy)

      container("tc-acc", "tc-cont")

      names = [
        "a.txt", "b.txt", "d/1", "d/2", "d/sub/1", "d/sub/2", "d/sub/deep/x",
        "e.txt", "d-adjacent", "d-mar"
      ]

      for name <- names do
        BlobStorage.put_blob("tc-acc", "tc-cont", name, "v")
      end

      Map.put(context, :stored, Enum.sort(names))
    end

    # For a sample of (prefix, delimiter) pairs, a full marker chain must
    # partition the stored set exactly: visible blobs + names under each
    # BlobPrefix == the stored names under the prefix. Composed from the
    # cycle-35 property, not a new mechanism.
    test "full chain over (prefix, delimiter) pairs partitions the stored set", %{stored: stored} do
      prefixes = ["", "d", "d/", "d/sub/", "e", "zz"]
      delims = ["", "/", "sub"]

      for p <- prefixes, d <- delims do
        {pages, final} = chain_tc(%{"prefix" => p, "delimiter" => d})

        assert final == nil, "chain overflow for prefix=#{inspect(p)}, delimiter=#{inspect(d)}"

        {visible, bps} = collect_tc(pages)

        assert bps == Enum.uniq(bps), "duplicate BlobPrefix: #{inspect({p, d, bps})}"
        assert bps == Enum.sort(bps), "BlobPrefixes unordered: #{inspect({p, d, bps})}"
        assert visible == Enum.sort(visible), "blobs unordered: #{inspect({p, d, visible})}"

        hidden = Enum.flat_map(bps, fn bp -> Enum.filter(stored, &String.starts_with?(&1, bp)) end)
        expected = Enum.filter(stored, &String.starts_with?(&1, p))

        assert Enum.sort(visible ++ hidden) == expected,
               "partition violated for prefix=#{inspect(p)}, delimiter=#{inspect(d)}: " <>
                 "visible #{inspect(visible)} + prefixes #{inspect(bps)}"
      end
    end

    # Hostile delimiters: multi-char, XML-hostile, long and astral delimiters
    # never corrupt the enumeration; output stays well-formed and the
    # partition property still holds exactly.
    test "hostile delimiters are escaped and partition exactly", %{stored: stored} do
      delims = ["::", "<&>", String.duplicate("z", 100), "🎉"]

      for d <- delims do
        {pages, final} = chain_tc(%{"delimiter" => d})

        assert final == nil, "chain overflow for delimiter #{inspect(d)}"

        {visible, bps} = collect_tc(pages)

        assert bps == Enum.uniq(bps) and bps == Enum.sort(bps),
               "prefix set inconsistent for delimiter #{inspect(d)}: #{inspect(bps)}"

        hidden = Enum.flat_map(bps, fn bp -> Enum.filter(stored, &String.starts_with?(&1, bp)) end)

        assert Enum.sort(visible ++ hidden) == stored,
               "partition violated for delimiter #{inspect(d)}: bps #{inspect(bps)}"

        {single, _} = BlobStorage.list_blobs_xml("tc-acc", "tc-cont", %{"delimiter" => d})

        parsed =
          try do
            {:parsed, :xmerl_scan.string(String.to_charlist(single))}
          catch
            :exit, _ -> :fatal
          end

        assert {:parsed, {{:xmlElement, :EnumerationResults, _, _, _, _, _, _, _, _, _, _}, _}} =
                 parsed,
               "ill-formed XML for delimiter #{inspect(d)}"
      end
    end

    defp chain_tc(opts) do
      do_chain_tc(Map.merge(%{"maxresults" => "3"}, opts), [], 0)
    end

    defp do_chain_tc(opts, acc, n) when n < 40 do
      {xml, next} = BlobStorage.list_blobs_xml("tc-acc", "tc-cont", opts)
      acc = [xml | acc]

      case next do
        nil -> {Enum.reverse(acc), nil}
        next -> do_chain_tc(Map.put(opts, "marker", next), acc, n + 1)
      end
    end

    defp do_chain_tc(_opts, acc, _n), do: {Enum.reverse(acc), :overflow}

    defp collect_tc(pages) do
      Enum.reduce(pages, {[], []}, fn page, {v, b} ->
        v2 =
          Regex.scan(~r/<Blob>.*?<\/Blob>/s, page)
          |> Enum.flat_map(fn [blk] ->
            Regex.scan(~r/<Name>([^<]+)<\/Name>/, blk) |> Enum.map(&List.last/1)
          end)

        b2 =
          Regex.scan(~r/<BlobPrefix>\s*<Name>([^<]+)<\/Name>/, page)
          |> Enum.map(&List.last/1)

        {v ++ v2, b ++ b2}
      end)
    end
  end

  # ===========================================================================
  # Lens 2, cycle-37: delimiter x include=metadata compose
  # ===========================================================================
  describe "lens2 delimiter x metadata compose" do
    setup do
      container("dm-acc", "dm-cont")

      # metadata-bearing blob OUTSIDE any delimiter dir, inside one, and a
      # metadata-bearing blob hidden behind a BlobPrefix
      BlobStorage.put_blob("dm-acc", "dm-cont", "root.bin", "v", %{
        "x-ms-meta-zone" => "edge&<>"
      })

      BlobStorage.put_blob("dm-acc", "dm-cont", "d/a.bin", "v", %{
        "x-ms-meta-zone" => "inner"
      })

      BlobStorage.put_blob("dm-acc", "dm-cont", "d/b.bin", "v")

      :ok
    end

    test "delimiter listing with include=metadata: blobs keep metadata, BlobPrefixes have none" do
      {xml, _} =
        BlobStorage.list_blobs_xml("dm-acc", "dm-cont", %{
          "delimiter" => "/",
          "include" => "metadata"
        })

      # root blob: visible with its escaped metadata
      assert xml =~ "<Name>root.bin</Name>"
      assert xml =~ "<zone>edge&amp;&lt;&gt;</zone>"

      # hidden dir: BlobPrefix, no metadata decoration
      assert xml =~ "<BlobPrefix>\n    <Name>d/</Name>\n  </BlobPrefix>"
      assert xml =~ "<Name>d/</Name>"

      # the hidden blob's metadata must NOT leak under the prefix
      assert not (xml =~ "<zone>inner</zone>")

      # metadata-bearing blob hidden behind the prefix is fully rolled up
      assert not String.contains?(xml, "a.bin")

      # well-formed
      parsed =
        try do
          {:parsed, :xmerl_scan.string(String.to_charlist(xml))}
        catch
          :exit, _ -> :fatal
        end

      assert {:parsed, {{:xmlElement, :EnumerationResults, _, _, _, _, _, _, _, _, _, _}, _}} =
               parsed
    end
  end

  # ---------------------------------------------------------------------------
  # v26.10.14 lane 06 — container-list hardening (XML escape parity,
  # maxresults grammar, XML error envelope, prefix echo)
  # ---------------------------------------------------------------------------

  describe "lane 06 container-list hardening" do
    test "xml_escape/1 delegates to BlobStorage (astral parity)" do
      astral = "\u{1F5A8}"

      escaped = BlobService.xml_escape(astral)
      assert escaped == BlobStorage.xml_escape(astral)
      # numeric character reference, never raw 4-byte UTF-8
      assert escaped == "&#x1f5a8;"
      refute escaped =~ astral
    end

    test "container list emits numeric character references for astral names and parses under xmerl" do
      astral_name = "c-\u{1F5A8}"

      # Container names are refused at create (3-63 lowercase grammar), so the
      # astral row is seeded directly into the real Store to exercise the
      # enumeration renderer (same table/shape the create path writes).
      Store.put(:smalt_blob_containers, "acc1/#{astral_name}", %{
        "account" => "acc1",
        "container" => astral_name,
        "immutable" => true,
        "retention_days" => 1095,
        "created_at" => System.os_time(:millisecond),
        "created" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

      conn =
        :get
        |> conn("/acc1?comp=list")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/xml"
      # numeric character reference, not the raw 4-byte UTF-8 sequence
      assert conn.resp_body =~ "&#x1f5a8;"
      refute conn.resp_body =~ "\u{1F5A8}"

      parsed =
        try do
          {:parsed, :xmerl_scan.string(String.to_charlist(conn.resp_body))}
        catch
          :exit, _ -> :fatal
        end

      assert {:parsed, {{:xmlElement, :EnumerationResults, _, _, _, _, _, _, _, _, _, _}, _}} =
               parsed
    end

    test "container comp=list junk/zero/negative maxresults -> 400 XML InvalidQueryParameter envelope" do
      container()

      for junk <- ["abc", "0", "-1", "5x"] do
        conn =
          :get
          |> conn("/acc1?comp=list&maxresults=#{junk}")
          |> put_req_header("x-ms-version", "2021-12-02")
          |> router_call()

        assert conn.status == 400
        assert get_resp_header(conn, "x-ms-error-code") == ["InvalidQueryParameter"]
        assert get_resp_header(conn, "content-type") |> hd() =~ "application/xml"
        assert conn.resp_body =~ ~r/<Error>.*<Code>InvalidQueryParameter<\/Code>.*<\/Error>/s
      end

      # 5000 and absent still 200
      for qs <- ["", "&maxresults=5000"] do
        conn =
          :get
          |> conn("/acc1?comp=list#{qs}")
          |> put_req_header("x-ms-version", "2021-12-02")
          |> router_call()

        assert conn.status == 200
      end
    end

    test "blob comp=list junk maxresults -> 400 XML envelope + x-ms-error-code header" do
      container()

      conn =
        :get
        |> conn("/acc1/cont1?comp=list&maxresults=abc")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 400
      assert get_resp_header(conn, "x-ms-error-code") == ["InvalidQueryParameter"]
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/xml"
      assert conn.resp_body =~ ~r/<Error>.*<Code>InvalidQueryParameter<\/Code>.*<\/Error>/s
    end

    test "fast-path Prefix echo matches the composed path (plain vs prefix=\"\"+marker)" do
      container()

      BlobStorage.put_blob("acc1", "cont1", "pe-a", "1")
      BlobStorage.put_blob("acc1", "cont1", "pe-b", "2")

      {plain, nil} = BlobStorage.list_blobs_xml("acc1", "cont1", %{})
      {composed, _} = BlobStorage.list_blobs_xml("acc1", "cont1", %{"prefix" => "", "marker" => "a"})

      assert plain =~ ~r/<Prefix>[^<]*<\/Prefix>/

      plain_prefix = plain |> String.split("<Prefix>") |> Enum.at(1) |> String.split("</Prefix>") |> hd()
      composed_prefix = composed |> String.split("<Prefix>") |> Enum.at(1) |> String.split("</Prefix>") |> hd()

      assert plain_prefix == composed_prefix
    end

    test "non-list blob errors keep JSON envelope but gain x-ms-error-code header" do
      container()

      conn =
        :get
        |> conn("/acc1/cont1/nonexistent-blob")
        |> put_req_header("x-ms-version", "2021-12-02")
        |> router_call()

      assert conn.status == 404
      assert get_resp_header(conn, "x-ms-error-code") == ["BlobNotFound"]
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end
  end
end
