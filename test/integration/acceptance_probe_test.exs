# MTTW LANE 14 — court for the substrate-side acceptance probe
# (scripts/acceptance_probe.exs).
#
# Chicago discipline: the court runs the probe's real logic in-process against
# the LIVE substrate (ARM :9443 / data :8443) — real HTTP over the curl
# transport, real STS mint, real stores, no mocks, no sleeps. Assertions are
# on the verdict's standing fields and on the signature law: a tampered
# payload MUST refuse.
#
# Context: solo (integration tier, live-substrate wire).
#
# Requires the live substrate: ARM 9443 + data 8443 listening.
defmodule Smalt.Integration.AcceptanceProbeTest do
  use ExUnit.Case, async: false

  @script Path.expand("../../scripts/acceptance_probe.exs", __DIR__)
  @module Smalt.AcceptanceProbe
  @arm "http://127.0.0.1:9443"
  @data "http://127.0.0.1:8443"

  setup do
    path = Path.join(System.tmp_dir!(), "lane14-court-#{System.unique_integer()}.json")
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  setup_all do
    # Compile the probe script once for this court module (the module is NOT
    # part of the mix compile surface — it is a script).
    System.put_env("SMALT_ACCEPTANCE_PROBE_SKIP_MAIN", "1")
    Code.compile_file(@script, File.cwd!())

    :ok
  end

  # Runtime dispatch (the probe module is compiled at setup_all from the
  # script file — not on the mix compile surface — so calls go through apply/3
  # to keep the court compile warning-clean).
  defp run(args, opts \\ []), do: apply(@module, :run, List.wrap([args, opts]))
  defp verify(path, opts \\ []), do: apply(@module, :verify, List.wrap([path, opts]))
  defp canonical_json(t), do: apply(@module, :canonical_json, [t])

  # -- gate 1: the probe runs, writes a signed verdict, and every check is ALIVE

  test "probe run: PASS verdict, all five checks ALIVE, signature verifies", %{path: path} do
    {:ok, verdict} = run(path, arm_base: @arm, data_base: @data)

    assert verdict["overall"] == "PASS"
    assert verdict["probe"] == "smalt-acceptance-probe"
    assert is_integer(verdict["completed_at"])

    checks = Map.new(verdict["results"], &{&1["check"], &1})

    # 1. health planes: ARM ready 200 + data plane typed 401 refusal
    assert checks["health_planes"]["standing"] == "ALIVE"
    assert checks["health_planes"]["arm_ready_status"] == 200
    assert checks["health_planes"]["data_tokenless_status"] == 401

    # 2. auth law: tokenless 401 / STS mint 200 / authed 200
    assert checks["auth_law"]["standing"] == "ALIVE"
    assert checks["auth_law"]["tokenless_status"] == 401
    assert checks["auth_law"]["mint_status"] == 200
    assert checks["auth_law"]["authed_status"] == 200

    # 3. pk fence (KD-S1): control read 200, wrong-pk read 404
    assert checks["pk_fence"]["standing"] == "ALIVE"
    assert checks["pk_fence"]["control_pk_status"] == 200
    assert checks["pk_fence"]["wrong_pk_status"] == 404
    assert checks["pk_fence"]["doc_status"] == 201

    # 4. keyvault version history: PUT 201 -> PUT 200 -> latest last-write
    assert checks["keyvault_version_history"]["standing"] == "ALIVE"
    assert checks["keyvault_version_history"]["create_status"] == 201
    assert checks["keyvault_version_history"]["update_status"] == 200
    assert checks["keyvault_version_history"]["latest_status"] == 200
    assert checks["keyvault_version_history"]["latest_is_last_write"] == true

    # 5. WORM opt-in: rewrite on immutable container -> 409 ContainerLocked
    assert checks["worm_opt_in"]["standing"] == "ALIVE"
    assert checks["worm_opt_in"]["rewrite_status"] == 409
    assert checks["worm_opt_in"]["rewrite_code"] == "ContainerLocked"

    # signature verifies under the default (dev) key law
    assert {:ok, ^verdict} = verify(path)
  end

  # -- gate 2: tampered verdict refuses (anti-vacuity of the signature law)

  test "tampered verdict refuses: flipped result byte -> signature_mismatch", %{path: path} do
    {:ok, _verdict} = run(path, arm_base: @arm, data_base: @data)
    file = Jason.decode!(File.read!(path))

    # flip the overall standing PASS -> FAIL in the payload string
    tampered =
      String.replace(file["payload"], "\"overall\":\"PASS\"", "\"overall\":\"FAIL\"")

    assert tampered != file["payload"], "tamper probe must actually mutate the payload"

    File.write!(path, Jason.encode!(%{file | "payload" => tampered}))

    assert {:error, :signature_mismatch} = verify(path)
  end

  # -- gate 3: cross-key refusal (a verdict under a different key material is
  # not ours — verify/2 under a different :key_material must refuse)

  test "cross-key verdict refuses: signed under key A, verified under key B", %{path: path} do

    {:ok, _} = run(path, arm_base: @arm, data_base: @data, key_material: "lane14-key-a-32-bytes-aaaaaaaa")

    assert {:error, :signature_mismatch} =
             verify(path, key_material: "lane14-key-b-32-bytes-bbbbbbbbbbbb")
  end

  # -- gate 4: key law fail-closed — a short env key must refuse, never silently
  # downgrade to the dev default

  test "short env probe key refuses fail-closed", %{path: path} do
    prev = System.get_env("SMALT_ACCEPTANCE_PROBE_KEY")
    :persistent_term.put({__MODULE__, :prev_key_env}, prev)

    System.put_env("SMALT_ACCEPTANCE_PROBE_KEY", "too-short")

    assert {:error, :probe_key_too_short} = run(path)
  after
    case :persistent_term.get({__MODULE__, :prev_key_env}, nil) do
      nil -> System.delete_env("SMALT_ACCEPTANCE_PROBE_KEY")
      v -> System.put_env("SMALT_ACCEPTANCE_PROBE_KEY", v)
    end
  end

  # -- gate 5: canonical JSON is byte-stable (the signature's substrate)

  test "canonical_json sorts keys recursively and is deterministic" do
    term = %{"b" => 1, "a" => %{"d" => [2, 1], "c" => nil}}
    enc = canonical_json(term)

    assert enc == ~s({"a":{"c":null,"d":[2,1]},"b":1})
    assert enc == canonical_json(%{"a" => %{"d" => [2, 1], "c" => nil}, "b" => 1})
  end
end
