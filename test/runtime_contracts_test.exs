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
  @wired [
    Smalt.RuntimeContracts.ArmEnvelope,
    Smalt.RuntimeContracts.CosmosHeader,
    Smalt.RuntimeContracts.AmqpDialect,
    Smalt.RuntimeContracts.SentinelIngest,
    Smalt.RuntimeContracts.ResourceGraphQuery,
    Smalt.RuntimeContracts.PurviewAtlas
  ]

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
      assert verdict.contract_count == 6
      assert verdict.failure_count == 0

      for name <- [:arm_envelope, :cosmos_header, :amqp_dialect, :sentinel_ingest, :resource_graph_query, :purview_atlas] do
        result = verdict.contracts[name]
        assert result, "missing contract #{name}"
        assert result.pass, "contract #{name} failed: #{inspect(result.failures)}"
        assert result.checks >= 6
        assert result.failures == []
      end

      # plane grouping is built from a map fold, so order within a plane is
      # not guaranteed — assert as sets.
      planes = Map.new(verdict.planes, fn {p, names} -> {p, Enum.sort(names)} end)

      assert planes == %{
               control_plane: [:arm_envelope, :resource_graph_query],
               data_plane: [:cosmos_header, :purview_atlas, :sentinel_ingest],
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
        assert function_exported?(mod, :check, 0)

        result = mod.check()
        assert is_map(result) and Map.has_key?(result, :failures)
        assert result.name == mod.name()
        assert result.pass, "#{inspect(mod)} failed: #{inspect(result.failures)}"
      end
    end

    test "ggen-projected catalog agrees with the wired contract modules" do
      entries =
        for mod <- @wired do
          mod
          |> inspect()
          |> String.replace("Smalt.RuntimeContracts.", "Smalt.RuntimeContracts.Generated.")
          |> String.split(".")
          |> Module.concat()
          |> then(& &1.entry())
        end

      assert length(entries) == 6

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

    test "replayed generated/*.ex are byte-identical to the replay-verified manifest" do
      manifest_path = "lib/smalt/runtime_contracts/generated/MANIFEST.sha256"

      assert File.exists?(manifest_path), "replay manifest missing at #{manifest_path}"

      for line <- manifest_path |> File.read!() |> String.split("\n", trim: true) do
        [sha, rel] = String.split(line, "  ")

        path = Path.join("lib/smalt/runtime_contracts/generated", rel)

        assert File.exists?(path), "pinned generated output missing on disk: #{path}"

        actual = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

        assert actual == sha,
               "generated drift: #{path} sha256 #{actual} != pinned #{sha}\n" <>
                 "Replay: cd lib/smalt/runtime_contracts/ggen && ggen sync run, then copy generated/*.ex to ../generated/ and regenerate MANIFEST.sha256"
      end
    end

    test "transient ggen workspace output is not left on disk (module-collision trap)" do
      trap = "lib/smalt/runtime_contracts/ggen/generated"

      refute File.exists?(trap),
             "#{trap} exists — leaving the transient sync workspace in the tree causes " <>
               "duplicate-module compile aborts (Smalt.RuntimeContracts.Generated.* defined twice). " <>
               "Remove it after replay: rm -r #{trap}"
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
  # gate-registry fuzz (lens-2 cycle 1): verify/1 must fail closed with typed
  # refusals on adversarial registry entries — never crash, never shadow.
  # ===========================================================================
  describe "gate registry fuzz (typed refusals)" do
    test "unregistered gate name (non-module atom) is a typed refusal, not a crash" do
      verdict = RuntimeContracts.verify([:nope])

      refute verdict.pass
      assert verdict.failure_count == 1
      # name guess falls back to the inspected term
      result = verdict.contracts |> Map.values() |> hd()
      assert [%{check: :contract_not_loaded, detail: detail}] = result.failures
      assert detail =~ ":nope"
    end

    test "wrong arity (module without check/0) is a typed refusal" do
      defmodule WrongArityGate do
        def name, do: :wrong_arity_gate
        def plane, do: :control_plane
        # check/1 exported but check/0 required — wrong arity
        def check(_arg), do: raise("never called")
      end

      verdict = RuntimeContracts.verify([WrongArityGate])

      refute verdict.pass
      result = verdict.contracts[:wrong_arity_gate]
      assert [%{check: :contract_not_loaded, detail: detail}] = result.failures
      assert detail =~ "does not export check/0"
    end

    test "non-boolean verdict / non-numeric checks / nil failures is a typed refusal" do
      defmodule MalformedVerdictGate do
        def name, do: :malformed_verdict_gate
        def plane, do: :control_plane
        def check, do: %{name: :malformed_verdict_gate, pass: "yes", checks: "3", failures: nil}
      end

      verdict = RuntimeContracts.verify([MalformedVerdictGate])

      refute verdict.pass
      assert verdict.check_count == 0
      result = verdict.contracts[:malformed_verdict_gate]
      assert [%{check: :contract_malformed_verdict, detail: detail}] = result.failures
      assert detail =~ "malformed verdict"
    end

    test "duplicate gate id cannot shadow a failing contract (no silent false PASS)" do
      defmodule FailingDupGate do
        def name, do: :dup_gate
        def plane, do: :control_plane
        def check, do: %{name: :dup_gate, pass: false, checks: 1, failures: [%{check: :injected, detail: "broken"}]}
      end




      defmodule PassingDupGate do
        def name, do: :dup_gate
        def plane, do: :control_plane
        def check, do: %{name: :dup_gate, pass: true, checks: 1, failures: []}
      end

      verdict = RuntimeContracts.verify([FailingDupGate, PassingDupGate])

      refute verdict.pass
      # the FIRST occurrence is kept (its own injected failure survives — the
      # duplicate cannot shadow it) and the collision marker is appended
      result = verdict.contracts[:dup_gate]
      checks = Enum.map(result.failures, & &1.check)
      assert :injected in checks
      assert :contract_name_collision in checks
      assert verdict.failure_count == 2
    end
  end

  describe "gate registry fuzz: crash and non-map verdicts (typed refusals)" do
    test "plane/0 returning a non-atom fails the registry typed (contract_malformed_plane)" do
      defmodule BadPlaneGate do
        def name, do: :bad_plane_gate
        def plane, do: "not-an-atom"
        def check, do: %{name: :bad_plane_gate, pass: true, checks: 1, failures: []}
      end

      verdict = RuntimeContracts.verify([BadPlaneGate])

      refute verdict.pass
      result = verdict.contracts[:bad_plane_gate]
      assert [%{check: :contract_malformed_plane, detail: detail}] = result.failures
      assert detail =~ "not-an-atom"
      # Grouped under the marker plane, never a binary-keyed planes map.
      assert verdict.planes == %{contract_malformed_plane: [:bad_plane_gate]}
    end

    test "plane/0 raising (or module without plane/0) still resolves :unknown without crashing" do
      defmodule NoPlaneGate do
        def name, do: :no_plane_gate
        def check, do: %{name: :no_plane_gate, pass: true, checks: 1, failures: []}
      end

      verdict = RuntimeContracts.verify([NoPlaneGate])

      assert verdict.pass
      assert verdict.planes[:unknown] == [:no_plane_gate]
    end

    test "crashing check/0 is a typed refusal (contract_crashed), not a fan-out crash" do
      defmodule CrashingGate do
        def name, do: :crashing_gate
        def plane, do: :control_plane
        def check, do: raise("injected crash")
      end

      verdict = RuntimeContracts.verify([CrashingGate])

      refute verdict.pass
      result = verdict.contracts[:crashing_gate]
      assert [%{check: :contract_crashed, detail: detail}] = result.failures
      assert detail =~ "injected crash"
    end

    test "non-map verdict (bare atom) is a typed refusal, not a crash" do
      defmodule NonMapVerdictGate do
        def name, do: :non_map_verdict_gate
        def plane, do: :control_plane
        def check, do: :ok
      end

      verdict = RuntimeContracts.verify([NonMapVerdictGate])

      refute verdict.pass
      result = verdict.contracts[:non_map_verdict_gate]
      assert [%{check: :contract_crashed, detail: detail}] = result.failures
      assert detail =~ "badmap"
    end

    test "string pass flag (\"true\") is a typed malformed verdict, not a truthy free pass" do
      defmodule PassStringGate do
        def name, do: :pass_string_gate
        def plane, do: :control_plane
        def check, do: %{name: :pass_string_gate, pass: "true", checks: 1, failures: []}
      end

      verdict = RuntimeContracts.verify([PassStringGate])

      refute verdict.pass
      assert verdict.check_count == 0
      result = verdict.contracts[:pass_string_gate]
      assert [%{check: :contract_malformed_verdict, detail: detail}] = result.failures
      assert detail =~ "pass a boolean"
    end

    test "non-map failure entries are a typed malformed verdict, not an inconsistent pass" do
      defmodule FailuresNonMapGate do
        def name, do: :failures_non_map_gate
        def plane, do: :control_plane

        def check,
          do: %{name: :failures_non_map_gate, pass: true, checks: 1, failures: [:not_a_map]}
      end

      verdict = RuntimeContracts.verify([FailuresNonMapGate])

      # the contract claimed pass=true with a non-map "failure" — the registry
      # must fail it typed, never expose untyped entries to downstream readers
      refute verdict.pass
      result = verdict.contracts[:failures_non_map_gate]
      assert result.pass == false
      assert [%{check: :contract_malformed_verdict, detail: detail}] = result.failures
      assert detail =~ "failures a list"
    end

    test "malformed verdict on a DUPLICATE gate id fails closed (no ++ crash on raw verdict)" do
      defmodule MalformedDupGate do
        def name, do: :dup_gate_malformed
        def plane, do: :control_plane

        def check,
          do: %{name: :dup_gate_malformed, pass: :x, checks: :y, failures: "oops"}
      end

      defmodule OkDupGate do
        def name, do: :dup_gate_malformed
        def plane, do: :control_plane
        def check, do: %{name: :dup_gate_malformed, pass: true, checks: 1, failures: []}
      end

      # crash witnessed pre-fix: ArgumentError "oops" ++ [...] in the collision
      # guard, which ran on the RAW verdict before coercion (lens-3 cycle 2).
      # Post-fix, coercion runs first, so the append is always on a list.
      verdict = RuntimeContracts.verify([MalformedDupGate, OkDupGate])

      refute verdict.pass
      result = verdict.contracts[:dup_gate_malformed]

      # first occurrence (the malformed verdict) is kept with its own typed
      # marker AND the collision marker — nothing shadowed, nothing lost
      checks = Enum.map(result.failures, & &1.check)
      assert :contract_malformed_verdict in checks
      assert :contract_name_collision in checks
      assert result.pass == false
    end
  end

  # ===========================================================================
  # cross-anchor fence (lens-2 cycle 2): the ggen receipt (BLAKE3 pins) and
  # the replay-verified MANIFEST (sha256 pins) must describe IDENTICAL bytes.
  # The algorithm must be pinned explicitly in the comparison — comparing a
  # blake3 pin against a sha256 digest is the exact false-witness channel
  # that produced the retracted cycle-6 "receipt-mint defect".
  # ===========================================================================
  describe "cross-anchor fence (receipt vs MANIFEST, algorithm-pinned)" do
    test "ggen receipt BLAKE3 pins and MANIFEST sha256 pins describe identical bytes" do
      receipt_path = "test/fixtures/runtime_contracts/ggen/receipt.json"
      manifest_path = "lib/smalt/runtime_contracts/generated/MANIFEST.sha256"

      assert File.exists?(receipt_path), "ggen receipt missing at #{receipt_path}"
      assert File.exists?(manifest_path), "MANIFEST missing at #{manifest_path}"

      receipt = receipt_path |> File.read!() |> Jason.decode!()
      assert %{"payload" => %{"outputs" => outputs}} = receipt

      # receipt pins are BLAKE3, keyed by workspace-relative "generated/X.ex"
      for {ws_rel, blake3_pin} <- outputs do
        base = Path.basename(ws_rel)
        disk_path = Path.join("lib/smalt/runtime_contracts/generated", base)

        assert File.exists?(disk_path), "receipt-pinned output missing on disk: #{disk_path}"

        disk_blake3 =
          case System.cmd("b3sum", [disk_path]) do
            {out, 0} -> out |> String.split() |> hd()
            {_out, code} -> flunk("b3sum failed (#{code}) on #{disk_path} — is b3sum installed?")
          end

        assert disk_blake3 == blake3_pin,
               "cross-anchor drift: #{disk_path} blake3 #{disk_blake3} != receipt pin #{blake3_pin} " <>
                 "(receipt pins are BLAKE3, MANIFEST pins are sha256 — never compare across algorithms)"
      end

      # and the MANIFEST side: sha256 pins still describe the same files
      for line <- manifest_path |> File.read!() |> String.split("\n", trim: true) do
        [sha, rel] = String.split(line, "  ")
        disk_path = Path.join("lib/smalt/runtime_contracts/generated", rel)
        disk_sha = :crypto.hash(:sha256, File.read!(disk_path)) |> Base.encode16(case: :lower)

        assert disk_sha == sha,
               "MANIFEST drift: #{disk_path} sha256 #{disk_sha} != pinned #{sha}"
      end
    end
  end

  describe "Support court residuals (lens-3)" do
    test "duplicate check ids inside one contract run both instances and mask nothing" do
      # lens-2 deferred decision, pinned lens-3: unlike gate ids (collisions
      # test fails the registry), duplicate CHECK ids are diagnosis labels —
      # every instance runs and every failure is counted, never deduplicated
      defmodule DupCheckIdGate do
        def name, do: :dup_check_id_gate
        def plane, do: :control_plane

        def check do
          Smalt.RuntimeContracts.Support.contract(:dup_check_id, [
            {:same_id, fn -> Smalt.RuntimeContracts.Support.assert(true, "first passes") end},
            {:same_id, fn -> raise "second fails" end}
          ])
        end
      end

      verdict = RuntimeContracts.verify([DupCheckIdGate])

      result = verdict.contracts[:dup_check_id_gate]
      assert result.checks == 2
      assert result.pass == false
      assert [%{check: :same_id, detail: detail}] = result.failures
      assert detail =~ "second fails"
    end

    test "a contract whose name/0 raises runs under a guessed name, fan-out survives" do
      defmodule RaisingNameGate do
        def plane, do: :control_plane
        def check, do: %{name: :guessed, pass: true, checks: 1, failures: []}

        def name, do: raise("injected name crash")
      end

      # name/0 crash is rescued into the underscored-module guess
      # (:raising_name_gate), the verdict still runs, fan-out survives
      verdict = RuntimeContracts.verify([RaisingNameGate])

      assert verdict.contract_count == 1
      result = verdict.contracts[:raising_name_gate]
      assert result.checks == 1
      assert result.pass == true
    end

    test "a contract whose name/0 returns a non-atom fails the registry typed (lens-5 sibling of plane/0)" do
      defmodule NonAtomNameGate do
        def plane, do: :control_plane
        def check, do: %{name: :whatever, pass: true, checks: 1, failures: []}

        def name, do: {"not", "an atom"}
      end

      verdict = RuntimeContracts.verify([NonAtomNameGate])

      result = verdict.contracts[:non_atom_name_gate]

      # The guessed key survives (fan-out keying is internal), but the
      # documented-type violation is never silent: typed failure appended,
      # pass flipped false.
      refute result.pass

      assert [
               %{check: :contract_malformed_name, detail: detail}
             ] = result.failures

      assert detail =~ "non-atom"
      assert detail =~ ~s|{"not", "an atom"}|
      refute verdict.pass
    end

    test "a float checks count is a typed malformed verdict, not a fractional check_count" do
      defmodule FloatChecksGate do
        def name, do: :float_checks_gate
        def plane, do: :control_plane

        def check,
          do: %{name: :float_checks_gate, pass: true, checks: 1.5, failures: []}
      end

      verdict = RuntimeContracts.verify([FloatChecksGate])
      result = verdict.contracts[:float_checks_gate]
      refute result.pass

      assert [%{check: :contract_malformed_verdict, detail: detail}] = result.failures
      assert detail =~ "non-negative integer"
      # The registry total is never fractional: the verdict() type
      # (check_count :: non_neg_integer()) holds.
      assert verdict.check_count == 0
      assert is_integer(verdict.check_count)
      refute verdict.pass
    end

    test "a negative checks count is a typed malformed verdict (non-negative integer guard)" do
      defmodule NegativeChecksGate do
        def name, do: :negative_checks_gate
        def plane, do: :control_plane

        def check,
          do: %{name: :negative_checks_gate, pass: true, checks: -3, failures: []}
      end

      verdict = RuntimeContracts.verify([NegativeChecksGate])
      result = verdict.contracts[:negative_checks_gate]
      refute result.pass
      refute verdict.pass
      assert [%{check: :contract_malformed_verdict, detail: detail}] = result.failures
      assert detail =~ "non-negative integer"
      assert verdict.check_count == 0
    end

    test "name/0 absent resolves via the guess and still passes (no over-blocking)" do
      defmodule NoNameGate do
        def plane, do: :control_plane
        def check, do: %{name: :x, pass: true, checks: 1, failures: []}
      end

      verdict = RuntimeContracts.verify([NoNameGate])

      result = verdict.contracts[:no_name_gate]
      assert result.pass == true
      assert result.failures == []
    end

    test "a malformed-NAME contract with a malformed PLANE gets BOTH typed markers (lens-6 mask probe)" do
      # lens-5 residual: plane_of/2 resolved the contract by RAW name/0, so a
      # contract whose name/0 returned a non-atom never matched in the find and
      # its plane/0 violation was silently resolved :unknown — the
      # contract_malformed_plane marker was masked by the malformed name.
      defmodule BadNameAndPlaneGate do
        def plane, do: "also-not-an-atom"
        def check, do: %{name: :whatever, pass: true, checks: 1, failures: []}

        def name, do: {"bad", "name"}
      end

      verdict = RuntimeContracts.verify([BadNameAndPlaneGate])

      result = verdict.contracts[:bad_name_and_plane_gate]

      checks = Enum.map(result.failures, & &1.check)
      assert :contract_malformed_name in checks
      assert :contract_malformed_plane in checks

      # Grouped under the marker plane, never silently :unknown.
      assert verdict.planes[:contract_malformed_plane] == [:bad_name_and_plane_gate]
      refute result.pass
      refute verdict.pass
    end
  end

  describe "Support.contract/2 court" do
    test "a failing check does not abort later checks; failures are collected with pinned ids" do
      defmodule PartialFailContract do
        def name, do: :partial_fail_contract
        def plane, do: :control_plane

        def check do
          Smalt.RuntimeContracts.Support.contract(:partial_fail_contract, [
            {:first_ok, fn -> :ok end},
            {:second_fails, fn -> Smalt.RuntimeContracts.Support.assert(false, "injected break") end},
            {:third_ok, fn -> :ok end}
          ])
        end
      end

      verdict = RuntimeContracts.verify([PartialFailContract])

      refute verdict.pass
      result = verdict.contracts[:partial_fail_contract]
      assert result.checks == 3
      assert result.pass == false
      assert [%{check: :second_fails, detail: detail}] = result.failures
      assert detail =~ "injected break"
    end

    test "malformed check entries (non-tuple, non-fun) fail the contract typed, not crash the fan-out" do
      defmodule MalformedEntriesContract do
        def name, do: :malformed_entries_contract
        def plane, do: :control_plane

        def check do
          Smalt.RuntimeContracts.Support.contract(:malformed_entries_contract, [
            {:ok_check, fn -> :ok end},
            :not_a_tuple
          ])
        end
      end

      verdict = RuntimeContracts.verify([MalformedEntriesContract])

      refute verdict.pass
      result = verdict.contracts[:malformed_entries_contract]
      assert [%{check: :contract_crashed, detail: detail}] = result.failures
      assert detail =~ "function_clause"
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
