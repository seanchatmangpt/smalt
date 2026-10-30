defmodule Smalt.Apim do
  @moduledoc """
  Minimal in-process APIM-style policy pipeline (PRD-APIM slice).

  A standalone plug pipeline runner over a list of typed policies:

      {:rate_limit, Keyword.t()}       # ETS windowed counter -> 429 over quota
      {:header_transform, Keyword.t()} # add/remove request headers -> :ok
      {:jwt, Keyword.t()}              # bearer verification via Smalt.Auth.Bearer

  Contract: each policy's check returns

      :ok                            -> continue to the next policy
      {:refuse, status, code, msg}   -> halt the chain with a typed error
                                        envelope (`{"error": {code, message}}`)

  The module is standalone — nothing wires it into the main router yet; that
  is a separate work order. Tests are the deliverable's witness.
  """

  @behaviour Plug

  import Plug.Conn

  @rate_table :smalt_apim_rate_limit

  # Supervised owner for the rate-limit ETS table. LAZY ownership (create in a
  # request process) is a wire-proven defect: Bandit serves each request in a
  # short-lived process, so the table died with the first request and the
  # window counter reset every request -- 429 never fired on a live server even
  # though the in-process court passed (witnessed on the APIMWIRE private boot,
  # v26.10.21). Starting {Smalt.Apim, []} in Smalt.Application gives the table
  # an owner that outlives requests; the lazy fallback below stays for
  # standalone/Plug-only runs.
  def child_spec(_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker
    }
  end

  # T44 lane compile/boot-unblock (SLA, disclosed): child_spec passes [] so
  # arity 0 is required; owner lane left only start_link/1 -> boot undef.
  def start_link, do: start_link([])

  # JA-1 #1 / JA-4 fix (2026-10-21): the owner is a proper proc_lib GenServer,
  # not a naked spawn_link + sleep(:infinity) — start failures now surface as
  # {:error, _} to the supervisor instead of being swallowed, crash reports
  # carry the proc_lib label, and the supervisor's restart strategy actually
  # governs a restartable process. init creates the table in the owner and
  # republishes the same persistent_term key the label test reads.
  def start_link(_arg) do
    # JA-10 compile-unblock (disclosed; minimal fix to the in-flight JA-1/JA-4 edit): Elixir 1.20.4 GenServer.start_link rejects an explicit {:local, _} tuple as :name — pass the bare atom, identical semantics.
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # BK-47 (2026-10-21): the JA-R2 conversion left init/1 as two UNGROUPED
  # clauses under different @impl annotations (@impl GenServer on the :ok
  # clause, @impl Plug on the opts clause) — Elixir 1.20 warns "def init/1
  # was previously defined" + "@impl GenServer but this behaviour was not
  # declared with @behaviour" (only @behaviour Plug is declared). Fix: one
  # grouped clause set under @impl true — GenServer and Plug BOTH declare
  # init/1, so a single impl satisfies both callbacks. The :ok clause is the
  # live GenServer owner (ETS table + label + persistent_term); the opts
  # clause is the Plug.init pass-through.
  @impl true
  def init(:ok) do
    Process.set_label(%{service: :apim, role: :rate_table_owner})
    ensure_table()
    :persistent_term.put({__MODULE__, :rate_table_owner}, self())
    {:ok, %{}}
  end

  def init(opts), do: opts

  # Not under @impl: the module declares @behaviour Plug only (declaring
  # GenServer too conflicts on init/1), so a bare def keeps 1.20 quiet while
  # GenServer still dispatches to it at runtime.
  def handle_info(_msg, state), do: {:noreply, state}

  @type policy ::
          {:rate_limit, Keyword.t()} | {:header_transform, Keyword.t()} | {:jwt, Keyword.t()}

  @doc """
  Runs `policies` in order over `conn`. First refusal halts the chain and
  sends the typed envelope; an all-`:ok` chain returns the (possibly
  header-transformed) conn with no response sent.
  """
  @impl Plug
  def call(conn, policies), do: run(conn, policies)

  @spec run(Plug.Conn.t(), [policy]) :: Plug.Conn.t()
  def run(conn, policies) do
    policies
    |> Enum.reduce_while(conn, fn policy, conn ->
      case check(policy, conn) do
        :ok ->
          {:cont, conn}

        {:transform, conn} ->
          {:cont, conn}

        {:refuse, status, code, msg} ->
          {:halt, refuse(conn, status, code, msg)}
      end
    end)
  end

  # -- gateway wire plane (PRD-APIM wire court, ApimWireTest) ---------------------
  #
  # Config-driven route family served from the LIVE router: paths under
  # /apim-gw/{api}/... dispatch through the policy chain named by
  # `config :smalt, :apim_gateways` (map of api NAME -> %{policies: [...]};
  # keys are BINARIES — never String.to_atom on anything request-shaped).
  #
  # Ordering law (r4-baseline-triage, all 12 ApimWire failures `left: 400`):
  # this plane must run BEFORE the router's blob catch-all, whose
  # MissingXMsVersion guard blanket-400s every unversioned 3-segment path —
  # the gateway policies (jwt / rate-limit 429) and the default-off typed
  # 404 must answer before that guard is ever reached.

  @gateway_first_segment "apim-gw"

  @doc """
  Plug entry wired into `Smalt.EgressRouter` (before `:match`). Claims
  `/apim-gw/{api}/{rest...}` paths only; everything else passes through
  untouched. A configured api runs its `:policies` chain (`Smalt.Apim.run/2`
  — first refusal halts with the typed envelope), then answers 200 with the
  built-in echo face (`{"api","method","path","headers"}`). An UNCONFIGURED
  api answers the typed 404 face. Never raises on request-shaped input.
  """
  def gateway(conn, _opts) do
    case conn.path_info do
      [@gateway_first_segment, api | _rest] ->
        dispatch_gateway(conn, api)

      _ ->
        conn
    end
  end

  defp dispatch_gateway(conn, api) do
    conf = gateway_config(api)

    if conf do
      conn
      |> run(conf_policies(conf))
      |> then(fn
        %Plug.Conn{state: :sent} = conn -> conn
        conn -> echo_response(conn, api)
      end)
    else
      gateway_not_found(conn, api)
    end
  end

  defp gateway_config(api) do
    :smalt
    |> Application.get_env(:apim_gateways, %{})
    |> Map.get(api)
  end

  # The gateway config entry is a MAP (`%{policies: [...]}` — the wire
  # contract's shape); a keyword list is tolerated for symmetry with the
  # `run/2` policy-list idiom.
  defp conf_policies(%{} = conf), do: Map.get(conf, :policies, [])
  defp conf_policies(conf) when is_list(conf), do: Keyword.get(conf, :policies, [])
  defp conf_policies(_), do: []

  # Default OFF posture: an unconfigured api is a typed 404 (the same face
  # class the blob catch-all serves), never a silent pass into the blob
  # MissingXMsVersion blanket 400.
  defp gateway_not_found(conn, api) do
    body =
      Jason.encode!(%{
        "error" => %{
          "code" => "ApiNotFound",
          "message" => "The api '#{api}' is not configured on this gateway."
        }
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, body)
    |> halt()
  end

  # Built-in echo backend (the wire court's witness): a fully-admitted
  # request answers 200 with the post-transform request echo. The header
  # map carries any :header_transform writes so the court can pin the
  # transform actually ran on the wire.
  defp echo_response(conn, api) do
    body =
      Jason.encode!(%{
        "api" => api,
        "method" => conn.method,
        "path" => conn.request_path,
        "headers" => Map.new(conn.req_headers)
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
    |> halt()
  end

  # -- policy dispatch -----------------------------------------------------------

  defp check({:rate_limit, opts}, conn), do: rate_limit(conn, opts)
  defp check({:header_transform, opts}, conn), do: {:transform, header_transform(conn, opts)}
  defp check({:jwt, _opts}, conn), do: jwt(conn)

  defp check(other, _conn),
    do: raise(ArgumentError, message: "unknown APIM policy: #{inspect(other)}")

  # -- rate limit (ETS windowed counter) -----------------------------------------

  defp rate_limit(conn, opts) do
    table = ensure_table()
    limit = Keyword.fetch!(opts, :limit)
    window_s = Keyword.get(opts, :window_seconds, 60)
    scope = Keyword.get(opts, :scope, "default")

    window = div(System.system_time(:second), window_s)
    ets_key = {scope, conn.remote_ip, window}

    count =
      case :ets.lookup(table, ets_key) do
        [{_, n}] -> n
        [] -> 0
      end

    if count >= limit do
      {:refuse, 429, "TooManyRequests",
       "Rate limit exceeded: #{count + 1} requests > limit #{limit} in window"}
    else
      :ets.insert(table, {ets_key, count + 1})
      :ok
    end
  end

  defp ensure_table do
    case :ets.whereis(@rate_table) do
      :undefined ->
        try do
          # JA-4 fix: write_concurrency for concurrent request processes +
          # heir to :init so a lazy creator (standalone/Plug-only runs) dying
          # cannot delete the window counters out from under later requests
          # (same class as the policy.ex shadow-table law).
          :ets.new(@rate_table, [
            :named_table,
            :set,
            :public,
            {:read_concurrency, true},
            {:write_concurrency, true},
            {:heir, Process.whereis(:init), []}
          ])
        rescue
          ArgumentError -> @rate_table
        end

        @rate_table

      _tid ->
        @rate_table
    end
  end

  # -- header transform ----------------------------------------------------------

  defp header_transform(conn, opts) do
    conn
    |> apply_sets(Keyword.get(opts, :set))
    |> apply_removes(Keyword.get(opts, :remove))
  end

  defp apply_sets(conn, nil), do: conn

  defp apply_sets(conn, sets) when is_list(sets) do
    Enum.reduce(sets, conn, fn {name, value}, c -> put_req_header(c, name, value) end)
  end

  defp apply_removes(conn, nil), do: conn

  defp apply_removes(conn, removes) when is_list(removes) do
    Enum.reduce(removes, conn, fn name, c -> delete_req_header(c, name) end)
  end

  # -- jwt (reuse the existing STS bearer verifier — no new crypto) ---------------

  defp jwt(conn) do
    case Smalt.Auth.Bearer.verify_bearer(conn) do
      :ok ->
        :ok

      {:refuse, code, msg} ->
        {:refuse, 401, code, msg}
    end
  end

  # -- typed refusal envelope ------------------------------------------------------

  defp refuse(conn, status, code, msg) do
    body = Jason.encode!(%{"error" => %{"code" => code, "message" => msg}})

    conn
    |> put_resp_header("retry-after", "1")
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
