defmodule PopcornDemo.LiveAppConfig do
  @moduledoc """
  App Configuration + feature-flag full-lifecycle walk (leg X5, KD-109 face):
  bearer via the KD-15 challenge handshake, PUT a kv (`.appconfig.key/{name}`),
  GET byte-equal, PUT a feature flag (`.appconfig.featureflag/{name}` with the
  enabled/conditions envelope per `Smalt.DataPlane.AppConfigFeatures`), GET the
  flag envelope back, LIST both under the `.appconfig.*` glob, DELETE both
  (If-Match, per the real-service delete contract), and assert 404 KvNotFound
  on re-GET.

  REST faces verified with curl against the LIVE substrate BEFORE this module
  existed (2026-10-20, leg X5):

  - Tokenless GET /kv/:key -> 401 with `www-authenticate:
    Bearer authorization="http://127.0.0.1:9443/organizations"
    resource="http://127.0.0.1:8443"`; the walk mints the bearer at the STS
    named by that header's `authorization=` authority and resends.
  - PUT /kv/.appconfig.key%2F{name} body {"value","contentType"} -> 201 with a
    quoted sha256 etag; the %2F-encoded slash inside the key survives Plug's
    path-param decode (verified: GET by the same encoded path returns the row).
  - PUT /kv/.appconfig.featureflag%2F{name} body
    {"value":{"enabled":true,"conditions":{"client_filters":[...]}}} -> 201,
    contentType pinned `application/vnd.microsoft.appconfig.ff+json;charset=utf-8`,
    value stored as the canonical flag JSON string. An invalid body
    ({"enabled":"yes"}) is a typed 400 InvalidFeatureFlag, never a silent store
    (the KD-109 typed-face pinion).
  - DELETE /kv/:key WITHOUT If-Match -> 409 MissingIfMatch (real-service
    contract, the wire face differs from PUT where absence imposes no
    precondition). With the row's etag -> 204.
  - Re-GET after delete -> 404 {"error":{"code":"KvNotFound"}}.

  Transport: same single calculus as `PopcornDemo.LiveKV` — all HTTP rides
  `PopcornDemo.Transport` (host: `Transport.Httpc`), raw binary bodies decoded
  best-effort at THIS module's edge.
  """

  @base "http://127.0.0.1:8443"
  @api_version "1.0"
  @kv_prefix ".appconfig.key/"
  @flag_prefix ".appconfig.featureflag/"

  defp run_name, do: Process.get({__MODULE__, :resname}) || name()
  defp name, do: "popcorn-ac-" <> Integer.to_string(:erlang.unique_integer([:positive]))

  @doc """
  Runs the walk. Returns:

  - `{:ok, "appconfig=OK(<name>:kv+flag-lifecycle)"}`
  - `{:skip, "appconfig=SKIP(<loud reason>)"}`
  - `{:error, "appconfig=FAIL(<step>:<reason>)"}`
  """
  def run do
    Process.put({__MODULE__, :resname}, name())
    with {:ok, _} <- health(),
         {:ok, token} <- challenge_token() do
      value = value()

      with :ok <- put_kv(token, value),
           :ok <- get_kv_equal(token, value),
           :ok <- put_flag(token),
           :ok <- get_flag_envelope(token),
           :ok <- list_both(token),
           :ok <- delete_both(token),
           :ok <- reget_404(token) do
        {:ok, "appconfig=OK(#{run_name()}:kv+flag-lifecycle)"}
      end
    else
      {:error, {step, reason}} when is_binary(step) ->
        # Same classifier as PopcornDemo.Live (BK-TESTBED-F1 close): a refused/
        # blocked loopback hop means the substrate is not listening — a loud
        # SKIP, never a FAIL. Anything else is a real step fault.
        if reason =~ ~r/econnrefused|failed to fetch/i do
          {:skip, "appconfig=SKIP(substrate-down:#{step}:#{fmt(reason)})"}
        else
          {:error, "appconfig=FAIL(#{step}:#{fmt(reason)})"}
        end
    end
  end

  # -- KD-15 challenge handshake (corpus premise pin, repo convention) -------

  # Send tokenless, take the 401 + WWW-Authenticate, resend with the bearer.
  defp challenge_token do
    req = %{method: "GET", url: kv_url(@kv_prefix <> run_name()), headers: [], body: nil}

    case request(req) do
      {:ok, %{status: 401, headers: headers}} ->
        with {:ok, authority} <- www_authenticate_authority(headers),
             {:ok, token} <- sts_token(authority) do
          {:ok, token}
        end

      {:ok, %{status: st, body: body}} ->
        {:error, {"challenge", "expected-401-got-http-#{st}:#{slice(body)}"}}

      {:error, reason} ->
        {:error, {"challenge", fmt(reason)}}
    end
  end

  defp www_authenticate_authority(headers) do
    case List.keyfind(headers, "www-authenticate", 0) do
      nil ->
        {:error, {"challenge", "401-without-www-authenticate-header"}}

      {_, value} ->
        case Regex.run(~r/authorization="([^"]+)"/i, value) do
          [_, authority] -> {:ok, authority}
          nil -> {:error, {"challenge", "www-authenticate-missing-authorization:#{slice(value)}"}}
        end
    end
  end

  defp sts_token(authority) do
    req = %{
      method: "POST",
      url: authority <> "/oauth2/v2.0/token",
      headers: [{"content-type", "application/x-www-form-urlencoded"}],
      body: "grant_type=client_credentials&client_id=popcorn-demo&client_secret=not-checked"
    }

    case request(req) do
      {:ok, %{status: 200, body: body}} ->
        case body do
          %{"access_token" => tok} when is_binary(tok) -> {:ok, tok}
          _ -> {:error, {"token", "no-access_token-in-sts-body"}}
        end

      {:ok, %{status: st, body: body}} ->
        {:error, {"token", "http-#{st}:#{slice(body)}"}}

      {:error, reason} ->
        {:error, {"token", fmt(reason)}}
    end
  end

  # -- lifecycle steps -------------------------------------------------------

  defp put_kv(token, value) do
    req = %{
      method: "PUT",
      url: kv_url(@kv_prefix <> run_name()),
      headers: auth_headers(token) ++ [{"content-type", "application/json"}],
      body: Jason.encode!(%{"value" => value, "contentType" => "text/plain"})
    }

    with {:ok, %{body: %{"key" => key, "value" => ^value}}} <-
           step_req("put-kv", req, [200, 201]) do
      assert_key(key, @kv_prefix, "put-kv")
    end
  end

  defp get_kv_equal(token, value) do
    req = %{method: "GET", url: kv_url(@kv_prefix <> run_name()), headers: auth_headers(token), body: nil}

    with {:ok, %{body: %{"value" => got, "etag" => etag}}} <-
           step_req("get-kv", req, [200]) do
      if got == value do
        Process.put({__MODULE__, :kv_etag}, etag)
        :ok
      else
        {:error, {"get-kv", "byte-mismatch(put=#{byte_size(value)},got=#{byte_size(got || "")})"}}
      end
    end
  end

  # The typed flag face (KD-109): an invalid envelope is a typed 400, asserted
  # BEFORE the happy-path write so the walk proves the refusal, not just the
  # store.
  defp put_flag(token) do
    bad = %{
      method: "PUT",
      url: flag_url(),
      headers: auth_headers(token) ++ [{"content-type", "application/json"}],
      body: Jason.encode!(%{"value" => %{"enabled" => "yes"}})
    }

    case step_req("put-flag-invalid", bad, [400]) do
      {:ok, %{body: %{"error" => %{"code" => "InvalidFeatureFlag"}}}} ->
        put_flag_ok(token)

      {:ok, %{status: st, body: body}} ->
        {:error, {"put-flag-invalid", "expected-400-InvalidFeatureFlag-got-http-#{st}:#{slice(body)}"}}

      err ->
        err
    end
  end

  defp put_flag_ok(token) do
    req = %{
      method: "PUT",
      url: flag_url(),
      headers: auth_headers(token) ++ [{"content-type", "application/json"}],
      body:
        Jason.encode!(%{
          "value" => %{
            "enabled" => true,
            "conditions" => %{
              "client_filters" => [
                %{"name" => "TimeWindowFilter", "parameters" => %{"From" => "2020-01-01T00:00:00Z"}}
              ]
            }
          }
        })
    }

    with {:ok, %{body: %{"key" => key, "contentType" => ct}}} <-
           step_req("put-flag", req, [200, 201]) do
      with :ok <- assert_key(key, @flag_prefix, "put-flag") do
        if ct == "application/vnd.microsoft.appconfig.ff+json;charset=utf-8" do
          :ok
        else
          {:error, {"put-flag", "wrong-content-type:#{inspect(ct)}"}}
        end
      end
    end
  end

  defp get_flag_envelope(token) do
    req = %{method: "GET", url: flag_url(), headers: auth_headers(token), body: nil}

    with {:ok, %{body: %{"value" => raw, "etag" => etag}}} <- step_req("get-flag", req, [200]) do
      case Jason.decode(raw) do
        {:ok, flag} ->
          cond do
            flag["enabled"] != true ->
              {:error, {"get-flag", "enabled-not-true:#{slice(raw)}"}}

            flag_filters(flag) != [
              %{"name" => "TimeWindowFilter", "parameters" => %{"From" => "2020-01-01T00:00:00Z"}}
            ] ->
              {:error, {"get-flag", "client_filters-not-roundtripped:#{slice(raw)}"}}

            true ->
              Process.put({__MODULE__, :flag_etag}, etag)
              :ok
          end

        {:error, reason} ->
          {:error, {"get-flag", "invalid-flag-json:#{fmt(reason)}"}}
      end
    end
  end

  defp flag_filters(flag), do: get_in(flag, ["conditions", "client_filters"]) || []

  # Both rows must appear under the .appconfig.* glob, key-sorted
  # (flag before kv: ".appconfig.featureflag/" < ".appconfig.key/").
  defp list_both(token) do
    req = %{
      method: "GET",
      url: @base <> "/kv?key=" <> URI.encode_www_form(".appconfig.*"),
      headers: auth_headers(token),
      body: nil
    }

    with {:ok, %{body: %{"items" => items}}} <- step_req("list", req, [200]) do
      keys = Enum.map(items, & &1["key"])
      mine = Enum.filter(keys, &String.contains?(&1, run_name()))

      cond do
        keys != Enum.sort(keys) ->
          {:error, {"list", "items-not-key-sorted"}}

        @flag_prefix <> run_name() not in mine ->
          {:error, {"list", "flag-row-missing-from-list:#{slice(inspect(keys))}"}}

        @kv_prefix <> run_name() not in mine ->
          {:error, {"list", "kv-row-missing-from-list:#{slice(inspect(keys))}"}}

        true ->
          :ok
      end
    end
  end

  # Real-service delete contract: no If-Match -> 409 MissingIfMatch; with the
  # row's etag -> 204.
  defp delete_both(token) do
    with :ok <- delete_row(token, @kv_prefix, Process.get({__MODULE__, :kv_etag}), "delete-kv"),
         :ok <- delete_row(token, @flag_prefix, Process.get({__MODULE__, :flag_etag}), "delete-flag") do
      :ok
    end
  end

  defp delete_row(token, prefix, etag, step) do
    no_if = %{method: "DELETE", url: row_url(prefix), headers: auth_headers(token), body: nil}

    case step_req("#{step}-no-if-match", no_if, [409]) do
      # The 409 delete face rides blob_error: FLAT %{"code","message"} body,
      # not the nested %{"error"=>%{"code"}} shape send_json produces.
      {:ok, %{body: %{"code" => "MissingIfMatch"}}} ->
        req = %{
          method: "DELETE",
          url: row_url(prefix),
          headers: auth_headers(token) ++ [{"if-match", etag}],
          body: nil
        }

        case step_req(step, req, [204]) do
          {:ok, _} -> :ok
          err -> err
        end

      {:ok, %{status: st, body: body}} ->
        {:error, {"#{step}-no-if-match", "expected-409-MissingIfMatch-got-http-#{st}:#{slice(body)}"}}

      err ->
        err
    end
  end

  defp reget_404(token) do
    with :ok <- reget_row(token, @kv_prefix, "reget-kv"),
         :ok <- reget_row(token, @flag_prefix, "reget-flag") do
      :ok
    end
  end

  defp reget_row(token, prefix, step) do
    req = %{method: "GET", url: row_url(prefix), headers: auth_headers(token), body: nil}

    case step_req(step, req, [404]) do
      {:ok, %{body: %{"error" => %{"code" => "KvNotFound"}}}} ->
        :ok

      {:ok, %{status: st, body: body}} ->
        {:error, {step, "http-#{st}-but-not-KvNotFound:#{slice(body)}"}}

      err ->
        err
    end
  end

  # -- urls / shared helpers -------------------------------------------------

  defp kv_url(prefix) do
    @base <> "/kv/" <> URI.encode(prefix, &URI.char_unreserved?/1) <> "?api-version=#{@api_version}"
  end

  defp flag_url, do: kv_url(@flag_prefix <> run_name())
  defp row_url(prefix), do: kv_url(prefix <> run_name())

  defp assert_key(key, prefix, step) do
    if key == prefix <> run_name() do
      :ok
    else
      {:error, {step, "unexpected-key:#{inspect(key)}"}}
    end
  end

  defp value, do: "popcorn-ac-#{System.system_time(:nanosecond)}"

  defp auth_headers(token), do: [{"authorization", "Bearer " <> token}]

  defp step_req(step, req, want) when is_list(want) do
    case request(req) do
      {:ok, %{status: st} = resp} ->
        if st in want do
          {:ok, resp}
        else
          {:error, {step, "http-#{st}-want-#{Enum.join(want, "|")}:#{slice(resp.body)}"}}
        end

      {:error, reason} ->
        {:error, {step, fmt(reason)}}
    end
  end

  defp health do
    case request(%{method: "GET", url: @base <> "/healthz", headers: [], body: nil}) do
      {:ok, %{status: 200}} -> {:ok, :ready}
      {:ok, %{status: st}} -> {:error, {"health", "http-#{st}"}}
      {:error, reason} -> {:error, {"health", fmt(reason)}}
    end
  end

  defp fmt(reason) when is_binary(reason), do: reason
  defp fmt(reason), do: inspect(reason)

  defp slice(bin) when is_binary(bin) do
    if byte_size(bin) > 160, do: binary_part(bin, 0, 160) <> "...", else: bin
  end

  defp slice(other), do: inspect(other)

  # -- transport dispatch (single calculus, mirrors PopcornDemo.LiveKV) ------

  defp browser? do
    Code.ensure_loaded?(Popcorn.JS) and function_exported?(Popcorn.JS, :available?, 0) and
      Popcorn.JS.available?()
  end

  defp request(%{method: method, url: url, headers: headers, body: body}) do
    request = %{method: method, url: url, headers: headers, body: body}

    if browser?() do
      request |> PopcornDemo.Transport.Fetch.request() |> decode_body()
    else
      request |> PopcornDemo.Transport.Httpc.request() |> decode_body()
    end
  end

  defp decode_body({:ok, %{body: body} = resp}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, %{resp | body: decoded}}
      _ -> {:ok, resp}
    end
  end

  defp decode_body(other), do: other
end
