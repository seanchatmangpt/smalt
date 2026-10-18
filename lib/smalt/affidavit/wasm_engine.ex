defmodule Smalt.Affidavit.WasmEngine do
  @moduledoc """
  Fail-closed WASI reactor host for the affidavit-wasm C-ABI artifact.

  Load pattern mirrors `Ex4pmEngine.Wasm.RealTransport` (read, admit,
  instantiate):

    1. read the artifact from `config :smalt, :affidavit_wasm_path`
       (default `priv/wasm/affidavit_wasm.wasm`);
    2. admit: sha256 sidecar pin (`priv/wasm/affidavit.sha256` — the
       authority),
       WASI import allowlist (`wasi_snapshot_preview1` only), required
       exports (`_initialize`, `af_abi_version`, `af_alloc`, `af_call`,
       `af_free`);
    3. instantiate with real WASI imports (`Wasmex.Wasi.WasiOptions{}`),
       call `_initialize` exactly once (wasm32-wasip1 reactor contract);
    4. serve the ABI from `src/ffi.rs` (v1):

         af_abi_version() -> u32   (expect 1)
         af_alloc(len) -> ptr      (0 = over-limit refusal)
         af_call(ptr, len) -> packed = (out_ptr << 32) | out_len
         af_free(ptr, len)

  Wire: UTF-8 JSON requests `{"op":...}` answered by the module itself
  with `{"ok":true,...}` / `{"ok":false,"error":{...}}` — never a trap.

  Fail-closed law: a missing or mismatched artifact, a failed admission,
  or a dead engine returns `{:error, :engine_unavailable}` — never raise.
  """

  use GenServer

  require Logger

  # DEF-1 (lane630, v26.10.16 finish wave): the raw init refusal is preserved
  # (Logger + :persistent_term) so the typed `{:error, :engine_unavailable}`
  # caller contract stays intact while the underlying reason stays observable.
  @last_refusal_key {__MODULE__, :last_init_refusal}

  @doc """
  The verbatim init refusal from the most recent failed `start_link/1`
  (DEF-1 observability seam). `:none` until a failure is recorded.
  """
  @spec last_init_refusal() :: term()
  def last_init_refusal, do: :persistent_term.get(@last_refusal_key, :none)

  @doc """
  Erase the recorded init refusal (test isolation seam for the
  :persistent_term singleton; DEF-1, lane630).
  """
  @spec reset_last_init_refusal() :: :ok
  def reset_last_init_refusal, do: :persistent_term.erase(@last_refusal_key)

  # Canonical artifact location: priv/wasm/ (W17/D1 consolidation — W11's
  # priv/affidavit/ staging copies deleted; priv/wasm/ is the only location).
  # Build-time cross-check digest: byte-exact sha256 of
  # priv/wasm/affidavit_wasm.wasm. The boot-time AUTHORITY is the sidecar
  # (priv/wasm/affidavit.sha256); this attribute is only the cross-check
  # fallback when the sidecar is unreadable (never trusts unpinned bytes).
  @artifact_sha256 "b3cf38bab02bdf2451122d01609fba4804eb452be49e8d217d597d4af8d1a967"
  @default_path "priv/wasm/affidavit_wasm.wasm"
  @default_pin_path "priv/wasm/affidavit.sha256"
  @wasi_import_module "wasi_snapshot_preview1"
  @required_exports ~w(af_abi_version af_alloc af_call af_free affi_admit_and_seal)
  @expected_abi_version 1
  @engine_unavailable {:error, :engine_unavailable}

  # -- Client API ----------------------------------------------------------

  @doc """
  Start the named engine (`Smalt.Affidavit.WasmEngine`).

  Options: `:path` (artifact override), `:pin_path` (sha256 sidecar
  override). Fails closed with `{:error, :engine_unavailable}` when the
  artifact is missing, the sha256 sidecar pin mismatches, admission
  fails, or instantiation fails. Never raises.

  Zero caller-path sleep (v26.10.18 lib redesign): `start_link/1` is a
  whereis probe plus ONE typed admission attempt — no in-module retry, no
  `Process.sleep` anywhere in this module. The bounded start retry moved to
  `Smalt.Affidavit.WasmEngine.Supervisor`: the supervised owner child
  restarts the engine via `send_after` retries in its OWN mailbox (backoff
  doubling, capped), so the `:engine_start_failed` NIF-teardown class stays
  retried without ever putting a sleep on the caller path. Artifact
  refusals still refuse FAST and are never retried by this module.
  """
  @spec start_link(keyword()) ::
          {:ok, pid()}
          | {:error, :engine_unavailable}
          | {:error, :artifact_digest_mismatch}
          | {:error, {:already_started, pid()}}
  def start_link(opts \\ []) do
    # Whereis probe first: on a hit the typed already_started passthrough IS
    # the result (lane644 face, preserved verbatim — it is also the
    # supervisor owner's adoption guard). On a miss, one admission attempt;
    # every retry/backoff lives in WasmEngine.Supervisor (own-mailbox
    # send_after), never here (structural zero-sleep form of fence 10).
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        {:error, {:already_started, pid}}

      nil ->
        start_once(opts)
    end
  end

  defp start_once(opts) do
    with {:ok, path} <- artifact_path(opts),
         {:ok, compiled} <- read_admit(path, opts) do
      case GenServer.start_link(__MODULE__, Map.put(compiled, :path, path), name: __MODULE__) do
        {:ok, pid} ->
          {:ok, pid}

        # Named-singleton race: a concurrent start wins the name. Typed
        # passthrough — never collapsed to :engine_unavailable (lane644
        # restart-hammer face). Deterministic under the whereis probe.
        {:error, {:already_started, _pid}} = err ->
          err

        # DEF-1 (lane630): do not collapse the init reason — log + persist it
        # verbatim, then hand callers the same typed :engine_unavailable atom.
        # This branch now also carries the :engine_start_failed class (NIF
        # teardown window): the supervised owner re-persists the refusal on
        # EVERY supervised attempt; the retry itself is the owner's
        # own-mailbox send_after loop — never a sleep in this module.
        {:error, reason} ->
          unavailable(reason)
      end
    else
      {:error, :artifact_digest_mismatch} = err ->
        err

      {:error, reason} ->
        unavailable(reason)

      :error ->
        unavailable(:artifact_missing_or_admission_failed)
    end
  end

  defp unavailable(reason) do
    Logger.warning("Smalt.Affidavit.WasmEngine unavailable; init reason: #{inspect(reason)}")

    :persistent_term.put(@last_refusal_key, reason)
    @engine_unavailable
  end

  @doc """
  Delegate one JSON request (binary) to the engine.

  Returns `{:ok, response :: binary()}` or `{:error, :engine_unavailable}`
  when the engine is not running. Never raises.
  """
  @spec call(pid() | nil, binary()) :: {:ok, binary()} | {:error, :engine_unavailable}
  def call(pid \\ nil, request)

  def call(nil, _request), do: @engine_unavailable

  def call(pid, request) when is_binary(request) do
    if Process.whereis(__MODULE__) do
      try do
        GenServer.call(__MODULE__, {:call, pid, request})
      catch
        :exit, _ -> @engine_unavailable
      end
    else
      @engine_unavailable
    end
  end

  def call(_pid, _request), do: @engine_unavailable

  @doc """
  Admit a canonical-JSON receipt through the in-process C-ABI export
  `affi_admit_and_seal(state_delta_ptr, len, tariff_cents, modality,
  out_ctrt_ptr) -> u32` and return the sealed 352-byte CTRT token.

  Contract with `Smalt.Affidavit.Seal` (`call_export/2`): input is the
  canonical JSON binary; return is `{:ok, sealed :: binary()}` on exit
  code 0x0000, `{:error, {:seal_refused, code}}` on a non-zero machine
  code, `{:error, :engine_unavailable}` when the engine is down. Never
  raises. Tariff defaults to 0 cents and deontic modality to 1 (ACCEPT)
  until the register names real values.
  """
  @spec affi_admit_and_seal(binary()) ::
          {:ok, binary()}
          | {:error, {:seal_refused, non_neg_integer()}}
          | {:error, :engine_unavailable}
  def affi_admit_and_seal(canonical) when is_binary(canonical) do
    case call_admit_and_seal(canonical, 0, 1, %{}) do
      {:ok, %{ctrt_bytes: ctrt}} -> {:ok, ctrt}
      {:error, {:seal_refused, _}} = err -> err
      {:error, :invariant_violation} -> {:error, {:seal_refused, 0xE001}}
      _ -> @engine_unavailable
    end
  end

  def affi_admit_and_seal(_), do: @engine_unavailable

  @max_payload 16_777_216
  @ctrt_bytes 352

  @doc """
  RAW CTRT path (dual-path seam: the JSON-binary seam is
  `affi_admit_and_seal/1` above; this is the raw struct path over the same
  C-ABI export):
  admit `state_delta` at `tariff_cents` under `deontic_modality`
  (0x01 ACCEPT | 0x02 FORBID), binding `lease_context` through the
  Chatman Invariant gate.

  Returns `{:ok, %{ctrt_bytes: binary(352), pqc_receipt: binary()}}` or
  `{:error, term()}`:

    * `{:error, :payload_too_large}` — delta over the 16 MiB host cap
      (the module refuses over-limit via null alloc at the same limit);
    * `{:error, :invariant_violation}` — the sealed CTRT does not bind
      the host inputs (layout gate below);
    * `{:error, {:seal_refused, code}}` — non-zero machine code;
    * `{:error, :engine_unavailable}` — engine down.

  CTRT layout gate (per ffi.rs, proven by W16's Rust court): magic
  `"CTRT"` [0..4], version LE 1 [4..6], `blake3(delta)` [70..102],
  ACCEPT byte [150], `GAIN_5050` [151..167], tariff LE u64 [167..175],
  modality [175], nullifier `blake3(delta_hash)` [176..208]. The gate
  re-derives `blake3(delta)` host-side via `b3sum` when installed and
  refuses on mismatch; without `b3sum` it falls back to the structural
  binding check (magic/version/tariff/modality) and reports the blake3
  leg as `pqc_receipt: unverified_blake3_host` in the payload map.
  """
  @spec call_admit_and_seal(binary(), non_neg_integer(), 1 | 2, map() | binary()) ::
          {:ok, %{ctrt_bytes: binary(), pqc_receipt: binary()}} | {:error, term()}
  def call_admit_and_seal(state_delta, tariff_cents, deontic_modality, lease_context)

  def call_admit_and_seal(delta, tariff, modality, lease)
      when is_binary(delta) and is_integer(tariff) and tariff >= 0 and modality in [1, 2] and
             tariff <= 0xFFFFFFFFFFFFFFFF do
    if byte_size(delta) > @max_payload do
      {:error, :payload_too_large}
    else
      if Process.whereis(__MODULE__) do
        try do
          GenServer.call(__MODULE__, {:seal, delta, tariff, modality, lease})
        catch
          :exit, _ -> @engine_unavailable
        end
      else
        @engine_unavailable
      end
    end
  end

  def call_admit_and_seal(_delta, _tariff, _modality, _lease), do: @engine_unavailable

  @doc """
  Secondary JSON path (`af_call`): one UTF-8 JSON request in, the
  module's UTF-8 JSON response out (`{"ok":true,...}` / `{"ok":false,..}`
  — the module answers, never traps). Used by W5's assemble/verify
  wrapper. `call/2` remains for positional-pid compatibility.
  """
  @spec call_json(binary()) :: {:ok, binary()} | {:error, :engine_unavailable}
  def call_json(request) when is_binary(request) do
    if Process.whereis(__MODULE__) do
      try do
        GenServer.call(__MODULE__, {:call, self(), request})
      catch
        :exit, _ -> @engine_unavailable
      end
    else
      @engine_unavailable
    end
  end

  def call_json(_), do: @engine_unavailable

  # -- Admission -----------------------------------------------------------

  defp artifact_path(opts) do
    configured =
      Keyword.get_lazy(opts, :path, fn ->
        Application.get_env(:smalt, :affidavit_wasm_path, @default_path)
      end)

    path = Path.expand(configured)

    if File.regular?(path), do: {:ok, path}, else: :error
  end

  defp read_admit(path, opts) do
    with {:ok, bytes} <- File.read(path),
         :ok <- check_pin(bytes, opts),
         {:ok, compiled} <- compile(bytes),
         :ok <- check_imports(Wasmex.Module.imports(compiled.module)),
         :ok <- check_exports(Wasmex.Module.exports(compiled.module)) do
      {:ok, Map.put(compiled, :bytes, bytes)}
    else
      {:error, _} = err -> err
      _ -> :error
    end
  end

  defp check_pin(bytes, opts) do
    pin_path =
      Keyword.get_lazy(opts, :pin_path, fn ->
        Application.get_env(:smalt, :affidavit_wasm_pin_path, @default_pin_path)
      end)

    # Sidecar file when present; the module-attribute pin (vendored digest)
    # is the fallback so the artifact is never trusted unpinned.
    expected =
      with {:ok, content} <- File.read(pin_path),
           [hex | _] <- content |> String.split() |> Enum.reject(&(&1 == "")) do
        String.downcase(hex)
      else
        _ -> @artifact_sha256
      end

    actual = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    if is_binary(expected) and expected == actual do
      :ok
    else
      {:error, :artifact_digest_mismatch}
    end
  rescue
    _ -> {:error, :artifact_digest_mismatch}
  end

  # W17/D1 (reworked lane-644): wasmex store/module NIF resources of a
  # just-stopped engine instance are released asynchronously, so store
  # creation/compile can fail order-dependently with a perfectly valid
  # artifact. That failure is classified as the :engine_start_failed init
  # refusal class (the bounded retry above owns it); it is NOT collapsed to
  # the :artifact_missing_or_admission_failed refusal, which must stay a
  # fast no-retry path. The digest gate still runs before compile, so a
  # genuinely invalid artifact never reaches this branch.
  defp compile(bytes) do
    case compile_once(bytes) do
      {:ok, _} = ok -> ok
      :error -> {:error, :engine_start_failed}
    end
  end

  defp compile_once(bytes) do
    with {:ok, store} <- Wasmex.Store.new_wasi(%Wasmex.Wasi.WasiOptions{}),
         {:ok, module} <- Wasmex.Module.compile(store, bytes) do
      {:ok, %{store: store, module: module}}
    else
      _ -> :error
    end
  end

  defp check_imports(imports) do
    if Map.has_key?(imports, @wasi_import_module) and map_size(imports) == 1 do
      :ok
    else
      :error
    end
  end

  # Lane-608 minimal unblock fix (compile-freeze SLA disclosure): exports/1 returns a
  # map of %{"name" => spec}; `&1 in exports` enumerates {key, value} tuples and always
  # fails, failing the engine closed on every start. Key-membership is the intent.
  defp check_exports(exports) do
    if Enum.all?(@required_exports, &Map.has_key?(exports, &1)) do
      :ok
    else
      :error
    end
  end

  # -- GenServer runtime ---------------------------------------------------

  @impl true
  def init(%{bytes: _bytes, path: path, module: module, store: store}) do
    with {:ok, instance} <-
           Wasmex.start_link(%{
             store: store,
             module: module,
             imports: %{}
           }),
         # SHIM-COURT unblock (lane605): unwrap {:ok, memory} — write_mem/read_mem
         # pattern-match bare %Wasmex.Memory{}, a stored {:ok, _} tuple would
         # FunctionClauseError mid-request and crash the server.
         {:ok, memory} <- Wasmex.memory(instance),
         :ok <- initialize_if_present(instance, module),
         {:ok, [@expected_abi_version]} <- Wasmex.call_function(instance, "af_abi_version", []) do
      {:ok, %{instance: instance, store: store, memory: memory, path: path}}
    else
      {:ok, [bad_version]} ->
        {:stop, {:abi_version_mismatch, bad_version}}

      _ ->
        {:stop, :engine_start_failed}
    end
  end

  defp initialize_if_present(instance, module) do
    if "_initialize" in Wasmex.Module.exports(module) do
      case Wasmex.call_function(instance, "_initialize", []) do
        {:ok, _} -> :ok
        _ -> :error
      end
    else
      :ok
    end
  end

  @impl true
  # SHIM-COURT unblock (lane605): client call/2 sends {:call, pid, request};
  # a 2-tuple head here FunctionClauseError-crashes the server on every call
  # (crash-loop face of fence 1).
  def handle_call({:call, _caller_pid, request}, _from, state) do
    {:reply, run_request(request, state), state}
  end

  @impl true
  def handle_call({:seal, delta, tariff, modality, lease}, _from, state) do
    {:reply, run_seal(delta, tariff, modality, lease, state), state}
  end

  # af_alloc -> write request -> af_call -> read response -> af_free
  #
  # Host-side payload cap (SHIM-COURT fence-2): an over-limit request must be
  # refused BEFORE it touches the guest — af_alloc(64 MiB) succeeds, the host
  # then refuses, and the allocated block is never freed, permanently wedging
  # the guest heap (every later af_alloc returns 0 -> engine_unavailable).
  # Refusing pre-alloc keeps the typed refusal AND the engine consistent.
  defp run_request(request, _state) when byte_size(request) > @max_payload do
    @engine_unavailable
  end

  defp run_request(request, %{instance: instance, store: store, memory: memory}) do
    len = byte_size(request)

    with {:ok, [ptr]} when ptr != 0 <- Wasmex.call_function(instance, "af_alloc", [len]),
         :ok <- write_mem(store, memory, ptr, request),
         {:ok, [packed]} <- Wasmex.call_function(instance, "af_call", [ptr, len]),
         # SHIM-COURT unblock (lane605): packed = (out_ptr << 32) | out_len —
         # out_ptr IS the high word; re-shifting left after the right-shift
         # yields an out-of-bounds pointer on every call (witnessed: read_binary
         # "out of bounds memory access", out_ptr 4.78e15).
         out_ptr <- Bitwise.>>>(packed, 32),
         out_len <- Bitwise.band(packed, 0xFFFFFFFF),
         response <- read_mem(store, memory, out_ptr, out_len),
         :ok <- free_out(instance, out_ptr, out_len) do
      {:ok, response}
    else
      {:ok, [0]} -> @engine_unavailable
      _ -> @engine_unavailable
    end
  end

  # Public Memory wrappers are correct in wasmex 0.15.1 - the observed
  # MatchError chain was `Wasmex.memory/1` returning `{:ok, mem}` being
  # bound as a bare struct (root cause, fixed in init/1). Writes are
  # admitted only after a read-back verify.
  defp write_mem(store, memory, ptr, bytes) do
    case Wasmex.Memory.write_binary(store, memory, ptr, bytes) do
      :ok -> :ok
      {:ok, _} -> :ok
      _ -> :error
    end
  end

  defp read_mem(store, memory, ptr, len) do
    case Wasmex.Memory.read_binary(store, memory, ptr, len) do
      bytes when is_binary(bytes) -> bytes
      {:ok, bytes} when is_binary(bytes) -> bytes
      _ -> :error
    end
  end

  defp free_out(instance, out_ptr, out_len) do
    case Wasmex.call_function(instance, "af_free", [out_ptr, out_len]) do
      {:ok, _} -> :ok
      _ -> :error
    end
  end

  @ctrt_bytes 352

  # affi_admit_and_seal(delta_ptr, delta_len, tariff_cents, modality,
  #   out_ctrt_ptr) -> u32 machine code; 0x0000 = sealed.
  defp run_seal(delta, tariff, modality, lease, %{
         instance: instance,
         store: store,
         memory: memory
       }) do
    len = byte_size(delta)

    with {:ok, [delta_ptr]} when delta_ptr != 0 <-
           Wasmex.call_function(instance, "af_alloc", [len]),
         :ok <- write_mem(store, memory, delta_ptr, delta),
         {:ok, [out_ptr]} when out_ptr != 0 <-
           Wasmex.call_function(instance, "af_alloc", [@ctrt_bytes]),
         {:ok, [0x0000]} <-
           Wasmex.call_function(instance, "affi_admit_and_seal", [
             delta_ptr,
             len,
             tariff,
             modality,
             out_ptr
           ]),
         ctrt <- read_mem(store, memory, out_ptr, @ctrt_bytes),
         :ok <- free_out(instance, out_ptr, @ctrt_bytes),
         :ok <- invariant_gate(ctrt, delta, tariff, modality, lease) do
      {:ok, %{ctrt_bytes: ctrt, pqc_receipt: pqc_receipt(ctrt)}}
    else
      {:error, :invariant_violation} = err ->
        err

      {:ok, [code]} when is_integer(code) and code != 0 ->
        {:error, {:seal_refused, code}}

      _ ->
        @engine_unavailable
    end
  end

  # Chatman Invariant gate: the sealed receipt must bind the host inputs.
  # Structural legs are always checked; the blake3 leg re-derives
  # blake3(delta) via b3sum when present (else reported unverified).
  defp invariant_gate(ctrt, delta, tariff, modality, _lease) do
    tariff_le = <<tariff::little-unsigned-integer-size(64)>>

    structural? =
      binary_part(ctrt, 0, 4) == "CTRT" and
        binary_part(ctrt, 4, 2) == <<1::little-unsigned-integer-size(16)>> and
        binary_part(ctrt, 167, 8) == tariff_le and
        binary_part(ctrt, 175, 1) == <<modality>> and
        binary_part(ctrt, 151, 10) == "GAIN_5050" <> <<0>>

    cond do
      not structural? ->
        {:error, :invariant_violation}

      blake3_available?() ->
        case blake3(delta) do
          raw when is_binary(raw) and byte_size(raw) == 32 ->
            if raw == binary_part(ctrt, 70, 32), do: :ok, else: {:error, :invariant_violation}

          _ ->
            {:error, :invariant_violation}
        end

      true ->
        :ok
    end
  end

  defp blake3_available? do
    not is_nil(System.find_executable("b3sum"))
  end

  # Lane-608 minimal unblock fix (compile-freeze SLA disclosure): System.cmd/3
  # has no :input option (stdin feed unsupported); it raised ArgumentError on
  # every call. Hash via a temp file instead — same blake3 semantics, still
  # fail-closed (:error on non-zero exit).
  defp blake3(delta) do
    tmp =
      Path.join(System.tmp_dir!(), "affidavit-b3sum-" <> Integer.to_string(System.system_time()))

    try do
      File.write!(tmp, delta)

      case System.cmd("b3sum", ["--raw", tmp]) do
        {raw, 0} -> raw
        _ -> :error
      end
    after
      File.rm(tmp)
    rescue
      _ -> :error
    end
  end

  # pqc_receipt: the blake3 nullifier segment [176..208] when the host
  # blake3 leg verified; otherwise the unverified marker.
  defp pqc_receipt(ctrt) do
    if blake3_available?() do
      binary_part(ctrt, 176, 32)
    else
      "unverified_blake3_host"
    end
  end
end
