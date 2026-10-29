defmodule Smalt.Wasm.Worker do
  @moduledoc """
  Port driver for one sandboxed WASM guest (WASM-SANDBOX-SPEC.md), speaking
  the REAL graphlaw wasm ABI (graphlaw `src/abi.rs`, `ABI_VERSION = 1`).

  One graphlaw call is a UTF-8 JSON request `{"op": "...", ...}` answered by
  `{"ok": true, ...}` or `{"ok": false, "error": {kind, engine, dialect,
  message[, details]}}`. Ops are the 14 registry ops (`capabilities`, `sniff`,
  `parse`, `convert`, `canonical`, `sparql`, `shacl`, `shex`, `n3`, `entail`,
  `datalog`, `hooks`, `law`, `policy`) — there is no `eval` op and no
  `OP_EVAL_FOCUS`/`OP_EXEC_DUCKDB` placeholder byte encoding.

  Owns a `Port` whose external process is the sandbox runtime. Two typed
  runtime modes, selected by config:

    * stub mode (default, `config :smalt, :wasm_binary_path` unset) — the
      stub runner (`priv/wasm/stub_runner.exs`). The port frame wraps the
      real ABI request bytes as `payload_b64` inside the runner's eval
      envelope, so the bytes that cross the sandbox boundary are already the
      production `call_json` shape.
    * abi mode (`config :smalt, :wasm_binary_path` set to the graphlaw wasm
      artifact) — the runner is
      `wasmtime run --max-memory 67108864 <binary>` and the port frame IS the
      raw ABI request (exactly the `gl_alloc`/`gl_call` buffer the host test
      in graphlaw `tests/wasm_abi.rs` writes). The reply is decoded per the
      real ABI response contract; `ok: false` becomes a typed
      `{:abi_refusal, %{kind, engine, dialect, message, details}}`.

  IPC is packet-4 binary frames over stdio in both modes.

  Failure model (zero BEAM contamination — no NIF in ERTS address space):

    * guest trap / non-zero exit (memory wall, panic)  -> `{:sandbox_aborted, detail}`, worker exits
    * no reply within the fail-closed timeout (default 5s) -> `{:gate_timeout, :fail_closed}`, worker exits
    * harness fault (runner missing, exec failure)     -> `{:sandbox_aborted, {:exit_status, s}}`, worker exits
    * abi mode: payload is not a JSON request object   -> `{:error, {:abi_request_malformed, detail}}` (typed, pre-send)

  In every failure case the port dies and only the port dies; the pool
  (`Smalt.Wasm.Pool`, trap_exit) sees the EXIT and respawns a fresh worker.
  """

  use GenServer, restart: :temporary

  @default_timeout_ms 5_000
  @default_limit_bytes 67_108_864
  @abi_max_request_bytes 16 * 1024 * 1024
  @abi_version 1

  # -- public API ------------------------------------------------------------

  @doc "Starts one worker. Options: `:name`, `:timeout_ms`, `:limit_bytes`, `:runner_args`."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc """
  Runs one graphlaw ABI frame on this worker.

  `payload` is the ABI request bytes (`{"op": ..., ...}` JSON) — pack a focus
  node with `Smalt.Wasm.Bridge.pack_focus_node/1` +
  `encode_abi_request/1`. In abi mode the raw bytes cross the port; in stub
  mode the same bytes ride the runner's eval envelope as `payload_b64`.

  Returns `{:ok, verdict}` or
  `{:error, {:sandbox_aborted, detail}} | {:error, {:gate_timeout, :fail_closed}}
  | {:error, {:abi_refusal, %{kind, engine, dialect, message, details}}}
  | {:error, {:abi_request_malformed, detail}}`.
  The caller (pool/bridge) MUST checkin afterwards; on any error the worker
  has exited and the checkin is a no-op.
  """
  def run(worker, payload, predicate_frames \\ []) when is_binary(payload) do
    GenServer.call(worker, {:run, payload, predicate_frames}, :infinity)
  end

  @doc """
  ABI revision the worker's encoding targets (graphlaw `src/abi.rs`).
  """
  def abi_version, do: @abi_version

  @doc """
  Encodes one graphlaw ABI request map to the exact call_json byte shape —
  the buffer a host writes via `gl_alloc` and hands to `gl_call`.
  """
  @spec encode_abi_request(map()) :: binary()
  def encode_abi_request(request) when is_map(request), do: Jason.encode!(request)

  @doc """
  Decodes one graphlaw ABI response frame per the real response contract:
  `{"ok": true, ...}` -> `{:ok, verdict}`; `{"ok": false, "error": {...}}` ->
  `{:error, {:abi_refusal, %{kind, engine, dialect, message, details}}}`;
  anything else is a typed malformed frame.
  """
  @spec decode_abi_response(binary()) ::
          {:ok, map()} | {:error, {:abi_refusal, map()}} | {:error, {:malformed_frame, term()}}
  def decode_abi_response(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"ok" => true} = verdict} ->
        {:ok, verdict}

      {:ok, %{"ok" => false, "error" => err}} when is_map(err) ->
        {:error, {:abi_refusal, normalize_refusal(err)}}

      {:ok, other} ->
        {:error, {:malformed_frame, other}}

      {:error, reason} ->
        {:error, {:malformed_frame, reason}}
    end
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    limit = Keyword.get(opts, :limit_bytes, @default_limit_bytes)
    runner_args = Keyword.get(opts, :runner_args, [])

    {program, script_args, mode} = runner_spec(runner_args)

    port =
      Port.open({:spawn_executable, program}, [
        :binary,
        :exit_status,
        packet: 4,
        args: script_args
      ])

    {:ok, %{port: port, timeout_ms: timeout_ms, limit: limit, mode: mode}}
  end

  @impl true
  def handle_call({:run, payload, _predicate_frames}, _from, %{mode: :abi} = state) do
    limit = state.limit

    cond do
      byte_size(payload) > limit ->
        {:stop, {:sandbox_aborted, :memory_wall}, {:error, {:sandbox_aborted, :memory_wall}}, state}

      not abi_request?(payload) ->
        # Typed pre-send refusal: bytes that are not a graphlaw ABI request
        # object never cross the sandbox boundary.
        {:reply, {:error, {:abi_request_malformed, :not_an_abi_request_object}}, state}

      byte_size(payload) > @abi_max_request_bytes ->
        # graphlaw src/abi.rs MAX_REQUEST_BYTES (16 MiB), checked host-side
        # exactly as the module checks it guest-side.
        {:reply,
         {:error,
          {:abi_refusal,
           %{kind: "ResourceLimit", engine: nil, dialect: nil,
             message: "request_bytes over ABI limit", details: %{"limit" => "request_bytes",
             "max" => @abi_max_request_bytes, "observed" => byte_size(payload)}}}}, state}

      true ->
        port = state.port
        Port.command(port, payload)

        receive do
          {^port, {:data, data}} ->
            case decode_abi_response(data) do
              {:ok, verdict} ->
                {:reply, {:ok, verdict}, state}

              {:error, {:abi_refusal, _}} = refusal ->
                {:reply, refusal, state}

              {:error, {:malformed_frame, _} = bad} ->
                {:stop, {:sandbox_aborted, :malformed_frame}, bad, state}
            end

          {^port, {:exit_status, status}} ->
            {:stop, {:sandbox_aborted, {:exit_status, status}},
             {:error, {:sandbox_aborted, {:exit_status, status}}}, state}
        after
          state.timeout_ms ->
            Port.close(state.port)
            {:stop, {:gate_timeout, :fail_closed}, {:error, {:gate_timeout, :fail_closed}}, state}
        end
    end
  end

  def handle_call({:run, payload, predicate_frames}, _from, %{mode: :stub} = state) do
    limit = state.limit

    if byte_size(payload) > limit do
      # The OS/runtime boundary enforces the same ceiling; refusing here is
      # belt-and-braces so an oversized frame never even crosses the port.
      {:stop, {:sandbox_aborted, :memory_wall}, {:error, {:sandbox_aborted, :memory_wall}}, state}
    else
      frame =
        Jason.encode!(%{
          "op" => "eval",
          "payload_b64" => Base.encode64(payload),
          "predicate_frames" => predicate_frames
        })

      Port.command(state.port, frame)
      port = state.port

      receive do
        {^port, {:data, data}} ->
          case Jason.decode(data) do
            {:ok, %{"ok" => true, "result" => result}} ->
              {:reply, {:ok, result}, state}

            {:ok, %{"error" => %{"code" => code} = err}} ->
              {:stop, {:sandbox_aborted, code},
               {:error, {:sandbox_aborted, err["detail"] || code}}, state}

            other ->
              {:stop, {:sandbox_aborted, {:malformed_frame, other}},
               {:error, {:sandbox_aborted, :malformed_frame}}, state}
          end

        {^port, {:exit_status, status}} ->
          {:stop, {:sandbox_aborted, {:exit_status, status}},
           {:error, {:sandbox_aborted, {:exit_status, status}}}, state}
      after
        state.timeout_ms ->
          # Fail-closed gate: no verified verdict within budget -> typed
          # refusal, port killed, worker exits (pool respawns fresh).
          Port.close(state.port)
          {:stop, {:gate_timeout, :fail_closed}, {:error, {:gate_timeout, :fail_closed}}, state}
      end
    end
  end

  @impl true
  def terminate(_reason, %{port: port} = state) do
    close_port(port)
    state
  end

  # Port.close drops the pipe but does NOT reap the child OS process; kill
  # the sandbox process explicitly so a hung guest can never orphan.
  defp close_port(port) do
    if is_port(port) and Port.info(port) != nil do
      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          # Port died between the liveness check and here.
          nil -> nil
        end

      try do
        Port.close(port)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end

      if os_pid, do: kill_os_pid(os_pid)
    end

    :ok
  end

  defp kill_os_pid(os_pid) do
    # The stub runner is elixir -> erl (two OS processes); kill the child
    # tree before the parent so a hung guest can never orphan.
    plist = :erlang.integer_to_list(os_pid)
    :os.cmd(:unicode.characters_to_list(~c"pkill -9 -P " ++ plist))
    :os.cmd(:unicode.characters_to_list(~c"kill -9 " ++ plist))
    :ok
  end

  # -- internal --------------------------------------------------------------

  defp abi_request?(payload) do
    case Jason.decode(payload) do
      {:ok, %{"op" => op}} when is_binary(op) -> true
      _ -> false
    end
  end

  defp normalize_refusal(err) do
    %{
      kind: err["kind"],
      engine: err["engine"],
      dialect: err["dialect"],
      message: err["message"],
      details: Map.get(err, "details")
    }
  end

  # Typed runtime switch. `config :smalt, :wasm_binary_path` set -> abi mode
  # over `wasmtime run --max-memory 67108864 <binary>`; unset -> stub mode.
  defp runner_spec(runner_args) do
    case Application.get_env(:smalt, :wasm_binary_path) do
      nil ->
        runner = runner_path()
        {program, script_args} = runner_command(runner, runner_args)
        {program, script_args, :stub}

      binary when is_binary(binary) ->
        wasmtime = wasm_runtime_executable()
        {wasmtime, ["run", "--max-memory", Integer.to_string(@default_limit_bytes), binary],
         :abi}
    end
  end

  defp runner_path do
    Application.get_env(
      :smalt,
      :wasm_runner_path,
      Path.join(:code.priv_dir(:smalt), "wasm/stub_runner.exs")
    )
  end

  defp wasm_runtime_executable do
    Application.get_env(:smalt, :wasm_runtime_path) || "wasmtime"
  end

  defp runner_command(runner, runner_args) do
    cond do
      # GWS-18 (disclosed minimal unblock fix in WASM-1r's file): a
      # program+args LIST is the config-only real-runner swap shape
      # (`[graphlaw-run, "--wasm", artifact, "--expect-blake3", digest]`);
      # the previous code called String.ends_with?/2 on a list and crashed
      # every worker boot in real-runner mode.
      is_list(runner) ->
        [program | rest] = runner
        {program, rest ++ runner_args}

      String.ends_with?(runner, ".exs") ->
        elixir = System.find_executable("elixir") || raise("elixir not on PATH for wasm runner")

        {elixir, [runner] ++ runner_args}

      true ->
        # Production path: an executable runner (e.g. wasmtime) plus its args.
        {runner, runner_args}
    end
  end
end
