defmodule Smalt.CanonicalProjectionTest do
  @moduledoc """
  Fence tests for the canonical PUBLIC projection surface.

  1. No-drift: the committed `docs/capabilities.json` equals Registry-derived
     truth at test time (generated artifact cannot go stale silently).
  2. Public-only: no Store keys, table names, or secret-shaped tokens in the
     rendered doc or its source (grep fence).
  3. The Ash read surface returns exactly Registry truth.
  """

  use ExUnit.Case, async: false

  alias Smalt.Projection.Canonical

  # The suite boots Smalt.Application with the suite's ephemeral listeners,
  # but :mcp_port (9545 default) has no SMALT_TEST_* override and a concurrent
  # lane's keeper can hold 9545. Start the app here (mix test --no-start) on a
  # fully pinned free-port set instead.
  setup_all do
    free_port = fn ->
      {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(sock)
      :gen_tcp.close(sock)
      port
    end

    for key <- [:arm_port, :arm_tls_port, :egress_port, :amqp_port, :event_hubs_port, :mcp_port] do
      Application.put_env(:smalt, key, free_port.())
    end

    {:ok, _} = Application.ensure_all_started(:smalt)

    on_exit(fn ->
      Application.stop(:smalt)
    end)

    :ok
  end

  @banned_tokens [
    # Secret-shaped tokens
    "connectionString",
    "accountKey",
    "primaryKey",
    "sharedKey",
    "sharedAccessKey",
    "clientSecret",
    "password",
    "secret",
    "sas",
    # Store internals (public surface must not name Store tables/keys)
    "smalt_resources",
    "smalt_ledger_transactions",
    ":smalt_store",
    "Smalt.Store"
  ]

  describe "capability document == Registry-derived truth" do
    test "types match the Registry exactly (set + count)" do
      doc = Canonical.capability_document()
      doc_types = doc["capabilities"] |> Enum.map(& &1["type"]) |> Enum.sort()

      assert doc_types == Enum.sort(Smalt.Registry.admitted_resource_types())
    end

    test "per-type shape and apiVersion match the Registry" do
      for cap <- Canonical.capability_document()["capabilities"] do
        type = cap["type"]

        assert cap["shape"] == Smalt.Registry.shape_for(type)
        assert cap["apiVersion"] == Smalt.Registry.latest_version(type)
      end
    end

    test "capabilities are deterministically ordered (Registry order)" do
      assert Enum.map(Canonical.capability_document()["capabilities"], & &1["type"]) ==
               Smalt.Registry.admitted_resource_types()
    end

    test "endpoints match Registry plane ports" do
      endpoints = Canonical.capability_document()["endpoints"]

      assert endpoints == %{
               "controlPlane" => Smalt.Registry.control_plane_port(),
               "dataPlane" => Smalt.Registry.data_plane_port(),
               "amqp" => Smalt.Registry.amqp_port(),
               "eventHubs" => round(Smalt.Registry.event_hubs_port())
             }
    end

    test "every admitted type is present (no silent subset)" do
      doc_types = MapSet.new(Canonical.capability_document()["capabilities"], & &1["type"])

      for type <- Smalt.Registry.admitted_resource_types() do
        assert MapSet.member?(doc_types, type), "missing admitted type in public doc: #{type}"
      end
    end
  end

  describe "generated artifact drift fence" do
    test "docs/capabilities.json equals rendered json/0" do
      path = Path.expand(Canonical.doc_path(), File.cwd!())
      assert File.exists?(path), "#{Canonical.doc_path()} missing — run Canonical.write/0"

      on_disk = File.read!(path) |> String.trim_trailing()
      assert on_disk == Canonical.json(), "docs/capabilities.json is stale vs Registry truth"
    end

    test "rendered JSON round-trips to the capability document" do
      doc = Canonical.capability_document()
      assert Jason.decode!(Canonical.json()) == doc
    end
  end

  describe "public projection hides internals (grep fence)" do
    test "rendered doc contains no banned internal tokens" do
      rendered = Canonical.json()

      for token <- @banned_tokens do
        refute rendered =~ token,
               "public capability doc leaks internal token #{inspect(token)}"
      end
    end

    test "on-disk doc contains no banned internal tokens" do
      path = Path.expand(Canonical.doc_path(), File.cwd!())
      on_disk = File.read!(path)

      for token <- @banned_tokens do
        refute on_disk =~ token,
               "docs/capabilities.json leaks internal token #{inspect(token)}"
      end
    end
  end

  describe "Ash read surface over the Registry" do
    test "read returns exactly one entry per admitted type with Registry attrs" do
      assert {:ok, rows} =
               Canonical.Entry
               |> Ash.Query.for_read(:read)
               |> Ash.read()

      assert length(rows) == length(Smalt.Registry.admitted_resource_types())

      by_type = Map.new(rows, &{&1.type, &1})

      for type <- Smalt.Registry.admitted_resource_types() do
        entry = Map.fetch!(by_type, type)
        assert entry.shape == Smalt.Registry.shape_for(type)
        assert entry.api_version == Smalt.Registry.latest_version(type)
      end
    end

    test "surface is read-only (no create/update/destroy actions)" do
      actions = Ash.Resource.Info.actions(Canonical.Entry)
      assert [%{name: :read, type: :read}] = actions
      assert length(actions) == 1
    end
  end
end
