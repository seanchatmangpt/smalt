defmodule Smalt.Posh.Client do
  @moduledoc """
  POSH-002 BEAM-side membrane client: 4-byte big-endian length-prefixed JSON
  over a Unix domain socket (`posh/docs/wire-protocol.md` v1).

  Typed failures only — the BEAM caller never sees a raw exception:

      {:ok, term}
      {:error, {:transport, map()}}
      {:error, {:upstream, map()}}
      {:error, {:deadline, map()}}

  Reconnect is supervision-owned: a broken socket is closed and the client
  schedules a reconnect via `Process.send_after` backoff (never
  `Process.sleep`); requests issued while disconnected fail typed transport
  immediately instead of blocking on a dead path.
  """

  use GenServer

  @max_frame_bytes 4 * 1024 * 1024
  @default_deadline_ms 5_000
  @initial_backoff_ms 50
  @max_backoff_ms 2_000

  # ── API ──────────────────────────────────────────────────────────────

  def start_link(opts) do
    path = Keyword.fetch!(opts, :socket_path)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{path: path}, name: name)
  end

  @doc """
  Sends `{id, op, params, deadline}` over the membrane socket.

  Options: `:deadline_ms` (bounded timeout derived from the envelope
  deadline, default #{@default_deadline_ms}). Params are coerced to the
  wire's string map. Frames over the 4 MiB cap are refused client-side.
  """
  @spec request(GenServer.server(), String.t(), map(), keyword) ::
          {:ok, term}
          | {:error, {:transport | :upstream | :deadline, map()}}
  def request(server, op, params \\ %{}, opts \\ []) do
    deadline_ms = Keyword.get(opts, :deadline_ms, @default_deadline_ms)

    try do
      GenServer.call(server, {:request, op, params, deadline_ms}, deadline_ms + 1_000)
    catch
      :exit, {:timeout, {GenServer, :call, _}} ->
        {:error, {:deadline, %{message: "request exceeded deadline", deadline_ms: deadline_ms}}}

      :exit, reason ->
        {:error, {:transport, %{message: "client not alive", reason: reason}}}
    end
  end

  @doc "Current connection state: :connected | {:disconnected, backoff_ms}."
  def status(server), do: GenServer.call(server, :status)

  # ── GenServer ────────────────────────────────────────────────────────

  @impl true
  def init(%{path: path}) do
    state = %{path: path, socket: nil, buffer: <<>>, pending: nil, backoff_ms: @initial_backoff_ms, drop_reason: nil}

    case connect(state) do
      {:ok, state} -> {:ok, state}
      {:error, state} -> {:ok, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, status_tuple(state), state}

  def handle_call({:request, op, params, deadline_ms}, from, state) do
    cond do
      state.pending != nil ->
        {:reply, {:error, {:transport, %{message: "client busy", reason: :request_in_flight}}}, state}

      not is_binary(op) or op == "" ->
        {:reply, {:error, {:transport, %{message: "op must be a non-empty string"}}}, state}

      not is_map(params) ->
        {:reply, {:error, {:transport, %{message: "params must be a map"}}}, state}

      state.socket == nil ->
        {:reply,
         {:error,
          {:transport,
           %{message: "membrane socket disconnected", reason: :closed, path: state.path}}},
         state}

      true ->
        id = "req-" <> Integer.to_string(System.unique_integer([:positive]))

        with {:ok, stringified} <- stringify_params(params) do
          envelope =
            %{"id" => id, "op" => op, "params" => stringified}
            |> maybe_deadline(deadline_ms)

          payload = Jason.encode!(envelope)

          if byte_size(payload) > @max_frame_bytes do
            {:reply,
             {:error,
              {:transport,
               %{
                 message: "frame exceeds 4 MiB client-side cap",
                 reason: :frame_too_large,
                 bytes: byte_size(payload)
               }}},
             state}
          else
            frame = <<byte_size(payload)::32-big, payload::binary>>
            timer = Process.send_after(self(), {:deadline_expired, id}, deadline_ms)

            case :gen_tcp.send(state.socket, frame) do
              :ok ->
                {:noreply, %{state | pending: %{from: from, id: id, timer: timer}}}

              {:error, reason} ->
                Process.cancel_timer(timer)
                state = drop_socket(state, reason)
                {:reply, transport_error(reason, state.path), state}
            end
          end
        else
          :error ->
            {:reply,
             {:error,
              {:transport,
               %{message: "params values must be string-coercible", reason: :bad_params}}},
             state}
        end
    end
  end

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    :inet.setopts(socket, active: :once)
    handle_frames(%{state | buffer: state.buffer <> data})
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    state = drop_socket(state, :closed)
    {:noreply, fail_pending(state, {:transport, %{message: "socket closed", reason: :closed}})}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    state = drop_socket(state, reason)
    {:noreply, fail_pending(state, transport_error(reason, state.path))}
  end

  def handle_info(:reconnect, state) do
    case connect(state) do
      {:ok, state} -> {:noreply, state}
      {:error, state} -> {:noreply, state}
    end
  end

  def handle_info({:deadline_expired, id}, %{pending: %{id: id}} = state) do
    {:noreply, fail_pending(state, {:deadline, %{message: "request exceeded deadline"}})}
  end

  def handle_info({:deadline_expired, _id}, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  # ── internals ────────────────────────────────────────────────────────

  defp status_tuple(%{socket: nil, backoff_ms: ms}), do: {:disconnected, ms}
  defp status_tuple(%{socket: socket}) when socket != nil, do: :connected

  defp connect(%{path: path} = state) do
    opts = [:binary, active: :once, packet: :raw]

    case :gen_tcp.connect({:local, path}, 0, opts) do
      {:ok, socket} ->
        {:ok, %{state | socket: socket, buffer: <<>>, backoff_ms: @initial_backoff_ms}}

      {:error, _reason} ->
        backoff = min(max(state.backoff_ms * 2, @initial_backoff_ms), @max_backoff_ms)
        Process.send_after(self(), :reconnect, backoff)
        {:error, %{state | backoff_ms: backoff}}
    end
  end

  defp drop_socket(%{socket: nil} = state, _reason), do: state

  defp drop_socket(%{backoff_ms: backoff} = state, reason) do
    :gen_tcp.close(state.socket)
    next_backoff = min(max(backoff * 2, @initial_backoff_ms), @max_backoff_ms)
    Process.send_after(self(), :reconnect, next_backoff)
    %{state | socket: nil, buffer: <<>>, backoff_ms: next_backoff, drop_reason: reason}
  end

  # Returns {:noreply, state}; consumes all complete frames in the buffer.
  defp handle_frames(state) do
    case take_frame(state.buffer) do
      {:ok, payload, rest} ->
        state = dispatch_response(%{state | buffer: rest}, payload)
        handle_frames(state)

      {:too_large, reason} ->
        state = drop_socket(state, reason)

        {:noreply,
         fail_pending(
           state,
           {:transport, %{message: "frame length out of bounds", reason: reason}}
         )}

      :incomplete ->
        {:noreply, state}
    end
  end

  defp take_frame(<<0::32-big, _::binary>>), do: {:too_large, :frame_zero}
  defp take_frame(<<len::32-big, _::binary>>) when len > @max_frame_bytes, do: {:too_large, :frame_too_large}

  defp take_frame(<<len::32-big, rest::binary>>) when byte_size(rest) >= len do
    <<payload::binary-size(^len), rest::binary>> = rest
    {:ok, payload, rest}
  end

  defp take_frame(_), do: :incomplete

  defp dispatch_response(%{pending: nil} = state, _payload), do: state

  defp dispatch_response(%{pending: %{from: from, id: id, timer: timer}} = state, payload) do
    Process.cancel_timer(timer)

    reply =
      case Jason.decode(payload) do
        {:ok, %{"id" => ^id} = resp} -> decode_envelope(resp)

        {:ok, _} ->
          {:error, {:transport, %{message: "response id mismatch", reason: :id_mismatch}}}

        {:error, %Jason.DecodeError{} = err} -> {:error, {:transport, %{message: Exception.message(err), reason: :bad_json}}}
      end

    GenServer.reply(from, reply)
    %{state | pending: nil}
  end

  defp decode_envelope(%{"ok" => result}), do: {:ok, result}

  defp decode_envelope(%{"error" => %{"code" => "UPSTREAM"} = err}),
    do: {:error, {:upstream, %{code: "UPSTREAM", message: err["message"], op: err["op"]}}}

  defp decode_envelope(%{"error" => %{"code" => "DEADLINE"} = err}),
    do: {:error, {:deadline, %{message: err["message"], op: err["op"]}}}

  defp decode_envelope(%{"error" => %{"code" => "REFUSED_EGRESS"} = err}),
    do: {:error, {:upstream, %{code: "REFUSED_EGRESS", message: err["message"], op: err["op"]}}}

  defp decode_envelope(%{"error" => %{"code" => code} = err}),
    do: {:error, {:transport, %{message: err["message"], reason: code}}}

  # SHIM-COURT-adjacent fix: an envelope that parses as JSON but carries no
  # recognized ok/error shape is a malformed envelope, not a silent drop.
  defp decode_envelope(_), do: {:error, {:transport, %{message: "malformed response envelope", reason: :bad_envelope}}}

  defp fail_pending(%{pending: nil} = state, _err), do: state

  defp fail_pending(%{pending: %{from: from, timer: timer}} = state, err) do
    Process.cancel_timer(timer)
    GenServer.reply(from, {:error, err})
    %{state | pending: nil}
  end

  defp transport_error(reason, path),
    do: {:transport, %{message: "membrane send failed", reason: reason, path: path}}

  defp maybe_deadline(envelope, ms) when is_integer(ms) and ms > 0 do
    iso =
      DateTime.utc_now()
      |> DateTime.add(ms, :millisecond)
      |> DateTime.to_iso8601()

    Map.put(envelope, "deadline", iso)
  end

  defp maybe_deadline(envelope, _), do: envelope

  # Safe per-value coercion: a value with no String.Chars implementation is a
  # typed :bad_params refusal, never a raise inside handle_call.
  defp stringify_params(params) do
    params
    |> Enum.reduce_while({:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case safe_to_string(v) do
        {:ok, s} -> {:cont, {:ok, Map.put(acc, to_string(k), s)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp safe_to_string(v) when is_binary(v), do: {:ok, v}

  defp safe_to_string(v) do
    {:ok, to_string(v)}
  rescue
    _ -> :error
  end
end
