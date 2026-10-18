defmodule Smalt.DataPlane.BlobServiceTest do
  use ExUnit.Case, async: false

  # Shifted ports so the suite can run while a live smalt instance holds
  # 8443/9443. No-op when the app is already started (full-suite runs).
  unless :ets.info(:smalt_blobs) != :undefined do
    Enum.each(SmaltTest.Lifecycle.shifted_envs(), fn {k, v} ->
      Application.put_env(:smalt, k, v)
    end)

    {:ok, _} = Application.ensure_all_started(:smalt)
  end

  # `mix test` prunes the code path relative to `mix run` and may drop the
  # xmerl OTP app entirely; re-add it so :xmerl_sax_parser is loadable.
  case :code.which(:xmerl_sax_parser) do
    :non_existing ->
      ebin =
        :code.lib_dir()
        |> to_string()
        |> then(&Path.wildcard(Path.join(&1, "xmerl-*/ebin")))
        |> List.first()

      true = Code.prepend_path(ebin)
      {:ok, _} = Application.ensure_all_started(:xmerl)

    _path ->
      :ok
  end

  alias Smalt.DataPlane.{BlobService, BlobStorage}

  @account "acc1"

  setup do
    # Canonical resilient shared-Store setup (v26.10.18): replaces the bare
    # ensure_store_up(); Store.clear() window (FLAKE_LEDGER F2-F5/F10).
    SmaltTest.Store.resilient_setup()
    BlobStorage.ensure_policy_table()
    :ets.delete_all_objects(:smalt_blob_policy)
    :ok
  end

  defp container(name, opts \\ %{}) do
    {:ok, _} = BlobStorage.create_container(@account, name, Map.put_new(opts, "immutable", false))
    name
  end

  # ---------------------------------------------------------------------------
  # List containers
  # ---------------------------------------------------------------------------

  describe "list_containers/2" do
    test "paginates 120 containers: 3 pages (50/50/20), markers chain correctly" do
      for i <- 1..120 do
        container("c" <> String.pad_leading(Integer.to_string(i), 4, "0"))
      end

      {:ok, page1} = BlobService.list_containers(@account, %{"maxresults" => "50"})
      assert length(page1["containers"]) == 50
      assert page1["next_marker"] == "c0050"

      {:ok, page2} =
        BlobService.list_containers(@account, %{
          "maxresults" => "50",
          "marker" => page1["next_marker"]
        })

      assert length(page2["containers"]) == 50
      assert page2["next_marker"] == "c0100"

      {:ok, page3} =
        BlobService.list_containers(@account, %{
          "maxresults" => "50",
          "marker" => page2["next_marker"]
        })

      assert length(page3["containers"]) == 20
      assert page3["next_marker"] == nil

      names =
        Enum.map(
          page1["containers"] ++ page2["containers"] ++ page3["containers"],
          & &1["container"]
        )

      assert length(Enum.uniq(names)) == 120
      assert names == Enum.sort(names)
      assert List.first(names) == "c0001"
      assert List.last(names) == "c0120"
    end

    test "default page size is 50 and caps at 50" do
      for i <- 1..60, do: container("c" <> String.pad_leading(Integer.to_string(i), 3, "0"))

      {:ok, default} = BlobService.list_containers(@account)
      assert length(default["containers"]) == 50
      assert default["next_marker"] == "c050"

      {:ok, over} = BlobService.list_containers(@account, %{"maxresults" => "5000"})
      assert length(over["containers"]) == 50
    end

    test "prefix filter applies before pagination" do
      for i <- 1..10, do: container("data" <> String.pad_leading(Integer.to_string(i), 2, "0"))
      for i <- 1..10, do: container("logs" <> String.pad_leading(Integer.to_string(i), 2, "0"))

      {:ok, result} = BlobService.list_containers(@account, %{"prefix" => "logs"})
      assert length(result["containers"]) == 10
      assert Enum.all?(result["containers"], &String.starts_with?(&1["container"], "logs"))
      assert result["next_marker"] == nil
    end

    test "marker is exclusive (marker = last name of previous page)" do
      container("pg1")
      container("pg2")
      container("pg3")

      {:ok, page1} = BlobService.list_containers(@account, %{"maxresults" => "2"})
      assert Enum.map(page1["containers"], & &1["container"]) == ["pg1", "pg2"]
      assert page1["next_marker"] == "pg2"

      {:ok, page2} = BlobService.list_containers(@account, %{"marker" => "pg2"})
      assert Enum.map(page2["containers"], & &1["container"]) == ["pg3"]
    end

    test "returns empty page for unknown account" do
      assert {:ok, %{"containers" => [], "next_marker" => nil}} =
               BlobService.list_containers("nope")
    end
  end

  describe "list_containers_xml/2" do
    test "well-formed XML parseable by :xmerl_sax_parser" do
      container("alpha")
      container("beta")

      {xml, next_marker} = BlobService.list_containers_xml(@account)
      assert next_marker == nil
      assert xml =~ ~s(<?xml version="1.0" encoding="utf-8"?>)
      assert xml =~ "<EnumerationResults"
      assert xml =~ "<Name>alpha</Name>"
      assert xml =~ "<Name>beta</Name>"

      :xmerl_sax_parser.stream(xml, [])
    end

    test "emits NextMarker element when more pages remain" do
      for i <- 1..55, do: container("c" <> String.pad_leading(Integer.to_string(i), 3, "0"))

      {xml, next_marker} = BlobService.list_containers_xml(@account)
      assert next_marker == "c050"
      assert xml =~ "<NextMarker>c050</NextMarker>"

      {:ok, _} = BlobService.list_containers(@account, %{"marker" => next_marker})
      {xml2, nil} = BlobService.list_containers_xml(@account, %{"marker" => next_marker})
      assert xml2 =~ "<NextMarker />"
      :xmerl_sax_parser.stream(xml2, [])
    end

    test "Pagination + XML end-to-end: 120 containers, 3 pages, all well-formed" do
      for i <- 1..120 do
        container("c" <> String.pad_leading(Integer.to_string(i), 4, "0"))
      end

      {xml1, m1} = BlobService.list_containers_xml(@account)
      {xml2, m2} = BlobService.list_containers_xml(@account, %{"marker" => m1})
      {xml3, m3} = BlobService.list_containers_xml(@account, %{"marker" => m2})

      assert m3 == nil
      Enum.each([xml1, xml2, xml3], &:xmerl_sax_parser.stream(&1, []))

      names =
        Enum.flat_map([xml1, xml2, xml3], fn xml ->
          {:ok, names, _} =
            :xmerl_sax_parser.stream(xml, event_fun: &sax_collect/3, event_state: [])

          Enum.reverse(names)
        end)

      assert length(names) == 120
      assert names == Enum.sort(names)
      assert List.first(names) == "c0001"
      assert List.last(names) == "c0120"
    end
  end

  # ---------------------------------------------------------------------------
  # Container metadata
  # ---------------------------------------------------------------------------

  describe "container metadata" do
    test "PUT ?comp=metadata round-trips via GET" do
      container("meta1")

      assert {:ok, 200, headers} =
               BlobService.set_container_metadata(@account, "meta1", %{
                 "team" => "platform",
                 "env" => "prod"
               })

      assert headers["x-ms-request-id"]
      assert headers["etag"] =~ ~r/^"[0-9A-F]{32}"$/

      assert {:ok, %{"team" => "platform", "env" => "prod"}} =
               BlobService.get_container_metadata(@account, "meta1")
    end

    test "PUT replaces (not merges) prior metadata" do
      container("meta2")

      {:ok, 200, _} = BlobService.set_container_metadata(@account, "meta2", %{"old" => "1"})
      {:ok, 200, _} = BlobService.set_container_metadata(@account, "meta2", %{"new" => "2"})

      assert {:ok, %{"new" => "2"}} = BlobService.get_container_metadata(@account, "meta2")
      assert {:ok, meta} = BlobService.get_container_metadata(@account, "meta2")
      refute Map.has_key?(meta, "old")
    end

    test "metadata visible as x-ms-meta-* headers in properties" do
      container("meta3")
      {:ok, 200, _} = BlobService.set_container_metadata(@account, "meta3", %{"owner" => "sre"})

      assert {:ok, 200, props} = BlobService.get_container_properties(@account, "meta3")
      assert props["x-ms-meta-owner"] == "sre"
    end

    test "404 for missing container" do
      assert {:error, 404, "ContainerNotFound", _} =
               BlobService.set_container_metadata(@account, "ghost", %{"a" => "b"})

      assert {:error, 404, "ContainerNotFound", _} =
               BlobService.get_container_metadata(@account, "ghost")
    end

    test "metadata survives legal hold / policy writes (shared policy row)" do
      container("meta4")
      {:ok, 200, _} = BlobService.set_container_metadata(@account, "meta4", %{"k" => "v"})
      {:ok, 200, _, _} = BlobStorage.set_legal_hold(@account, "meta4", true)

      assert {:ok, %{"k" => "v"}} = BlobService.get_container_metadata(@account, "meta4")
      assert %{true => _} = %{BlobStorage.get_policy(@account, "meta4")["legal_hold"] => :ok}
    end
  end

  # ---------------------------------------------------------------------------
  # Container properties
  # ---------------------------------------------------------------------------

  describe "get_container_properties/2" do
    test "returns ETag, Last-Modified, WORM flags" do
      container("props1")

      assert {:ok, 200, props} = BlobService.get_container_properties(@account, "props1")
      assert props["etag"] =~ ~r/^"[0-9A-F]{32}"$/
      assert props["last-modified"]
      assert props["x-ms-has-immutability-policy"] == "false"
      assert props["x-ms-has-legal-hold"] == "false"
      assert props["x-ms-request-id"]
      assert props["x-ms-version"] == "2021-12-02"
    end

    test "WORM flags flip true after policy actions" do
      container("props2")

      {:ok, 200, _, _} = BlobStorage.set_legal_hold(@account, "props2", true)
      assert {:ok, 200, props} = BlobService.get_container_properties(@account, "props2")
      assert props["x-ms-has-legal-hold"] == "true"
      assert props["x-ms-has-immutability-policy"] == "false"

      {:ok, 200, _, _} =
        BlobStorage.set_immutability_policy(@account, "props2", %{"period_days" => 30})

      assert {:ok, 200, props2} = BlobService.get_container_properties(@account, "props2")
      assert props2["x-ms-has-immutability-policy"] == "true"
    end

    test "default (immutable) container reports false flags without policy rows" do
      {:ok, _} = BlobStorage.create_container(@account, "props3")
      assert {:ok, 200, props} = BlobService.get_container_properties(@account, "props3")
      assert props["x-ms-has-immutability-policy"] == "false"
      assert props["x-ms-has-legal-hold"] == "false"
    end

    test "ETag is stable across calls" do
      container("props4")
      {:ok, 200, h1} = BlobService.get_container_properties(@account, "props4")
      {:ok, 200, h2} = BlobService.get_container_properties(@account, "props4")
      assert h1["etag"] == h2["etag"]
    end

    test "404 for missing container" do
      assert {:error, 404, "ContainerNotFound", _} =
               BlobService.get_container_properties(@account, "ghost")
    end
  end

  # ---------------------------------------------------------------------------
  # SAX helper
  # ---------------------------------------------------------------------------

  # SAX event accumulator: captures <Name> character data.
  defp sax_collect({:startElement, _, ~c"Name", _, _}, _location, state),
    do: [:in_name | state]

  defp sax_collect({:characters, chars}, _location, [:in_name | state]),
    do: [to_string(chars) | state]

  defp sax_collect({:endElement, _, ~c"Name", _}, _location, state),
    do: List.delete(state, :in_name)

  defp sax_collect(_event, _location, state), do: state
end
