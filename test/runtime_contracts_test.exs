defmodule Smalt.RuntimeContractsTest do
  @moduledoc """
  Gate for the runtime integration contracts lane.

  Covers:

    * `Smockit` alias drift — n/a; real: `Smalt.RuntimeContracts.verify/0`
      over the real routers passes
    * generated catalog modules (ggen projection of `ggen/ontology.ttl`)
      agree with the wired contract modules
    * mutation court: a deliberately broken test-copy contract makes
      `verify/1` fail with the pinned check id
  """

  use ExUnit.Case, async: false

  alias Smalt.RuntimeContracts
  @wired [Smalt.RuntimeContracts.ArmEnvelope, Smalt.RuntimeContracts.CosmosHeader, Smalt.RuntimeContracts.AmqpDialect]

  setup do
    ensure_store()

    prev_auth = Application.get_env(:smalt, :auth_mode)
    Application.put_env(:smalt, :auth_mode, :anonymous)
    prev_lro = Application.get_env(:smalt, :lro_delay_ms)
    Application.put_env(:smalt, :lro_delay_ms, 0)

    on_exit(fn ->
      Application.put_env(:smalt, :auth_mode, prev_auth)
      Application.put_env(:smalt, :lro_delay_ms, prev_lro)
    end)

    Smalt.Store.clear()
    :ok
  end

  # ===========================================================================
  # verify/0 over the real routers
  # ===========================================================================

  describe "verify/0" do
    test "passes over the real routers with a full verdict map" do
      verdict = RuntimeContracts.verify()

      assert verdict.pass
      assert verdict.contract_count == 3
      assert verdict.failure_count == 0

      for name <- [:arm_envelope, :cosmos_header, :amqp_dialect] do
        result = verdict.contracts[name]
        assert result, "missing contract #{name}"
        assert result.pass, "contract #{name} failed: #{inspect(result.failures)}"
        assert result.checks >= 6
        assert result.failures == []
      end

      assert verdict.planes == %{
               control_plane: [:arm_envelope],
               data_plane: [:cosmos_header],
               messaging_plane: [:amqp_dialect]
             }
    end
  end

  # ===========================================================================
  # behaviour + generated catalog coherence
  # ===========================================================================

  describe "catalog coherence" do
    test "every wired module satisfies the Contract behaviour" do
      for mod <- @wired do
        Code.ensure_loaded!(mod)

        assert function_exported?(mod, :name, 0)
        assert function_exported?(mod, :plane, 0)
        assert function_exported?(mod, :consumer, 0)
        assert function_exported?(mod, :source_pack, 0)
        assert function_exported?(mod, :check, 0)

        result = mod.check()
        assert is_map(result) and Map.has_key?(result, :failures)
        assert result.name == mod.name()
        assert result.pass, "#{inspect(mod)} failed: #{inspect(result.failures)}"
      end
    end

    test "ggen-projected catalog agrees with the wired contract modules" do
      entries = [
        Smalt.RuntimeContracts.Generated.ArmEnvelope.entry(),
        Smalt.RuntimeContracts.Generated.CosmosHeader.entry(),
        Smalt.RuntimeContracts.Generated.AmqpDialect.entry()
      ]

      assert length(entries) == 3

      for e <- entries do
        mod = Module.concat([Smalt.RuntimeContracts, String.to_atom(e.module |> String.split(".") |> List.last())])

        # generated `module` column names the hand-written wired module
        assert String.to_atom("Elixir." <> e.module) in @wired,
               "generated catalog entry #{e.module} not wired"

        assert mod.check() |> then(& &1.name) == String.to_atom(e.id)
      end

      for mod <- @wired do
        assert Enum.any?(entries, &(&1.module == inspect(mod))),
               "wired #{inspect(mod)} missing from generated catalog"
      end
    end
  end

  # ===========================================================================
  # mutation court: injected break via a test-copy contract
  # ===========================================================================

  describe "mutation court" do
    test "a deliberately broken test-copy contract fails verify/1 with pinned check id" do
      # Test copy of the ARM envelope contract with one invariant deliberately
      # falsified (expects 500 where the real router returns 404).
      defmodule BrokenArmEnvelope do
        @moduledoc "Test copy of ArmEnvelope with a deliberately injected break."
        alias Smalt.RuntimeContracts.Support

        def name, do: :arm_envelope_broken

        def plane, do: :control_plane

        def consumer, do: "Smalt.ArmGateway.Router"

        def source_pack, do: "ash-runtime-integration-contract-pack"

        def check do
          Support.contract(:arm_envelope_broken, [
            {:injected_break_catch_all_404, fn ->
              resp = Support.dispatch(Smalt.ArmGateway.Router, "get", "/definitely/not/a/route?api-version=2021-04-01")

              Support.assert_equal(resp.status, 500, "INJECTED BREAK: expect catch-all to 500")
            end}
          ])
        end
      end

      verdict = RuntimeContracts.verify([BrokenArmEnvelope])

      refute verdict.pass
      assert verdict.failure_count == 1
      result = verdict.contracts[:arm_envelope_broken]
      assert [%{check: :injected_break_catch_all_404, detail: detail}] = result.failures
      assert is_binary(detail) and detail != ""
    end

    test "verify/1 with an empty contract list fails closed" do
      refute RuntimeContracts.verify([]).pass
    end
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

  defp ensure_store do
    case Smalt.Store.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
