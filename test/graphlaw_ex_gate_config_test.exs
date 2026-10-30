# GL28-2 — `config :smalt, :graphlaw_ex_gate` wiring courts (lane E2).
#
# The config block in config/config.exs (enabled/engine_digest/max_queue/
# fail_closed) was read by NOTHING; these courts pin the reading:
#   1. `enabled: false` (prod posture, config.exs) short-circuits the gate to
#      :ok BEFORE any validation — even a tampered, replayed, oversize
#      envelope passes through (that is the opt-out working, and the reason
#      prod keeps the flag false).
#   2. `fail_closed: false` is the spec §8 fail-open posture: an UNAVAILABLE
#      engine digest admits; a PRESENT-but-drifted digest still refuses.
#   3. `max_request_bytes` (router gate_opts/1) overrides the 16 MiB default.
#   4. `engine_digest_key` resolves the digest from :persistent_term when no
#      explicit :engine_digest opt is given; explicit opt wins.
#
# Chicago: no mocks — real Application env (put_env/delete_env in setup, with
# on_exit restore) and the real :persistent_term. async: false because
# Application env is node-global.

defmodule Smalt.GraphlawEx.GateConfigTest do
  use ExUnit.Case, async: false

  alias Smalt.GraphlawEx.AdmissionGate

  @engine "gl-engine-digest-config"
  @receipt String.duplicate("f", 64)
  @body "config-court-body"

  defp env(overrides \\ []) do
    Enum.into(overrides, %{
      admitted_mutation: true,
      payload_bytes: @body,
      receipt_blake3: @receipt,
      engine_digest: @engine,
      ocel_frame: %{event_class: :mutation_admitted}
    })
  end

  defp opts(overrides \\ []) do
    Keyword.merge([body: @body, engine_digest: @engine], overrides)
  end

  defp code({:refused, code, _details}), do: code
  defp code(:ok), do: :ok

  setup do
    original = Application.get_env(:smalt, :graphlaw_ex_gate)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:smalt, :graphlaw_ex_gate)
        env -> Application.put_env(:smalt, :graphlaw_ex_gate, env)
      end

      :persistent_term.erase({:gl_engine_digest, :gate_config_court})
    end)

    :ok
  end

  test "enabled: false short-circuits to :ok before ANY validation (prod posture)" do
    Application.put_env(:smalt, :graphlaw_ex_gate, enabled: false, fail_closed: true)

    # The same envelope class the chain courts refuse — tampered body,
    # malformed receipt, nil envelope — all pass through when disabled.
    assert AdmissionGate.gate("PUT", env(payload_bytes: "tampered"), opts()) == :ok

    assert AdmissionGate.gate("PUT", env(receipt_blake3: "nothex"), opts()) == :ok
    assert AdmissionGate.gate("PUT", nil, opts()) == :ok
  end

  test "absent env key defaults to enabled (pure-function courts keep working)" do
    Application.delete_env(:smalt, :graphlaw_ex_gate)

    assert AdmissionGate.gate("PUT", env(), opts()) == :ok
    assert code(AdmissionGate.gate("PUT", env(payload_bytes: "other"), opts())) ==
             :smalt_payload_mismatch
  end

  test "fail_closed: false admits an UNAVAILABLE digest but refuses a drifted one" do
    Application.put_env(:smalt, :graphlaw_ex_gate, enabled: true, fail_closed: false)

    # Unavailable (nil) digest: fail-open, admit-and-seal posture (spec §8).
    assert AdmissionGate.gate("PUT", env(), engine_digest: nil, body: @body) == :ok

    # Present-but-drifted digest: ALWAYS refuses, flag notwithstanding.
    assert code(AdmissionGate.gate("PUT", env(engine_digest: "engine-X"), opts(engine_digest: "engine-Y"))) ==
             :smalt_engine_drift
  end

  test "fail_closed default is true: nil digest refuses with no config" do
    Application.delete_env(:smalt, :graphlaw_ex_gate)

    assert code(AdmissionGate.gate("PUT", env(), engine_digest: nil)) == :smalt_engine_drift
  end

  test "max_request_bytes opt overrides the 16 MiB default cap" do
    Application.delete_env(:smalt, :graphlaw_ex_gate)

    tiny = 16
    body = :binary.copy("x", 17)

    assert code(
             AdmissionGate.gate("PUT", env(payload_bytes: body),
               body: body, max_request_bytes: tiny
             )
           ) == :smalt_oversize

    # At-cap commits (boundary inclusive).
    at_cap = :binary.copy("x", tiny)

    assert AdmissionGate.gate("PUT", env(payload_bytes: at_cap),
             body: at_cap, max_request_bytes: tiny, engine_digest: @engine
           ) == :ok

    # Non-positive/garbage opts fall back to the module default.
    assert AdmissionGate.gate("PUT", env(payload_bytes: @body),
             body: @body, max_request_bytes: 0, engine_digest: @engine
           ) == :ok
  end

  test "engine_digest_key resolves the digest from :persistent_term; explicit opt wins" do
    Application.delete_env(:smalt, :graphlaw_ex_gate)
    :persistent_term.put({:gl_engine_digest, :gate_config_court}, @engine)

    assert AdmissionGate.gate("PUT", env(),
             engine_digest_key: {:gl_engine_digest, :gate_config_court}
           ) == :ok

    # Key present but digest differs -> drift.
    assert code(
             AdmissionGate.gate("PUT", env(engine_digest: "engine-Z"),
               engine_digest_key: {:gl_engine_digest, :gate_config_court}
             )
           ) == :smalt_engine_drift

    # Explicit :engine_digest opt shadows the persistent_term value.
    :persistent_term.put({:gl_engine_digest, :gate_config_court}, "stale")

    assert AdmissionGate.gate("PUT", env(),
             engine_digest: @engine,
             engine_digest_key: {:gl_engine_digest, :gate_config_court}
           ) == :ok
  end
end
