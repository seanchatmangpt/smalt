defmodule PopcornDemo.BindGateTest do
  # Chicago: real collaborators — the canonical source files themselves and
  # the gate script as a real subprocess. No mocks.
  use ExUnit.Case, async: true

  @config Path.expand("../../lib/smalt/config.ex", __DIR__)
  @application Path.expand("../../lib/smalt/application.ex", __DIR__)
  @gate Path.expand("../scripts/bind_gate.sh", __DIR__)

  @tag :w212
  test "Smalt.Config.bind_ip/0 accessor is env-first and nilable (no wildcard default)" do
    src = File.read!(@config)
    assert src =~ ~s{def bind_ip, do: System.get_env("SMALT_BIND_IP") || Application.get_env(:smalt, :bind_ip)}
  end

  @tag :w212
  test "application.ex resolves bind_ip nil -> {127,0,0,1} (loopback-only default)" do
    src = File.read!(@application)
    assert src =~ ~s(nil ->) and src =~ ~s({127, 0, 0, 1})
    # no wildcard bind literal outside comments
    code =
      src
      |> String.split("\n")
      |> Enum.map(&String.replace(&1, ~r/#.*/, ""))
      |> Enum.join("\n")
    refute code =~ "0.0.0.0"
    refute code =~ "{0, 0, 0, 0}"
  end

  @tag :w212
  test "bind_gate.sh exits 0 against the live substrate when it is up (loud skip when down)" do
    # Real run of the gate. If the substrate is down the gate refuses with
    # LISTENER_ABSENT — a loud, typed skip, never a silent pass.
    case System.cmd("bash", [@gate], stderr_to_stdout: true) do
      {out, 0} ->
        assert out =~ "BIND_GATE_PASS"

      {out, 1} ->
        assert out =~ "LISTENER_ABSENT",
               "gate refused for a reason other than substrate-down: #{out}"
    end
  end
end
