defmodule Smalt.Aoq.QuicSession.Session do
  @moduledoc """
  Per-connection QUIC session (FNOX-SJ-QUIC-2): a `:gen_statem` that owns one
  accepted connection reference.

  States: `:awaiting_stream` (waiting for the peer's bi-directional stream)
  and `:serving` (echoing payloads on that stream).

  The blocking NIF calls (`Quic.accept_bi/2`, `Quic.stream_recv/2`, both
  DirtyIo) never run in the state-machine process: each is performed by a
  linked helper process that reports back with a message, so the session stays
  responsive to `:sys` and to calls while a recv is pending. Helpers are
  linked, so killing the session takes its helper down with it; sessions are
  `:temporary` and isolated from each other.

  The QUIC engine executes jobs serially on one thread, so a long blocking
  accept or recv would stall every other connection on that engine (witnessed:
  a second connection's stream was never surfaced while the first session sat
  in a 10 s recv). Both calls therefore poll in short slices (`:poll_ms`,
  default 50) and re-arm until the idle budget (`:accept_timeout_ms` /
  `:recv_timeout_ms`, default 10_000) is spent.

  Options: `:conn` (required connection reference), `:accept_timeout_ms`
  (default 10_000), `:recv_timeout_ms` (default 10_000), `:poll_ms`
  (default 50).
  """

  @behaviour :gen_statem

  alias Smalt.Aoq.Quic

  @type state :: :awaiting_stream | :serving

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts), do: :gen_statem.start_link(__MODULE__, opts, [])

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 1_000,
      type: :worker
    }
  end

  @doc "Current state name of a session."
  @spec state(pid()) :: state()
  def state(pid) do
    {state, _data} = :sys.get_state(pid)
    state
  end

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(opts) do
    data = %{
      conn: Keyword.fetch!(opts, :conn),
      stream: nil,
      accept_timeout_ms: Keyword.get(opts, :accept_timeout_ms, 10_000),
      recv_timeout_ms: Keyword.get(opts, :recv_timeout_ms, 10_000),
      poll_ms: Keyword.get(opts, :poll_ms, 50)
    }

    {:ok, :awaiting_stream, data, [{:next_event, :internal, :accept}]}
  end

  @impl true
  def handle_event(:internal, :accept, :awaiting_stream, data) do
    offload_accept(data)
    {:keep_state_and_data, []}
  end

  def handle_event(:info, {:session_io, {:accept_idle, spent_ms}}, :awaiting_stream, data) do
    if spent_ms >= data.accept_timeout_ms do
      {:stop, :normal, data}
    else
      offload_accept(data, spent_ms)
      :keep_state_and_data
    end
  end

  def handle_event(:info, {:session_io, {:accepted, {:ok, stream}}}, :awaiting_stream, data) do
    data = %{data | stream: stream}
    offload_recv(data)
    {:next_state, :serving, data}
  end

  def handle_event(:info, {:session_io, {:accepted, {:error, _}}}, :awaiting_stream, data) do
    {:stop, :normal, data}
  end

  def handle_event(:info, {:session_io, {:recv, {:ok, bytes}}}, :serving, data) do
    case Quic.stream_send(data.stream, bytes) do
      :ok ->
        offload_recv(data)
        :keep_state_and_data

      {:error, _} ->
        {:stop, :normal, data}
    end
  end

  def handle_event(:info, {:session_io, {:recv_idle, spent_ms}}, :serving, data) do
    if spent_ms >= data.recv_timeout_ms do
      _ = Quic.stream_close(data.stream)
      {:stop, :normal, data}
    else
      offload_recv(data, spent_ms)
      :keep_state_and_data
    end
  end

  def handle_event(:info, {:session_io, {:recv, {:error, _}}}, :serving, data) do
    _ = Quic.stream_close(data.stream)
    {:stop, :normal, data}
  end

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  # A slice that returns an error after spending its whole budget is an idle
  # timeout (the NIF reports timeouts and closures with the same shape); an error
  # that comes back early is a real closure.
  defp offload_recv(data, spent_ms \\ 0) do
    offload(fn ->
      case timed(fn -> Quic.stream_recv(data.stream, data.poll_ms) end, data.poll_ms) do
        {:error, :slice_elapsed} -> {:recv_idle, spent_ms + data.poll_ms}
        other -> {:recv, other}
      end
    end)
  end

  defp offload_accept(data, spent_ms \\ 0) do
    offload(fn ->
      case timed(fn -> Quic.accept_bi(data.conn, data.poll_ms) end, data.poll_ms) do
        {:error, :slice_elapsed} -> {:accept_idle, spent_ms + data.poll_ms}
        other -> {:accepted, other}
      end
    end)
  end

  defp timed(fun, slice_ms) do
    t0 = System.monotonic_time(:millisecond)

    case fun.() do
      {:error, _} = err ->
        if System.monotonic_time(:millisecond) - t0 >= slice_ms - 2,
          do: {:error, :slice_elapsed},
          else: err

      ok ->
        ok
    end
  end

  defp offload(fun) do
    parent = self()
    spawn_link(fn -> send(parent, {:session_io, fun.()}) end)
    :ok
  end
end
