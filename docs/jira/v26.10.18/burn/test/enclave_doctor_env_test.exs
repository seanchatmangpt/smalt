defmodule EnclaveDoctorEnvTest do
  use ExUnit.Case

  # Regression: Doctor's store_invariants check used to leak
  # Application env :lro_retention_ms => 0 permanently (doctor.ex:147).
  # It must scope the setting and restore the prior value (or delete it
  # if unset), so a following check sees the original env.

  test "store_invariants check restores prior :lro_retention_ms env" do
    # Canonical save/restore (SmaltTest.Env, foundations §3.3): put_restored
    # records the prior value (unset-aware) and restores via on_exit.
    :ok = SmaltTest.Env.put_restored(lro_retention_ms: 123_456)

    report = Smalt.Enclave.Doctor.run()

    assert Application.get_env(:smalt, :lro_retention_ms) == 123_456

    # The check itself must still PASS (restore must not break the check).
    ets_check = Enum.find(report["checks"], &(&1["check"] == "ets_baseline_identity"))
    assert ets_check["status"] == "PASS", "details: #{ets_check["details"]}"
  end

  test "store_invariants check deletes env when none was set" do
    # Unset-prior case: put_restored records the key as :__unset__ and the
    # on_exit restore delete_envs it — the delete-before-run is still needed
    # to reach the unset state under an externally-set value.
    prev_retention = Application.get_env(:smalt, :lro_retention_ms)
    Application.delete_env(:smalt, :lro_retention_ms)

    on_exit(fn ->
      if is_nil(prev_retention) do
        Application.delete_env(:smalt, :lro_retention_ms)
      else
        Application.put_env(:smalt, :lro_retention_ms, prev_retention)
      end
    end)

    report = Smalt.Enclave.Doctor.run()

    refute Application.get_env(:smalt, :lro_retention_ms)

    ets_check = Enum.find(report["checks"], &(&1["check"] == "ets_baseline_identity"))
    assert ets_check["status"] == "PASS", "details: #{ets_check["details"]}"
  end
end
