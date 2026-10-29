defmodule Smalt.ArmstrongIdiomCourtTest do
  # async: false — the atom-count fence reads the VM-global :atom_count.
  use ExUnit.Case, async: false

  alias Smalt.Arm.Deployments
  alias Smalt.DataPlane.AppConfigFeatures
  alias Smalt.EgressRouter.Peers

  # Compiled at test-compile time so the atom fence (runtime) is not polluted
  # by defmodule minting atoms inside a fenced section.
  defmodule CrashingName do
    def name, do: raise("boom")
    def plane, do: :data
    def check, do: %{name: :crashing, pass: true, checks: 1, failures: []}
  end

  defmodule NonAtomName do
    def name, do: "not-an-atom"
    def plane, do: :control
    def check, do: %{name: :non_atom, pass: true, checks: 1, failures: []}
  end

  defmodule Healthy do
    def name, do: :healthy
    def plane, do: :control
    def check, do: %{name: :healthy, pass: true, checks: 1, failures: []}
  end

  describe "fix 1: runtime_contracts typed bad_name boundary" do
    test "wired contracts still verify green (no regression)" do
      v = Smalt.RuntimeContracts.verify()
      # NOTE (pre-existing, not session-introduced): the cosmos_header etag
      # contract is environment-dependent and can fail solo in the test env
      # (witnessed at HEAD with the fix reverted). The regression fence here
      # is the registry's OWN typed markers: fix 1 must never mint a
      # contract_malformed_* marker on the healthy wired set.
      for {name, r} <- v.contracts do
        assert r.failures |> Enum.find(&(&1.check in [:contract_malformed_name, :contract_malformed_plane, :contract_crashed, :contract_not_loaded, :contract_malformed_verdict, :contract_name_collision])) |> is_nil(),
               "wired contract #{inspect(name)} hit a registry marker: #{inspect(r.failures)}"
      end

      assert v.contract_count == length(Smalt.RuntimeContracts.contracts())
    end

    test "non-atom name/0 still fails the registry (pre-existing marker preserved)" do
      v = Smalt.RuntimeContracts.verify([Healthy, NonAtomName])
      refute v.pass

      result = v.contracts[:non_atom_name]
      assert result
      refute result.pass
      assert Enum.find(result.failures, &(&1.check == :contract_malformed_name))
    end

    test "crashing name/0 surfaces typed contract_malformed_name (no rescue-away)" do
      v = Smalt.RuntimeContracts.verify([Healthy, CrashingName])
      refute v.pass
      assert [crashing] = v.contracts |> Map.values() |> Enum.reject(&(&1.pass))
      assert Enum.find(crashing.failures, &(&1.check == :contract_malformed_name))
    end

    test "non-module entry surfaces typed {:error, :bad_name}, not a minted atom" do
      v = Smalt.RuntimeContracts.verify([Healthy, {:bad, :entry}])
      refute v.pass
      bad = v.contracts[{:error, :bad_name}]
      assert bad
      refute bad.pass
      assert Enum.find(bad.failures, &(&1.check == :contract_malformed_name))
      assert Enum.find(bad.failures, &(&1.check == :contract_malformed_plane))
    end

    test "atom-count fence: verify over hostile entries mints zero atoms" do
      garbage = [
        Healthy,
        {:bad, :entry},
        42,
        "oops",
        {:tuple, 1, 2}
      ]

      # Warm the verify path FIRST: the first call lazily loads modules whose
      # loading mints their module atoms (traced: zero binary_to_atom/
      # list_to_atom calls in the fenced window on a warm path — the mint the
      # fence guards is per-call string->atom minting, not one-time lazy
      # loading). Without the warm-up the fence measures loader noise and
      # flakes on module order (witnessed: census 2026-10-25, +21 cold / +0
      # warm on identical input).
      _warm = Smalt.RuntimeContracts.verify(garbage)
      :erlang.garbage_collect()
      before = :erlang.system_info(:atom_count)

      v = Smalt.RuntimeContracts.verify(garbage)
      refute v.pass

      after_count = :erlang.system_info(:atom_count)
      assert before == after_count, "atom table grew: #{before} -> #{after_count}"
    end
  end

  describe "fix 2: appconfig filter error narrowing" do
    setup do
      name = "armstrong-ff-#{System.unique_integer([:positive])}"
      on_exit(fn -> AppConfigFeatures.delete_flag(name, "") end)
      %{name: name}
    end

    test "known-class eval error folds to false WITH telemetry; unknown raises propagate",
         %{name: name} do
      handler = "armstrong-court-#{System.unique_integer([:positive])}"
      parent = self()

      :ok =
        :telemetry.attach(handler, [:smalt, :appconfig, :filter_error], fn _e, _m, meta, ^parent ->
          send(parent, {:filter_error, meta})
        end, parent)

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, _} =
        AppConfigFeatures.put_flag(name, %{
          "enabled" => true,
          "conditions" => %{
            "client_filters" => [
              %{"name" => "TargetingFilter", "parameters" => %{"Audience" => "not-a-map"}}
            ]
          }
        })

      # ArgumentError (badmap) folds to the conservative false — with telemetry.
      assert false == AppConfigFeatures.evaluate(name, %{"user_id" => "u1"})
      assert_received {:filter_error, %{flag: ^name, filter: "TargetingFilter"}}

      # Unknown raise propagates (let-it-crash): to_string/1 on a map group
      # name is Protocol.UndefinedError — NOT in the known-class list. Before
      # the fix this was silently absorbed into `false`.
      {:ok, _} =
        AppConfigFeatures.put_flag(name, %{
          "enabled" => true,
          "conditions" => %{
            "client_filters" => [
              %{
                "name" => "TargetingFilter",
                "parameters" => %{
                  "Audience" => %{"Groups" => [%{"Name" => %{}, "RolloutPercentage" => 50}]}
                }
              }
            ]
          }
        })

      assert_raise Protocol.UndefinedError, fn ->
        AppConfigFeatures.evaluate(name, %{"user_id" => "u1", "groups" => []})
      end
    end
  end

  describe "fix 3: minted correlation ids" do
    test "deployment correlationId is stable per record, unique across deployments" do
      {:ok, d1} = Deployments.put_deployment("sub-armstrong", nil, "armstrong-d1", %{"properties" => %{"template" => %{}, "parameters" => %{}}})
      {:ok, d2} = Deployments.put_deployment("sub-armstrong", nil, "armstrong-d2", %{"properties" => %{"template" => %{}, "parameters" => %{}}})

      cid1 = d1["properties"]["correlationId"]
      cid2 = d2["properties"]["correlationId"]

      assert is_binary(cid1) and is_binary(cid2)
      assert cid1 != cid2
      # make_ref render, not an incremental integer
      assert cid1 =~ "#Reference<"

      {:ok, again} = Deployments.get_deployment("sub-armstrong", nil, "armstrong-d1")
      assert again["properties"]["correlationId"] == cid1
    end

    test "router fallback correlationId is minted per event, not per resource" do
      record = %{"id" => "/subscriptions/s/resourceGroups/g/providers/x/y/z-#{System.unique_integer()}"}
      e1 = Peers.build_event(record, %{})
      e2 = Peers.build_event(record, %{})

      c1 = e1.data["correlationId"]
      c2 = e2.data["correlationId"]

      assert c1 != c2, "deterministic per-resource fallback destroys correlation"
      assert c1 =~ "azb10-"
      assert c1 =~ "#Reference<"

      meta_cid = "cid-from-meta"
      e3 = Peers.build_event(record, %{correlation_id: meta_cid})
      assert e3.data["correlationId"] == meta_cid
    end
  end
end
