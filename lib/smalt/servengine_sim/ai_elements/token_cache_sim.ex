defmodule Smalt.ServengineSim.AiElements.TokenCacheSim do
  @moduledoc """
  GCE metadata server OAuth2 token caching and pre-expiry refresh simulator
  for AI Elements (IDE, Workflow, Chatbot) Vertex AI requests (`global` /
  `gemini-4-neon`).

  Models the runtime token lifecycle on Cloud Run / GCE:

    * Fetches OAuth2 bearer tokens from the GCE metadata endpoint
      (`http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token`)
      requiring the `Metadata-Flavor: Google` header.
    * Caches the active token in memory until `expires_at_ms - refresh_margin_ms`.
    * Triggers a pre-expiry refresh once the current time enters the refresh
      window (`now_ms >= expires_at_ms - refresh_margin_ms`).
    * Falls back to the still-unexpired cached token if a pre-expiry refresh
      fails transiently (`stale_on_error?: true`), while refusing to serve
      hard-expired tokens (`now_ms >= expires_at_ms`).
    * Supports explicit invalidation (e.g. after a `401 Unauthorized` from
      Vertex AI) and deterministic virtual-clock testing via an injectable
      `clock_fn` or `advance_clock/2`.
  """

  use GenServer

  @metadata_url "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
  @metadata_flavor_header {"Metadata-Flavor", "Google"}
  @default_expires_in_sec 3600
  @default_refresh_margin_ms 60_000
  @vertex_scope "https://www.googleapis.com/auth/cloud-platform"

  @type token_payload :: %{
          required(String.t()) => term()
        }

  @type cached_token :: %{
          access_token: String.t(),
          token_type: String.t(),
          expires_in: pos_integer(),
          fetched_at_ms: integer(),
          expires_at_ms: integer()
        }

  @type fetcher_fn :: (map() -> {:ok, token_payload()} | {:error, term()})

  @type stats :: %{
          cache_hits: non_neg_integer(),
          metadata_fetches: non_neg_integer(),
          pre_expiry_refreshes: non_neg_integer(),
          hard_expiry_refreshes: non_neg_integer(),
          stale_fallbacks: non_neg_integer(),
          errors: non_neg_integer(),
          invalidations: non_neg_integer()
        }

  @doc """
  Returns the canonical GCE metadata token URL.
  """
  @spec metadata_url() :: String.t()
  def metadata_url, do: @metadata_url

  @doc """
  Returns the required GCE metadata flavor header tuple.
  """
  @spec metadata_flavor_header() :: {String.t(), String.t()}
  def metadata_flavor_header, do: @metadata_flavor_header

  @doc """
  Returns the Vertex AI OAuth2 scope.
  """
  @spec vertex_scope() :: String.t()
  def vertex_scope, do: @vertex_scope

  @doc """
  Validates a simulated HTTP request map targeting the GCE metadata server.

  Ensures the URL matches the GCE metadata token endpoint and that the
  `Metadata-Flavor: Google` header is present (case-insensitive header name).
  """
  @spec validate_metadata_request(map()) :: :ok | {:error, term()}
  def validate_metadata_request(%{url: url, headers: headers}) when is_binary(url) do
    cond do
      url != @metadata_url ->
        {:error, {:invalid_metadata_url, url}}

      true ->
        case find_header(headers, "metadata-flavor") do
          nil -> {:error, :missing_metadata_flavor}
          "Google" -> :ok
          other -> {:error, {:invalid_metadata_flavor, other}}
        end
    end
  end

  def validate_metadata_request(_), do: {:error, :malformed_metadata_request}

  @doc """
  Starts a `TokenCacheSim` process.

  ## Options

    * `:name` - optional GenServer name.
    * `:now_ms` - initial virtual clock timestamp in milliseconds (default: `1_700_000_000_000`).
    * `:clock_fn` - optional 0-arity function returning current time in ms; when omitted,
      uses the internal virtual clock controlled by `set_clock/2` and `advance_clock/2`.
    * `:refresh_margin_ms` - pre-expiry refresh window in ms (default: `60_000`).
    * `:default_expires_in_sec` - default token TTL in seconds for the built-in mock fetcher (default: `3600`).
    * `:stale_on_error?` - if `true` (default), returns the still-unexpired cached token
      when a pre-expiry refresh fails.
    * `:fetcher` - custom 1-arity function receiving `%{url: ..., headers: ..., scope: ..., seq: ...}`
      and returning `{:ok, %{"access_token" => ..., "expires_in" => ..., "token_type" => "Bearer"}}`
      or `{:error, reason}`.
    * `:headers` - headers sent to the metadata fetcher (default: `[{"Metadata-Flavor", "Google"}]`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Retrieves a valid OAuth2 access token, serving from cache when fresh or
  fetching/refreshing from the simulated GCE metadata endpoint when cold,
  within the pre-expiry window, or expired.
  """
  @spec get_token(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def get_token(server) do
    GenServer.call(server, :get_token)
  end

  @doc """
  Retrieves the full `Authorization` header value (`"Bearer <token>"`).
  """
  @spec authorization_header(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def authorization_header(server) do
    with {:ok, token} <- get_token(server) do
      {:ok, "Bearer " <> token}
    end
  end

  @doc """
  Invalidates the cached token so the next `get_token/1` forces a fresh
  metadata fetch.
  """
  @spec invalidate(GenServer.server()) :: :ok
  def invalidate(server) do
    GenServer.call(server, :invalidate)
  end

  @doc """
  Advances the internal virtual clock by `delta_ms` milliseconds.
  """
  @spec advance_clock(GenServer.server(), integer()) :: integer()
  def advance_clock(server, delta_ms) when is_integer(delta_ms) do
    GenServer.call(server, {:advance_clock, delta_ms})
  end

  @doc """
  Sets the internal virtual clock to `now_ms`.
  """
  @spec set_clock(GenServer.server(), integer()) :: integer()
  def set_clock(server, now_ms) when is_integer(now_ms) do
    GenServer.call(server, {:set_clock, now_ms})
  end

  @doc """
  Replaces the metadata fetcher function at runtime (useful for simulating
  transient metadata outages and recovery).
  """
  @spec set_fetcher(GenServer.server(), fetcher_fn()) :: :ok
  def set_fetcher(server, fetcher) when is_function(fetcher, 1) do
    GenServer.call(server, {:set_fetcher, fetcher})
  end

  @doc """
  Returns the current cached token metadata (or `nil` if empty).
  """
  @spec cached_token(GenServer.server()) :: cached_token() | nil
  def cached_token(server) do
    GenServer.call(server, :cached_token)
  end

  @doc """
  Returns accumulated cache and refresh statistics.
  """
  @spec stats(GenServer.server()) :: stats()
  def stats(server) do
    GenServer.call(server, :stats)
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    default_ttl = Keyword.get(opts, :default_expires_in_sec, @default_expires_in_sec)

    state = %{
      now_ms: Keyword.get(opts, :now_ms, 1_700_000_000_000),
      clock_fn: Keyword.get(opts, :clock_fn),
      refresh_margin_ms: Keyword.get(opts, :refresh_margin_ms, @default_refresh_margin_ms),
      stale_on_error?: Keyword.get(opts, :stale_on_error?, true),
      headers: Keyword.get(opts, :headers, [@metadata_flavor_header]),
      fetcher: Keyword.get(opts, :fetcher, default_fetcher(default_ttl)),
      token: nil,
      seq: 0,
      stats: %{
        cache_hits: 0,
        metadata_fetches: 0,
        pre_expiry_refreshes: 0,
        hard_expiry_refreshes: 0,
        stale_fallbacks: 0,
        errors: 0,
        invalidations: 0
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_token, _from, state) do
    now = current_time_ms(state)

    case token_status(state.token, now, state.refresh_margin_ms) do
      :fresh ->
        state = inc_stat(state, :cache_hits)
        {:reply, {:ok, state.token.access_token}, state}

      status when status in [:empty, :pre_expiry, :expired] ->
        fetch_and_update(state, now, status)
    end
  end

  def handle_call(:invalidate, _from, state) do
    state =
      state
      |> Map.put(:token, nil)
      |> inc_stat(:invalidations)

    {:reply, :ok, state}
  end

  def handle_call({:advance_clock, delta_ms}, _from, state) do
    new_now = state.now_ms + delta_ms
    {:reply, new_now, %{state | now_ms: new_now}}
  end

  def handle_call({:set_clock, now_ms}, _from, state) do
    {:reply, now_ms, %{state | now_ms: now_ms}}
  end

  def handle_call({:set_fetcher, fetcher}, _from, state) do
    {:reply, :ok, %{state | fetcher: fetcher}}
  end

  def handle_call(:cached_token, _from, state) do
    {:reply, state.token, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end

  ## Internals

  defp fetch_and_update(state, now, status) do
    next_seq = state.seq + 1

    request = %{
      url: @metadata_url,
      headers: state.headers,
      scope: @vertex_scope,
      seq: next_seq
    }

    state = %{state | seq: next_seq} |> inc_stat(:metadata_fetches)

    state =
      case status do
        :pre_expiry -> inc_stat(state, :pre_expiry_refreshes)
        :expired -> inc_stat(state, :hard_expiry_refreshes)
        :empty -> state
      end

    with :ok <- validate_metadata_request(request),
         {:ok, payload} <- safe_fetch(state.fetcher, request),
         {:ok, cached} <- parse_token_payload(payload, now) do
      {:reply, {:ok, cached.access_token}, %{state | token: cached}}
    else
      {:error, reason} ->
        state = inc_stat(state, :errors)

        if status == :pre_expiry and state.stale_on_error? and state.token != nil and
             now < state.token.expires_at_ms do
          state = inc_stat(state, :stale_fallbacks)
          {:reply, {:ok, state.token.access_token}, state}
        else
          # Never serve a hard-expired token.
          state = if status == :expired, do: %{state | token: nil}, else: state
          {:reply, {:error, reason}, state}
        end
    end
  end

  defp token_status(nil, _now, _margin), do: :empty

  defp token_status(%{expires_at_ms: expires_at_ms}, now, margin) do
    cond do
      now >= expires_at_ms -> :expired
      now >= expires_at_ms - margin -> :pre_expiry
      true -> :fresh
    end
  end

  defp safe_fetch(fetcher, request) do
    fetcher.(request)
  rescue
    e -> {:error, {:fetcher_exception, e}}
  end

  defp parse_token_payload(
         %{"access_token" => token, "expires_in" => expires_in} = payload,
         now
       )
       when is_binary(token) and byte_size(token) > 0 and is_integer(expires_in) and expires_in > 0 do
    token_type = Map.get(payload, "token_type", "Bearer")

    {:ok,
     %{
       access_token: token,
       token_type: token_type,
       expires_in: expires_in,
       fetched_at_ms: now,
       expires_at_ms: now + expires_in * 1000
     }}
  end

  defp parse_token_payload(payload, _now), do: {:error, {:invalid_token_payload, payload}}

  defp default_fetcher(default_ttl) do
    fn %{seq: seq} ->
      {:ok,
       %{
         "access_token" => "ya29.sim-vertex-token-#{seq}",
         "expires_in" => default_ttl,
         "token_type" => "Bearer"
       }}
    end
  end

  defp current_time_ms(%{clock_fn: clock_fn}) when is_function(clock_fn, 0), do: clock_fn.()
  defp current_time_ms(%{now_ms: now_ms}), do: now_ms

  defp inc_stat(state, key) do
    update_in(state, [:stats, key], &(&1 + 1))
  end

  defp find_header(headers, target_downcased) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} when is_binary(k) and is_binary(v) ->
        if String.downcase(k) == target_downcased, do: v, else: nil

      _ ->
        nil
    end)
  end

  defp find_header(headers, target_downcased) when is_map(headers) do
    Enum.find_value(headers, fn
      {k, v} when is_binary(k) and is_binary(v) ->
        if String.downcase(k) == target_downcased, do: v, else: nil

      _ ->
        nil
    end)
  end

  defp find_header(_, _), do: nil
end
