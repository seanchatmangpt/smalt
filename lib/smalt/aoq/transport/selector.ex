defmodule Smalt.Aoq.Transport.Selector do
  @moduledoc """
  FNOX-SJ-QUIC-4: chooses between `Smalt.Aoq.Quic` and h2 over TLS/TCP.

  `connect/1` tries QUIC first. A typed `{:error, {:quic_refusal, _}}` from the
  QUIC open or connect (handshake failure, blocked or closed UDP, NIF absent)
  falls back to an h2 session (`:ssl`, ALPN `h2`, `verify_peer` against the
  same CA). The result records which transport carried the session.

  A malformed CA is not a handshake failure: it is refused up front as
  `{:error, {:selector_refusal, {:bad_ca, _}}}` with no fallback. An h2 failure
  after fallback is returned typed as `{:error, {:h2_refusal, reason}}`; there
  is no third transport.

  Options (all required unless noted):

    * `:ca_der` - trust-anchor DER binary
    * `:quic` - `{host, port}` of the QUIC endpoint
    * `:h2` - `{host, port}` of the TCP TLS endpoint
    * `:server_name` - SNI / verification name (default `"localhost"`)
    * `:timeout_ms` - h2 connect budget (default 5_000)
  """

  alias Smalt.Aoq.Quic

  @type session :: %{
          required(:transport) => :quic | :h2,
          required(:fallback_reason) => nil | term(),
          optional(:conn) => reference(),
          optional(:stream) => reference(),
          optional(:socket) => :ssl.sslsocket()
        }

  @type refusal ::
          {:error, {:selector_refusal, term()}} | {:error, {:h2_refusal, term()}}

  @doc "Selects a transport and returns an open session map."
  @spec connect(keyword()) :: {:ok, session()} | refusal()
  def connect(opts) do
    with {:ok, ca_der} <- fetch_ca(opts),
         {:ok, quic_addr} <- fetch_addr(opts, :quic),
         {:ok, h2_addr} <- fetch_addr(opts, :h2),
         :ok <- validate_ca(ca_der) do
      name = Keyword.get(opts, :server_name, "localhost")

      case try_quic(ca_der, quic_addr, name) do
        {:ok, session} -> {:ok, session}
        {:error, {:quic_refusal, _} = reason} -> connect_h2(ca_der, h2_addr, name, reason, opts)
      end
    end
  end

  @doc "Sends `data` on the selected transport."
  @spec send(session(), iodata()) :: :ok | {:error, term()}
  def send(%{transport: :quic, stream: stream}, data), do: Quic.stream_send(stream, data)

  def send(%{transport: :h2, socket: socket}, data) do
    case :ssl.send(socket, data) do
      :ok -> :ok
      {:error, reason} -> {:error, {:h2_refusal, reason}}
    end
  end

  @doc "Receives one payload (bounded by `timeout_ms`) on the selected transport."
  @spec recv(session(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def recv(%{transport: :quic, stream: stream}, timeout_ms) do
    case Quic.stream_recv(stream, timeout_ms) do
      {:ok, bin} -> {:ok, :binary.copy(bin)}
      other -> other
    end
  end

  def recv(%{transport: :h2, socket: socket}, timeout_ms) do
    case :ssl.recv(socket, 0, timeout_ms) do
      {:ok, bin} -> {:ok, bin}
      {:error, reason} -> {:error, {:h2_refusal, reason}}
    end
  end

  @doc "Closes the session."
  @spec close(session()) :: :ok
  def close(%{transport: :h2, socket: socket}) do
    _ = :ssl.close(socket)
    :ok
  end

  def close(%{transport: :quic, stream: stream}) do
    _ = Quic.stream_close(stream)
    :ok
  end

  # -- QUIC leg ---------------------------------------------------------------

  defp try_quic(ca_der, {host, port}, name) do
    with {:ok, engine} <- Quic.open(0, ca_der),
         {:ok, conn} <- Quic.connect(engine, "#{host}:#{port}", name),
         {:ok, stream} <- Quic.stream_open(conn) do
      {:ok, %{transport: :quic, fallback_reason: nil, conn: conn, stream: stream}}
    end
  end

  # -- h2 leg -----------------------------------------------------------------

  defp connect_h2(ca_der, {host, port}, name, reason, opts) do
    timeout = Keyword.get(opts, :timeout_ms, 5_000)

    ssl_opts = [
      :binary,
      active: false,
      verify: :verify_peer,
      cacerts: [ca_der],
      server_name_indication: String.to_charlist(name),
      alpn_advertised_protocols: ["h2"]
    ]

    with {:ok, socket} <- h2_connect(host, port, ssl_opts, timeout),
         :ok <- check_alpn(socket) do
      {:ok, %{transport: :h2, fallback_reason: reason, socket: socket}}
    end
  end

  defp h2_connect(host, port, ssl_opts, timeout) do
    case :ssl.connect(to_host(host), port, ssl_opts, timeout) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, {:h2_refusal, reason}}
    end
  end

  defp check_alpn(socket) do
    case :ssl.negotiated_protocol(socket) do
      {:ok, "h2"} ->
        :ok

      other ->
        _ = :ssl.close(socket)
        {:error, {:h2_refusal, {:alpn_not_h2, other}}}
    end
  end

  defp to_host(host) when is_binary(host), do: String.to_charlist(host)
  defp to_host(host), do: host

  # -- option checks ----------------------------------------------------------

  defp fetch_ca(opts) do
    case Keyword.fetch(opts, :ca_der) do
      {:ok, ca} when is_binary(ca) -> {:ok, ca}
      _ -> {:error, {:selector_refusal, {:bad_ca, :missing}}}
    end
  end

  defp fetch_addr(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, {host, port}} when is_integer(port) -> {:ok, {host, port}}
      _ -> {:error, {:selector_refusal, {:bad_address, key}}}
    end
  end

  defp validate_ca(ca_der) do
    _ = :public_key.pkix_decode_cert(ca_der, :otp)
    :ok
  rescue
    e -> {:error, {:selector_refusal, {:bad_ca, e.__struct__}}}
  catch
    kind, _ -> {:error, {:selector_refusal, {:bad_ca, kind}}}
  end
end
