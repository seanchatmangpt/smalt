defmodule Smalt.Enclave.Doctor do
  @moduledoc """
  Operator diagnostic engine (v26.10.16 lane 416).

  Five real checks over the live in-process substrate; aggregate verdict
  PASS / DEGRADED / FAIL. The mix task always exits 0 unless the engine
  itself crashes (Check-4 safety rule: a doctor that exits nonzero on a
  WARN is a doctor CI learns to ignore).
  """

  alias Smalt.ArmGateway.Router
  alias Smalt.Enclave.Hcl
  alias Smalt.Enclave.Remediations
  alias Smalt.Registry
  alias Smalt.Store

  @excluded_tables [:smalt_sb_locks]

  @doc "Runs all five checks; returns the full receipt map."
  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    checks =
      [
        {"native_hcl_engine", "hcl_ast_parser_conformance", fn -> check_native_hcl() end},
        {"store_invariants", "ets_baseline_identity", fn -> check_store_invariants() end},
        {"wire_parity_gateway", "monotonic_api_version_lattice",
         fn -> check_wire_parity_gateway() end},
        {"host_transport", "darwin_keychain_trust", fn -> check_host_transport(opts) end},
        {"affidavit_wasm", "artifact_integrity_and_engine", fn -> check_affidavit_wasm() end}
      ]
      |> Enum.map(fn {domain, check, fun} ->
        try do
          fun.()
        rescue
          e ->
            %{
              "domain" => domain,
              "check" => check,
              "status" => "FAIL",
              "code" => "CHECK_ENGINE_CRASH",
              "details" => ("check crashed: " <> Exception.format(:error, e)) |> String.trim()
            }
        end
      end)

    # Normalize the typed contract onto every check: explicit code (nil on
    # PASS) and closed-vocabulary severity (nil on PASS).
    checks =
      for check <- checks do
        check
        |> Map.put_new("code", nil)
        |> Map.put("severity", Remediations.severity_for(check["status"]))
      end

    status =
      cond do
        Enum.any?(checks, &(&1["status"] == "FAIL")) -> "FAIL"
        Enum.any?(checks, &(&1["status"] == "WARN")) -> "DEGRADED"
        true -> "PASS"
      end

    # Typed diagnostic exit contract: every finding carries an explicit
    # {code, severity} pair, and every code resolves to a remediation
    # command through the shared table (fail-closed: a code with no row
    # raises here, so an unmapped code can never ride through a receipt).
    remediation_map =
      checks
      |> Enum.map(& &1["code"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Map.new(fn code -> {code, Remediations.command!(code)} end)

    %{
      "status" => status,
      "receipt_timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "checks" => checks,
      "remediation_map" => remediation_map
    }
  end

  ## Check 1: native HCL engine — parse every terraform fixture, 0 faults = PASS.

  defp check_native_hcl do
    fixtures =
      Path.wildcard("test/terraform_fixture/*.tf") ++
        Path.wildcard("test/terraform_fixture_per_resource/*.tf")

    {faults, parsed} =
      Enum.reduce(fixtures, {[], 0}, fn path, {faults, n} ->
        case Hcl.parse(path) do
          {:ok, _doc} ->
            {faults, n + 1}

          {:error, {:hcl_parse, line, msg}} ->
            {["#{path}:#{line}: #{msg}" | faults], n}
        end
      end)

    faults = Enum.reverse(faults)

    {status, code} =
      case faults do
        [] -> {"PASS", nil}
        _ -> {"FAIL", "HCL_PARSE_FAULTS"}
      end

    %{
      "domain" => "native_hcl_engine",
      "check" => "hcl_ast_parser_conformance",
      "status" => status,
      "code" => code,
      "details" =>
        fault_details(
          "parsed #{parsed}/#{length(fixtures)} terraform fixtures with 0 faults",
          faults
        )
    }
  end

  ## Check 2: store invariants — fresh Store + ETS baseline-identity lifecycle.

  defp check_store_invariants do
    case store_identity_lifecycle() do
      :ok ->
        %{
          "domain" => "store_invariants",
          "check" => "ets_baseline_identity",
          "status" => "PASS",
          "details" =>
            "fresh Store snapshot -> real RG+topic create/delete over " <>
              "Smalt.ArmGateway.Router -> strict ETS identity restored (no residue)"
        }

      {:fault, msg} ->
        %{
          "domain" => "store_invariants",
          "check" => "ets_baseline_identity",
          "status" => "FAIL",
          "code" => "ETS_IDENTITY_RESIDUE",
          "details" => msg
        }
    end
  end

  # Real lifecycle: snapshot all Store tables, drive RG+topic create/delete
  # over the real router (Plug.Test), require strict identity after. Mirrors
  # test/smalt_ets_baseline_identity_test.exs (the fence, extracted).
  defp store_identity_lifecycle do
    ensure_store()
    baseline = snapshot()

    sub = "00000000-0000-0000-0000-000000000000"
    rg_path = "/subscriptions/#{sub}/resourceGroups/doctor-identity-rg"
    rg_api = Registry.latest_version("Microsoft.Resources/resourceGroups") || "2021-04-01"
    topic_api = Registry.latest_version("Microsoft.EventGrid/topics") || "2021-04-01"
    res_path = rg_path <> "/providers/Microsoft.EventGrid/topics/doctor-identity-topic"

    opts = Router.init([])

    with {:put_rg, conn} <- {:put_rg, put_json(rg_path, rg_api, %{"location" => "eastus"}, opts)},
         :ok <- expect_status({:put_rg, conn}, [200, 201]),
         {:put_res, conn} <-
           {:put_res, put_json(res_path, topic_api, %{"location" => "eastus"}, opts)},
         :ok <- expect_status({:put_res, conn}, [200, 201]),
         :ok <- expect_status({:get_res, wire(:get, res_path, topic_api, opts)}, [200]),
         :ok <-
           expect_status({:del_res, wire(:delete, res_path, topic_api, opts)}, [200, 202, 204]),
         :ok <- expect_status({:get_res2, wire(:get, res_path, topic_api, opts)}, [404]),
         :ok <- expect_status({:del_rg, wire(:delete, rg_path, rg_api, opts)}, [200, 202, 204]),
         :ok <- expect_status({:get_rg, wire(:get, rg_path, rg_api, opts)}, [404]) do
      # RG delete is an LRO: poll to terminality over the real wire path, then
      # drive the real retention-eviction pass so :smalt_operations returns to
      # identity (same route as the fence test — never a hand-delete).
      op_id = op_key()
      poll_to_terminal(op_id, topic_api, opts)

      # SHIM-COURT: scope the retention-0 setting so a following check sees
      # the original env (previously leaked :lro_retention_ms 0 permanently).
      prior_retention = Application.get_env(:smalt, :lro_retention_ms)
      Application.put_env(:smalt, :lro_retention_ms, 0)

      try do
        # SLEEP-CLASS: SIGNALABLE-PENDING-REDESIGN — eviction_pass reads env
        # synchronously instead (settle-delay removal); redesign:
        # docs/jira/v26.10.18/rewrite-drafts/lib-redesign-wasm-lro.md
        Process.sleep(10)
        :ok = Smalt.ArmGateway.LRO.Sweeper.eviction_pass()
      after
        case prior_retention do
          nil -> Application.delete_env(:smalt, :lro_retention_ms)
          value -> Application.put_env(:smalt, :lro_retention_ms, value)
        end
      end

      after_state = snapshot()

      if after_state == baseline do
        :ok
      else
        {:fault,
         "ETS baseline-identity FAULT: lifecycle left residue in tables " <>
           inspect(differing_tables(baseline, after_state))}
      end
    else
      {:status_fault, step, status, body} ->
        {:fault, "#{step} returned #{status}: #{body}"}
    end
  end

  defp expect_status({step, %{status: status, resp_body: body}}, allowed) do
    if status in allowed do
      :ok
    else
      {:status_fault, step, status, inspect(body)}
    end
  end

  defp put_json(path, api, body, opts) do
    wire(:put, path, api, opts, Jason.encode!(body))
  end

  defp wire(method, path, api, opts, body \\ nil) do
    method
    |> Plug.Test.conn(path <> "?api-version=#{api}", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Router.call(opts)
  end

  defp snapshot do
    Store.table_names()
    |> Kernel.--(@excluded_tables)
    |> Map.new(fn table -> {table, Enum.sort(:ets.tab2list(table))} end)
  end

  defp differing_tables(baseline, after_state) do
    for {t, b} <- baseline, a = Map.get(after_state, t), a != b, do: t
  end

  defp op_key do
    case :ets.tab2list(:smalt_operations) do
      [{key, _}] -> key
      rows -> raise "doctor: expected exactly one LRO op row, got #{inspect(rows)}"
    end
  end

  defp poll_to_terminal(op_id, api, opts) do
    path = "/subscriptions/00000000-0000-0000-0000-000000000000/operations/#{op_id}"
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_poll(path, api, opts, deadline)
  end

  defp do_poll(path, api, opts, deadline) do
    conn = wire(:get, path, api, opts)
    body = Jason.decode!(conn.resp_body)

    case body["status"] do
      "InProgress" ->
        if System.monotonic_time(:millisecond) > deadline do
          raise "doctor: LRO op #{path} never reached terminality: #{inspect(body)}"
        end

        # SLEEP-CLASS: SIGNALABLE-PENDING-REDESIGN — poll step; candidate to
        # fold into LRO.await shared poll primitive; redesign:
        # docs/jira/v26.10.18/rewrite-drafts/lib-redesign-wasm-lro.md
        Process.sleep(20)
        do_poll(path, api, opts, deadline)

      _status ->
        :ok
    end
  end

  # Same fresh-Store race handling as the fence test.
  defp ensure_store do
    case Store.start_link([]) do
      {:ok, _} ->
        Store.clear()
        :ok

      {:error, {:already_started, _}} ->
        if :ets.info(:smalt_subscriptions) == :undefined do
          pid = Process.whereis(Store)
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> ensure_store()
          after
            500 -> ensure_store()
          end
        end

        Store.clear()
        :ok
    end
  end

  ## Check 3: wire parity gateway — monotonic api-version lattice semantics.

  defp check_wire_parity_gateway do
    types = types_under_test()

    {faults, latests} =
      Enum.reduce(types, {[], %{}}, fn type, {faults, latests} ->
        case Registry.latest_version(type) do
          latest when is_binary(latest) ->
            latest_admitted = Registry.admitted_version?(type, latest)
            older_admitted = Registry.admitted_version?(type, shift_year(latest, -1))
            newer_refused = not Registry.admitted_version?(type, shift_year(latest, +1))
            malformed_refused = not Registry.admitted_version?(type, "not-a-date")

            cond do
              not latest_admitted ->
                {[{type, "latest #{latest} NOT admitted"} | faults], latests}

              not older_admitted ->
                {[{type, "older version NOT admitted (lattice must be (-inf, latest])"} | faults],
                 latests}

              not newer_refused ->
                {[{type, "newer-than-latest WRONGLY admitted"} | faults], latests}

              not malformed_refused ->
                {[{type, "malformed version WRONGLY admitted"} | faults], latests}

              true ->
                {faults, Map.put(latests, type, latest)}
            end

          _ ->
            {[{type, "no latest_version registered"} | faults], latests}
        end
      end)

    {status, code} =
      case faults do
        [] -> {"PASS", nil}
        _ -> {"FAIL", "API_VERSION_LATTICE_FAULT"}
      end

    %{
      "domain" => "wire_parity_gateway",
      "check" => "monotonic_api_version_lattice",
      "status" => status,
      "code" => code,
      "details" =>
        "monotonic lattice holds for #{map_size(latests)}/#{length(types)} baseline types " <>
          "(latest admitted, older admitted, newer+malformed refused)",
      "latest_versions" => latests
    }
  end

  defp types_under_test do
    [
      "Microsoft.Resources/resourceGroups",
      "Microsoft.EventGrid/topics",
      "Microsoft.ServiceBus/namespaces/queues",
      "Microsoft.ServiceBus/namespaces/topics",
      "Microsoft.Storage/storageAccounts/blobServices/containers",
      "Microsoft.DocumentDB/databaseAccounts"
    ]
  end

  # "2024-01-01" -> "2023-01-01" / "2025-01-01"; parse, never string-arithmetic.
  defp shift_year(version, delta) do
    [y, rest] = String.split(version, "-", parts: 2)
    {y_int, ""} = Integer.parse(y)
    "#{y_int + delta}-#{rest}"
  end

  ## Check 4: host transport — darwin keychain trust for the TLS twin.

  defp check_host_transport(_opts) do
    script = Path.expand("scripts/tf_trust_setup.sh", File.cwd!())

    if File.exists?(script) do
      case System.cmd("bash", [script, "status", "--json"], stderr_to_stdout: true) do
        {out, 0} ->
          trusted(out)

        {out, _} ->
          case Jason.decode(out) do
            {:ok, %{} = decoded} -> warn_or_fail(decoded)
            _ -> warn_or_fail_raw(out)
          end
      end
    else
      %{
        "domain" => "host_transport",
        "check" => "darwin_keychain_trust",
        "status" => "WARN",
        "code" => "DARWIN_TRUST_UNREACHABLE",
        "details" => "tf_trust_setup.sh not found at #{script}",
        "remediation" => %{"action" => "USE_NATIVE_MODE", "command" => "just test-native"}
      }
    end
  end

  defp trusted(out) do
    case Jason.decode(out) do
      {:ok, %{"status" => "PASS"}} ->
        %{
          "domain" => "host_transport",
          "check" => "darwin_keychain_trust",
          "status" => "PASS",
          "details" => "smalt-dev-ca trusted in login keychain; wire_parity_tier AVAILABLE"
        }

      {:ok, decoded} ->
        warn_or_fail(decoded)

      {:error, _} ->
        warn_or_fail_raw(out)
    end
  end

  defp warn_or_fail(decoded) do
    %{
      "domain" => "host_transport",
      "check" => "darwin_keychain_trust",
      "status" => "WARN",
      "code" => "DARWIN_TRUST_MISSING",
      "details" =>
        "smalt-dev-ca not trusted: #{decoded["reason"]} (script status=#{decoded["status"]})",
      "remediation" => %{"action" => "USE_NATIVE_MODE", "command" => "just test-native"}
    }
  end

  defp warn_or_fail_raw(out) do
    %{
      "domain" => "host_transport",
      "check" => "darwin_keychain_trust",
      "status" => "WARN",
      "code" => "DARWIN_TRUST_MISSING",
      "details" => "trust gate unparseable/untrusted: #{String.trim(out)}",
      "remediation" => %{"action" => "USE_NATIVE_MODE", "command" => "just test-native"}
    }
  end

  ## Check 5: affidavit-wasm — artifact present, sha256 matches pin, engine loads.

  # Config contract (mirrors Smalt.Affidavit.WasmEngine): artifact via
  # config :smalt, :affidavit_wasm_path (default priv/wasm/affidavit_wasm.wasm);
  # pin via the priv/wasm/affidavit.sha256 sidecar (the engine's boot-time
  # authority; the engine module-attribute digest is a build-time cross-check
  # only). Any degraded finding is a WARN (aggregate DEGRADED) under the
  # single remediation row AFFIDAVIT_WASM_DEGRADED — details carry the
  # precise cause. Any unexpected crash inside the check (W17/D2: ArgumentError
  # "not an iodata term") is converted to a typed FAIL refusal
  # AFFIDAVIT_ENGINE_UNAVAILABLE — the doctor never crashes on this check.
  defp check_affidavit_wasm do
    typed_affidavit_check()
  end

  defp typed_affidavit_check do
    check_affidavit_wasm_impl()
  rescue
    e ->
      %{
        "domain" => "affidavit_wasm",
        "check" => "artifact_integrity_and_engine",
        "status" => "FAIL",
        "code" => "AFFIDAVIT_ENGINE_UNAVAILABLE",
        "details" =>
          "affidavit engine check crashed and was refused typed: #{Exception.format(:error, e, __STACKTRACE__)}",
        "remediation" => %{
          "action" => "REBUILD_ARTIFACT",
          "command" => "bash scripts/affidavit_wasm_build.sh"
        }
      }
  end

  defp check_affidavit_wasm_impl do
    base = %{
      "domain" => "affidavit_wasm",
      "check" => "artifact_integrity_and_engine"
    }

    path =
      Application.get_env(:smalt, :affidavit_wasm_path, "priv/wasm/affidavit_wasm.wasm")
      |> Path.expand()

    cond do
      not File.regular?(path) ->
        warn(base, "AFFIDAVIT_WASM_DEGRADED", "artifact not found at #{path}")

      true ->
        case verify_sha256(path) do
          {:ok, pinned} ->
            case engine_loads?(path) do
              :ok ->
                Map.merge(base, %{
                  "status" => "PASS",
                  "details" =>
                    "affidavit-wasm artifact verified (sha256 #{String.slice(pinned, 0, 12)}…) and engine loads"
                })

              {:error, reason} ->
                # DEF-1 (lane630): surface the engine's verbatim init refusal
                # alongside the typed load result when one was recorded.
                last = Smalt.Affidavit.WasmEngine.last_init_refusal()

                details =
                  "artifact verified (sha256 #{String.slice(pinned, 0, 12)}…) but engine failed to load: #{inspect(reason)}"

                details =
                  if last == :none,
                    do: details,
                    else: details <> "; last init refusal: #{inspect(last)}"

                warn(base, "AFFIDAVIT_WASM_DEGRADED", details)
            end

          {:error, :pin_file_missing} ->
            warn(
              base,
              "AFFIDAVIT_WASM_DEGRADED",
              "sha256 pin not found (artifact present at #{path})"
            )

          {:error, {:mismatch, pinned, actual}} ->
            warn(
              base,
              "AFFIDAVIT_WASM_DEGRADED",
              "sha256 mismatch: pinned #{pinned}, actual #{actual} (#{path})"
            )
        end
    end
  end

  # sha256 of the artifact vs the pin (same config contract as
  # Smalt.Affidavit.WasmEngine): pin via config :smalt, :affidavit_wasm_pin_path
  # (default priv/wasm/affidavit.sha256, "HEX  filename" format — hash token only).
  defp verify_sha256(path) do
    pin_file =
      Application.get_env(:smalt, :affidavit_wasm_pin_path, "priv/wasm/affidavit.sha256")
      |> Path.expand()

    if File.regular?(pin_file) do
      [pinned | _] =
        pin_file |> File.read!() |> String.trim() |> String.split(~r/\s+/)

      compare(path, String.downcase(pinned))
    else
      {:error, :pin_file_missing}
    end
  end

  defp compare(path, pinned) do
    actual =
      path
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    if actual == pinned,
      do: {:ok, pinned},
      else: {:error, {:mismatch, pinned, actual}}
  end

  # Real engine load: named WasmEngine GenServer. Already-running counts as
  # loaded (whereis). Under the supervised envelope, a miss KICKS the owner
  # child and awaits reappearance with own-mailbox receive-after retries
  # (backoff doubling capped) — zero caller-path sleep. Direct typed start
  # remains the fallback when the owner is not running (isolated faces).
  # The engine fails closed to :engine_unavailable for every admission/
  # instantiation refusal (never raises).
  @await_initial_ms 25
  @await_cap_ms 400
  @await_max_tries 6

  defp engine_loads?(_path) do
    cond do
      Process.whereis(Smalt.Affidavit.WasmEngine) ->
        :ok

      owner = Process.whereis(Smalt.Affidavit.WasmEngine.Supervisor.Owner) ->
        send(owner, {:engine_kick, self()})
        await_engine(@await_max_tries, @await_initial_ms)

      true ->
        case Smalt.Affidavit.WasmEngine.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
  end

  # Monitored reappearance poll in THIS process's own mailbox: receive-after
  # backoff (doubling, capped) — never Process.sleep.
  defp await_engine(tries, _delay) when tries <= 0, do: {:error, :engine_unavailable}

  defp await_engine(tries, delay) do
    if Process.whereis(Smalt.Affidavit.WasmEngine) do
      :ok
    else
      receive do
      after
        delay -> await_engine(tries - 1, min(delay * 2, @await_cap_ms))
      end
    end
  end

  defp warn(base, code, details) do
    Map.merge(base, %{"status" => "WARN", "code" => code, "details" => details})
  end

  defp fault_details(base, []), do: base
  defp fault_details(base, faults), do: "#{base}; faults: #{Enum.join(faults, " | ")}"
end
