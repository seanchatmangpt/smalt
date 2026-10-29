defmodule Smalt.DataPlane.ApimGateway do
  @moduledoc """
  APIM policy-execution gateway (ticket T-07, receipt r16).

  A pass-through Plug that serves TWO path families and lets everything
  else through untouched (no response sent, no halt), so it can be mounted
  in front of `plug(:match)` in `Smalt.ArmGateway.Router` without changing
  any existing route:

  1. **ARM data-plane invocation** —
     `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ApiManagement/service/{svc}/apis/{api}/{rest...}`
     (fixed segments matched case-insensitively, like ARM's own paths).
  2. **Configured gateway base** (default `"/api-gw"`,
     `Application.get_env(:smalt, :apim_gateway_base)`) —
     `/{base}/{svc}/{api}/{rest...}`, where `{api}` matches the api resource
     NAME or its `properties.path` gateway alias.

  For a matched path the gateway resolves the service/api/operation out of
  `Smalt.Store` (`:smalt_resources`, written by `Smalt.DataPlane.Apim`),
  gathers the policy documents in APIM inheritance order
  (service -> api -> operation), parses each inbound section with
  `Smalt.DataPlane.Apim.parse_policy/1`, and executes the policies in
  document order:

  - `rate-limit` — fixed-window counter in the `:smalt_apim_rate` ETS
    table (mirrors the ARM-wide `:arm_rate_limit` throttle: named table,
    heir to `:init`, `:ets.update_counter/4`, previous window pruned). On
    breach: `429` + `Retry-After` + the real gateway body
    `{"statusCode":429,"message":"Rate limit is exceeded"}`.
  - `set-header` — inbound request-header rewrite with `exists-action`
    semantics (overwrite default / append / skip / delete).
  - `validate-jwt` — token present + Bearer shape + full STS verification
    through `Smalt.Auth.Bearer.verify_bearer/1` (signature, exp/nbf, aud,
    iss — no relaxed crypto), then `required-claims` value checks against
    the decoded JWT payload. Tokenless/malformed/signature failures answer
    `401` with the house `WWW-Authenticate: Bearer` challenge (the shape
    the error middleware already expects); a token LACKING a required
    claim answers `403`. The policy's `failed-validation-httpcode`
    attribute overrides the default status; `failed-validation-error-
    message` overrides the message. Failures carry the ARM error envelope.

  When every policy admits, the request forwards to the operation's
  `properties.backendUrl` (or the api's `properties.serviceUrl`) via
  **Finch** (vendored transitive dep, promoted at integration — see the
  receipt; started lazily on the first forwarded request) and the backend
  response is relayed verbatim (status + headers minus hop-by-hop + body).
  No backend configured, or a refused/timeout backend connection, answers
  a typed `502` — real APIM's face for a dead backend.
  """

  @behaviour Plug

  import Plug.Conn

  alias Smalt.DataPlane.Apim

  @default_gateway_base "/api-gw"
  @finch_name :smalt_apim_finch
  @rate_table :smalt_apim_rate
  @default_backend_timeout_ms 30_000

  # Hop-by-hop / connection-managed request headers never forwarded
  # (RFC 9110 §7.6.1); content-length/host are recomputed by Finch.
  @drop_req_headers [
    "host",
    "content-length",
    "connection",
    "keep-alive",
    "transfer-encoding",
    "upgrade",
    "te",
    "trailer",
    "proxy-authorization",
    "proxy-authenticate",
    "expect"
  ]

  # Response headers that describe the connection to US, not to the client;
  # relaying them would lie about the hop (date/server/content-length/
  # transfer-encoding are recomputed by the adapter).
  @drop_resp_headers [
    "content-length",
    "transfer-encoding",
    "connection",
    "keep-alive",
    "date",
    "server",
    "content-encoding"
  ]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case resolve(conn) do
      :pass ->
        # Not ours: leave the conn completely untouched for the next plug.
        conn

      {:apim, sub, rg, svc, api_segment, rest} ->
        dispatch(conn, sub, rg, svc, api_segment, rest)
    end
  end

  # ---------------------------------------------------------------------------
  # path family resolution
  # ---------------------------------------------------------------------------

  # ARM family (downcased):
  #   subscriptions/{sub}/{rg}/providers/microsoft.apimanagement/service/{svc}/apis/{api}/{rest}
  # The resource-name segments are recovered from the ORIGINAL path_info so
  # resource ids keep the case the client sent (house id convention).
  defp resolve(conn) do
    info = conn.path_info
    lower = Enum.map(info, &String.downcase/1)

    case lower do
      ["subscriptions", _sub, _rg, "providers", "microsoft.apimanagement", "service", _svc, "apis", _api | _rest] ->
        [raw_sub, raw_rg, _p, _ns, raw_svc, _apis, raw_api] = Enum.take(info, 7)
        {:apim, raw_sub, raw_rg, raw_svc, raw_api, Enum.drop(info, 9)}

      _ ->
        gateway_family(info)
    end
  end

  defp gateway_family(info) do
    base = gateway_base_segments()

    if Enum.take(info, length(base)) == base do
      case Enum.drop(info, length(base)) do
        [svc, api | rest] ->
          {:apim, nil, nil, svc, api, rest}

        _ ->
          # {base}/{svc} or {base}/{svc}/{api} with no operation path: a
          # gateway address without an operation target is a typed 404, and
          # a bare {base} prefix belongs to whoever configured it — pass.
          :pass
      end
    else
      :pass
    end
  end

  defp gateway_base_segments do
    base = Application.get_env(:smalt, :apim_gateway_base, @default_gateway_base)

    base
    |> String.split("/", trim: true)
    |> Enum.map(&String.downcase/1)
  end

  # ---------------------------------------------------------------------------
  # dispatch
  # ---------------------------------------------------------------------------

  defp dispatch(conn, sub, rg, svc, api_segment, rest) do
    {sub, rg} = locate_service(sub, rg, svc)

    with {:ok, _service} <- Apim.get_service(sub, rg, svc),
         {:ok, api} <- Apim.find_api(sub, rg, svc, api_segment),
         {:ok, op} <- Apim.find_operation(sub, rg, svc, api["name"], conn.method, rest) do
      execute(conn, sub, rg, svc, api, op, rest)
    else
      {:error, status, code, msg} ->
        arm_error(conn, status, code, msg)
    end
  end

  # Gateway-base family carries no subscription context in the URL. The
  # seeded default subscription is tried first (the az apim create flow puts
  # the service there); anything else is found by the downcased id suffix.
  defp locate_service(nil, _rg, svc) do
    suffix = "/providers/microsoft.apimanagement/service/#{String.downcase(svc)}"

    match =
      Smalt.Store.keys(:smalt_resources)
      |> Enum.find(fn key -> is_binary(key) and String.ends_with?(key, suffix) end)

    case match do
      nil ->
        {nil, nil}

      key ->
        case String.split(key, "/", trim: true) do
          ["subscriptions", sub, "resourcegroups", rg | _] -> {sub, rg}
          _ -> {nil, nil}
        end
    end
  end

  defp locate_service(sub, rg, _svc), do: {sub, rg}

  # ---------------------------------------------------------------------------
  # policy execution
  # ---------------------------------------------------------------------------

  defp execute(conn, sub, rg, svc, api, op, rest) do
    scope_key = {String.downcase(Apim.api_id(sub, rg, svc, api["name"])), op["name"]}

    with {:ok, policies} <- gathered_policies(sub, rg, svc, api, op) do
      conn = run_inbound(conn, policies, scope_key)
      maybe_forward(conn, api, op, rest)
    else
      {:error, status, code, msg} ->
        arm_error(conn, status, code, msg)
    end
  end

  # Service -> api -> operation scope order is the real APIM inheritance
  # order; within each document the parsed inbound list keeps document order.
  defp gathered_policies(sub, rg, svc, api, op) do
    api_name = api["name"]
    op_name = op["name"]

    scopes = [
      {:service, nil, nil},
      {:api, api_name, nil},
      {:operation, api_name, op_name}
    ]

    Enum.reduce_while(scopes, {:ok, []}, fn
      {scope, a, b}, {:ok, acc} ->
        case Apim.get_policy(sub, rg, svc, scope, a, b, "policy") do
          {:ok, record} ->
            case Apim.parse_policy(record["properties"]["value"]) do
              {:ok, parsed} ->
                {:cont, {:ok, acc ++ parsed["inbound"]}}

              # Stored docs are validated at PUT; a refusal here means the
              # row was tampered with outside the API — refuse fail-closed.
              {:error, _, _, _} = refusal ->
                {:halt, refusal}
            end

          {:error, 404, _, _} ->
            {:cont, {:ok, acc}}

          {:error, _, _, _} = refusal ->
            {:halt, refusal}
        end
    end)
  end

  defp run_inbound(conn, policies, scope_key) do
    Enum.reduce_while(policies, conn, fn policy, conn ->
      case apply_policy(policy, conn, scope_key) do
        {:halt, conn} -> {:halt, conn}
        {:cont, conn} -> {:cont, conn}
      end
    end)
  end

  defp apply_policy(%{"type" => "rate-limit"} = policy, conn, scope_key) do
    calls = policy["calls"]
    window_s = policy["renewal-period"]

    window = div(System.system_time(:second), window_s)
    key = {scope_key, window}

    count = :ets.update_counter(rate_table(), key, {2, 1}, {key, 0})

    # Fixed-window lease: the previous window's key is pruned so the table
    # does not grow one key per window for the life of the VM (the same
    # contract as the ARM-wide throttle's pruning).
    :ets.delete(rate_table(), {scope_key, window - 1})

    if count > calls do
      retry_after = policy["retry-after"] || 1
      {:halt, rate_limited(conn, retry_after)}
    else
      {:cont, conn}
    end
  end

  defp apply_policy(%{"type" => "set-header"} = policy, conn, _scope_key) do
    name = String.downcase(policy["name"])
    value = policy["value"]
    action = policy["exists-action"]
    exists? = get_req_header(conn, name) != []

    conn =
      cond do
        action == "delete" ->
          delete_req_header(conn, name)

        action == "skip" and exists? ->
          conn

        action == "append" and exists? ->
          [current | _] = get_req_header(conn, name)
          put_req_header(conn, name, "#{current},#{value}")

        true ->
          # overwrite (the default exists-action) and skip/append targeting
          # a header the request does not carry yet.
          put_req_header(conn, name, value)
      end

    {:cont, conn}
  end

  defp apply_policy(%{"type" => "validate-jwt"} = policy, conn, _scope_key) do
    validate_jwt(policy, conn)
  end

  # -- rate limit ---------------------------------------------------------------

  # Test seam: the window-counter table (creates it when missing).
  @doc false
  def rate_table_for_test, do: rate_table()

  defp rate_table do
    if :ets.info(@rate_table) == :undefined do
      try do
        # Mirrors the ARM-wide throttle's table law (router.ex rate_table/0):
        # the first creator is a request task — without an heir the counter
        # table DIES with that request and the next burst re-creates a fresh
        # table mid-window. Heir to :init (permanent, node-local) makes the
        # window survive its creator; the ArgumentError rescue keeps the
        # create race fail-safe.
        :ets.new(@rate_table, [
          :named_table,
          :public,
          :set,
          {:read_concurrency, true},
          {:write_concurrency, true},
          {:heir, Process.whereis(:init), []}
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    @rate_table
  end

  # Real APIM's rate-limit breach face: 429 + Retry-After +
  # {"statusCode":429,"message":"Rate limit is exceeded"}.
  defp rate_limited(conn, retry_after) do
    body = Jason.encode!(%{"statusCode" => 429, "message" => "Rate limit is exceeded"})

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_resp_content_type("application/json")
    |> send_resp(429, body)
    |> halt()
  end

  # -- validate-jwt -------------------------------------------------------------

  defp validate_jwt(policy, conn) do
    header_name = String.downcase(policy["header-name"] || "authorization")
    failure_status = policy["failed-validation-httpcode"]
    failure_message = policy["failed-validation-error-message"]

    case token_from(conn, header_name) do
      {:ok, token} ->
        verified =
          conn
          |> put_req_header("authorization", "Bearer " <> token)
          |> Smalt.Auth.Bearer.verify_bearer()

        case verified do
          :ok ->
            with {:ok, claims} <- decode_claims(token),
                 :ok <- check_claims(policy, claims) do
              {:cont, conn}
            else
              {:error, reason} ->
                {:halt, jwt_refuse(conn, 403, failure_status, failure_message, reason)}

              {:refuse, code, reason} ->
                {:halt, jwt_refuse(conn, 401, failure_status, failure_message, reason, code)}
            end

          {:refuse, code, reason} ->
            {:halt, jwt_refuse(conn, 401, failure_status, failure_message, reason, code)}
        end

      {:error, reason} ->
        {:halt, jwt_refuse(conn, 401, failure_status, failure_message, reason)}

      :missing ->
        {:halt,
         jwt_refuse(
           conn,
           401,
           failure_status,
           failure_message || "Invalid JWT: token is not present",
           "AuthenticationFailed"
         )}
    end
  end

  defp token_from(conn, header_name) do
    case get_req_header(conn, header_name) do
      [value | _] ->
        value = String.trim(value)

        case String.split(value, " ", parts: 2) do
          [scheme, token] when byte_size(String.trim(token)) > 0 ->
            if String.downcase(scheme) == "bearer" do
              {:ok, String.trim(token)}
            else
              {:error, "Invalid JWT: header scheme '#{scheme}' is not Bearer"}
            end

          [raw_token] when byte_size(raw_token) > 0 ->
            # Policy targeting a raw-token header (no auth scheme) — real
            # APIM reads the header value as the token verbatim.
            {:ok, raw_token}

          _ ->
            :missing
        end

      _ ->
        :missing
    end
  end

  # JWT payload reading — STRUCTURAL only. The cryptographic envelope
  # (signature / exp / nbf / aud / iss) was already verified through
  # Smalt.Auth.Bearer.verify_bearer/1 above; this step just decodes the
  # payload for the policy's required-claims value checks.
  defp decode_claims(token) do
    case String.split(token, ".", parts: 3) do
      [_header, payload, _signature] ->
        with {:ok, json} <- b64url_decode(payload),
             {:ok, claims} <- Jason.decode(json) do
          {:ok, claims}
        else
          _ -> {:error, "Invalid JWT: payload is not decodable"}
        end

      _ ->
        {:error, "Invalid JWT: token is not a JWS compact serialization"}
    end
  end

  defp b64url_decode(payload) do
    case Base.url_decode64(payload, padding: false) do
      {:ok, _} = ok ->
        ok

      :error ->
        Base.url_decode64(payload)
    end
  end

  defp check_claims(policy, claims) do
    policy["required-claims"]
    |> Enum.reduce_while(:ok, fn claim, :ok ->
      name = claim["name"]
      required = claim["values"] || []
      present? = Map.has_key?(claims, name)
      actual = claim_values(claims[name])

      ok? =
        cond do
          not present? ->
            false

          required == [] ->
            # No <value> children: presence-only check (real APIM requires
            # at least the claim to exist).
            true

          claim["match"] == "any" ->
            Enum.any?(required, &(&1 in actual))

          true ->
            Enum.all?(required, &(&1 in actual))
        end

      if ok? do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          "Invalid JWT: required claim '#{name}' #{claim_failure_detail(required, present?)}"}}
      end
    end)
  end

  defp claim_failure_detail([], _present?), do: "is missing"
  defp claim_failure_detail(_required, false), do: "is missing"

  defp claim_failure_detail(required, true),
    do: "does not carry the required values (#{Enum.join(required, ", ")})"

  defp claim_values(nil), do: []
  defp claim_values(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp claim_values(value), do: [to_string(value)]

  # The house 401 face: ARM error envelope + the Bearer challenge shape the
  # error middleware already consumes (Smalt.Auth.Bearer refuse parity).
  defp jwt_refuse(conn, default_status, policy_status, policy_message, reason, code \\ "InvalidAuthenticationToken") do
    status = policy_status || default_status
    message = policy_message || reason

    body = Jason.encode!(%{"error" => %{"code" => code, "message" => message}})

    conn =
      if status == 401 do
        put_resp_header(conn, "www-authenticate", Smalt.Auth.Bearer.challenge_value(conn, message))
      else
        conn
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end

  # ---------------------------------------------------------------------------
  # backend forwarding (Finch)
  # ---------------------------------------------------------------------------

  defp maybe_forward(%{state: :sent} = conn, _api, _op, _rest), do: conn

  defp maybe_forward(conn, api, op, rest) do
    backend =
      (op["properties"] || %{})["backendUrl"] ||
        (api["properties"] || %{})["serviceUrl"]

    case backend do
      nil ->
        arm_error(
          conn,
          502,
          "BackendUnavailable",
          "No backend is configured for operation '#{op["name"]}' (set properties.serviceUrl on the api, or backendUrl on the operation)."
        )

      _backend ->
        forward(conn, backend, rest)
    end
  end

  defp forward(conn, backend, rest) do
    with {:ok, body, conn} <- read_forward_body(conn),
         {:ok, resp} <- finch_request(conn, backend, rest, body) do
      relay(conn, resp)
    else
      {:error, reason} when is_binary(reason) ->
        backend_down(conn, reason)

      {:error, reason} ->
        backend_down(conn, inspect(reason))
    end
  end

  defp read_forward_body(conn) do
    case conn.method do
      m when m in ["GET", "HEAD"] ->
        {:ok, nil, conn}

      _ ->
        case read_body(conn) do
          {:ok, body, conn} -> {:ok, body, conn}
          {:more, body, conn} -> {:ok, body, conn}
          {:error, reason} -> {:error, "backend request body unreadable: #{inspect(reason)}"}
        end
    end
  end

  defp finch_request(conn, backend, rest, body) do
    url = build_url(backend, rest, conn.query_string)

    headers =
      conn.req_headers
      |> Enum.reject(fn {name, _} -> name in @drop_req_headers end)

    ensure_finch()

    request = Finch.build(method_atom(conn.method), url, headers, body)

    timeout_ms = Application.get_env(:smalt, :apim_backend_timeout_ms, @default_backend_timeout_ms)

    case Finch.request(request, @finch_name, receive_timeout: timeout_ms, pool_timeout: 5_000) do
      {:ok, %Finch.Response{} = resp} ->
        {:ok, resp}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  # The rest of the gateway path is forwarded verbatim (percent-encoding as
  # received); the operation template only ROUTES, it does not rewrite.
  defp build_url(backend, rest, query_string) do
    path =
      case rest do
        [] -> ""
        segs -> "/" <> Enum.join(segs, "/")
      end

    base = String.trim_trailing(backend, "/") <> path

    if query_string == "", do: base, else: "#{base}?#{query_string}"
  end

  defp method_atom(method) do
    case String.downcase(method) do
      "get" -> :get
      "post" -> :post
      "put" -> :put
      "patch" -> :patch
      "delete" -> :delete
      "head" -> :head
      "options" -> :options
      _ -> :get
    end
  end

  # Finch is a vendored transitive dep (no :finch entry in mix.exs yet — the
  # integrator promotes it, see the receipt), so there is no supervised
  # instance to borrow. Start lazily, tolerating the already-started race.
  # Lifecycle note (disclosed): the started instance links to the first
  # requesting process, so a keep-alive connection task death takes the pool
  # with it and the NEXT request re-arms — rate windows are unaffected
  # (they live in the ETS table, not Finch).
  defp ensure_finch do
    if Process.whereis(@finch_name) == nil do
      case Finch.start_link(name: @finch_name) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_started} -> :ok
      end
    else
      :ok
    end
  end

  defp relay(conn, %Finch.Response{status: status, headers: headers, body: body}) do
    conn =
      headers
      |> Enum.reject(fn {name, _} -> name in @drop_resp_headers end)
      |> Enum.reduce(conn, fn {name, value}, c -> put_resp_header(c, name, value) end)

    send_resp(conn, status, body)
  end

  defp backend_down(conn, reason) do
    arm_error(conn, 502, "BackendUnavailable", "The backend did not answer: #{reason}")
  end

  # ---------------------------------------------------------------------------
  # envelopes
  # ---------------------------------------------------------------------------

  defp arm_error(conn, status, code, message) do
    body = Jason.encode!(%{"error" => %{"code" => code, "message" => message, "innererror" => %{}}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
