defmodule PopcornDemoTest do
  use ExUnit.Case

  # Host-side gate: the same pure modules must behave identically under the
  # OTP-29 toolchain that builds the WASM runtime, before cooking.
  test "pure smalt slice passes the smoke layers" do
    message = PopcornDemo.Smoke.run()
    assert message =~ "cosmos_sql=OK"
    assert message =~ "sb_rule=OK"
    assert message =~ "registry=OK"
  end
end
