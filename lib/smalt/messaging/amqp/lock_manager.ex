defmodule Smalt.Amqp.LockManager do
  @moduledoc """
  Message-lock and session-lock lifecycle for the AMQP 1.0 broker.

  Locks live in `:smalt_sb_locks` (key = lock token) and `:smalt_sb_sessions`
  (key = `{queue, session_id}`). Duration is clamped to 100–30000 ms
  (default 30000). All time-dependent functions take `now_ms` (default
  `System.system_time(:millisecond)`) so tests are deterministic.

  Renew status mapping (management `renew-lock`): unknown token → `{:error, :not_found}`
  (HTTP 404); expired token → `{:error, :lock_lost}` (HTTP 410).
  """

  @min_duration 100
  @max_duration 30000
  @default_duration 30000

  @type lock :: %{
          required(:lock_token) => binary(),
          required(:queue) => String.t(),
          required(:seq) => integer() | nil,
          required(:kind) => :message | :session,
          required(:locked_until) => integer(),
          required(:duration_ms) => pos_integer(),
          optional(:session_id) => String.t()
        }

  # -- Duration / expiry (pure) ------------------------------------------------

  @doc "Clamp a lock duration into the 100–30000 ms window."
  @spec clamp_duration(integer() | nil) :: pos_integer()
  def clamp_duration(nil), do: @default_duration
  def clamp_duration(d) when is_integer(d), do: d |> max(@min_duration) |> min(@max_duration)

  @doc "Pure expiry check: `expired?(locked_until_or_lock, now_ms)`."
  @spec expired?(integer() | lock(), integer()) :: boolean()
  def expired?(%{locked_until: until}, now_ms), do: expired?(until, now_ms)
  def expired?(until, now_ms) when is_integer(until), do: until <= now_ms

  @doc "UUID v4 lock token from `:crypto.strong_rand_bytes(16)`."
  @spec new_token() :: binary()
  def new_token do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)
    <<u0::48, 4::4, u1::12, 2::2, u2::62>> |> format_uuid()
  end

  @doc """
  Canonical lock-token form: dashed lowercase UUID string. Wire tokens arrive
  as raw 16-byte AMQP uuid values (rhea `string_to_uuid` round-trip); the
  store keys them in the dashed string form `new_token/0` mints.
  """
  @spec format_uuid(<<_::128>>) :: String.t()
  def format_uuid(<<a::32, b::16, c::16, d::16, e::48>>) do
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
    |> String.downcase()
  end

  # SHIM-COURT R51: token_to_raw/1 returns the WIRE layout. Inverse of
  # `format_uuid/1`: dashed UUID string -> raw 16 bytes in the on-wire
  # .NET-GUID-reordered layout the delivery-tag actually carries
  # (`token_to_wire/1`, connection.ex delivery_tag). The store keys the
  # dashed form. Returning the straight uuid layout here made tests
  # synthesizing wire bytes mint a permuted store key on settle ->
  # 410 MESSAGE_LOCK_LOST on every live lock (repair lane R51).
  @doc """
  Inverse of `format_uuid/1`: dashed UUID string -> raw 16 bytes in the WIRE
  (.NET-GUID-reordered, `shouldReorderLockToken: true`) layout the
  delivery-tag carries (rhea `string_to_uuid` round-trip on the client);
  the store keys the dashed form.
  """
  @spec token_to_raw(String.t()) :: <<_::128>>
  def token_to_raw(dashed) when is_binary(dashed) do
    <<b0, b1, b2, b3, b4, b5, b6, b7, rest::binary-size(8)>> =
      dashed |> String.replace("-", "") |> Base.decode16!(case: :mixed)

    # .NET-GUID reorder, byte-identical to the former token_to_wire/1 body:
    # [b3,b2,b1,b0, b5,b4, b7,b6, rest].
    <<b3, b2, b1, b0, b5, b4, b7, b6, rest::binary>>
  end

  @doc """
  Wire delivery-tag layout for lock tokens. The Service Bus SDKs construct
  the client-side lockToken with `shouldReorderLockToken: true`
  (@azure/service-bus 7.10.0 serviceBusMessage.js:296, all receiver call sites
  pass true): the raw uuid bytes are reordered .NET-GUID style
  ([b3,b2,b1,b0,b5,b4,b7,b6,rest]) before uuid_to_string. Delivering the
  straight uuid layout made every client echo a permuted token on
  update-disposition -> 410 MESSAGE_LOCK_LOST (census session probes).
  """
  @spec token_to_wire(String.t()) :: <<_::128>>
  def token_to_wire(dashed) when is_binary(dashed) do
    token_to_raw(dashed)
  end

  # -- Message locks -----------------------------------------------------------

  @doc "Acquire a message lock. Returns `{:ok, lock}`."
  @spec acquire(String.t(), integer(), keyword()) :: {:ok, lock()} | {:error, :not_found}
  def acquire(queue, seq, opts \\ []) do
    now = opts[:now_ms] || System.system_time(:millisecond)
    duration = clamp_duration(opts[:duration_ms])
    token = new_token()

    lock = %{
      lock_token: token,
      queue: queue,
      seq: seq,
      kind: :message,
      locked_until: now + duration,
      duration_ms: duration
    }

    Smalt.Store.put(:smalt_sb_locks, token, lock)
    {:ok, lock}
  end

  @doc """
  Renew by lock token. `{:error, :not_found}` (404) for unknown tokens,
  `{:error, :lock_lost}` (410) for expired tokens.

  For session locks the renewal is delegated to `session_renew/4` (V261014-04
  F2), so the mirrored `{queue, session_id}` record in `:smalt_sb_sessions` is
  written from the same renewal — both records carry the new `locked_until`.
  Message locks mirror the renewal into the `{queue, seq}` message row the same
  way (lane-242 fix): the renew is serialized through QueueStore's claim/settle
  server so `do_sweep` (which consults the message row's `locked_until`) can
  never sweep a successfully renewed lock at its original expiry.
  """
  @spec renew(binary(), integer(), keyword()) :: {:ok, lock()} | {:error, :not_found | :lock_lost}
  def renew(token, now_ms, opts \\ []) when is_binary(token) do
    case Smalt.Store.get(:smalt_sb_locks, token) do
      {:ok, %{kind: :session, queue: queue, session_id: session_id}} ->
        session_renew(queue, session_id, now_ms, opts)

      {:ok, %{kind: :message}} ->
        # Serialized with claims/settlements/sweeps (same server as
        # session_renew) so the token-row put and the message-row mirror are
        # atomic against do_sweep.
        GenServer.call(Smalt.Amqp.QueueStore.server(), {:message_renew, token, now_ms, opts})

      other ->
        renew_lock(other, now_ms, opts)
    end
  end

  @doc false
  # Runs inside the QueueStore claim server. Public only for that call-site.
  def do_message_renew(token, now_ms, opts) do
    with {:ok, lock} <- renew_lock(Smalt.Store.get(:smalt_sb_locks, token), now_ms, opts) do
      mirror_message_renew(lock)
      {:ok, lock}
    end
  end

  defp mirror_message_renew(%{
         kind: :message,
         queue: queue,
         seq: seq,
         lock_token: token,
         locked_until: until
       }) do
    # Table-absent (unit harnesses that only provision the lock tables): the
    # token-row renewal already happened; there is no message row to mirror.
    if :ets.info(:smalt_sb_messages) == :undefined do
      :ok
    else
      case Smalt.Store.get(:smalt_sb_messages, {queue, seq}) do
        # Token-scoped mirror (ABA-safe): if the message row was re-claimed by a
        # different token, leave it alone — the old token's renewal must not
        # extend the new claim.
        {:ok, %{lock_token: ^token} = m} ->
          Smalt.Store.put(:smalt_sb_messages, {queue, seq}, %{m | locked_until: until})

        _ ->
          :ok
      end
    end
  end

  defp mirror_message_renew(_), do: :ok

  @doc """
  `Smalt.Amqp.ManagementRpc` pinned contract: renew by token and return the
  bare expiry in ms. Unknown token → `{:error, :not_found}`; expired →
  `{:error, :lock_lost}`.
  """
  @spec renew_lock(binary(), integer()) :: {:ok, integer()} | {:error, :not_found | :lock_lost}
  def renew_lock(token, now_ms) do
    case renew(token, now_ms) do
      {:ok, %{locked_until: expiry}} -> {:ok, expiry}
      other -> other
    end
  end

  @doc """
  `Smalt.Amqp.ManagementRpc` pinned contract: renew the session lock for
  `{queue, session_id}` and return the bare expiry in ms. Unknown session →
  `{:error, :not_found}`; expired → `{:error, :session_lock_lost}`.
  """
  @spec renew_session_lock(String.t(), String.t(), integer()) ::
          {:ok, integer()} | {:error, :not_found | :session_lock_lost}
  def renew_session_lock(queue, session_id, now_ms) do
    case session_renew(queue, session_id, now_ms) do
      {:ok, %{locked_until: expiry}} -> {:ok, expiry}
      {:error, :lock_lost} -> {:error, :session_lock_lost}
      other -> other
    end
  end

  @doc "Release (delete) a lock by token. Always `:ok`."
  @spec release(binary()) :: :ok
  def release(token), do: Smalt.Store.delete(:smalt_sb_locks, token)

  @doc "Fetch a lock record by token."
  @spec get(binary()) :: {:ok, lock()} | :error
  def get(token), do: Smalt.Store.get(:smalt_sb_locks, token)

  # -- Session locks -----------------------------------------------------------

  @doc """
  Acquire the session lock for `{queue, session_id}`.

  Serialized through `Smalt.Amqp.QueueStore`'s claim server, so exactly one
  concurrent racer can win the get-check-put window (the ST4 TOCTOU): losers
  get `{:error, :already_locked}`, never two winners.
  """
  @spec session_acquire(String.t(), String.t(), keyword()) ::
          {:ok, lock()} | {:error, :already_locked}
  def session_acquire(queue, session_id, opts \\ []) do
    now = opts[:now_ms] || System.system_time(:millisecond)
    GenServer.call(Smalt.Amqp.QueueStore.server(), {:session_claim, queue, session_id, now, opts})
  end

  @doc false
  # Runs inside the QueueStore claim server. Public only for that call-site.
  def do_session_claim(queue, session_id, now, opts) do
    key = {queue, session_id}

    case Smalt.Store.get(:smalt_sb_sessions, key) do
      {:ok, lock} ->
        if expired?(lock, now),
          do: do_session_acquire(key, now, opts),
          else: {:error, :already_locked}

      :error ->
        do_session_acquire(key, now, opts)
    end
  end

  defp do_session_acquire(key, now, opts) do
    {queue, session_id} = key
    duration = clamp_duration(opts[:duration_ms])
    token = new_token()

    lock = %{
      lock_token: token,
      queue: queue,
      seq: nil,
      session_id: session_id,
      kind: :session,
      # GAP-A2-05: opaque session state bytes (set/get-session-state). nil until
      # the first set; dies with the session lock record (disclosed emulator
      # divergence — see ManagementRpc.set_session_state).
      session_state: nil,
      locked_until: now + duration,
      duration_ms: duration
    }

    Smalt.Store.put(:smalt_sb_sessions, key, lock)
    Smalt.Store.put(:smalt_sb_locks, token, Map.put(lock, :session_key, key))
    {:ok, lock}
  end

  @doc """
  Reclaim expired locks: deletes expired session-lock records (both the
  `{queue, session_id}` record and its token in `:smalt_sb_locks`) and any
  expired orphan token in `:smalt_sb_locks`. Serialized with
  `QueueStore` claims. Returns the number of records reclaimed.
  """
  @spec sweep() :: non_neg_integer()
  def sweep(now_ms \\ System.system_time(:millisecond)) when is_integer(now_ms) do
    GenServer.call(Smalt.Amqp.QueueStore.server(), {:lock_sweep, now_ms})
  end

  @doc false
  # Runs inside the QueueStore claim server.
  def do_sweep_expired(now) do
    expired_sessions =
      :ets.match_object(:smalt_sb_sessions, {:_, :_})
      |> Enum.filter(fn {_k, lock} -> expired?(lock, now) end)

    Enum.each(expired_sessions, fn {_key, lock} ->
      Smalt.Store.delete(:smalt_sb_locks, lock.lock_token)
    end)

    Enum.each(expired_sessions, fn {key, _lock} ->
      Smalt.Store.delete(:smalt_sb_sessions, key)
    end)

    expired_tokens =
      :ets.match_object(:smalt_sb_locks, {:_, :_})
      |> Enum.filter(fn {_k, lock} -> expired?(lock, now) and orphan_token?(lock, now) end)

    Enum.each(expired_tokens, fn {token, _lock} ->
      Smalt.Store.delete(:smalt_sb_locks, token)
    end)

    length(expired_sessions) + length(expired_tokens)
  end

  # SHIM-COURT-guarded lane R178j: an expired :session token row is an orphan
  # when its `{queue, session_id}` sessions row is gone or was overwritten by a
  # re-acquire (different lock_token). A token whose sessions row still matches
  # is the live lock and must survive the sweep. (no KD-COVERS id — in-repo fix)
  defp orphan_token?(%{kind: :message}, _now), do: true

  defp orphan_token?(%{kind: :session, queue: q, session_id: sid, lock_token: token}, _now) do
    case Smalt.Store.get(:smalt_sb_sessions, {q, sid}) do
      :error -> true
      {:ok, %{lock_token: ^token}} -> false
      {:ok, _} -> true
    end
  end

  @doc """
  Renew a session lock, addressed by `{queue, session_id}` (or by token via
  `renew/3` — both records are kept in sync). Same 404/410 mapping as `renew/3`.
  """
  @spec session_renew(String.t(), String.t(), integer(), keyword()) ::
          {:ok, lock()} | {:error, :not_found | :lock_lost}
  def session_renew(queue, session_id, now_ms, opts \\ []) do
    # A32 fix 2: the get+put pair on :smalt_sb_sessions ran outside the claim
    # server (same lost-update class as F3). Serialize it: renew now executes
    # inside the QueueStore claim server, so a concurrent acquire can never
    # interleave between the get and the put.
    GenServer.call(
      Smalt.Amqp.QueueStore.server(),
      {:session_renew, queue, session_id, now_ms, opts}
    )
  end

  @doc false
  # Runs inside the QueueStore claim server. Public only for that call-site.
  def do_session_renew(queue, session_id, now_ms, opts) do
    key = {queue, session_id}

    with {:ok, lock} <- renew_lock(Smalt.Store.get(:smalt_sb_sessions, key), now_ms, opts) do
      # V261014-04 F2: always mirror the renewal into :smalt_sb_sessions. The
      # previous `Map.has_key?(lock, :session_key)` guard never fired — the
      # sessions row written by do_session_acquire/4 carries no :session_key
      # (only the :smalt_sb_locks token row does) — so the mirrored record
      # kept its stale locked_until and stale-expiry reclaims could double-
      # acquire a live session.
      Smalt.Store.put(:smalt_sb_sessions, key, lock)
      {:ok, lock}
    end
  end

  @doc """
  Release the session lock for `{queue, session_id}`.

  Serialized through `Smalt.Amqp.QueueStore`'s claim server (same serialization
  point as `session_acquire/3`), so a concurrent acquire can never interleave
  between the get and the deletes (the ST4 TOCTOU lost-lock window: acquire
  wins on the not-yet-deleted record, then release deletes the fresh lock).
  """
  @spec session_release(String.t(), String.t()) :: :ok
  def session_release(queue, session_id) do
    # A32 fix 1 (LockManager F3 ABA): capture the expected token caller-side
    # and ship it with the release; the serialized server does a token-scoped
    # compare-and-delete, so a releaser can never delete B's fresh lock.
    expected_token =
      case Smalt.Store.get(:smalt_sb_sessions, {queue, session_id}) do
        {:ok, lock} -> lock.lock_token
        :error -> nil
      end

    GenServer.call(
      Smalt.Amqp.QueueStore.server(),
      {:session_release, queue, session_id, expected_token}
    )
  end

  @doc false
  # Runs inside the QueueStore claim server. Public only for that call-site.
  def do_session_release(queue, session_id, expected_token) do
    case Smalt.Store.get(:smalt_sb_sessions, {queue, session_id}) do
      {:ok, %{lock_token: token}} when expected_token != nil and token == expected_token ->
        Smalt.Store.delete(:smalt_sb_locks, token)
        Smalt.Store.delete(:smalt_sb_sessions, {queue, session_id})
        :ok

      # Token mismatch (B re-acquired) or row gone: :ok leaving B intact.
      _ ->
        :ok
    end
  end

  # -- Shared renewal ----------------------------------------------------------

  defp renew_lock({:ok, lock}, now_ms, opts) do
    if expired?(lock, now_ms) do
      {:error, :lock_lost}
    else
      extension = clamp_duration(opts[:duration_ms] || lock.duration_ms)
      lock = %{lock | locked_until: now_ms + extension}
      Smalt.Store.put(:smalt_sb_locks, lock.lock_token, lock)
      {:ok, lock}
    end
  end

  defp renew_lock(:error, _now_ms, _opts), do: {:error, :not_found}
end
