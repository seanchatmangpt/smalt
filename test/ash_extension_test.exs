# Lane: ash-extension. Gate: mix test test/ash_extension_test.exs
# Receipt: docs/PACK_INTEGRATION/ash-extension.md
#
# Run mode: `MIX_ENV=test mix test --no-start test/ash_extension_test.exs`.
# The full smalt app boots an MCP listener on FIXED port 9545
# (lib/smalt/application.ex:24, no test-exs probe), which collides with any
# concurrent substrate keeper on this shared checkout (eaddrinuse before any
# test runs). --no-start + in-suite boot of only what this suite needs
# (Store + :ash/:spark) keeps the gate runnable alongside other lanes.
#
# Compile-time Ash config, same idiom (and same reason) as the semantic
# projection resources: config/config.exs is outside this lane's owned files.
Application.put_env(:ash, :default_string_length_count, :codepoints, persistent: true)

defmodule SmaltTest.AshExtension.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SmaltTest.AshExtension.Probe)
  end
end

defmodule SmaltTest.AshExtension.Probe do
  @moduledoc """
  Test resource carrying the manufactured `substrate_resource` extension:
  Store-backed manual read over `:smalt_resources`, private matter scope.
  """
  use Ash.Resource,
    domain: SmaltTest.AshExtension.Domain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [Smalt.AshExtension.SubstrateResource]

  attributes do
    attribute(:id, :string, allow_nil?: false, primary_key?: true, public?: true)
    attribute(:name, :string, public?: true)
  end

  actions do
    read :read do
      manual(Smalt.AshExtension.SubstrateResource.ManualRead)
      primary?(true)
    end
  end

  substrate do
    store_table(:smalt_resources)
    matter_scope([:private])
  end
end

defmodule Smalt.AshExtensionTest do
  use ExUnit.Case, async: false

  alias Smalt.AshExtension.SubstrateResource.Info
  alias Smalt.Store

  setup do
    {:ok, _} = Application.ensure_all_started(:ash)

    if Process.whereis(Store) == nil do
      start_supervised!(Store)
    end

    :ok
  end

  # Builds a full specimen source: its own inline Ash.Domain (so Ash's
  # domain-inclusion check cannot shadow this extension's verifier refusals)
  # plus one resource carrying the extension.
  defp specimen(name, actions, substrate) do
    id = System.unique_integer([:positive])

    """
    defmodule SmaltTest.AshExtension.Refused.#{name}Domain#{id} do
      use Ash.Domain, validate_config_inclusion?: false
      resources do
        resource SmaltTest.AshExtension.Refused.#{name}#{id}
      end
    end

    defmodule SmaltTest.AshExtension.Refused.#{name}#{id} do
      use Ash.Resource,
        domain: SmaltTest.AshExtension.Refused.#{name}Domain#{id},
        data_layer: Ash.DataLayer.Simple,
        extensions: [Smalt.AshExtension.SubstrateResource]

      attributes do
        attribute(:id, :string, allow_nil?: false, primary_key?: true, public?: true)
      end

      actions do
        #{actions}
      end

      #{substrate}
    end
    """
  end


  # Specimen refusal: a Spark verifier failure during `Code.compile_string/1`
  # can surface as an async parallel-checker crash rather than a synchronous
  # raise (Elixir 1.19), so the refusal is witnessed as EITHER a raised
  # Spark.Error.DslError matching `re` OR a captured error diagnostic whose
  # message matches `re`. A clean compile with neither = vacuous verifier.
  defp compile_refused(source, re) do
    {outcome, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          Code.compile_string(source)
          :compiled_clean
        rescue
          e -> {:raised, e}
        end
      end)

    raised? =
      case outcome do
        {:raised, e} ->
          struct_name = e.__struct__ |> Module.split() |> Enum.join(".")
          struct_name == "Spark.Error.DslError" and Regex.match?(re, Exception.message(e))

        _ ->
          false
      end

    diagnostic? =
      Enum.any?(diagnostics, fn d ->
        d.severity in [:error, :warning] and Regex.match?(re, d.message)
      end)

    assert raised? or diagnostic?,
           "expected refusal matching #{inspect(re)} -- got outcome=#{inspect(outcome)} " <>
             "diagnostics=#{inspect(Enum.map(diagnostics, &{&1.severity, &1.message}))}"
  end

  describe "extension compiles into a test resource" do
    test "compiled extension state is present with the declared configuration" do
      assert Info.compiled?(SmaltTest.AshExtension.Probe)
      assert Info.store_table(SmaltTest.AshExtension.Probe) == :smalt_resources
      assert Info.matter_scope(SmaltTest.AshExtension.Probe) == [:private]
      assert Info.compiled!(SmaltTest.AshExtension.Probe).metadata == %{source: :smalt_store_read}
    end

    test "info getters return not_compiled for a resource without the extension" do
      assert {:error, :not_compiled} = Info.store_table_result(Smalt.Semantic.Resource)
      refute Info.compiled?(Smalt.Semantic.Resource)
    end
  end

  describe "verifier" do
    test "accepts the legal probe resource (no compile-time refusal)" do
      assert Code.ensure_loaded?(SmaltTest.AshExtension.Probe)
    end

    test "refuses a resource with a non-read action (matter-isolation read-only surface)" do
      source =
        specimen(
          "Write",
          """
          default_accept []
          create :create
          read :read do
            manual(Smalt.AshExtension.SubstrateResource.ManualRead)
            primary?(true)
          end
          """,
          """
          substrate do
            store_table(:smalt_resources)
          end
          """
        )

      compile_refused(source, ~r/read-only/)
    end

    test "refuses a store_table outside the smalt_ Store namespace" do
      source =
        specimen(
          "Table",
          """
          read :read do
            manual(Smalt.AshExtension.SubstrateResource.ManualRead)
            primary?(true)
          end
          """,
          """
          substrate do
            store_table(:bogus_table)
          end
          """
        )

      compile_refused(source, ~r/smalt_ Store table namespace/)
    end

    test "refuses a matter_scope outside the vocabulary" do
      source =
        specimen(
          "Scope",
          """
          read :read do
            manual(Smalt.AshExtension.SubstrateResource.ManualRead)
            primary?(true)
          end
          """,
          """
          substrate do
            store_table(:smalt_resources)
            matter_scope([:secret])
          end
          """
        )

      compile_refused(source, ~r/matter_scope/)
    end
  end

  describe "Store-backed read projection" do
    test "projects a seeded Store row into the resource with matter-scope metadata" do
      uid = "aex-probe-#{System.unique_integer([:positive])}"

      Store.put(:smalt_resources, uid, %{
        "id" => uid,
        "name" => "aex-probe-resource",
        "matter" => "payload-that-must-not-leak"
      })

      projected = Enum.find(Ash.read!(SmaltTest.AshExtension.Probe), &(&1.id == uid))

      assert projected, "seeded Store row not projected through the extension read path"
      assert projected.name == "aex-probe-resource"
      assert projected.__metadata__.matter_scope == [:private]
    end

    test "absent row keys project as nil, never raise" do
      uid = "aex-probe-nil-#{System.unique_integer([:positive])}"
      Store.put(:smalt_resources, uid, %{"id" => uid})

      projected = Enum.find(Ash.read!(SmaltTest.AshExtension.Probe), &(&1.id == uid))

      assert projected
      assert projected.name == nil
    end

    @tag :churn
    test "manual_read under concurrent Store churn: no crash, valid rows, consistent snapshot" do
      uid = fn k -> "aex-churn-#{k}-#{System.unique_integer([:positive])}" end

      rows =
        Map.new(1..40, fn k ->
          key = uid.(k)

          value = %{
            "id" => key,
            "name" => "churn-#{k}",
            "matter" => "m-#{k}"
          }

          Store.put(:smalt_resources, key, value)
          {key, value}
        end)

      # 8 writer tasks mutate (overwrite / delete) for ~200ms while 16 reader
      # tasks run real Ash.read! through ManualRead over the SAME table.
      stop = System.monotonic_time(:millisecond) + 200
      key_of = fn k, n -> "aex-churn-#{k}-#{n}" end
      run = System.unique_integer([:positive])

      writers =
        for w <- 1..8 do
          Task.async(fn ->
            keys = Map.new(1..40, fn k -> {k, key_of.(k, run)} end)

            Enum.each(churn_window(stop), fn _ ->
              k = :rand.uniform(40)

              case :rand.uniform(3) do
                n when n in [1, 2] ->
                  key = Map.fetch!(keys, k)

                  Store.put(:smalt_resources, key, %{
                    "id" => key,
                    "name" => "churn-#{k}-w#{w}",
                    "value" => "v"
                  })

                _ ->
                  Store.delete(:smalt_resources, Map.fetch!(keys, k))
              end
            end)
          end)
        end

      readers =
        for _ <- 1..16 do
          Task.async(fn ->
            reads =
              Enum.map(churn_window(stop + 50), fn _ ->
                Enum.count(Ash.read!(SmaltTest.AshExtension.Probe), fn row ->
                  String.starts_with?(row.id || "", "aex-churn-")
                end)
              end)

            # Torn-row fence (lens-2 cycle 1): every writer's value embeds its
            # own key (`churn-<k>...`), and ManualRead projects id and name
            # from the SAME ETS row in one pass. So mid-flight, a churn row's
            # name must belong to its own id's key — a torn projection (id
            # from one row generation, name from another) breaks the pairing
            # and fails here. ETS per-key atomicity makes this safe by
            # construction; the fence pins that invariant so a future
            # ManualRead change (e.g. multi-pass row assembly) cannot
            # introduce torn reads silently.
            for row <- Ash.read!(SmaltTest.AshExtension.Probe) do
              case row.id && String.split(row.id, "-") do
                ["aex", "churn", k, _run] ->
                  assert row.name == "churn-#{k}" or
                           (is_binary(row.name) and
                              Regex.match?(~r/^churn-#{k}-w\d$/, row.name || "")),
                         "torn projected row: id=#{row.id} name=#{inspect(row.name)}"

                _ ->
                  :ok
              end
            end

            length(reads)
          end)
        end

      Task.await_many(writers, 30_000)
      reader_counts = Task.await_many(readers, 30_000)
      assert Enum.sum(reader_counts) > 0, "no concurrent reads actually executed"

      # Post-churn consistency: for every churn key still in the Store, the
      # projection shows exactly the Store row (no phantom, no divergence).
      for k <- 1..40 do
        key = key_of.(k, run)

        case Store.get(:smalt_resources, key) do
          :error ->
            :ok

          {:ok, row} ->
            projected =
              Enum.find(Ash.read!(SmaltTest.AshExtension.Probe), &(&1.id == key))

            assert projected, "Store row \#{key} exists but was not projected"
            assert projected.name == row["name"]
        end
      end
    end
  end

  defp churn_window(stop) do
    Stream.take_while(Stream.iterate(0, &(&1 + 1)), fn _ ->
      System.monotonic_time(:millisecond) < stop
    end)
  end
  # Lens-2 cycle 4: boundary crash class on the read path. Store is an
  # untyped key-value table; ManualRead.build/2 has an is_map guard, so a
  # non-map value under a :smalt_resources key crashed the WHOLE Ash read
  # with FunctionClauseError — the exact class lens-1 closed at the ledger
  # boundaries (never a crash, never silent-empty). Same discipline: a
  # malformed row refuses the read typed.
  test "non-map Store row refuses the read typed, never crashes" do
    uid = "aex-nonmap-#{System.unique_integer([:positive])}"
    Store.put(:smalt_resources, uid, 42)
    Store.put(:smalt_resources, uid <> "-ok", %{"id" => uid <> "-ok", "name" => "n"})

    assert {:error, %Ash.Error.Unknown{} = err} =
             Ash.read(SmaltTest.AshExtension.Probe)

    text = Exception.message(err) <> inspect(err.errors)
    assert text =~ "non-map Store row"
    Store.delete(:smalt_resources, uid)
    Store.delete(:smalt_resources, uid <> "-ok")
  end

  # Lens-3 cycle 5: same vacuous-identity class as Semantic.StoreRead —
  # struct/2 does not enforce allow_nil?, so a row with a nil or blank
  # primary key projected an identity-less Probe struct through the
  # generic extension read path. Refused typed now.
  test "vacuous primary key refuses the substrate read typed, never projects" do
    uid_nil = "aex-nil-pk-#{System.unique_integer([:positive])}"
    uid_blank = "aex-blank-pk-#{System.unique_integer([:positive])}"

    Store.put(:smalt_resources, uid_nil, %{"id" => nil, "name" => "x"})
    Store.put(:smalt_resources, uid_blank, %{"id" => "", "name" => "y"})

    assert {:error, %Ash.Error.Unknown{} = err} = Ash.read(SmaltTest.AshExtension.Probe)
    text = Exception.message(err) <> inspect(err.errors)
    assert text =~ "vacuous identity"

    Store.delete(:smalt_resources, uid_nil)
    Store.delete(:smalt_resources, uid_blank)

    assert Ash.read!(SmaltTest.AshExtension.Probe)
  end
end
# Lens-4 cycle 1: whitespace-only / invisible-format-only primary keys on the
# generic substrate read path — same vacuous-identity class, one shared fence
# (Smalt.Projection.Identity).
defmodule SmaltTest.AshExtension.Lens4IdentityTest do
  use ExUnit.Case, async: false

  setup_all do
    # Lens-4: this appended module needs the Store GenServer up for the
    # Store-backed read path (same boot prerequisite as the parent suite).
    if Process.whereis(Smalt.Store) == nil do
      start_supervised!(Smalt.Store)
    end

    :ok
  end

  alias Smalt.Store

  test "whitespace-only primary key refuses the substrate read typed" do
    uid = "aex-ws-pk-#{System.unique_integer([:positive])}"
    Store.put(:smalt_resources, uid, %{"id" => "  \t", "name" => "x"})

    assert {:error, %Ash.Error.Unknown{} = err} = Ash.read(SmaltTest.AshExtension.Probe)
    assert Exception.message(err) <> inspect(err.errors) =~ "vacuous identity"

    Store.delete(:smalt_resources, uid)
  end

  test "invisible-format-only (zero-width) primary key refuses the substrate read typed" do
    uid = "aex-zw-pk-#{System.unique_integer([:positive])}"
    Store.put(:smalt_resources, uid, %{"id" => "​", "name" => "x"})

    assert {:error, %Ash.Error.Unknown{} = err} = Ash.read(SmaltTest.AshExtension.Probe)
    assert Exception.message(err) <> inspect(err.errors) =~ "vacuous identity"

    Store.delete(:smalt_resources, uid)
  end
end
