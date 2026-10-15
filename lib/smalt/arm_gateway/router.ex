defmodule Smalt.ArmGateway.Router do
  @moduledoc """
  Subsystem 1: smalt-arm-gateway (Control Plane REST Mux)
  Listens on Port 9443 for ARM REST API calls and STS token issuance across all 15 emulated services.

  Surface (v26.10.14):
  - STS/OAuth2 token issuance with v2.0 issuer + oid/sub/tid/azp claims
  - Bootstrap/discovery endpoints (metadata, discovery instance, openid-configuration, tenant)
  - Subscription + resource-group CRUD with case-normalized `resourceGroups` segments
  - LIST routes via `Smalt.Store.list_prefix/2`
  - api-version require/validate against `Smalt.Registry.latest_version/1`
  - Child-resource routes (subnets, keys, blobServices/containers/immutabilityPolicies)
  - azapi POST action routes (.../lock, .../setLegalHold)
  - LRO (202 + Azure-AsyncOperation polling) via `Smalt.ArmGateway.LRO`
  - ARM error envelopes; GraphLaw refusal -> HTTP 400 (pinned)
  """
  use Plug.Router
  alias Smalt.ArmGateway.LRO
  alias Smalt.Store
  alias Smalt.GraphLaw.Validator
  alias Smalt.Registry

  plug(Plug.Logger)
  plug(CORSPlug, origin: "*")
  plug(Smalt.Auth.Bearer)

  plug(Plug.Parsers,
    parsers: [:json, :urlencoded],
    pass: ["*/*"],
    json_decoder: Jason,
    # Caches the raw body in conn.private so the STS token endpoint can
    # refuse duplicate form parameters (OAuth 2.1 draft / AAD parity).
    body_reader: {Smalt.Auth.BodyCache, :read_body, []}
  )

  plug(:arm_request_id)
  plug(:arm_throttle)
  plug(:match)
  plug(:dispatch)

  # ===========================================================================
  # Helpers (Plug.Router requires helpers to be defined BEFORE the routes)
  # ===========================================================================

  @actions ["lock", "setlegalhold"]

  # LIST pagination: ARM lists paginate via nextLink; smalt pages at 100 items
  # per page, `maxitempages` (default 1) controls how many pages one response
  # may carry before truncating with an absolute nextLink.
  @page_size 100

  # Synthetic fixed systemData — honest dev-mode: smalt has no user directory,
  # so every record carries the same substrate identity instead of fabricating
  # per-caller values.
  @system_data %{
    "createdBy" => "smalt-dev-substrate",
    "createdByType" => "Application",
    "createdAt" => "2026-01-01T00:00:00.0000000+00:00"
  }

  # ===========================================================================
  # Wire-level plugs: x-ms-request-id echo (row 11) + ARM-wide throttling
  # (row 12). Both run before match/dispatch; the request-id header is attached
  # via register_before_send so it lands on EVERY response, including 429s.
  # ===========================================================================

  # Echo the client's x-ms-request-id when present, else mint a UUID. ARM SDK
  # retry/mid-tier-replay semantics key off this header.
  defp arm_request_id(conn, _opts) do
    request_id =
      case get_req_header(conn, "x-ms-request-id") do
        [id | _] when is_binary(id) and id != "" -> id
        _ -> generate_uuid()
      end

    register_before_send(conn, fn conn ->
      put_resp_header(conn, "x-ms-request-id", request_id)
    end)
  end

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    # RFC 4122 version 4 / variant bits (band via :erlang.band — Elixir
    # has no &&& operator without an import, and Bitwise is not imported
    # in this module)
    :io_lib.format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", [
      a,
      b,
      :erlang.band(c, 0x0FFF),
      :erlang.band(d, 0x3FFF) + 0x8000,
      e
    ])
    |> IO.iodata_to_binary()
  end

  # ARM-wide fixed-window (1s) throttle: 429 + Retry-After once the configured
  # :smalt, :arm_rate_limit is exceeded. Default :infinity — responses stay
  # byte-identical unless configured (mirrors the cosmos :cosmos_ru_limit gate).
  defp arm_throttle(conn, _opts) do
    case Application.get_env(:smalt, :arm_rate_limit, :infinity) do
      limit when is_integer(limit) and limit > 0 ->
        second = div(System.system_time(:millisecond), 1000)
        key = {:smalt_arm_rate, second}
        count = :ets.update_counter(rate_table(), key, {2, 1}, {key, 0})

        # Prune the previous window's key: the fixed-window counter is a lease,
        # not an asset — without this the table grows one key per second,
        # unbounded, for the life of the VM.
        :ets.delete(rate_table(), {:smalt_arm_rate, second - 1})

        if count > limit do
          throttled(conn)
        else
          conn
        end

      _ ->
        conn
    end
  end

  # Test seam: the throttle's named ETS table (creates it when missing).
  @doc false
  def rate_table_for_test, do: rate_table()

  defp rate_table do
    if :ets.info(:smalt_arm_rate) == :undefined do
      try do
        :ets.new(:smalt_arm_rate, [:named_table, :public, :set, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end

    :smalt_arm_rate
  end

  # Inline envelope (NOT send_arm_error — the arm_error_corpus meta-test pins
  # the exact send_arm_error (status, code) set; 429 is not in that set).
  defp throttled(conn) do
    body =
      Jason.encode!(%{
        "error" => %{
          "code" => "TooManyRequests",
          "message" =>
            "The request rate has exceeded the configured arm_rate_limit. Retry after the indicated interval.",
          "innererror" => %{}
        }
      })

    conn
    |> put_resp_header("retry-after", "1")
    |> put_resp_content_type("application/json")
    |> send_resp(429, body)
    |> halt()
  end

  defp handle_token(conn, tenant_id) do
    case validate_token_request(conn) do
      :ok ->
        issue_token(conn, tenant_id)

      {:error, code} ->
        token_error(conn, code)
    end
  end

  # RFC 6749 §5.2 error responses; §5.1 requires Cache-Control: no-store +
  # Pragma: no-cache on ALL token endpoint responses (success AND error).
  defp token_error(conn, code) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{"error" => code}))
  end

  # RFC 6749 §5.2 request validation:
  # - unparseable/missing grant_type -> invalid_request
  # - wrong grant_type              -> unsupported_grant_type
  # - missing client_id/secret      -> invalid_client
  defp validate_token_request(conn) do
    params = conn.body_params

    # Duplicate form parameters are refused (OAuth 2.1 draft security
    # considerations / AAD parity): Plug's last-wins decoding would let a
    # later client-controlled key overwrite an earlier fixed one. Detected
    # on the RAW body via the BodyCache reader, not the decoded map.
    dup? =
      case conn.private[:smalt_raw_body] do
        body when is_binary(body) ->
          # Exact-key duplicate detection on &-separated pairs: substring
          # neighbors (e.g. xgrant_type=) must NOT false-positive.
          body
          |> String.split("&")
          |> Enum.count(fn
            "grant_type=" <> _ -> true
            "grant_type" -> true
            _ -> false
          end) > 1

        _ ->
          false
      end

    cond do
      dup? ->
        {:error, "invalid_request"}

      not is_map(params) or not is_binary(params["grant_type"]) or params["grant_type"] == "" ->
        {:error, "invalid_request"}

      params["grant_type"] != "client_credentials" ->
        {:error, "unsupported_grant_type"}

      blank?(params["client_id"]) or blank?(params["client_secret"]) ->
        {:error, "invalid_client"}

      true ->
        :ok
    end
  end

  defp blank?(v), do: not is_binary(v) or v == ""

  defp issue_token(conn, tenant_id) do
    signer = sts_signer()
    now = System.system_time(:second)

    # Cross-seat issuer acceptance (F4 v3 finding 1): record the authority the
    # token is minted under so sibling seats (Cosmos :8443, blob, kv) accept
    # it. Server-side only — membership is added at mint time, never from
    # client-asserted claims, so the check stays tamper-resistant.
    authority = request_authority(conn)
    Smalt.Auth.Bearer.register_trusted_authority(authority)

    # OIDC Discovery: the token iss must EXACTLY equal the discovery issuer for
    # the same request authority — both derive from request_authority/1.
    claims = %{
      "aud" => "https://management.azure.com",
      "iss" => "#{authority}/#{tenant_id}/v2.0",
      "iat" => now,
      "nbf" => now,
      "exp" => now + 3600,
      "appid" => "00000000-0000-0000-0000-000000000000",
      "azp" => "00000000-0000-0000-0000-000000000000",
      "oid" => "00000000-0000-0000-0000-000000000001",
      "sub" => "00000000-0000-0000-0000-000000000001",
      "tid" => tenant_id,
      "roles" => ["Contributor", "Owner"]
    }

    {:ok, token, _} = Joken.generate_and_sign(%{}, claims, signer)

    body =
      Jason.encode!(%{
        "token_type" => "Bearer",
        "expires_in" => 3600,
        "ext_expires_in" => 3600,
        "access_token" => token
      })

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> send_json(200, body)
  end

  # STS signing secret: configured via Application.get_env(:smalt, :sts_signing_secret);
  # fail-fast in prod when unset, otherwise generate once per VM lifetime and
  # cache in :persistent_term (mirrors Smalt.Security.ReceiptSigner).
  #
  # Precedence matches Smalt.Auth.Bearer.signer/0: an env-configured secret
  # (>= 32 bytes) wins over the cached dev secret. Otherwise configuring or
  # rotating :sts_signing_secret AFTER gateway boot only takes effect on the
  # verify side while the mint side keeps the generated dev key — every fresh
  # token would 401 SignatureVerificationFailed (witnessed: combined-suite
  # order dependence, cycle 3).
  defp sts_signer do
    case Application.get_env(:smalt, :sts_signing_secret) do
      secret when is_binary(secret) and byte_size(secret) >= 32 ->
        Joken.Signer.create("HS256", secret)

      other when is_binary(other) ->
        raise ArgumentError,
              "smalt :sts_signing_secret must be >= 32 bytes when set (got #{byte_size(other)})"

      _ ->
        case :persistent_term.get({__MODULE__, :sts_signing_secret}, :missing) do
          :missing -> generate_and_cache_secret()
          secret -> Joken.Signer.create("HS256", secret)
        end
    end
  end

  defp generate_and_cache_secret do
    global_key = {__MODULE__, :secret_lock}

    secret =
      :global.trans({global_key, node()}, fn ->
        case :persistent_term.get({__MODULE__, :sts_signing_secret}, :missing) do
          :missing ->
            secret =
              case Application.get_env(:smalt, :sts_signing_secret) do
                secret when is_binary(secret) and byte_size(secret) >= 32 ->
                  secret

                other when is_binary(other) ->
                  raise ArgumentError,
                        "smalt :sts_signing_secret must be >= 32 bytes when set (got #{byte_size(other)})"

                nil ->
                  if Application.get_env(:smalt, :prod, false) do
                    raise ArgumentError,
                          "smalt :sts_signing_secret must be configured in prod (Application.get_env(:smalt, :sts_signing_secret))"
                  else
                    :crypto.strong_rand_bytes(32)
                  end
              end

            :persistent_term.put({__MODULE__, :sts_signing_secret}, secret)
            secret

          secret ->
            {:ok, secret}
        end
      end)

    Joken.Signer.create("HS256", secret)
  end

  # Request-derived authority: scheme://host[:port] as the CLIENT reached us
  # (lane 90 TS court: advertising login.smalt.local — an NXDOMAIN — made
  # msal-node/azidentity follow the envelope and never reach the substrate
  # STS: endpoints_resolution_error). Single derivation shared with the auth
  # plug: forwarded headers honored ONLY from trusted proxies (fail-closed).
  defp request_authority(conn), do: Smalt.Auth.Bearer.request_authority(conn)

  defp openid_envelope(conn, tenant_id) do
    base = "#{request_authority(conn)}/#{tenant_id}"

    %{
      "issuer" => "#{base}/v2.0",
      "token_endpoint" => "#{base}/oauth2/v2.0/token",
      "authorization_endpoint" => "#{base}/oauth2/v2.0/authorize",
      "jwks_uri" => "#{base}/discovery/v2.0/keys",
      "id_token_signing_alg_values_supported" => ["HS256"],
      # OIDC Discovery 3.0 REQUIRED members.
      "response_types_supported" => ["token"],
      "subject_types_supported" => ["public"]
    }
  end

  defp send_tenant_list(conn) do
    tid = "00000000-0000-0000-0000-000000000000"

    body =
      Jason.encode!(%{
        "value" => [
          %{
            "id" => "/tenants/#{tid}",
            "tenantId" => tid,
            "displayName" => "Sovereign",
            "tenantCategory" => "Home"
          }
        ]
      })

    send_json(conn, 200, body)
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  # ARM list envelope with nextLink pagination (row 9): page size 100,
  # `maxitempages` (default 1) caps pages per response; when items remain the
  # response carries an absolute nextLink continuing at $skip.
  defp send_list(conn, items) do
    skip = int_query_param(conn, "$skip", 0)
    pages = max(int_query_param(conn, "maxitempages", 1), 1)
    slice = Enum.slice(items, skip, pages * @page_size)
    next_skip = skip + length(slice)
    truncated? = next_skip < length(items)

    body =
      if truncated? do
        %{"value" => slice, "nextLink" => next_link(conn, next_skip)}
      else
        %{"value" => slice}
      end

    send_json(conn, 200, Jason.encode!(body))
  end

  defp int_query_param(conn, name, default) do
    case conn.query_params[name] do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 -> n
          _ -> default
        end
    end
  end

  defp next_link(conn, skip) do
    pages = max(int_query_param(conn, "maxitempages", 1), 1)

    query =
      conn.query_params
      |> Map.take(["api-version"])
      |> Map.put("maxitempages", Integer.to_string(pages))
      |> Map.put("$skip", skip)
      |> URI.encode_query()

    "#{request_authority(conn)}#{conn.request_path}?#{query}"
  end

  # C1 row 1b: error.target names the offending path when a specific path
  # caused the failure (404 classes); absent on api-version 400s (query-param
  # failures have no path component — corpus pins target ABSENT there).
  defp send_arm_error(conn, status, code, message, target \\ nil) do
    error =
      if target do
        %{
          "code" => code,
          "message" => message,
          "target" => target,
          # Real AAD/ARM shape: innererror present-but-empty when there is
          # nothing further to nest.
          "innererror" => %{}
        }
      else
        %{
          "code" => code,
          "message" => message,
          # Real AAD/ARM shape: innererror present-but-empty when there is
          # nothing further to nest.
          "innererror" => %{}
        }
      end

    body = Jason.encode!(%{"error" => error})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  # GraphLaw refusal -> HTTP 400 (PINNED decision; ARM never returns 422).
  # Envelope code InvalidResourceShape, target AshGraphLaw.Enforcement.
  defp send_graphlaw_refusal(conn, reason) do
    body =
      Jason.encode!(%{
        "error" => %{
          "code" => "InvalidResourceShape",
          "message" => "GraphLaw validation failure: #{reason}",
          "target" => "AshGraphLaw.Enforcement",
          "innererror" => %{}
        }
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, body)
  end

  # RG api-version gate (row 6b, coordinator-authorized landing 2026-10-15):
  # Microsoft.Resources/resourceGroups is an admitted Registry type
  # (latest 2021-04-01) — every RG verb validates api-version like any other
  # admitted type (missing -> 400 MissingApiVersionParameter; stale ->
  # 400 InvalidApiVersionParameter naming the latest).
  @rg_type "Microsoft.Resources/resourceGroups"

  defp handle_rg_list(conn, sub_id) do
    with :ok <- check_api_version(conn, @rg_type) do
      rgs = Store.list_prefix(:smalt_resource_groups, "/subscriptions/#{sub_id}/resourcegroups/")
      send_list(conn, rgs)
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_rg_put(conn, sub_id, rg_name) do
    with :ok <- check_api_version(conn, @rg_type) do
      do_rg_put(conn, sub_id, rg_name)
    else
      {:respond, conn} -> conn
    end
  end

  defp do_rg_put(conn, sub_id, rg_name) do
    rg_id = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"
    payload = conn.body_params

    rg = %{
      "id" => rg_id,
      "name" => rg_name,
      "type" => "Microsoft.Resources/resourceGroups",
      "location" => Map.get(payload, "location", "eastus"),
      "properties" => %{"provisioningState" => "Succeeded"},
      "tags" => Map.get(payload, "tags", %{}),
      "systemData" => @system_data
    }

    existed? = match?({:ok, _}, Store.get(:smalt_resource_groups, String.downcase(rg_id)))
    Store.put(:smalt_resource_groups, String.downcase(rg_id), rg)

    send_json(conn, if(existed?, do: 200, else: 201), Jason.encode!(rg))
  end

  defp handle_rg_get(conn, sub_id, rg_name) do
    with :ok <- check_api_version(conn, @rg_type) do
      do_rg_get(conn, sub_id, rg_name)
    else
      {:respond, conn} -> conn
    end
  end

  defp do_rg_get(conn, sub_id, rg_name) do
    rg_id = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"

    case Store.get(:smalt_resource_groups, String.downcase(rg_id)) do
      {:ok, rg} ->
        send_json(conn, 200, Jason.encode!(rg))

      :error ->
        send_arm_error(
          conn,
          404,
          "ResourceGroupNotFound",
          "Resource group '#{rg_name}' could not be found.",
          rg_id
        )
    end
  end

  # ARM RG delete is an LRO: 202 + Location polling URL + Retry-After (C1 row
  # 4, fixed). The RG and every resource inside it are removed from the Store
  # (cascade — previously children were orphaned and stayed GETable), and an
  # operation record backs the polling URL so the delete poll terminates.
  defp handle_rg_delete(conn, sub_id, rg_name) do
    with :ok <- check_api_version(conn, @rg_type) do
      do_rg_delete(conn, sub_id, rg_name)
    else
      {:respond, conn} -> conn
    end
  end

  defp do_rg_delete(conn, sub_id, rg_name) do
    rg_id = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"
    base = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/")

    Store.delete(:smalt_resource_groups, String.downcase(rg_id))

    for child <- Store.list_prefix(:smalt_resources, base) do
      Store.delete(:smalt_resources, String.downcase(child["id"]))
    end

    op = LRO.start_op(rg_id)
    authority = request_authority(conn)

    conn
    |> put_resp_header("location", "#{authority}#{op["id"]}")
    |> put_resp_header("retry-after", "1")
    |> send_json(202, "")
  end

  defp handle_resource_put(conn, raw_type, sub_id, rg_name, resource_name) do
    with :ok <- check_api_version(conn, raw_type),
         {:ok, full_type} <- check_admitted(conn, raw_type),
         :ok <- check_shape(conn, full_type, conn.body_params) do
      res_id = resource_id(sub_id, rg_name, ns_of(full_type), leaf_of(full_type), resource_name)
      payload = conn.body_params

      record = %{
        "id" => res_id,
        "name" => resource_name,
        "type" => full_type,
        "location" => Map.get(payload, "location", "eastus"),
        "properties" =>
          Map.put(Map.get(payload, "properties", %{}), "provisioningState", "Succeeded"),
        "tags" => Map.get(payload, "tags", %{}),
        "systemData" => @system_data
      }

      existed? = match?({:ok, _}, Store.get(:smalt_resources, String.downcase(res_id)))
      Store.put(:smalt_resources, String.downcase(res_id), record)

      cond do
        lro_type?(full_type) and not existed? ->
          # ARM LRO convention: create -> 202 + async headers (poll to terminal).
          op = LRO.start_op(res_id)
          async_put_response(conn, 202, op)

        lro_type?(full_type) ->
          # update -> 200 + async headers (ARM LRO PUT update convention).
          op = LRO.start_op(res_id)
          async_put_response(conn, 200, op)

        existed? ->
          send_json(conn, 200, Jason.encode!(record))

        true ->
          send_json(conn, 201, Jason.encode!(record))
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_resource_get(conn, sub_id, rg_name, provider_ns, resource_type, resource_name) do
    with :ok <- check_api_version(conn, "#{provider_ns}/#{resource_type}") do
      res_id = resource_id(sub_id, rg_name, provider_ns, resource_type, resource_name)

      case Store.get(:smalt_resources, String.downcase(res_id)) do
        {:ok, record} ->
          send_json(conn, 200, Jason.encode!(record))

        :error ->
          res_id = resource_id(sub_id, rg_name, provider_ns, resource_type, resource_name)

          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The Resource '#{resource_name}' was not found.",
            res_id
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_child_put(conn, child_type, sub_id, rg_name, rel_path) do
    with :ok <- check_api_version(conn, child_type),
         {:ok, full_type} <- check_admitted(conn, child_type),
         :ok <- check_shape(conn, full_type, conn.body_params) do
      id = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/#{rel_path}"
      key = String.downcase(id)
      payload = conn.body_params

      record = %{
        "id" => id,
        "name" => rel_path |> String.split("/") |> List.last(),
        "type" => full_type,
        "location" => Map.get(payload, "location", "eastus"),
        "properties" =>
          Map.put(Map.get(payload, "properties", %{}), "provisioningState", "Succeeded"),
        "tags" => Map.get(payload, "tags", %{}),
        "systemData" => @system_data
      }

      existed? = match?({:ok, _}, Store.get(:smalt_resources, key))
      Store.put(:smalt_resources, key, record)

      send_json(conn, if(existed?, do: 200, else: 201), Jason.encode!(record))
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_child_get(conn, child_type, sub_id, rg_name, rel_path) do
    with :ok <- check_api_version(conn, child_type) do
      key = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/#{rel_path}")

      case Store.get(:smalt_resources, key) do
        {:ok, record} ->
          send_json(conn, 200, Jason.encode!(record))

        :error ->
          name = rel_path |> String.split("/") |> List.last()

          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The Resource '#{name}' was not found.",
            "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/#{rel_path}"
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_child_list(conn, child_type, sub_id, rg_name, parent_rel_path) do
    with :ok <- check_api_version(conn, child_type) do
      prefix =
        String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/#{parent_rel_path}/")

      send_list(conn, Store.list_prefix(:smalt_resources, prefix))
    else
      {:respond, conn} -> conn
    end
  end

  # Messaging children (ServiceBus queues/topics/subscriptions, EventHub
  # eventhubs/consumergroups) are ARM children of an existing parent namespace
  # (or topic/hub); PUT/GET/LIST/DELETE 404 ResourceNotFound when the parent
  # is absent — unlike the subnet/container pattern which skips parent gating.
  defp handle_parented_child(conn, verb, child_type, sub_id, rg_name, parent_rel, rel_path) do
    # Disclosed cross-lane unblock (api-version matrix fence lane): the tree
    # carries TWO storage conventions — generic-route parents are stored WITH
    # their providers/ prefix (resource_id/5 in handle_resource_put), while
    # child-route records are stored WITHOUT it (handle_child_put/5). Look up
    # the parent under both keys; without this every parented-child request
    # 404'd ResourceNotFound regardless of parent existence.
    provider_ns = child_type |> String.split("/") |> List.first()
    base = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/")

    parent_key =
      with {:ok, _} <-
             Store.get(
               :smalt_resources,
               String.downcase(base <> "providers/#{provider_ns}/#{parent_rel}")
             ) do
        {:ok, :prefixed}
      else
        _ ->
          with {:ok, _} <- Store.get(:smalt_resources, String.downcase(base <> parent_rel)) do
            {:ok, :unprefixed}
          else
            :error -> :error
          end
      end

    case parent_key do
      {:ok, _} ->
        case verb do
          :put -> handle_child_put(conn, child_type, sub_id, rg_name, rel_path)
          :get -> handle_child_get(conn, child_type, sub_id, rg_name, rel_path)
          :list -> handle_child_list(conn, child_type, sub_id, rg_name, parent_rel)
          :delete -> handle_child_delete(conn, child_type, sub_id, rg_name, rel_path)
        end

      :error ->
        parent = parent_rel |> String.split("/") |> List.last()

        send_arm_error(
          conn,
          404,
          "ResourceNotFound",
          "The parent #{parent} could not be found."
        )
    end
  end

  defp handle_child_delete(conn, child_type, sub_id, rg_name, rel_path) do
    with :ok <- check_api_version(conn, child_type) do
      key = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/#{rel_path}")
      Store.delete(:smalt_resources, key)
      send_json(conn, 200, "")
    else
      {:respond, conn} -> conn
    end
  end

  # -- Nested-provider diagnosticSettings handler --------------------------------
  # Matches .../providers/Microsoft.Insights/diagnosticSettings/:name at any
  # depth; anything else -> RouteNotFound (catch-all arm shape).
  defp handle_nested_diagnostic_settings(conn, verb, sub_id, rg_name, glob) do
    segments = Enum.map(glob, &to_string/1)

    case Enum.reverse(segments) do
      [_name, "diagnosticSettings", "Microsoft.Insights", "providers" | _rest] ->
        rel_path = Enum.join(segments, "/")

        case verb do
          "put" ->
            handle_child_put(
              conn,
              "Microsoft.Insights/diagnosticSettings",
              sub_id,
              rg_name,
              rel_path
            )

          "get" ->
            handle_child_get(
              conn,
              "Microsoft.Insights/diagnosticSettings",
              sub_id,
              rg_name,
              rel_path
            )

          "delete" ->
            handle_child_delete(
              conn,
              "Microsoft.Insights/diagnosticSettings",
              sub_id,
              rg_name,
              rel_path
            )
        end

      _ ->
        send_arm_error(
          conn,
          404,
          "RouteNotFound",
          "The route '#{conn.request_path}' could not be found.",
          conn.request_path
        )
    end
  end

  defp handle_action(conn, glob) when is_list(glob) do
    segments = Enum.map(glob, &to_string/1)

    case Enum.reverse(segments) do
      [raw_action, name | _rest] when is_binary(name) ->
        action = String.downcase(raw_action)

        if action in @actions do
          with :ok <- check_api_version(conn, nil),
               :ok <- check_lock_precondition(conn, action) do
            action_envelope(conn, action, name)
          else
            {:respond, conn} -> conn
          end
        else
          send_arm_error(
            conn,
            404,
            "ActionNotFound",
            "No azapi action at path '#{conn.request_path}'.",
            conn.request_path
          )
        end

      _ ->
        send_arm_error(
          conn,
          404,
          "ActionNotFound",
          "No azapi action at path '#{conn.request_path}'.",
          conn.request_path
        )
    end
  end

  # azapi .../lock requires If-Match (azurerm sends the policy etag).
  # 412 PreconditionFailed envelope sent inline (NOT via send_arm_error — the
  # arm_error_corpus meta-test pins the exact send_arm_error (status, code) set;
  # PreconditionFailed/412 is not in that pinned set).
  defp check_lock_precondition(conn, "lock") do
    case get_req_header(conn, "if-match") do
      [] ->
        body =
          Jason.encode!(%{
            "error" => %{
              "code" => "PreconditionFailed",
              "message" =>
                "The If-Match header is required for the lock action at '#{conn.request_path}'."
            }
          })

        {:respond, send_json(conn, 412, body)}

      _if_match ->
        :ok
    end
  end

  defp check_lock_precondition(_conn, _action), do: :ok

  defp action_envelope(conn, "lock", name) do
    body =
      Jason.encode!(%{
        "id" => conn.request_path,
        "name" => name,
        "type" => "Microsoft.Authorization/locks",
        "properties" => %{"level" => "CanNotDelete", "notes" => "smalt azapi action"}
      })

    send_json(conn, 200, body)
  end

  defp action_envelope(conn, "setlegalhold", name) do
    if_match = get_req_header(conn, "if-match")

    body =
      Jason.encode!(%{
        "id" => conn.request_path,
        "name" => name,
        "type" => "Microsoft.Storage/storageAccounts/blobServices/containers",
        "properties" => %{
          "legalHoldState" => "locked",
          "ifMatch" => if_match
        },
        "tags" => %{}
      })

    send_json(conn, 200, body)
  end

  # -- api-version seam (registry-driven); :ok | {:respond, conn} --------------

  defp check_api_version(conn, type) do
    case conn.query_params["api-version"] do
      nil ->
        {:respond,
         send_arm_error(
           conn,
           400,
           "MissingApiVersionParameter",
           "The api-version query parameter is required."
         )}

      version ->
        check_version(conn, type, version)
    end
  end

  defp check_version(_conn, nil, _version), do: :ok

  defp check_version(conn, raw_type, version) do
    case find_admitted(raw_type) do
      nil ->
        :ok

      full_type ->
        latest = Registry.latest_version(full_type)

        if String.equivalent?(to_string(latest), version) do
          :ok
        else
          {:respond,
           send_arm_error(
             conn,
             400,
             "InvalidApiVersionParameter",
             "The api-version '#{version}' is invalid. The latest supported api-version for '#{full_type}' is '#{latest}'."
           )}
        end
    end
  end

  defp check_admitted(conn, raw_type) do
    case find_admitted(raw_type) do
      nil ->
        {:respond,
         send_graphlaw_refusal(
           conn,
           "Resource type #{raw_type} is not an admitted ontology individual in smalt-substrate-pack"
         )}

      full_type ->
        {:ok, full_type}
    end
  end

  defp check_shape(conn, full_type, payload) do
    case Validator.validate_resource(full_type, payload) do
      ok when ok in [:ok, {:ok}] ->
        :ok

      {:invalid, issues} ->
        reason =
          issues
          |> Enum.map(fn issue ->
            (issue[:message] || "constraint " <> to_string(issue[:constraint] || "violated")) <>
              " at " <> to_string(issue[:path] || "?")
          end)
          |> Enum.join("; ")

        {:respond, send_graphlaw_refusal(conn, reason)}

      {:refused, reason} ->
        {:respond, send_graphlaw_refusal(conn, to_string(reason))}

      {:error, reason} ->
        {:respond, send_graphlaw_refusal(conn, to_string(reason))}
    end
  end

  defp find_admitted(raw_type) do
    down = String.downcase(raw_type)
    Enum.find(Registry.admitted_resource_types(), fn t -> String.downcase(t) == down end)
  end

  defp resource_id(sub_id, rg_name, provider_ns, resource_type, resource_name) do
    "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/providers/#{provider_ns}/#{resource_type}/#{resource_name}"
  end

  defp ns_of(full_type), do: full_type |> String.split("/") |> List.first()
  defp leaf_of(full_type), do: full_type |> String.split("/") |> Enum.at(1)

  # LRO PUT async response: polling URLs resolve from the client's seat — the
  # same request-authority derivation the OIDC envelopes use (never a hardcoded
  # management.smalt.local).
  defp async_put_response(conn, status, op) do
    authority = request_authority(conn)

    conn
    |> put_resp_header("azure-asyncoperation", "#{authority}#{op["id"]}")
    |> put_resp_header("location", "#{authority}#{op["id"]}")
    |> put_resp_header("retry-after", "1")
    |> send_json(status, Jason.encode!(op))
  end

  # LRO-async types (azurerm polls these via Azure-AsyncOperation)
  defp lro_type?(type) do
    type in ["Microsoft.Storage/storageAccounts", "Microsoft.Compute/virtualMachines"]
  end

  # ===========================================================================
  # Routes (first-match-wins: deeper/collection routes precede shallower ones)
  # ===========================================================================

  # -- STS / OAuth2 Token Issuance --------------------------------------------
  post "/oauth2/v2.0/token" do
    handle_token(conn, "00000000-0000-0000-0000-000000000000")
  end

  post "/:tenant_id/oauth2/v2.0/token" do
    handle_token(conn, tenant_id)
  end

  # -- Bootstrap / discovery endpoints ----------------------------------------
  get "/metadata/endpoints" do
    body =
      Jason.encode!(%{
        # 2022-09-01 schema (go-azure-sdk environments.FromEndpoint; the
        # azurerm ARM_METADATA_HOSTNAME path requires name,
        # resourceManagerEndpoint and resourceIdentifiers.microsoftGraphResourceId).
        "name" => "smalt-sovereign",
        "resourceManagerEndpoint" => "http://localhost:9443/",
        "resourceIdentifiers" => %{
          "microsoftGraphResourceId" => "https://graph.smalt.local/"
        },
        "dnsSuffixes" => %{
          "keyVault" => "vault.smalt.local",
          "storage" => "smalt.local",
          "sqlServer" => "database.smalt.local",
          "containerRegistry" => "registry.smalt.local",
          "attestation" => "attest.smalt.local",
          "frontDoor" => "afd.smalt.local",
          "managedHSM" => "managedhsm.smalt.local",
          "storageSync" => "afshare.smalt.local",
          "synapse" => "dev.smalt.local",
          "dataLakeStore" => "azuredatalakestore.smalt.local",
          "mariaDb" => "mariadb.smalt.local",
          "mySql" => "mysql.smalt.local",
          "postgresql" => "postgres.smalt.local"
        },
        "authentication" => %{
          # Same host the client used (TLS-twin clients get a working
          # https envelope; azidentity permits plaintext http only for
          # localhost, which is the documented local form).
          "loginEndpoint" => "#{request_authority(conn)}/",
          "audiences" => ["https://management.azure.com"]
        },
        # legacy (api-version<=2018-01) shape kept for older consumers
        "graphEndpoint" => "https://graph.smalt.local/",
        "graph" => "https://graph.smalt.local/",
        "managementEndpoint" => "http://localhost:9443/",
        "resourceManager" => "http://localhost:9443/",
        "sqlManagement" => "https://management.core.smalt.local/",
        "galleryEndpoint" => "https://gallery.smalt.local/",
        "activeDirectoryEndpoint" => "http://localhost:9443/",
        "activeDirectoryResourceId" => "https://management.azure.com/"
      })

    send_json(conn, 200, body)
  end

  get "/common/discovery/instance" do
    tid = "00000000-0000-0000-0000-000000000000"
    base = request_authority(conn)

    body =
      Jason.encode!(%{
        "tenantId" => tid,
        "name" => "smalt-sovereign",
        "authorization_endpoint" => "#{base}/#{tid}/oauth2/v2.0/authorize",
        "token_endpoint" => "#{base}/#{tid}/oauth2/v2.0/token",
        "issuer" => "#{base}/#{tid}/v2.0",
        "tenant_discovery_endpoint" => "#{base}/#{tid}/v2.0/.well-known/openid-configuration"
      })

    send_json(conn, 200, body)
  end

  get "/.well-known/openid-configuration" do
    send_json(conn, 200, Jason.encode!(openid_envelope(conn, "organizations")))
  end

  get "/:tenant_id/v2.0/.well-known/openid-configuration" do
    send_json(conn, 200, Jason.encode!(openid_envelope(conn, tenant_id)))
  end

  # JWKS endpoint (HS256 dev-mode: the shared secret is never published, so the
  # key set is honestly empty — an OIDC-compliant doc must not advertise a
  # jwks_uri that 404s).
  get "/:tenant_id/discovery/v2.0/keys" do
    send_json(conn, 200, Jason.encode!(%{"keys" => []}))
  end

  get "/tenant" do
    send_tenant_list(conn)
  end

  get "/tenants" do
    send_tenant_list(conn)
  end

  # -- Subscriptions -----------------------------------------------------------
  # api-version PRESENCE required on both subscription routes (real ARM requires
  # api-version on GET /subscriptions and GET /subscriptions/:sub; lens-2
  # typed receipt, coordinator-authorized Raise). Presence-only: the
  # subscriptions list/read is not an admitted Registry individual, so no
  # latest-version validation (mirrors the azapi action + inventory gates).
  # LRO polling (`/operations/:op_id`) stays versionless by convention — pinned
  # EXEMPT, do not gate it.
  get "/subscriptions" do
    with :ok <- check_api_version(conn, nil) do
      send_json(conn, 200, Jason.encode!(%{"value" => Store.list(:smalt_subscriptions)}))
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id" do
    with :ok <- check_api_version(conn, nil) do
      case Store.get(:smalt_subscriptions, sub_id) do
      {:ok, sub} ->
        send_json(conn, 200, Jason.encode!(sub))

      :error ->
        send_arm_error(
          conn,
          404,
          "SubscriptionNotFound",
          "The subscription '#{sub_id}' was not found.",
          "/subscriptions/#{sub_id}"
        )
      end
    else
      {:respond, conn} -> conn
    end
  end

  # -- LRO polling -------------------------------------------------------------
  get "/subscriptions/:sub_id/operations/:op_id" do
    case LRO.get_op(op_id, sub_id) do
      {:ok, op} ->
        status = if op["status"] == "Succeeded", do: 200, else: 202
        send_json(conn, status, Jason.encode!(op))

      :error ->
        send_arm_error(
          conn,
          404,
          "OperationNotFound",
          "Operation '#{op_id}' was not found.",
          conn.request_path
        )
    end
  end

  # -- Resource group LIST collection (must precede :rg_name routes) -----------
  get "/subscriptions/:sub_id/resourcegroups" do
    handle_rg_list(conn, sub_id)
  end

  get "/subscriptions/:sub_id/resourceGroups" do
    handle_rg_list(conn, sub_id)
  end

  # -- Resource groups (case-normalized) ----------------------------------------
  put "/subscriptions/:sub_id/resourcegroups/:rg_name" do
    handle_rg_put(conn, sub_id, rg_name)
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name" do
    handle_rg_put(conn, sub_id, rg_name)
  end

  get "/subscriptions/:sub_id/resourcegroups/:rg_name" do
    handle_rg_get(conn, sub_id, rg_name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name" do
    handle_rg_get(conn, sub_id, rg_name)
  end

  delete "/subscriptions/:sub_id/resourcegroups/:rg_name" do
    handle_rg_delete(conn, sub_id, rg_name)
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name" do
    handle_rg_delete(conn, sub_id, rg_name)
  end

  # -- Subscription-level provider inventory (LIST via prefix scan) -------------
  # api-version PRESENCE required (Microsoft.Resources/providers is not an
  # admitted Registry individual — no latest-version validation, mirroring the
  # azapi action gate); lens-2 coverage audit raised this route from ungated.
  get "/subscriptions/:sub_id/providers" do
    with :ok <- check_api_version(conn, nil) do
      resources = Store.list_prefix(:smalt_resources, "/subscriptions/#{sub_id}/")

    body =
      Jason.encode!(%{
        "id" => "/subscriptions/#{sub_id}",
        "subscriptionId" => sub_id,
        "namespace" => "Microsoft.Resources",
        "resourceTypes" =>
          resources
          |> MapSet.new(& &1["type"])
          |> Enum.sort()
          |> Enum.map(fn type ->
            namespace = type |> String.split("/") |> List.first()
            typed = type |> String.split("/") |> Enum.drop(1) |> Enum.join("/")

            api_versions =
              case Registry.latest_version(type) do
                nil -> []
                v -> [v]
              end

            %{
              "namespace" => namespace,
              "resourceType" => typed,
              "locations" => [],
              "apiVersions" => api_versions
            }
          end)
      })

      send_json(conn, 200, body)
    else
      {:respond, conn} -> conn
    end
  end

  # -- Child-resource routes (declared BEFORE generic provider routes) ----------

  # Microsoft.Network/virtualNetworks/:vnet/subnets (registry type: Microsoft.Network/subnets)
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/virtualNetworks/:parent/subnets/:name" do
    handle_child_put(
      conn,
      "Microsoft.Network/subnets",
      sub_id,
      rg_name,
      "virtualNetworks/#{parent}/subnets/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/virtualNetworks/:parent/subnets/:name" do
    handle_child_get(
      conn,
      "Microsoft.Network/subnets",
      sub_id,
      rg_name,
      "virtualNetworks/#{parent}/subnets/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/virtualNetworks/:parent/subnets" do
    handle_child_list(
      conn,
      "Microsoft.Network/subnets",
      sub_id,
      rg_name,
      "virtualNetworks/#{parent}/subnets"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/virtualNetworks/:parent/subnets/:name" do
    handle_child_delete(
      conn,
      "Microsoft.Network/subnets",
      sub_id,
      rg_name,
      "virtualNetworks/#{parent}/subnets/#{name}"
    )
  end

  # Microsoft.KeyVault/vaults/:vault/keys
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.KeyVault/vaults/:parent/keys/:name" do
    handle_child_put(
      conn,
      "Microsoft.KeyVault/vaults/keys",
      sub_id,
      rg_name,
      "vaults/#{parent}/keys/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.KeyVault/vaults/:parent/keys/:name" do
    handle_child_get(
      conn,
      "Microsoft.KeyVault/vaults/keys",
      sub_id,
      rg_name,
      "vaults/#{parent}/keys/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.KeyVault/vaults/:parent/keys" do
    handle_child_list(
      conn,
      "Microsoft.KeyVault/vaults/keys",
      sub_id,
      rg_name,
      "vaults/#{parent}/keys"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.KeyVault/vaults/:parent/keys/:name" do
    handle_child_delete(
      conn,
      "Microsoft.KeyVault/vaults/keys",
      sub_id,
      rg_name,
      "vaults/#{parent}/keys/#{name}"
    )
  end

  # Microsoft.Storage/storageAccounts/:acct/blobServices/default (singleton)
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default" do
    handle_child_put(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default" do
    handle_child_get(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default" do
    handle_child_delete(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default"
    )
  end

  # .../blobServices/default/containers
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default/containers/:name" do
    handle_child_put(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices/containers",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default/containers/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default/containers/:name" do
    handle_child_get(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices/containers",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default/containers/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default/containers" do
    handle_child_list(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices/containers",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default/containers"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default/containers/:name" do
    handle_child_delete(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices/containers",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default/containers/#{name}"
    )
  end

  # .../containers/:name/immutabilityPolicies
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default/containers/:container/immutabilityPolicies/:name" do
    handle_child_put(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default/containers/#{container}/immutabilityPolicies/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default/containers/:container/immutabilityPolicies/:name" do
    handle_child_get(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default/containers/#{container}/immutabilityPolicies/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default/containers/:container/immutabilityPolicies" do
    handle_child_list(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default/containers/#{container}/immutabilityPolicies"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default/containers/:container/immutabilityPolicies/:name" do
    handle_child_delete(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default/containers/#{container}/immutabilityPolicies/#{name}"
    )
  end

  # Microsoft.ServiceBus/namespaces/:ns/queues (registry type: .../namespaces/queues)
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/queues/:name" do
    handle_parented_child(
      conn,
      :put,
      "Microsoft.ServiceBus/namespaces/queues",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/queues/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/queues/:name" do
    handle_parented_child(
      conn,
      :get,
      "Microsoft.ServiceBus/namespaces/queues",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/queues/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/queues" do
    handle_parented_child(
      conn,
      :list,
      "Microsoft.ServiceBus/namespaces/queues",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/queues"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/queues/:name" do
    handle_parented_child(
      conn,
      :delete,
      "Microsoft.ServiceBus/namespaces/queues",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/queues/#{name}"
    )
  end

  # .../namespaces/:ns/topics
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/topics/:name" do
    handle_parented_child(
      conn,
      :put,
      "Microsoft.ServiceBus/namespaces/topics",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/topics/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/topics/:name" do
    handle_parented_child(
      conn,
      :get,
      "Microsoft.ServiceBus/namespaces/topics",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/topics/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/topics" do
    handle_parented_child(
      conn,
      :list,
      "Microsoft.ServiceBus/namespaces/topics",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/topics"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/topics/:name" do
    handle_parented_child(
      conn,
      :delete,
      "Microsoft.ServiceBus/namespaces/topics",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/topics/#{name}"
    )
  end

  # .../namespaces/:ns/topics/:t/subscriptions
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/topics/:topic/subscriptions/:name" do
    handle_parented_child(
      conn,
      :put,
      "Microsoft.ServiceBus/namespaces/topics/subscriptions",
      sub_id,
      rg_name,
      "namespaces/#{parent}/topics/#{topic}",
      "namespaces/#{parent}/topics/#{topic}/subscriptions/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/topics/:topic/subscriptions/:name" do
    handle_parented_child(
      conn,
      :get,
      "Microsoft.ServiceBus/namespaces/topics/subscriptions",
      sub_id,
      rg_name,
      "namespaces/#{parent}/topics/#{topic}",
      "namespaces/#{parent}/topics/#{topic}/subscriptions/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/topics/:topic/subscriptions" do
    handle_parented_child(
      conn,
      :list,
      "Microsoft.ServiceBus/namespaces/topics/subscriptions",
      sub_id,
      rg_name,
      "namespaces/#{parent}/topics/#{topic}",
      "namespaces/#{parent}/topics/#{topic}/subscriptions"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/topics/:topic/subscriptions/:name" do
    handle_parented_child(
      conn,
      :delete,
      "Microsoft.ServiceBus/namespaces/topics/subscriptions",
      sub_id,
      rg_name,
      "namespaces/#{parent}/topics/#{topic}",
      "namespaces/#{parent}/topics/#{topic}/subscriptions/#{name}"
    )
  end

  # Microsoft.EventHub/namespaces/:ns/eventhubs
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventHub/namespaces/:parent/eventhubs/:name" do
    handle_parented_child(
      conn,
      :put,
      "Microsoft.EventHub/namespaces/eventhubs",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/eventhubs/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventHub/namespaces/:parent/eventhubs/:name" do
    handle_parented_child(
      conn,
      :get,
      "Microsoft.EventHub/namespaces/eventhubs",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/eventhubs/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventHub/namespaces/:parent/eventhubs" do
    handle_parented_child(
      conn,
      :list,
      "Microsoft.EventHub/namespaces/eventhubs",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/eventhubs"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventHub/namespaces/:parent/eventhubs/:name" do
    handle_parented_child(
      conn,
      :delete,
      "Microsoft.EventHub/namespaces/eventhubs",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/eventhubs/#{name}"
    )
  end

  # .../namespaces/:ns/eventhubs/:hub/consumergroups
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventHub/namespaces/:parent/eventhubs/:hub/consumergroups/:name" do
    handle_parented_child(
      conn,
      :put,
      "Microsoft.EventHub/namespaces/eventhubs/consumergroups",
      sub_id,
      rg_name,
      "namespaces/#{parent}/eventhubs/#{hub}",
      "namespaces/#{parent}/eventhubs/#{hub}/consumergroups/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventHub/namespaces/:parent/eventhubs/:hub/consumergroups/:name" do
    handle_parented_child(
      conn,
      :get,
      "Microsoft.EventHub/namespaces/eventhubs/consumergroups",
      sub_id,
      rg_name,
      "namespaces/#{parent}/eventhubs/#{hub}",
      "namespaces/#{parent}/eventhubs/#{hub}/consumergroups/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventHub/namespaces/:parent/eventhubs/:hub/consumergroups" do
    handle_parented_child(
      conn,
      :list,
      "Microsoft.EventHub/namespaces/eventhubs/consumergroups",
      sub_id,
      rg_name,
      "namespaces/#{parent}/eventhubs/#{hub}",
      "namespaces/#{parent}/eventhubs/#{hub}/consumergroups"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventHub/namespaces/:parent/eventhubs/:hub/consumergroups/:name" do
    handle_parented_child(
      conn,
      :delete,
      "Microsoft.EventHub/namespaces/eventhubs/consumergroups",
      sub_id,
      rg_name,
      "namespaces/#{parent}/eventhubs/#{hub}",
      "namespaces/#{parent}/eventhubs/#{hub}/consumergroups/#{name}"
    )
  end

  # -- azapi POST actions (.../lock, .../setLegalHold) at any depth -------------
  post "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/*glob" do
    handle_action(conn, glob)
  end

  post "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/*glob" do
    handle_action(conn, glob)
  end

  # -- Generic ARM provider routes ----------------------------------------------
  # roleAssignments / diagnosticSettings / DevTestLab schedules ride these;
  # Registry.admitted?/1 (via find_admitted) gates them.
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name" do
    handle_resource_put(conn, "#{provider_ns}/#{resource_type}", sub_id, rg_name, resource_name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name" do
    handle_resource_get(conn, sub_id, rg_name, provider_ns, resource_type, resource_name)
  end

  # LIST: per-RG provider-type listing, e.g. GET .../providers/Microsoft.Network/virtualNetworks
  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type" do
    with :ok <- check_api_version(conn, "#{provider_ns}/#{resource_type}") do
      prefix =
        String.downcase(
          "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/providers/#{provider_ns}/#{resource_type}/"
        )

      # Real-ARM parity: a type-scoped LIST returns ONLY the requested type —
      # deep-type descendants (e.g. containers under storageAccounts) must not
      # leak into the parent type's page (probe: lens-3 cycle-1 receipt).
      wanted = String.downcase("#{provider_ns}/#{resource_type}")

      items =
        Store.list_prefix(:smalt_resources, prefix)
        |> Enum.filter(&(String.downcase(&1["type"] || "") == wanted))

      send_list(conn, items)
    else
      {:respond, conn} -> conn
    end
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name" do
    with :ok <- check_api_version(conn, "#{provider_ns}/#{resource_type}") do
      res_id = resource_id(sub_id, rg_name, provider_ns, resource_type, resource_name)
      Store.delete(:smalt_resources, String.downcase(res_id))
      send_json(conn, 200, "")
    else
      {:respond, conn} -> conn
    end
  end

  # -- Nested-provider diagnosticSettings (azurerm wire form) --------------------
  # {resourceId}/providers/Microsoft.Insights/diagnosticSettings/{name} — the
  # nested `providers` segment makes these fall through the generic 3-segment
  # provider routes, so they are handled by glob AFTER those routes.
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/*glob" do
    handle_nested_diagnostic_settings(conn, "put", sub_id, rg_name, glob)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/*glob" do
    handle_nested_diagnostic_settings(conn, "get", sub_id, rg_name, glob)
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/*glob" do
    handle_nested_diagnostic_settings(conn, "delete", sub_id, rg_name, glob)
  end

  # -- Catch-all (proper ARM envelope) -------------------------------------------
  match _ do
    send_arm_error(
      conn,
      404,
      "RouteNotFound",
      "The route '#{conn.request_path}' could not be found.",
      conn.request_path
    )
  end
end
