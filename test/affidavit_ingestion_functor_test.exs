defmodule AffidavitIngestionFunctorTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Store

  @opts Router.init([])
  @sub "00000000-0000-0000-0000-000000000000"
  @rg "seal-rg"
  @vnet_type "Microsoft.Network/virtualNetworks"
  @res_id "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Network/virtualNetworks/vnet-seal"
  @subject String.downcase(@res_id)

  setup do
    ensure_store()
    Store.clear()

    Store.put(:smalt_subscriptions, @sub, %{
      "id" => "/subscriptions/#{@sub}",
      "subscriptionId" => @sub,
      "displayName" => "Sovereign Smalt Subscription",
      "state" => "Enabled"
    })

    Application.put_env(:smalt, :lro_delay_ms, 0)

    if :ets.info(:smalt_affidavit_witnesses) != :undefined do
      :ets.delete_all_objects(:smalt_affidavit_witnesses)
    end

    :ok
  end

  defp call(conn), do: Router.call(conn, @opts)

  # Idempotent Store boot (same contract as smalt_arm_gateway_test.exs).
  defp ensure_store do
    case Store.start_link([]) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        if :ets.info(:smalt_subscriptions) == :undefined do
          pid = Process.whereis(Store)
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> ensure_store()
          after
            500 -> :ok
          end
        else
          :ok
        end
    end
  end

  defp api_v(type) do
    case Smalt.Registry.latest_version(type) do
      nil -> "2024-01-01"
      v -> v
    end
  end

  defp put_vnet do
    path =
      "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Network/virtualNetworks/vnet-seal?api-version=#{api_v(@vnet_type)}"

    payload = %{
      "location" => "eastus",
      "properties" => %{"addressPrefixes" => ["10.0.0.0/16"]}
    }

    conn(:put, path, payload) |> call()
  end

  test "PUT produces a sealed witness on the sideband receipt when the engine is up" do
    start_engine()
    conn = put_vnet()
    assert conn.status in 200..299

    witness = Router.affidavit_witness(@subject)
    assert is_map(witness), "expected a witness, got :error"
    assert witness["sealed"] == true
    assert witness["ctrt"]
    assert is_binary(witness["ctrt"]) and witness["ctrt"] != ""
    assert witness["receipt"]
    assert witness["modality"] in [1, 2]
    assert is_integer(witness["tariff_cents"])
  end

  test "PUT still answers 2xx when the engine is down (typed witness-absent, no crash)" do
    stop_engine()

    conn = put_vnet()
    assert conn.status in 200..299

    witness = Router.affidavit_witness(@subject)
    assert is_map(witness)
    assert witness["sealed"] == false
    assert witness["receipt"] == "PQC_NOT_PROVISIONED"
  end

  test "RG-delete cascade seals the deleted RG record (sideband, 202 unchanged)" do
    start_engine()

    rg_path = "/subscriptions/#{@sub}/resourcegroups/#{@rg}?api-version=#{api_v("Microsoft.Resources/resourceGroups")}"

    # Create the RG (201), then delete (202 + Location).
    put_conn =
      conn(:put, "/subscriptions/#{@sub}/resourceGroups/#{@rg}?api-version=#{api_v("Microsoft.Resources/resourceGroups")}", %{
        "location" => "eastus"
      })
      |> call()

    assert put_conn.status == 201

    subject = String.downcase("/subscriptions/#{@sub}/resourceGroups/#{@rg}")
    Router.affidavit_witness("warmup")
    :ets.delete_all_objects(:smalt_affidavit_witnesses)

    del_conn = conn(:delete, rg_path) |> call()
    assert del_conn.status == 202

    witness = Router.affidavit_witness(subject)
    assert is_map(witness), "expected a witness for the deleted RG, got :error"
    assert witness["sealed"] == true
  end

  # SHIM-COURT lane622: the seal sideband must emit one registry-gated
  # `affidavit.seal` OCEL event per seal into the real NDJSON sink
  # (matter-isolation: subject_sha/verdict/engine_hash only), and the
  # registry gate must be non-vacuous — a mutated event type is dropped,
  # never admitted (same flip pattern as AffidavitOcelEmitTest).
  test "PUT emits an affidavit.seal event to the OCEL sink; mutated type is dropped" do
    start_engine()
    dir = Path.join("tmp", "ocel-lane622-#{System.system_time(:millisecond)}")
    File.mkdir_p!(dir)
    prev = Application.get_env(:smalt, :ocel_dir)
    Application.put_env(:smalt, :ocel_dir, dir)
    log = Path.join(dir, "events.ndjson")

    on_exit(fn ->
      if prev,
        do: Application.put_env(:smalt, :ocel_dir, prev),
        else: Application.delete_env(:smalt, :ocel_dir)

      File.rm_rf!(dir)
    end)

    conn = put_vnet()
    assert conn.status in 200..299

    assert {:ok, doc} = Smalt.Telemetry.OcelNdjson.read_document(log)
    seal_events = Enum.filter(doc["ocel:events"], &(&1["type"] == "affidavit.seal"))
    assert seal_events != [], "expected at least one affidavit.seal event in the sink"

    for event <- seal_events do
      assert is_binary(event["attributes"]["subject_sha"]) and event["attributes"]["subject_sha"] != ""
      assert event["attributes"]["verdict"] in ["admitted", "refused"]
      assert is_binary(event["attributes"]["engine_hash"]) and event["attributes"]["engine_hash"] != ""
    end

    for rel <- Enum.flat_map(seal_events, & &1["relationships"]) do
      assert rel["objectId"] in Enum.map(doc["ocel:objects"], & &1["id"])
    end

    # Flip (anti-vacuity): a mutated-type seal emission never reaches the sink.
    mutated = %{
      "id" => "ev-affidavit-seal-lane622-mutated",
      "type" => "affidavit.seal.MUTATED",
      "time" => "2026-10-16T00:00:00Z",
      "attributes" => %{"subject_sha" => "ff", "verdict" => "admitted", "engine_hash" => "x"},
      "relationships" => []
    }

    assert {:ok, :dropped} = Smalt.Telemetry.OcelNdjson.append(mutated, [])
    refute Smalt.Ocel.EventRegistry.event_type?("affidavit.seal.MUTATED")

    assert {:ok, doc2} = Smalt.Telemetry.OcelNdjson.read_document(log)
    refute Enum.any?(doc2["ocel:events"], &(&1["type"] == "affidavit.seal.MUTATED"))
  end

  # Engine boot: fail-closed start of the real WASM artifact. If the artifact
  # cannot be admitted in this environment the sealed legs would be vacuous,
  # so surface the engine failure loudly instead of faking a pass. The engine
  # is linked to a throwaway holder process, NOT the test process — a WASM
  # fault that kills the engine must fail the assertion (witness-absent), not
  # EXIT the whole test with an unrelated crash trace.
  defp start_engine do
    case Process.whereis(Smalt.Affidavit.WasmEngine) do
      nil -> :ok
      _pid -> :ok
    end

    unless Process.whereis(Smalt.Affidavit.WasmEngine) do
      parent = self()

      holder =
        spawn(fn ->
          case Smalt.Affidavit.WasmEngine.start_link([]) do
            {:ok, _} -> send(parent, {:engine_started, self()})
            {:error, {:already_started, _}} -> send(parent, {:engine_started, self()})
            other -> send(parent, {:engine_failed, other})
          end

          Process.sleep(:infinity)
        end)

      receive do
        {:engine_started, _} -> :ok
        {:engine_failed, other} -> flunk("affidavit WASM engine failed to start: \#{inspect(other)}")
      after
        10_000 -> flunk("affidavit WASM engine start timed out")
      end
    end

    # Warm the witness sideband table so :ets helpers never race a lazy init.
    Router.affidavit_witness("warmup")
    :ok
  end

  defp stop_engine do
    case Process.whereis(Smalt.Affidavit.WasmEngine) do
      nil ->
        :ok

      pid ->
        GenServer.stop(pid, :normal)

        wait_until(fn ->
          Process.whereis(Smalt.Affidavit.WasmEngine) == nil
        end)
    end
  end

  defp wait_until(fun), do: wait_until(fun, 50)

  defp wait_until(_fun, 0), do: :ok

  defp wait_until(fun, n) do
    if fun.(), do: :ok, else: (Process.sleep(10) && wait_until(fun, n - 1))
  end
end
