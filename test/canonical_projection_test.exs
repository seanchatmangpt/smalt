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
    # Baseline barrier (i29): this suite pins all six port keys with raw
    # Application.put_env (no SmaltTest.Env), so without the barrier the
    # twin's case_started baseline can race the pins (measured: the suite's
    # own pin set inside its own baseline, flagged as its own leak).
    :ok = SmaltTest.IsolationFormatter.sync()

    free_port = fn ->
      {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(sock)
      :gen_tcp.close(sock)
      port
    end

    # AZB-11b / i29: snapshot ALL six keys the suite pins. The comment here
    # already claimed "all six" but the code listed only [:mcp_port], leaving
    # the other five at this suite's random pins for the rest of the run
    # (the twin leak class `arm_port`/`arm_tls_port`/`egress_port`/`amqp_port`/
    # `event_hubs_port`).
    prev_ports =
      SmaltTest.PortEnv.snapshot([
        :arm_port,
        :arm_tls_port,
        :egress_port,
        :amqp_port,
        :event_hubs_port,
        :mcp_port
      ])

    for key <- [:arm_port, :arm_tls_port, :egress_port, :amqp_port, :event_hubs_port, :mcp_port] do
      Application.put_env(:smalt, key, free_port.())
    end

    {:ok, _} = Application.ensure_all_started(:smalt)

    # This suite boots the app on its own pinned free-port set (above), so the
    # teardown must be a true reboot: stop the tree, restore the config-time
    # port env, and start the app back on those restored values so listeners
    # and env agree for every downstream module (i29 ordering law, below).
    on_exit(fn ->
      # i29 ordering law: restore the env FIRST, then boot the app on the
      # restored values. The previous order (restore_app pins the Lifecycle
      # shifted ports and starts, THEN PortEnv.restore) left env claiming
      # config-time ports while the fresh listeners held the shifted set —
      # every downstream wire client (Azsim DrScenarios) connected to ports
      # with no listener (measured: 4 scenario failures, connect-class).
      Application.stop(:smalt)
      SmaltTest.PortEnv.restore(prev_ports)
      {:ok, _} = Application.ensure_all_started(:smalt)
      SmaltTest.Lifecycle.ensure_store_up()
    end)

    :ok
  end

  # The token grep runs against the rendered doc with every admitted resource
  # type string REMOVED first: the ARM noun "vaults/secrets" is a resource-type
  # name, not a leaked internal token, and would otherwise false-positive the
  # bare "secret" ban while real leaks (connectionString, clientSecret, ...)
  # stay fenced.
  defp scrub_type_literals(text) do
    text
    |> then(fn t ->
      Enum.reduce(
        Enum.sort_by(Smalt.Registry.admitted_resource_types(), &byte_size/1, :desc),
        t,
        fn type, acc -> String.replace(acc, type, "") end
      )
    end)
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
               "amqp" => Smalt.Registry.amqp_port_default(),
               "eventHubs" => round(Smalt.Registry.event_hubs_port_default())
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
      # byte-equal except the self digest, which json/0 fills in over the
      # doc-without-the-key (fenced separately below); capability_document/0
      # carries the nil placeholder slot, popped on both sides here.
      decoded = Jason.decode!(Canonical.json())

      assert pop_in(decoded, ["identity", "contentSha256"]) |> elem(1) ==
               pop_in(Canonical.capability_document(), ["identity", "contentSha256"]) |> elem(1)
    end
  end

  describe "THIRD_PARTY rider (E4 #6/#5b)" do
    test "docs/THIRD_PARTY.md equals third_party_markdown/0 byte-for-byte" do
      path = Path.expand(Canonical.third_party_doc_path(), File.cwd!())

      assert File.exists?(path),
             "#{Canonical.third_party_doc_path()} missing — run Canonical.write/0"

      assert File.read!(path) == Canonical.third_party_markdown(),
             "docs/THIRD_PARTY.md is stale vs mix.lock truth — run Canonical.write/0"
    end

    test "third_party rows cover every mix.lock entry with full shape" do
      packages = Canonical.third_party_packages()
      assert length(packages) == map_size(Mix.Dep.Lock.read())

      for p <- packages do
        assert is_binary(p["name"]) and p["name"] != ""
        assert is_binary(p["version"]) and p["version"] != ""
        assert is_binary(p["license"]) and p["license"] != ""
        assert p["origin"] in ["hex.pm", "path", "git", "unknown"]
      end
    end

    test "rows are sorted by name and unique" do
      names = Enum.map(Canonical.third_party_packages(), & &1["name"])
      assert names == Enum.sort(names)
      assert length(names) == MapSet.new(names) |> MapSet.size()
    end

    test "hex deps are marked hex.pm; the rustler dual license renders explicitly" do
      packages = Canonical.third_party_packages()
      by_name = Map.new(packages, &{&1["name"], &1})

      # every lock entry currently resolves to hex.pm
      for p <- packages, do: assert(p["origin"] == "hex.pm")

      assert by_name["rustler"]["license"] == "MIT / Apache-2.0 (dual)"
    end

    test "no copyleft license token in the license surface" do
      # The prose footer names the banned families in the negative ("no
      # copyleft (GPL/AGPL/...)"), so the fence binds over the DATA rows —
      # every license value — not the prose.
      for p <- Canonical.third_party_packages() do
        for token <- ["GPL", "AGPL", "LGPL", "MPL", "EPL"] do
          refute p["license"] =~ token,
                 "copyleft token #{token} in license of #{p["name"]}"
        end
      end
    end
  end

  describe "identity block (E4 #5b)" do
    test "shape: packLockSha256, semanticEpoch, contentSha256" do
      identity = Canonical.json() |> Jason.decode!() |> get_in(["identity"])

      assert is_binary(identity["semanticEpoch"]) and identity["semanticEpoch"] != ""
      assert is_binary(identity["packLockSha256"])
      assert Regex.match?(~r/^[0-9a-f]{64}$/, identity["packLockSha256"])
      assert is_binary(identity["contentSha256"])
      assert Regex.match?(~r/^[0-9a-f]{64}$/, identity["contentSha256"])
    end

    test "packLockSha256 is the sha256 of ggen_igniter.pack.lock bytes" do
      expected =
        :crypto.hash(:sha256, File.read!("ggen_igniter.pack.lock"))
        |> Base.encode16(case: :lower)

      assert Canonical.capability_document()["identity"]["packLockSha256"] == expected
    end

    test "contentSha256 recomputes from the doc with the key removed" do
      doc = Canonical.capability_document() |> pop_in(["identity", "contentSha256"]) |> elem(1)

      expected =
        doc
        |> sort_keys()
        |> Jason.encode!(pretty: true, indent: "  ")
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert Canonical.json() |> Jason.decode!() |> get_in(["identity", "contentSha256"]) ==
               expected
    end

    test "the content digest is content-sensitive (a mutated doc changes it)" do
      # The non-vacuity half: the digest must actually track doc content,
      # not be a constant stamped on every render.
      doc = Canonical.capability_document() |> pop_in(["identity", "contentSha256"]) |> elem(1)
      [first_cap | _] = doc["capabilities"]

      mutated =
        put_in(doc, ["capabilities"], [
          %{first_cap | "type" => "mutated/type"} | doc["capabilities"] -- [first_cap]
        ])

      digest_of = fn d ->
        d
        |> sort_keys()
        |> Jason.encode!(pretty: true, indent: "  ")
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
      end

      refute digest_of.(doc) == digest_of.(mutated)
    end
  end

  defp sort_keys(term) when is_map(term) do
    term |> Enum.map(fn {k, v} -> {to_string(k), sort_keys(v)} end) |> Map.new()
  end

  defp sort_keys(term) when is_list(term), do: Enum.map(term, &sort_keys/1)
  defp sort_keys(term), do: term

  describe "public projection hides internals (grep fence)" do
    test "rendered doc contains no banned internal tokens" do
      rendered = scrub_type_literals(Canonical.json())

      for token <- @banned_tokens do
        refute rendered =~ token,
               "public capability doc leaks internal token #{inspect(token)}"
      end
    end

    test "on-disk doc contains no banned internal tokens" do
      path = Path.expand(Canonical.doc_path(), File.cwd!())
      on_disk = scrub_type_literals(File.read!(path))

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
