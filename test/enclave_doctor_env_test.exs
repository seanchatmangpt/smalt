defmodule EnclaveDoctorEnvTest do
  use ExUnit.Case

  # Regression: Doctor's store_invariants check used to leak
  # Application env :lro_retention_ms => 0 permanently (doctor.ex:147).
  # It must scope the setting and restore the prior value (or delete it
  # if unset), so a following check sees the original env.

  test "store_invariants check restores prior :lro_retention_ms env" do
    Application.put_env(:smalt, :lro_retention_ms, 123_456)
    on_exit(fn -> Application.delete_env(:smalt, :lro_retention_ms) end)

    report = Smalt.Enclave.Doctor.run()

    assert Application.get_env(:smalt, :lro_retention_ms) == 123_456

    # The check itself must still PASS (restore must not break the check).
    ets_check = Enum.find(report["checks"], &(&1["check"] == "ets_baseline_identity"))
    assert ets_check["status"] == "PASS", "details: #{ets_check["details"]}"
  end

  test "store_invariants check deletes env when none was set" do
    Application.delete_env(:smalt, :lro_retention_ms)

    report = Smalt.Enclave.Doctor.run()

    refute Application.get_env(:smalt, :lro_retention_ms)

    ets_check = Enum.find(report["checks"], &(&1["check"] == "ets_baseline_identity"))
    assert ets_check["status"] == "PASS", "details: #{ets_check["details"]}"
  end
end
