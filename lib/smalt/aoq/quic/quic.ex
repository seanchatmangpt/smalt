defmodule Smalt.Aoq.Quic do
  @moduledoc """
  The AoQ QUIC transport face (v26.11.6 LANE-4): an Elixir API over the
  `Smalt.Aoq.Quic.Nif` dylib surface.

  Laws carried over from the AoQ transport/egress doctrine:
  - every raw NIF `:error` is typed into
    `{:error, {:quic_refusal, reason}}` (the `transport.ex` refusal
    convention, mirrored - never a bare atom leaking to callers);
  - egress takes Frame iolists DIRECTLY, zero append in this module
    (the aoq egress fence law);
  - recv returns the resource-binary untouched - re-parse with
    `Smalt.Aoq.Frame.decode` on the caller side;
  - all waits are bounded INSIDE the NIF (DirtyIo, tokio timeouts in
    the cgap engine) - this module never sleeps, adds no timer.

  Scope honesty: the landed cgap dylib surface is CLIENT-ROLE ONLY
  (open/connect/send/recv, uni-stream). The server face is typed
  UNSUPPORTED here until that surface lands (see `serve/2`).
  """

  alias Smalt.Aoq.Quic.Nif

  @typedoc "Refusal tuple: the transport.ex convention, mirrored."
  @type refusal :: {:error, {:quic_refusal, reason :: term}}

  @typedoc "Engine resource reference (opaque, held by the caller)."
  @type engine :: reference()

  @typedoc "Connection resource reference (opaque, held by the caller)."
  @type conn :: reference()

  @typedoc "Received payload: the NIF resource binary, unparsed."
  @type wire_payload :: binary()

  @doc """
  Opens the QUIC engine: binds a local client endpoint on `port`
  (0 = ephemeral) and pins `ca_der` (trust-anchor DER) for the
  per-connect TLS config. Bounded budget lives in the NIF engine
  (5 s tokio timeout), never a sleep here.
  """
  @spec open(non_neg_integer(), binary()) :: {:ok, engine()} | refusal()
  def open(port, ca_der)
      when is_integer(port) and port >= 0 and port <= 65_535 and is_binary(ca_der) do
    case Nif.aq_quic_open(port, ca_der) do
      ref when is_reference(ref) -> {:ok, ref}
      :error -> {:error, {:quic_refusal, {:nif_open_failed, Nif.load_status()}}}
      other -> {:error, {:quic_refusal, {:nif_bad_return, other}}}
    end
  end

  def open(_port, _ca_der), do: {:error, {:quic_refusal, :badarg}}

  @doc """
  Connects to `addr` ("ip:port" text, e.g. "127.0.0.1:47891")
  presenting `server_name` (SNI). Real TLS 1.3 QUIC handshake on the
  engine thread, bounded 5 s inside the NIF.
  """
  @spec connect(engine(), String.t() | binary(), String.t() | binary()) ::
          {:ok, conn()} | refusal()
  def connect(engine, addr, server_name)
      when is_reference(engine) and is_binary(addr) and is_binary(server_name) do
    case Nif.aq_quic_connect(engine, addr, server_name) do
      ref when is_reference(ref) -> {:ok, ref}
      :error -> {:error, {:quic_refusal, {:nif_connect_failed, Nif.load_status()}}}
      other -> {:error, {:quic_refusal, {:nif_bad_return, other}}}
    end
  end

  def connect(_engine, _addr, _name), do: {:error, {:quic_refusal, :badarg}}

  @doc """
  Sends one uni-stream payload. Accepts the `Smalt.Aoq.Frame.encode/2`
  iolist DIRECTLY - this module performs zero append in its egress
  path (the aoq_egress_fence law). The landed NIF inspects a flat
  binary (enif_inspect_binary), so a non-binary iolist is passed
  through `:erlang.iolist_to_binary/1` - the BEAM scatter-gather
  flattener, a single alloc, DISCLOSED DIVERGENCE from the dispatch
  premise "iolist all the way into the NIF" (the Rust side landed
  enif_inspect_binary, not enif_inspect_iolist_as_binary).
  """
  @spec send(conn(), iodata()) :: :ok | refusal()
  def send(conn, data) when is_reference(conn) and is_binary(data) do
    case nif_send(conn, data) do
      :ok -> :ok
      refusal -> refusal
    end
  end

  def send(conn, data) when is_reference(conn) and is_list(data) do
    case nif_send(conn, :erlang.iolist_to_binary(data)) do
      :ok -> :ok
      refusal -> refusal
    end
  end

  def send(_conn, _data), do: {:error, {:quic_refusal, :badarg}}

  defp nif_send(conn, data) do
    case Nif.aq_quic_send(conn, data) do
      :ok -> :ok
      :error -> {:error, {:quic_refusal, {:nif_send_failed, Nif.load_status()}}}
      other -> {:error, {:quic_refusal, {:nif_bad_return, other}}}
    end
  end

  @doc """
  Receives one uni-stream payload with a bounded budget (ms, 0..60_000,
  enforced by the NIF). Returns the resource-binary untouched.
  """
  @spec recv(conn(), non_neg_integer()) :: {:ok, wire_payload()} | refusal()
  def recv(conn, timeout_ms)
      when is_reference(conn) and is_integer(timeout_ms) and timeout_ms >= 0 and
             timeout_ms <= 60_000 do
    case Nif.aq_quic_recv(conn, timeout_ms) do
      bin when is_binary(bin) -> {:ok, bin}
      :error -> {:error, {:quic_refusal, {:nif_recv_failed, Nif.load_status()}}}
      other -> {:error, {:quic_refusal, {:nif_bad_return, other}}}
    end
  end

  def recv(_conn, _timeout_ms), do: {:error, {:quic_refusal, :badarg}}

  @doc """
  Server face - typed UNSUPPORTED until the cgap dylib lands the
  server role (aq_quic.rs is client-role scaffolding). A typed
  refusal, never a silent no-op.
  """
  @spec serve(non_neg_integer(), keyword()) :: {:ok, reference()} | refusal()
  def serve(_port, _opts) do
    {:error, {:quic_refusal, {:unsupported, :server_role_not_in_nif_surface}}}
  end

  @doc "Accept face - UNSUPPORTED, same receipt as `serve/2`."
  @spec accept(reference()) :: {:ok, conn()} | refusal()
  def accept(_server) do
    {:error, {:quic_refusal, {:unsupported, :server_role_not_in_nif_surface}}}
  end

  @doc "Stream-open face - UNSUPPORTED, same receipt as `serve/2`."
  @spec stream_open(conn()) :: {:ok, reference()} | refusal()
  def stream_open(_conn) do
    {:error, {:quic_refusal, {:unsupported, :server_role_not_in_nif_surface}}}
  end
end
