defmodule EnclaveDoctorSeverityTest do
  use ExUnit.Case

  # Typed diagnostic exit contract (v26.10.16 lane 430): every doctor
  # finding carries an explicit {code, severity} pair and every code maps
  # to a remediation command via the shared table
  # (Smalt.Enclave.Remediations). A clean run carries no failure entries.

  describe "clean run" do
    test "every check carries explicit code + closed-vocabulary severity; remediation_map empty" do
      report = Smalt.Enclave.Doctor.run()

      # host_transport is environment-dependent (darwin keychain trust): a
      # machine without the system-keychain trust carries the advisory. The
      # contract: no BLOCKING_GATE finding on a clean machine.
      assert report["status"] in ["PASS", "DEGRADED"],
             "expected clean doctor run, got: #{inspect(Enum.map(report["checks"], &{&1["check"], &1["status"]}))}"

      refute Enum.any?(report["checks"], &(&1["severity"] == :BLOCKING_GATE)),
             "clean run must carry no BLOCKING_GATE findings"

      for check <- report["checks"] do
        assert Map.has_key?(check, "code")
        assert Map.has_key?(check, "severity")
      end

      # Every finding (non-nil code) resolves through the remediation table.
      for check <- report["checks"], code = check["code"] do
        assert report["remediation_map"][code] ==
                 Smalt.Enclave.Remediations.command!(code)
      end

      case report["status"] do
        "PASS" ->
          assert report["remediation_map"] == %{}

        "DEGRADED" ->
          assert report["remediation_map"]["DARWIN_TRUST_MISSING"] == "just test-native"
      end
    end

    test "remediation table: given mappings + severity vocabulary" do
      assert Smalt.Enclave.Remediations.severity_for("FAIL") == :BLOCKING_GATE
      assert Smalt.Enclave.Remediations.severity_for("WARN") == :ADVISORY
      assert Smalt.Enclave.Remediations.severity_for("PASS") == nil

      assert Smalt.Enclave.Remediations.command!("ETS_IDENTITY_RESIDUE") ==
               "mix smalt.audit_residue --strict"

      assert Smalt.Enclave.Remediations.command!("DARWIN_TRUST_MISSING") == "just test-native"
    end
  end

  describe "forced failure (real temp residue rows, no mocks)" do
    test "residue rows during doctor run -> store_invariants FAIL with ETS_IDENTITY_RESIDUE / BLOCKING_GATE + remediation" do
      prefix = "lane430-residue-"

      # Residue injector, NO-SLEEP-DOCTRINE form (v26.10.18 W14): no paced
      # Process.sleep loop. The doctor run executes in a Task while this
      # process inserts unique residue rows in a tight loop for the entire
      # lifetime of the run, so rows land strictly after the strict identity
      # check's baseline snapshot and strictly before its after_state
      # snapshot — the assert (baseline == after_state) must observe the
      # residue deterministically, with no timing guess. The injector is
      # killed after the doctor Task completes; rows are swept by prefix.
      doctor = Task.async(fn -> Smalt.Enclave.Doctor.run() end)

      {:ok, injector} =
        Task.start(fn ->
          for n <- Stream.iterate(1, &(&1 + 1)) do
            :ets.insert(
              :smalt_resources,
              {prefix <> Integer.to_string(n), %{"type" => "Microsoft.Storage/storageAccounts"}}
            )
          end
        end)

      try do
        report = Task.await(doctor, 60_000)

        ets_check = Enum.find(report["checks"], &(&1["check"] == "ets_baseline_identity"))

        assert ets_check["status"] == "FAIL",
               "injected residue rows must fault the strict identity check (got PASS)"

        assert ets_check["code"] == "ETS_IDENTITY_RESIDUE"
        assert ets_check["severity"] == :BLOCKING_GATE

        assert report["status"] == "FAIL"

        assert report["remediation_map"]["ETS_IDENTITY_RESIDUE"] ==
                 "mix smalt.audit_residue --strict"
      after
        # Cleanup: sweep every injected row regardless of outcome.
        Process.exit(injector, :kill)
        sweep(prefix)
      end
    end

    test "State.destroy residue computation sees injected orphaned rows" do
      prefix = "lane430-residue-state-"
      :ets.insert(:smalt_resources, {prefix <> "a", %{"type" => "X"}})
      :ets.insert(:smalt_resources, {prefix <> "b", %{"type" => "X"}})

      try do
        %{residue: residue} = Smalt.Enclave.State.destroy(%{})

        assert Enum.any?(residue, fn
                 {:smalt_resources, keys} -> (prefix <> "a") in keys and (prefix <> "b") in keys
                 _ -> false
               end)
      after
        sweep(prefix)
      end
    end
  end

  describe "affidavit-wasm doctor check (lane 607)" do
    @tag :affidavit_doctor
    test "missing artifact -> WARN / ADVISORY with AFFIDAVIT_WASM_DEGRADED; aggregate DEGRADED" do
      # Real absence: point the configured path at a path that does not exist.
      prior = Application.get_env(:smalt, :affidavit_wasm_path)

      Application.put_env(
        :smalt,
        :affidavit_wasm_path,
        "tmp/affidavit-doctor-missing/affidavit_wasm.wasm"
      )

      try do
        report = Smalt.Enclave.Doctor.run()

        check = Enum.find(report["checks"], &(&1["check"] == "artifact_integrity_and_engine"))

        assert check["status"] == "WARN",
               "expected WARN for a missing artifact, got: #{inspect(check)}"

        assert check["code"] == "AFFIDAVIT_WASM_DEGRADED"
        assert check["severity"] == :ADVISORY
        assert check["details"] =~ "not found"

        assert report["status"] == "DEGRADED"

        assert report["remediation_map"]["AFFIDAVIT_WASM_DEGRADED"] ==
                 "bash scripts/affidavit_wasm_build.sh"
      after
        restore_env(:affidavit_wasm_path, prior)
      end
    end

    @tag :affidavit_doctor
    test "present artifact + sha256 pin match + engine loads -> PASS" do
      # Real run over the real artifact (priv/wasm/affidavit_wasm.wasm)
      # against the real pin file (priv/wasm/affidavit.sha256).
      report = Smalt.Enclave.Doctor.run()
      check = Enum.find(report["checks"], &(&1["check"] == "artifact_integrity_and_engine"))

      assert check["status"] == "PASS",
             "expected PASS over the real artifact, got: #{inspect(check)}"

      assert is_nil(check["code"])
      assert check["details"] =~ "engine loads"
      refute Map.has_key?(report["remediation_map"], "AFFIDAVIT_WASM_DEGRADED")
    end
  end

  describe "remediation table totality" do
    test "all operator + gate codes are mapped; unmapped code raises fail-closed" do
      t = Smalt.Enclave.Remediations.table()

      for code <- ~w(
          SHAPE_REJECTED_BEFORE_DEFAULT_HYDRATION
          ETS_IDENTITY_RESIDUE
          DARWIN_TRUST_MISSING
          ORPHANED_DATA_PLANE_ROWS_DETECTED
          SPC_3SIG_BREACH
          KD_ROW_CANDIDATE
          NFR3_RSS_BUDGET_BREACH
          AFFIDAVIT_WASM_DEGRADED
        ) do
        assert Map.has_key?(t, code), "remediation table missing row for #{code}"
        assert is_binary(t[code]) and t[code] != ""
      end

      assert_raise RuntimeError, fn ->
        Smalt.Enclave.Remediations.command!("NOT_A_REAL_CODE")
      end
    end
  end

  defp restore_env(_key, nil), do: Application.delete_env(:smalt, :affidavit_wasm_path)

  defp restore_env(:affidavit_wasm_path, value),
    do: Application.put_env(:smalt, :affidavit_wasm_path, value)

  defp sweep(prefix) do
    for {k, _} <- :ets.tab2list(:smalt_resources), is_binary(k), String.starts_with?(k, prefix) do
      :ets.delete(:smalt_resources, k)
    end

    :ok
  end
end
