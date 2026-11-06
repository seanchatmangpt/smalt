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

  Scope (2026-11-05): the L3 server role LANDED - the full face is
  open/connect/send/recv (uni-stream client) PLUS serve/accept/
  accept_bi/stream_open/stream_send/stream_recv/stream_close (bi-dir
  server+client streams). ALPN is `aq/1`, REQUIRED server-side; the
  SHIM-COURT mutation `AQ_MUTATE_ALPN_DROP=1` strips it client-side
  and the handshake must refuse.
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
  Server face (L3 server role LANDED 2026-11-05): builds the rustls
  ServerConfig (ALPN aq/1 REQUIRED server-side) and binds UDP `port`
  on the engine thread. Takes the ENGINE resource from `open/2` plus
  the leaf cert DER + key DER (PKCS8). `{:ok, listener}` | refusal.
  """
  @spec serve(engine(), non_neg_integer(), binary(), binary()) ::
          {:ok, reference()} | refusal()
  def serve(engine, port, cert_der, key_der)
      when is_reference(engine) and is_integer(port) and port >= 0 and
             port <= 65_535 and is_binary(cert_der) and is_binary(key_der) do
    case Nif.aq_quic_serve(engine, port, cert_der, key_der) do
      ref when is_reference(ref) -> {:ok, ref}
      :error -> {:error, {:quic_refusal, {:nif_serve_failed, Nif.load_status()}}}
      other -> {:error, {:quic_refusal, {:nif_bad_return, other}}}
    end
  end

  def serve(_engine, _port, _cert_der, _key_der), do: {:error, {:quic_refusal, :badarg}}

  @doc "Bounded server-side accept of one inbound QUIC connection."
  @spec accept(reference(), non_neg_integer()) :: {:ok, conn()} | refusal()
  def accept(listener, timeout_ms)
      when is_reference(listener) and is_integer(timeout_ms) and timeout_ms >= 0 and
             timeout_ms <= 60_000 do
    case Nif.aq_quic_accept(listener, timeout_ms) do
      ref when is_reference(ref) -> {:ok, ref}
      :error -> {:error, {:quic_refusal, {:nif_accept_failed, Nif.load_status()}}}
      other -> {:error, {:quic_refusal, {:nif_bad_return, other}}}
    end
  end

  def accept(_listener, _timeout_ms), do: {:error, {:quic_refusal, :badarg}}

  @doc "Server side: accept a peer-initiated bi-directional stream."
  @spec accept_bi(conn(), non_neg_integer()) :: {:ok, reference()} | refusal()
  def accept_bi(conn, timeout_ms)
      when is_reference(conn) and is_integer(timeout_ms) and timeout_ms >= 0 and
             timeout_ms <= 60_000 do
    case Nif.aq_quic_accept_bi(conn, timeout_ms) do
      ref when is_reference(ref) -> {:ok, ref}
      :error -> {:error, {:quic_refusal, {:nif_accept_bi_failed, Nif.load_status()}}}
      other -> {:error, {:quic_refusal, {:nif_bad_return, other}}}
    end
  end

  def accept_bi(_conn, _timeout_ms), do: {:error, {:quic_refusal, :badarg}}

  @doc "Client side: open one bi-directional stream."
  @spec stream_open(conn()) :: {:ok, reference()} | refusal()
  def stream_open(conn) when is_reference(conn) do
    case Nif.aq_quic_stream_open(conn) do
      ref when is_reference(ref) -> {:ok, ref}
      :error -> {:error, {:quic_refusal, {:nif_stream_open_failed, Nif.load_status()}}}
      other -> {:error, {:quic_refusal, {:nif_bad_return, other}}}
    end
  end

  def stream_open(_conn), do: {:error, {:quic_refusal, :badarg}}

  @doc """
  Sends on a bi-directional stream. The `Smalt.Aoq.Frame.encode/2`
  iolist goes DIRECTLY into the NIF (enif_inspect_iolist_as_binary -
  the dispatch's zero-concat egress premise, LANDED in the stream
  path). write_all, no finish - bi streams persist for further frames.
  """
  @spec stream_send(reference(), iodata()) :: :ok | refusal()
  def stream_send(stream, data)
      when is_reference(stream) and (is_binary(data) or is_list(data)) do
    case Nif.aq_quic_stream_send(stream, data) do
      :ok -> :ok
      :error -> {:error, {:quic_refusal, {:nif_stream_send_failed, Nif.load_status()}}}
      other -> {:error, {:quic_refusal, {:nif_bad_return, other}}}
    end
  end

  def stream_send(_stream, _data), do: {:error, {:quic_refusal, :badarg}}

  @doc "Bounded recv on a bi-directional stream (resource-binary out)."
  @spec stream_recv(reference(), non_neg_integer()) :: {:ok, binary()} | refusal()
  def stream_recv(stream, timeout_ms)
      when is_reference(stream) and is_integer(timeout_ms) and timeout_ms >= 0 and
             timeout_ms <= 60_000 do
    case Nif.aq_quic_stream_recv(stream, timeout_ms) do
      bin when is_binary(bin) -> {:ok, bin}
      :error -> {:error, {:quic_refusal, {:nif_stream_recv_failed, Nif.load_status()}}}
      other -> {:error, {:quic_refusal, {:nif_bad_return, other}}}
    end
  end

  def stream_recv(_stream, _timeout_ms), do: {:error, {:quic_refusal, :badarg}}

  @doc "Closes a bi-directional stream (recv STOP + send RESET)."
  @spec stream_close(reference()) :: :ok | refusal()
  def stream_close(stream) when is_reference(stream) do
    case Nif.aq_quic_stream_close(stream) do
      :ok -> :ok
      :error -> {:error, {:quic_refusal, {:nif_stream_close_failed, Nif.load_status()}}}
      other -> {:error, {:quic_refusal, {:nif_bad_return, other}}}
    end
  end

  def stream_close(_stream), do: {:error, {:quic_refusal, :badarg}}
end

