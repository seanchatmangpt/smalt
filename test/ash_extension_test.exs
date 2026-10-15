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
  end
end
