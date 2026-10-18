defmodule Smalt.Amqp.CbsRouter do
  # Per-connection (per owner_ref) claim ceiling (F2 finding: a single total
  # cap let one connection's exhausted table block every NEW connection's
  # put-token — fail-closed DoS surface).
  @max_claims 128
  # Global ceiling across all connections: reaps dead-owner/expired claims
  # before refusing typed, so total memory stays bounded without letting one
  # connection starve another.
  @max_total_claims 4096

  @moduledoc """
  `$cbs` entity router for the Service Bus emulator dialect.

  Handles `put-token` / `delete-token` requests shaped as

      %{
        operation: "put-token" | "delete-token",
        type: "servicebus.windows.net:sastoken",
        name: binary(),          # audience / scope
        expiration: integer(),   # epoch seconds (optional)
        token: binary()          # SharedAccessSignature string
      }

  Validated claims are cached per `{owner_ref, audience}` with expiry; each
  connection holds at most #{@max_claims} active claims (per-connection, not
  total — see F2), and the whole table holds at most #{@max_total_claims}.
  Over-capacity put-token requests get `{429, "CLAIM_CAPACITY"}` after expired
  and dead-owner claims are reaped. Expired claims are reaped by `gc/0`.

  Status tuples: `{200, "LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY"}`,
  `{400, "UNSUPPORTED_CBS_REQUEST"}` | `{400, "INVALID_CBS_BODY"}`,
  `{401, "INVALID_LOCAL_SAS"}`, `{429, "CLAIM_CAPACITY"}`.
  """

  use GenServer

  alias Smalt.Amqp.SasVerifier

  defstruct [:table, :audience_config]
  @cbs_type "servicebus.windows.net:sastoken"

  @type request :: %{
          required(:operation) => binary(),
          optional(:type) => binary(),
          optional(:name) => term(),
          optional(:expiration) => term(),
          optional(:token) => term()
        }

  # -- client API ---------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Verifies and caches a put-token request."
  @spec put_token(GenServer.server(), request(), term()) ::
          {:ok, {200, binary()}} | {:error, {integer(), binary()}}
  def put_token(server, request, owner_ref \\ self()),
    do: GenServer.call(server, {:put_token, request, owner_ref})

  @doc "Deletes the cached claim for `{owner_ref, name}` (idempotent)."
  @spec delete_token(GenServer.server(), request(), term()) ::
          {:ok, {200, binary()}} | {:error, {integer(), binary()}}
  def delete_token(server, request, owner_ref \\ self()),
    do: GenServer.call(server, {:delete_token, request, owner_ref})

  @doc "Whether a live (unexpired) cached claim exists for `{owner_ref, audience}`."
  @spec authorized?(GenServer.server(), term(), term()) :: boolean()
  def authorized?(server \\ __MODULE__, owner_ref, audience) do
    GenServer.call(server, {:authorized?, owner_ref, audience})
  end

  @doc "Reaps expired claims. Returns the number removed."
  @spec gc(GenServer.server()) :: non_neg_integer()
  def gc(server \\ __MODULE__), do: GenServer.call(server, :gc)

  # -- server --------------------------------------------------------------------

  @impl true
  def init(opts) do
    table =
      case opts[:table] do
        nil -> :ets.new(:smalt_cbs_claims, [:set, :private, keypos: 1])
        t -> t
      end

    {:ok, %__MODULE__{table: table, audience_config: opts[:audience_config]}}
  end

  @impl true
  def handle_call({:put_token, request, owner_ref}, _from, state) do
    {reply, state} = do_put(request, owner_ref, state)
    {:reply, reply, state}
  end

  def handle_call({:delete_token, request, owner_ref}, _from, state) do
    {reply, state} = do_delete(request, owner_ref, state)
    {:reply, reply, state}
  end

  def handle_call({:authorized?, owner_ref, audience}, _from, state) do
    now = System.system_time(:second)

    found =
      case :ets.lookup(state.table, {owner_ref, audience}) do
        [{{_owner, _aud}, %{expires: expires}}] -> expires > now
        _ -> false
      end

    {:reply, found, state}
  end

  def handle_call(:gc, _from, state) do
    {:reply, gc_claims(state.table, System.system_time(:second)), state}
  end

  defp gc_claims(table, now) do
    expired =
      table
      |> :ets.tab2list()
      |> Enum.filter(fn {{_, _}, %{expires: expires}} -> expires <= now end)

    Enum.each(expired, fn key -> :ets.delete(table, key) end)
    length(expired)
  end

  # Claims owned by dead connections are unreachable by delete-token (the
  # owner pid is gone); drop them during global-cap pressure.
  defp reap_dead_owners(table) do
    dead =
      table
      |> :ets.tab2list()
      |> Enum.map(fn {{owner, _}, _} -> owner end)
      |> Enum.uniq()
      |> Enum.reject(&Process.alive?/1)

    Enum.each(
      table |> :ets.tab2list() |> Enum.filter(fn {{owner, _}, _} -> owner in dead end),
      fn key ->
        :ets.delete(table, key)
      end
    )

    length(dead)
  end

  # -- request handling -----------------------------------------------------------

  defp do_put(request, owner_ref, state)

  defp do_put(request, owner_ref, state) when is_map(request) do
    with :ok <- check_operation(request, "put-token"),
         :ok <- check_type(request),
         {:ok, name} <- fetch_name(request),
         {:ok, token} <- fetch_field(request, :token),
         {:ok, claims} <- SasVerifier.verify(token, audience_for(name, state)) do
      if :ets.member(state.table, {owner_ref, claims.audience}) do
        # refresh in place — always fits the cap
        insert_claim(state, owner_ref, claims.audience, expires_for(request, claims))
      else
        owner_count =
          :ets.select_count(state.table, [{{{owner_ref, :_}, :_}, [], [true]}])

        total = :ets.info(state.table, :size)

        cond do
          owner_count >= @max_claims ->
            {{:error, {429, "CLAIM_CAPACITY"}}, state}

          total >= @max_total_claims ->
            # Reap expired/dead-owner claims; refuse typed only if still full.
            gc_claims(state.table, System.system_time(:second))
            reap_dead_owners(state.table)

            if :ets.info(state.table, :size) >= @max_total_claims,
              do: {{:error, {429, "CLAIM_CAPACITY"}}, state},
              else: insert_claim(state, owner_ref, claims.audience, expires_for(request, claims))

          true ->
            insert_claim(state, owner_ref, claims.audience, expires_for(request, claims))
        end
      end
    else
      {:error, {_code, _desc}} = error -> {error, state}
    end
  end

  defp do_put(_request, _owner_ref, state), do: {{:error, {400, "INVALID_CBS_BODY"}}, state}

  defp do_delete(request, owner_ref, state) when is_map(request) do
    with :ok <- check_operation(request, "delete-token"),
         :ok <- check_type(request),
         {:ok, name} <- fetch_name(request) do
      :ets.delete(state.table, {owner_ref, name})
      {{:ok, {200, "LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY"}}, state}
    else
      {:error, {_code, _desc}} = error -> {error, state}
    end
  end

  defp do_delete(_request, _owner_ref, state), do: {{:error, {400, "INVALID_CBS_BODY"}}, state}

  defp check_operation(request, expected) do
    if Map.get(request, :operation) == expected,
      do: :ok,
      else: {:error, {400, "UNSUPPORTED_CBS_REQUEST"}}
  end

  # pyamqp dialect (S-1, disclosed in s1-amqp-shims receipt): the Python
  # azure-servicebus CBS client sends `type: "jwt"` where rhea sends
  # "servicebus.windows.net:sastoken". Same put-token semantics; the token
  # body is verified identically by SasVerifier.
  @pyamqp_cbs_types ["jwt"]

  defp check_type(request) do
    if Map.get(request, :type) == @cbs_type or Map.get(request, :type) in @pyamqp_cbs_types,
      do: :ok,
      else: {:error, {400, "UNSUPPORTED_CBS_REQUEST"}}
  end

  defp fetch_name(request) do
    case Map.get(request, :name) do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, {400, "INVALID_CBS_BODY"}}
    end
  end

  defp fetch_field(request, key) do
    case Map.get(request, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {400, "INVALID_CBS_BODY"}}
    end
  end

  # Request expiration wins when present and integer; the token's own `se`
  # claim bounds the cache entry otherwise.
  defp expires_for(request, claims) do
    case Map.get(request, :expiration) do
      exp when is_integer(exp) -> min(exp, claims.se)
      _ -> claims.se
    end
  end

  # Explicit per-router audience config wins; otherwise the configured Service
  # Bus endpoint (`:smalt, :sb_endpoint`) scopes the token audience.
  defp audience_for(_name, state), do: state.audience_config || SasVerifier.endpoint()

  defp insert_claim(state, owner_ref, audience, expires) do
    :ets.insert(state.table, {{owner_ref, audience}, %{expires: expires}})
    {{:ok, {200, "LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY"}}, state}
  end
end
