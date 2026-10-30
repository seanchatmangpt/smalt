defmodule Smalt.DataPlane.RedisWire do
  @moduledoc """
  RESP2 wire listener over `Smalt.DataPlane.AzureCache.handle/2` — the
  `:gen_tcp` byte pump the T-06 revision dropped (see the AzureCache moduledoc
  history): framing only. Every command is evaluated by the SAME engine the
  in-BEAM callers use; this layer owns sockets, framing and account selection
  and nothing else.

  ## Topology (mirrors `Smalt.AmqpBroker` / `Smalt.Amqp.Listener`)

    * `Smalt.DataPlane.RedisWire` — facade supervisor, a child of
      `Smalt.Plane.IntegrationSupervisor` (non-deferred, the
      `broker_children/0` precedent). It OWNS the bind: the listening socket
      is opened in `init/1` so a bind failure is CONTAINED — the listener
      child is simply not added to the tree and the app boots (the
      AmqpBroker containment contract; the facade stays up serving nothing).
    * `Smalt.DataPlane.RedisWire.Listener` — one accept-loop GenServer over
      the facade-owned listen socket (bounded accept + backoff, the
      `Smalt.Amqp.Listener` pattern). Accepted sockets are handed off to
    * `Smalt.DataPlane.RedisWire.Conn` — one connection process per client,
      a `:temporary` child of the facade's DynamicSupervisor: a conn crash is
      contained to that client, the listener keeps accepting.

  ## Framing

  RESP2 multibulk (`*N\\r\\n` + `$len\\r\\n<payload>\\r\\n` per token) AND
  inline commands (`PING\\r\\n`) are accepted, per the real Redis protocol.
  Parsed token lists go to `AzureCache.handle(account, tokens)`; the returned
  resp2 binary is written verbatim. `QUIT` closes. An unrecoverable framing
  error answers `-ERR protocol error\\r\\n` and closes. Bounded recv buffer +
  a command-size ceiling (no unbounded accumulation).

  ## Account selection

  `AUTH <account-token> <password>` (2 args) with a structurally valid account
  token (the `AzureCache` account charset law) selects that account's keyspace
  for the rest of the connection; the engine itself accepts any AUTH
  (documented divergence), so the wire layer only pins the KEYSPACE. All other
  commands ride the connection's current account (default:
  `AzureCache.default_account/0`).

  ## AAD token auth (Azure Cache Entra ID; r16 lane S3, additive)

  The real Azure Cache Entra mechanism is also accepted: `AUTH <oid> <token>`
  (JWT-shaped password) and the combined `AUTH <user>=<token>` (1-arg) form
  route to `Smalt.Identity.EntraToken.verify_redis_auth/2` (signature via the
  STS key, exp/nbf/aud law, audience `https://redis.azure.com/` by default).
  On a verified token the wire answers `+OK` and KEEPS the current keyspace
  (Azure Cache is one shared keyspace across Entra identities; keyspace
  selection stays the legacy access-key law). Any failure maps to the real
  Redis refusal: `-ERR WRONGPASS invalid username-password pair or user is
  disabled.`

  ## Honesty surface (follow-up wiring for `AzureCache.registry/2`)

  `configured_port/0` and `honesty_rows/0` are pure functions reporting the
  configured `:redis_port` / listener standing. The `tcp_port:0` /
  `wireListener:"none"` rows inside `AzureCache.registry/2` are NOT this
  lane's file (azure_cache.ex is contract-read-only here) — flipping them to
  call these functions is a one-line follow-up; noted in the lane receipt.
  """

  use Supervisor
  require Logger

  @conn_sup_name Smalt.DataPlane.RedisWire.ConnSup
  @listener_name Smalt.DataPlane.RedisWire.Listener

  # -- Facade supervisor ---------------------------------------------------------

  @doc "Starts the facade. `opts[:port]` overrides `config :smalt, :redis_port` (default 6380)."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The bound port of the live listener, or `nil` when the bind failed/was skipped."
  @spec port(GenServer.server() | nil) :: :inet.port_number() | nil
  def port(nil), do: nil

  def port(server), do: GenServer.call(server, :port)

  @doc "The configured redis port: `config :smalt, :redis_port`, default 6380."
  @spec configured_port() :: :inet.port_number()
  def configured_port, do: Application.get_env(:smalt, :redis_port, 6380)

  @doc """
  Ensures `account`'s Cachex instance runs SUPERVISED under the wire facade's
  conn supervisor (idempotent). The engine's own `cache_start/1` is
  first-caller-LINKED — a wire conn process must never be that first caller,
  or the keyspace dies with the connection. Wire conns call this before their
  first command (and on AUTH account switches).
  """
  @spec ensure_cache(binary()) :: {:ok, pid()} | {:error, term()}
  def ensure_cache(account) when is_binary(account) do
    name = Smalt.DataPlane.AzureCache.cache_name(account)

    case Process.whereis(name) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        child = Smalt.DataPlane.AzureCache.cache_child_spec(account)

        case DynamicSupervisor.start_child(@conn_sup_name, child) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Pure honesty rows for the registry flip follow-up: the `tcp_port` /
  `wireListener` values reflecting the configured `:redis_port`. AzureCache
  may call these later (azure_cache.ex is read-only for this lane).
  """
  @spec honesty_rows() :: %{tcp_port: :inet.port_number(), wire_listener: String.t()}
  def honesty_rows,
    do: %{tcp_port: configured_port(), wire_listener: "RESP2 on :#{configured_port()}"}

  # The bind_ip law (lib/smalt/application.ex bind_ip/0): the
  # Smalt.Config.bind_ip() override order — nil/"loopback" -> loopback,
  # binary -> :inet.parse_address (fail-closed raise on garbage), tuple ->
  # taken as configured.
  @doc "The bind address per the `Smalt.Config.bind_ip()` law (default loopback)."
  @spec bind_ip() :: :inet.ip_address()
  def bind_ip do
    case Smalt.Config.bind_ip() do
      nil -> {127, 0, 0, 1}
      "loopback" -> {127, 0, 0, 1}

      str when is_binary(str) ->
        case :inet.parse_address(String.to_charlist(str)) do
          {:ok, ip} ->
            ip

          {:error, _} ->
            raise ArgumentError, "SMALT_BIND_IP=#{str} is not a valid IPv4/IPv6 address"
        end

      ip when is_tuple(ip) ->
        ip
    end
  end

  @impl true
  def init(opts) do
    Process.set_label(%{service: :redis, role: :wire_facade})
    port = Keyword.get(opts, :port) || configured_port()

    listen_opts = [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true,
      ip: bind_ip(),
      backlog: 128,
      buffer: 65_536
    ]

    case :gen_tcp.listen(port, listen_opts) do
      {:ok, lsock} ->
        {:ok, bound} = :inet.port(lsock)
        Logger.info("[redis] RESP2 wire listener bound on port #{bound}")

        children = [
          {DynamicSupervisor, name: @conn_sup_name, strategy: :one_for_one},
          {@listener_name, {@listener_name, lsock}}
        ]

        Supervisor.init(children, strategy: :one_for_one)

      {:error, reason} ->
        # Containment contract: a bind failure stops the LISTENER, not the
        # app. The facade boots with the conn supervisor only.
        Logger.warning(
          "[redis] RESP2 wire listener could not bind port #{port}: #{inspect(reason)}; booting without it"
        )

        children = [{DynamicSupervisor, name: @conn_sup_name, strategy: :one_for_one}]
        Supervisor.init(children, strategy: :one_for_one)
    end
  end
end

defmodule Smalt.DataPlane.RedisWire.Listener do
  @moduledoc """
  Accept loop over the facade-owned listen socket (the `Smalt.Amqp.Listener`
  pattern): bounded `:gen_tcp.accept` with backoff on transient errors,
  handoff to a `:temporary` conn child of the facade's DynamicSupervisor.
  Never crashes on accept noise.
  """

  use GenServer
  require Logger

  @accept_timeout_ms 200
  @base_backoff_ms 50
  @max_backoff_ms 5_000

  @doc """
  Starts the accept loop over an ALREADY-BOUND listen socket (facade-owned
  bind). Arg is `{registered_name_or_nil, lsock}` — the facade passes the
  canonical name; a private listener (courts) passes `nil` for an unnamed
  process.
  """
  @spec start_link({GenServer.name() | nil, :gen_tcp.socket()}) ::
          {:ok, pid()} | {:error, term()}
  def start_link({name, lsock}) when is_port(lsock) do
    GenServer.start_link(__MODULE__, lsock, name: name)
  end

  @doc "The actual bound port."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @impl true
  def init(lsock) do
    Process.set_label(%{service: :redis, role: :listener})
    {:ok, port} = :inet.port(lsock)
    Process.send_after(self(), :accept, 0)
    {:ok, %{lsock: lsock, port: port, attempts: 0}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.lsock, @accept_timeout_ms) do
      {:ok, socket} ->
        handoff(socket)
        schedule_accept(state, 0)

      {:error, :timeout} ->
        schedule_accept(state, 0)

      {:error, :closed} ->
        {:stop, :normal, state}

      {:error, reason} ->
        attempts = state.attempts + 1

        Logger.warning("[redis] wire accept error #{inspect(reason)} (attempt #{attempts})")
        schedule_accept(%{state | attempts: attempts}, backoff_ms(attempts))
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- Internals ----------------------------------------------------------------

  defp schedule_accept(state, delay_ms) do
    Process.send_after(self(), :accept, delay_ms)
    {:noreply, state}
  end

  defp backoff_ms(attempts), do: min(@base_backoff_ms * 2 ** (attempts - 1), @max_backoff_ms)

  defp handoff(socket) do
    sup = Smalt.DataPlane.RedisWire.ConnSup

    child = %{
      id: {:redis_conn, make_ref()},
      start: {Smalt.DataPlane.RedisWire.Conn, :start_link, [[socket: socket]]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(sup, child) do
      {:ok, pid} ->
        # Ownership handoff: the LISTENER accepted the socket, so the listener
        # is the port owner — without controlling_process, the conn's exit
        # would never close the client socket.
        case :gen_tcp.controlling_process(socket, pid) do
          :ok -> :ok
          {:error, reason} ->
            :gen_tcp.close(socket)
            Logger.warning("[redis] controlling_process handoff failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        :gen_tcp.close(socket)

        Logger.warning(
          "[redis] could not start conn process for accepted socket: #{inspect(reason)}"
        )
    end

    :ok
  end
end

defmodule Smalt.DataPlane.RedisWire.Conn do
  @moduledoc """
  One RESP2 client connection: buffered framing (multibulk + inline), token
  accumulation, `Smalt.DataPlane.AzureCache.handle/2` dispatch, byte-exact
  reply write. `QUIT` closes; unrecoverable framing errors answer `-ERR` and
  close. `active: false`, bounded recv buffer, no Process.sleep anywhere (the
  recv timeout is a bounded deadline on a real observable — socket readiness —
  not a wait-and-hope sleep).
  """

  use GenServer
  require Logger

  @recv_timeout_ms 30_000
  @max_buffer 65_536
  @max_command_bytes 64 * 1024 * 1024

  # Same account charset law as AzureCache (`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$`).
  @account_re ~r/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/

  @doc "Starts a conn process over an accepted socket (listener handoff)."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()} | :ignore
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts[:socket])
  end

  # -- GenServer callbacks ------------------------------------------------------

  @impl true
  def init(socket) do
    Process.set_label(%{service: :redis, role: :conn})
    :ok = :inet.setopts(socket, buffer: @max_buffer)
    Process.send(self(), :ensure_default_cache, [])

    account = Smalt.DataPlane.AzureCache.default_account()
    {:ok, %{socket: socket, buffer: "", account: account, resp3: false}}
  end

  # The default-account keyspace is ensured via a queued message, NOT in
  # init/1: the listener's handoff is a synchronous DynamicSupervisor
  # start_child that blocks on this process's init ack — calling start_child
  # on the SAME supervisor from inside init would self-deadlock.
  def handle_info(:ensure_default_cache, state) do
    case Smalt.DataPlane.RedisWire.ensure_cache(state.account) do
      {:ok, _pid} ->
        Process.send(self(), :pump, [])
        {:noreply, state}

      {:error, reason} ->
        Logger.error("[redis] conn could not ensure cache: #{inspect(reason)}")
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info(:pump, state), do: pump(state)
  def handle_info({:tcp, _socket, _data}, state), do: pump(state)
  def handle_info({:tcp_closed, _socket}, state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, _socket, reason}, state), do: {:stop, {:tcp_error, reason}, state}
  def handle_info(_other, state), do: {:noreply, state}

  # -- Byte pump ----------------------------------------------------------------

  # Reads the socket, frames complete commands, executes them, loops. Every
  # exit path here is a GenServer return (no stop-signalling helper misuse).
  defp pump(%{socket: socket} = state) do
    case :gen_tcp.recv(socket, 0, @recv_timeout_ms) do
      {:ok, data} ->
        case feed(%{state | buffer: IO.iodata_to_binary([state.buffer, data])}) do
          {:cont, state} when is_binary(state.buffer) ->
            if byte_size(state.buffer) > @max_command_bytes do
              write(socket, "-ERR protocol error: too big\r\n")
              {:stop, :normal, %{state | socket: nil, buffer: ""}}
            else
              pump(state)
            end

          {:cont, state} ->
            # Framing already answered -ERR; stop cleanly.
            {:stop, :normal, %{state | socket: nil, buffer: ""}}

          {:quit, state} ->
            {:stop, :normal, %{state | socket: nil, buffer: ""}}
        end

      {:error, :closed} ->
        {:stop, :normal, state}

      {:error, :timeout} ->
        # Bounded recv deadline on a real observable (socket readability): an
        # idle client conn closes; the client owns reconnects. No sleep.
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.debug("[redis] conn recv error: #{inspect(reason)}")
        {:stop, :normal, state}
    end
  end

  # Drains every COMPLETE command out of the buffer.
  #   {:cont, state}   — keep pumping (buffer holds a partial frame or is empty)
  #   {:quit, state}   — QUIT handled, socket closed
  #
  # PIPELINE LAW (r3 court bisect, 2026-10-29): feed MUST loop until the buffer
  # holds no complete command. A one-command-per-recv cycle stalls on pipelined
  # clients — node-redis 6.3 sends HELLO + 3x CLIENT (SETINFO x2,
  # MAINT_NOTIFICATIONS) in ONE TCP segment; with the remainder parked in the
  # buffer while pump blocks on recv, no reply to the pipelined commands ever
  # fires and the client times out/closes ("Socket closed unexpectedly").
  defp feed(state) do
    feed_command(state, state.buffer)
  end

  defp feed_command(state, buffer) do
    case parse_command(buffer) do
      {:ok, tokens, rest} ->
        case execute(%{state | buffer: rest}, tokens) do
          {:cont, state} -> feed_command(state, state.buffer)
          # QUIT/protocol-error: stop draining, hand the terminal state back.
          terminal -> terminal
        end

      :partial ->
        {:cont, state}

      {:error, _reason} ->
        write(state.socket, "-ERR protocol error\r\n")
        {:cont, %{state | buffer: :protocol_error}}
    end
  rescue
    e ->
      write(state.socket, "-ERR #{Exception.message(e)}\r\n")
      {:cont, %{state | buffer: :protocol_error}}
  end

  # -- Command execution (framing -> engine -> bytes) ----------------------------

  defp execute(state, []), do: {:cont, state}

  defp execute(%{socket: socket} = state, ["QUIT" | _]) do
    write(socket, "+OK\r\n")
    :gen_tcp.close(socket)
    {:quit, state}
  end

  # AUTH <user>=<token> (1-arg combined form; r16 lane S3): an "=" inside
  # the single argument routes to the AAD token path; a 1-arg AUTH without
  # "=" keeps the unchanged engine accept-any behavior.
  defp execute(state, ["AUTH", user_and_token]) when is_binary(user_and_token) do
    case String.split(user_and_token, "=", parts: 2) do
      [_user, token] -> aad_auth(state, token)
      _ -> reply(state, state.account, ["AUTH", user_and_token], state.account)
    end
  end

  # AUTH <account-token> <password>: a structurally valid first arg selects
  # that account's keyspace for the rest of the connection (the engine itself
  # accepts any AUTH — documented divergence; the wire layer pins the keyspace).
  # The switched-to keyspace must be SUPERVISED (never conn-linked).
  # A JWT-shaped password is the Azure Cache Entra ID token form instead:
  # verify via Smalt.Identity.EntraToken, answer +OK, and do NOT switch
  # keyspace (Entra auth is identity auth, not account pinning).
  defp execute(state, ["AUTH", token, pass] = tokens) do
    if Smalt.Identity.EntraToken.jwt?(pass) do
      aad_auth(state, pass)
    else
      account =
        if is_binary(token) and Regex.match?(@account_re, token), do: token, else: state.account

      case Smalt.DataPlane.RedisWire.ensure_cache(account) do
        {:ok, _pid} -> reply(state, account, tokens, account)
        {:error, _} -> write(state.socket, "-ERR cache start failed\r\n") && state
      end
    end
  end

  # AAD token AUTH (both wire forms): one verified token -> +OK with the
  # keyspace unchanged; every error class -> the real Redis WRONGPASS
  # refusal shape (never a silent accept).
  defp aad_auth(%{socket: socket} = state, token) do
    case Smalt.Identity.EntraToken.verify_redis_auth(token) do
      {:ok, claims} ->
        Logger.debug("[redis] AAD token AUTH ok oid=#{inspect(claims["oid"])}")
        write(socket, "+OK\r\n")
        {:cont, state}

      {:error, reason} ->
        Logger.warning("[redis] AAD token AUTH refused: #{inspect(reason)}")
        write(socket, "-ERR WRONGPASS invalid username-password pair or user is disabled.\r\n")
        {:cont, state}
    end
  end

  # RESP3 negotiation (v26.10.29 consumer court r3 witness): node-redis 6.x
  # defaults RESP 3 and NEVER downgrades (client-driven negotiation; the
  # option is the only knob). Once the client sends HELLO 3 its parser demands
  # the RESP3 grammar for the hello reply itself — a RESP2 flat array desyncs
  # it ("Unknown RESP type 111 'o'", fake-server bisect witness). Answer with
  # a true RESP3 map (%-type) and mark the conn RESP3: subsequent replies keep
  # RESP2 syntax, a strict subset of RESP3 (simple strings, errors, integers,
  # bulk strings, arrays parse identically). Divergence: map-semantics
  # commands (HGETALL) still emit *N arrays — the pinned consumer set
  # (SET/GET/DEL/EXPIRE/TTL/INCR + connect-redis session writes) never
  # distinguishes them.
  #
  # CLAUSE ORDER LAW: this clause MUST precede the generic execute/2 catch-all
  # below — first-match wins, and the catch-all would route HELLO 3 into
  # AzureCache's RESP2 hello_reply() (the exact desync defect the wire court's
  # %-prefix pin caught, 2026-10-29).
  defp execute(%{socket: socket} = state, ["HELLO", "3"]) do
    write(socket, resp3_hello())
    {:cont, %{state | resp3: true}}
  end

  defp execute(state, tokens), do: reply(state, state.account, tokens, state.account)

  defp resp3_hello do
    vsn =
      case Application.spec(:cachex, :vsn) do
        nil -> "unknown"
        v -> IO.iodata_to_binary(v)
      end

    entries = [
      {"server", "redis", :bulk},
      {"version", "smalt-cachex-#{vsn}", :bulk},
      {"proto", "3", :int},
      {"id", run_id(), :bulk},
      {"mode", "standalone", :bulk}
    ]

    ["%" <> Integer.to_string(length(entries)), "\r\n"] ++
      Enum.flat_map(entries, fn {k, v, t} ->
        case t do
          :bulk -> ["$" <> Integer.to_string(byte_size(k)), "\r\n", k, "\r\n", "$" <> Integer.to_string(byte_size(v)), "\r\n", v, "\r\n"]
          :int -> ["$" <> Integer.to_string(byte_size(k)), "\r\n", k, "\r\n", ":" <> v, "\r\n"]
        end
      end)
    |> IO.iodata_to_binary()
  end

  defp run_id, do: :crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower)

  defp reply(state, exec_account, tokens, next_account) do
    case Smalt.DataPlane.AzureCache.handle(exec_account, tokens) do
      {:ok, resp} -> write(state.socket, resp)
      {:error, resp} -> write(state.socket, resp)
    end

    {:cont, %{state | account: next_account}}
  end

  defp write(socket, bytes) when is_binary(bytes), do: :gen_tcp.send(socket, bytes)

  # ===========================================================================
  # RESP2 framing (pure)
  # ===========================================================================

  # Parses ONE command off the front of `buffer`:
  #   {:ok, tokens, rest} | :partial | {:error, reason}
  # Multibulk when the buffer opens with `*`, inline otherwise.
  defp parse_command(<<?*, ?-, ?1, ?\r, ?\n, rest::binary>>), do: {:ok, [], rest}

  defp parse_command(<<?*, body::binary>>) do
    case take_line(body) do
      {:ok, count_str, rest} ->
        case Integer.parse(count_str) do
          {count, ""} when count >= 0 -> parse_bulks(rest, count, [])
          _ -> {:error, :bad_multibulk_count}
        end

      :partial ->
        :partial
    end
  end

  defp parse_command(buffer) do
    case take_inline_line(buffer) do
      {:ok, line, rest} -> {:ok, inline_tokens(line), rest}
      :partial -> :partial
    end
  end

  defp inline_tokens(line) do
    line
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&unescape_inline/1)
  end

  # Inline commands support the Redis quoted-string form minimally: a token
  # opening with `"` keeps its literal body (escape processing is NOT applied —
  # multibulk is the binary-safe path; inline is the telnet convenience path).
  defp unescape_inline(tok), do: tok

  # `$len\r\n<payload>\r\n` x count
  defp parse_bulks(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_bulks(rest, count, acc) when count > 0 do
    case take_line(rest) do
      {:ok, <<?$, len_str::binary>>, rest1} ->
        case Integer.parse(len_str) do
          {len, ""} when len >= 0 and len <= @max_command_bytes ->
            case take_bulk(rest1, len) do
              {:ok, payload, rest2} -> parse_bulks(rest2, count - 1, [payload | acc])
              :partial -> :partial
            end

          _ ->
            {:error, :bad_bulk_length}
        end

      :partial ->
        :partial
    end
  end

  defp parse_bulks(_rest, _count, _acc), do: {:error, :bad_multibulk_count}

  # Takes a `\r\n`-terminated line; `:partial` when the terminator hasn't arrived.
  defp take_line(bin) do
    case :binary.split(bin, "\r\n") do
      [line, rest] -> {:ok, line, rest}
      [_] -> :partial
    end
  end

  defp take_bulk(bin, len) when byte_size(bin) >= len + 2 do
    <<payload::binary-size(^len), ?\r, ?\n, rest::binary>> = bin
    {:ok, payload, rest}
  end

  defp take_bulk(bin, len) when byte_size(bin) < len + 2, do: :partial

  # Inline commands terminate on `\r\n` OR a bare `\n` (telnet class).
  defp take_inline_line(bin) do
    case :binary.split(bin, "\n") do
      [line, rest] -> {:ok, String.replace_suffix(line, "\r", ""), rest}
      [_] -> :partial
    end
  end
end
