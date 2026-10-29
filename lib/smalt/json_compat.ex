defmodule Smalt.JsonCompat do
  @moduledoc """
  JSON decode engine seam (AR-WIRE-01 rollout, IMPL-5).

  Routes hot decode sites between Jason and native `:json` (stdlib-7.2,
  OTP 28+) behind a config flag. Default is runtime-gated: `:native` when
  `:json` is loaded on the host, else `:jason` — an explicit
  `config :smalt, :json_engine, :jason | :native` overrides the detection.

  Known semantic divergence, typed here and courted in
  `test/json_compat_test.exs`:

  - `:json` decodes JSON `null` to the atom `null`; Jason decodes to `nil`.
    This module normalizes `null` -> `nil` so results are structurally equal
    for every payload both engines accept. All other observed classes are
    byte-equivalent: strings, integers (arbitrary precision preserved),
    floats (1e2 -> 100.0 both engines), maps, arrays, booleans.
  """

  @doc """
  Decode binary JSON (raising). Engine selection:

    * `config :smalt, :json_engine` unset (default) — `:native` when `:json`
      is loadable, else `:jason`
    * `:jason` — force Jason
    * `:native` — force `:json` (falls back to Jason when unavailable)
  """
  @spec decode!(binary()) :: term()
  def decode!(binary) when is_binary(binary) do
    if native?() do
      binary |> :json.decode() |> normalize_null()
    else
      Jason.decode!(binary)
    end
  end

  @doc "Non-raising form: `{:ok, term()} | {:error, exception()}`."
  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    {:ok, decode!(binary)}
  rescue
    e -> {:error, e}
  end

  @doc "Public for the equivalence court: normalize raw `:json` output (null -> nil)."
  def normalize_for_court(term), do: normalize_null(term)

  defp native? do
    Application.get_env(:smalt, :json_engine, default_engine()) == :native and
      Code.ensure_loaded?(:json) and
      function_exported?(:json, :decode, 1)
  end

  # Runtime-gated default: prefer the native OTP `:json` engine when the host
  # ships it, keeping Jason as the fallback on pre-28 hosts. An explicit
  # `config :smalt, :json_engine` overrides this either way.
  defp default_engine do
    if Code.ensure_loaded?(:json) and function_exported?(:json, :decode, 1) do
      :native
    else
      :jason
    end
  end

  # :json maps JSON null to the atom `null`; Jason maps it to `nil`. Normalize
  # so callers see one shape.
  defp normalize_null(null) when null == nil, do: nil
  defp normalize_null(null) when null == :null, do: nil
  defp normalize_null(%{} = map), do: Map.new(map, fn {k, v} -> {k, normalize_null(v)} end)
  defp normalize_null(list) when is_list(list), do: Enum.map(list, &normalize_null/1)
  defp normalize_null(other), do: other


  # ------------------------------------------------------------------
  # Stream (SAX) — T42-verified hook architecture
  # (scripts/bench/t42_json.exs is the executed-API witness). Hooks are
  # arity-specific funs: container-start arity-1, array-push arity-2,
  # object-push arity-3, finish arity-2. The folklore `:json.decode/3`
  # map-of-handlers form does not exist.
  # ------------------------------------------------------------------

  @default_stream_chunk 64 * 1024
  @stream_count_key :smalt_json_stream_count
  @stream_mode_key :smalt_json_stream_mode
  @stream_values_key :smalt_json_stream_values
  @stream_acc_key :smalt_json_stream_acc

  @doc """
  Discard-style SAX streaming decode over the native `:json` decoder
  (OTP 28+ `json:decode_start/3` + `json:decode_continue/2`).

  Feeds the input chunk-wise (default 64 KiB, `opts[:chunk_size]`), builds
  one delivered value at a time, dispatches it to `on_value_fun`, then drops
  it. Peak heap is bounded by the largest single delivered value plus the
  chunk window, never by input size; nothing is retained across values
  unless `opts[:accumulate]` is set.

  Delivery contract:
    * top-level array -> elements dispatched exactly once, in order
    * top-level object -> delivered whole, once, on completion
    * top-level scalar -> delivered on completion
    * concatenated top-level values (NDJSON or unseparated) each delivered

  Returns `{:ok, count}` — or `{:ok, count, values}` with
  `opts[:accumulate]` — or `{:error, {:malformed_json, reason}}` on decode
  failure, truncated input, or empty input.

  Raises `ArgumentError` when the native `:json` SAX API is unavailable
  (pre-OTP-28 host): the helper is API-shaped, not engine-shaped.
  """
  @spec stream(binary() | iodata(), (term() -> term()), keyword()) ::
          {:ok, non_neg_integer()}
          | {:ok, non_neg_integer(), [term()]}
          | {:error, {:malformed_json, term()}}

  def stream(input, on_value_fun, opts \\ []) when is_function(on_value_fun, 1) do
    unless native_sax?() do
      raise ArgumentError,
        "Smalt.JsonCompat.stream/3 requires the native :json SAX API (OTP 28+)"
    end

    acc_mode? = opts[:accumulate] || false
    decoders = stream_decoders(on_value_fun)
    chunks = stream_chunks(IO.iodata_to_binary(input), opts[:chunk_size] || @default_stream_chunk)

    # Hooks and deliver/4 both execute in the caller process (the decoder
    # is a plain fun state machine), so stream state rides the process
    # dictionary for the duration of the call.
    Process.put(@stream_count_key, 0)
    Process.put(@stream_acc_key, acc_mode?)
    Process.put(@stream_values_key, [])

    try do
      run_stream(chunks, :start, decoders, on_value_fun, acc_mode?)
      count = Process.get(@stream_count_key)
      finish_stream(count, acc_mode?, Process.get(@stream_values_key))
    catch
      :throw, {:malformed, reason} -> {:error, {:malformed_json, reason}}
    after
      Process.put(@stream_count_key, nil)
      Process.put(@stream_acc_key, nil)
      Process.put(@stream_values_key, nil)
    end
  end

  defp native_sax? do
    Code.ensure_loaded?(:json) and
      function_exported?(:json, :decode_start, 3) and
      function_exported?(:json, :decode_continue, 2)
  end

  # Hook map. Overrides beyond the T42 discard shape: container lifecycle
  # (build one delivered value at a time) and null normalization. Scalars
  # keep the decoder's native decoding, so delivered terms match decode!/1
  # output modulo null -> nil.
  defp stream_decoders(on_value_fun) do
    %{
      array_start: fn parent_acc -> {acc_depth(parent_acc) + 1, []} end,
      array_push: fn
        v, {1, _elems} ->
          # Direct element of a top-level array: dispatch, drop, count.
          on_value_fun.(normalize_null(v))
          bump_count()
          remember_if_acc(v)
          Process.put(@stream_mode_key, :elementwise)
          {1, []}

        v, {d, elems} ->
          {d, [v | elems]}
      end,
      array_finish: fn {_d, elems}, old -> {:lists.reverse(elems), old} end,
      object_start: fn parent_acc -> {acc_depth(parent_acc) + 1, []} end,
      object_push: fn k, v, {d, kv} -> {d, [{k, v} | kv]} end,
      object_finish: fn {_d, kv}, old -> {Map.new(:lists.reverse(kv)), old} end,
      null: nil
    }
  end

  defp acc_depth({d, _}), do: d
  defp acc_depth(_), do: 0

  defp bump_count, do: Process.put(@stream_count_key, Process.get(@stream_count_key) + 1)

  # Accumulate happens at dispatch time so element-wise docs are captured
  # even though their frame is dropped. Values are stored normalized; only
  # when opts[:accumulate] put the mode key.
  defp remember_if_acc(v) do
    if Process.get(@stream_acc_key) do
      Process.put(@stream_values_key, [normalize_null(v) | Process.get(@stream_values_key)])
    end
  end

  # Split the flattened input into fixed-size chunks (last one short).
  defp stream_chunks(bin, size) when is_integer(size) and size > 0,
    do: do_chunks(bin, size, [])

  defp do_chunks(<<>>, _size, acc), do: Enum.reverse(acc)

  defp do_chunks(bin, size, acc) do
    case bin do
      <<c::binary-size(^size), rest::binary>> -> do_chunks(rest, size, [c | acc])
      _ -> Enum.reverse([bin | acc])
    end
  end

  # Chunk pump. `state` is :start (no decoder state yet) or {:st, st}.
  # When a value completes with leftover bytes, the leftover restarts as the
  # new head chunk (concatenated-document mode) before the next chunk feeds.
  defp run_stream(chunks, state, dec, on_value_fun, acc_mode?) do
    case chunks do
      [] ->
        finish_or_drain(state, dec, on_value_fun, acc_mode?)

      [chunk | rest_chunks] ->
        res =
          try do
            case state do
              :start -> :json.decode_start(chunk, 0, dec)
              {:st, st} -> :json.decode_continue(chunk, st)
            end
          rescue
            e in ErlangError -> {:erlang_error, e}
          end

        case res do
          {:erlang_error, e} ->
            throw({:malformed, decode_error_reason(e)})

          {:continue, st} ->
            run_stream(rest_chunks, {:st, st}, dec, on_value_fun, acc_mode?)

          {:error, reason} ->
                        throw({:malformed, reason})

          {val, _old, leftover} ->
            deliver(val, on_value_fun, acc_mode?)

            case leftover do
              <<>> ->
                run_stream(rest_chunks, :start, dec, on_value_fun, acc_mode?)

              _ ->
                run_stream([leftover | rest_chunks], :start, dec, on_value_fun, acc_mode?)
            end
        end
    end
  end

  # Input exhausted. No pending decoder state: stream done (or empty input).
  # Pending state: drain the decoder — a completed value is delivered; a
  # still-hungry decoder means truncated input.
  defp finish_or_drain(:start, _dec, _on_value_fun, _acc_mode?) do
    if Process.get(@stream_count_key) == 0 do
      throw({:malformed, :empty_input})
    else
      :ok
    end
  end

  defp finish_or_drain({:st, st}, _dec, on_value_fun, acc_mode?) do
    case :json.decode_continue(<<>>, st) do
      {val, _old, <<>>} ->
        deliver(val, on_value_fun, acc_mode?)

      {:continue, _} ->
        # A bare trailing scalar ("1 2 3") is only terminated by whitespace;
        # one space is pure JSON whitespace, so it can complete the value
        # without ever corrupting a genuinely truncated stream.
        case :json.decode_continue(<<" ">>, st) do
          {val, _old, _rest} ->
            deliver(val, on_value_fun, acc_mode?)

          _ ->
            throw({:malformed, :unexpected_end_of_input})
        end

      {:error, reason} ->
        throw({:malformed, reason})
    end
  end

  # Loop-level delivery for top-level objects/scalars (array elements are
  # dispatched inside array_push). The element-wise residual (empty list)
  # is not a value. Normalize, dispatch, count.
  defp deliver(val, on_value_fun, acc_mode?) do
    unless Process.get(@stream_mode_key) == :elementwise and val == [] do
      val = normalize_null(val)
      on_value_fun.(val)
      bump_count()
      if acc_mode?, do: remember_if_acc(val)
    end
  end

  defp finish_stream(count, false, _values), do: {:ok, count}
  defp finish_stream(count, true, values), do: {:ok, count, :lists.reverse(values)}

  # :json raises ErlangError with reason shapes like {:invalid_byte, byte},
  # :unexpected_end, {:unexpected_end, pos}... Map to the typed error.
  defp decode_error_reason(%ErlangError{original: reason}) when is_tuple(reason),
    do: reason

  defp decode_error_reason(%ErlangError{original: reason}), do: reason
  defp decode_error_reason(_), do: :decode_failed
end
