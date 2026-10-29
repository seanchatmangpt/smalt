defmodule Smalt.Wasm.Bridge do
  @moduledoc """
  Ingress router to the sandboxed guard engine (WASM-SANDBOX-SPEC.md),
  mapping smalt focus-node transactions onto the REAL graphlaw wasm ABI
  (graphlaw `src/abi.rs`, `ABI_VERSION = 1`).

  `eval/2` packs a focus-node payload into a graphlaw ABI request (the
  production path additionally route-classifies RU charge / If-Match /
  blob-type / byte-range into typed predicate frames), checks a worker out
  of `Smalt.Wasm.Pool`, runs one frame, and maps every sandbox outcome:

    * `{:ok, verdict}`                       — graphlaw ABI verdict envelope
    * `{:error, {:abi_refusal, %{kind, engine, dialect, message, details}}}`
                                             — real ABI refusal (`ok: false`)
    * `{:error, {:sandbox_aborted, detail}}` — trap/panic/memory wall
    * `{:error, {:gate_timeout, :fail_closed}}` — no verdict within budget
    * `{:error, :pool_exhausted}`            — all workers busy

  Fail-closed: a timeout or non-zero guest exit is never a transition; the
  wire layer maps `{:sandbox_aborted, _}` / `{:gate_timeout, _}` to the
  HTTP 500 `SecurityGateFailure` envelope.
  """

  alias Smalt.Wasm.{Pool, Worker}

  @default_dialect "ntriples"

  @doc """
  Packs a smalt focus node into the REAL graphlaw ABI call_json request
  shape (`{"op": ..., ...}`). Real ABI fields, real op names:

    * `"shapes"` present -> `{"op":"shacl","data":{"text","dialect"},"shapes"}` —
      admission is SHACL validation against the focus node's data graph
      (the real `shacl` op in graphlaw `src/abi.rs`).
    * no `"shapes"` -> `{"op":"parse","text","dialect"[,"base"]}` —
      structural admission of the focus node's data graph (the real
      `parse` op).

  Dialects are the ABI's wire names (`dialect_by_name` in graphlaw
  `src/abi.rs`); the default is `ntriples`.
  """
  @spec pack_focus_node(map()) :: map()
  def pack_focus_node(focus) when is_map(focus) do
    case focus do
      %{"shapes" => shapes, "text" => _text} = f when is_binary(shapes) ->
        %{"op" => "shacl", "data" => data_spec(f), "shapes" => shapes}

      %{"text" => text} = f when is_binary(text) ->
        request = %{"op" => "parse", "text" => text}
        request = if base = f["base"], do: Map.put(request, "base", base), else: request
        Map.put(request, "dialect", dialect(f))

      other ->
        raise ArgumentError,
              "pack_focus_node/1 needs a \"text\" (or \"shapes\"+\"text\") focus node, got: #{inspect(other)}"
    end
  end

  @doc "Encodes a packed request to the exact ABI call_json bytes."
  @spec encode_request(map()) :: binary()
  def encode_request(request) when is_map(request), do: Worker.encode_abi_request(request)

  @doc """
  Decodes one ABI response in the opposite direction: `{"ok": true, ...}` ->
  `{:ok, verdict}`; `{"ok": false, "error": {kind, engine, dialect, message,
  details?}}` -> `{:error, {:abi_refusal, normalized}}`. This is the decode
  leg of the encoding round-trip court.
  """
  @spec decode_response(binary()) ::
          {:ok, map()} | {:error, {:abi_refusal, map()}} | {:error, {:malformed_frame, term()}}
  def decode_response(bytes) when is_binary(bytes), do: Worker.decode_abi_response(bytes)

  @doc """
  Unpacks a decoded ABI verdict into the smalt guard envelope. The real
  `shacl` op answers `{"conforms": bool, "results": [...]}`, `parse` answers
  `{"dialect", "quads"|"valid", "id"?}`; both admit on `ok: true`, and a
  SHACL non-conform is a typed guard refusal mapped to the refusal envelope
  the sandbox contract documents.
  """
  @spec unpack_verdict({:ok, map()} | {:error, term()}) ::
          {:ok, map()} | {:error, {:abi_refusal, map()}} | {:error, term()}
  def unpack_verdict({:ok, %{"conforms" => false} = verdict}) do
    {:error,
     {:abi_refusal,
      %{
        kind: "EngineRejected",
        engine: verdict["kind"],
        dialect: nil,
        message: "graphlaw SHACL admission refused: focus node non-conformant",
        details: %{"code" => "NotAdmitted", "results" => verdict["results"] || []}
      }}}
  end

  # Real-runner swap leg (GWS-18): the graphlaw-run adapter returns the RAW
  # ABI response as the stub-mode "result", so an ABI refusal ({"ok": false,
  # "error": {...}}) arrives as a verdict map and must map typed, exactly as
  # decode_response/1 would classify the same bytes on the wire.
  def unpack_verdict({:ok, %{"ok" => false, "error" => err}}) when is_map(err) do
    {:error,
     {:abi_refusal,
      %{
        kind: err["kind"],
        engine: err["engine"],
        dialect: err["dialect"],
        message: err["message"],
        details: Map.get(err, "details")
      }}}
  end

  def unpack_verdict({:ok, verdict}), do: {:ok, verdict}

  def unpack_verdict({:error, _} = other), do: other

  @doc """
  Runs one focus-node transaction end to end: pack -> encode -> sandbox ->
  decode -> unpack. Legacy raw-binary payloads bypass packing (transport-
  level courts use them to exercise failure modes, not encoding).
  """
  @spec eval(binary() | map(), keyword()) :: {:ok, map()} | {:error, term()}
  def eval(payload, opts \\ [])

  def eval(payload, opts) when is_binary(payload) do
    predicate_frames = Keyword.get(opts, :predicate_frames, [])
    do_eval(payload, predicate_frames, opts)
  end

  def eval(focus, opts) when is_map(focus) do
    request = pack_focus_node(focus)
    do_eval(encode_request(request), Keyword.get(opts, :predicate_frames, []), opts)
  end

  defp dialect(f) when is_map(f), do: f["dialect"] || @default_dialect

  defp data_spec(f) do
    spec = %{"text" => f["text"], "dialect" => dialect(f)}
    if base = f["base"], do: Map.put(spec, "base", base), else: spec
  end

  defp do_eval(payload, predicate_frames, opts) do
    pool = Keyword.get(opts, :pool, Pool)

    with {:ok, worker} <- Pool.checkout(pool) do
      try do
        Worker.run(worker, payload, predicate_frames)
      after
        Pool.checkin(pool, worker)
      end
      |> unpack_verdict()
    end
  end
end
