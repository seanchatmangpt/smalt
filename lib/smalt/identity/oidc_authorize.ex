defmodule Smalt.Identity.OidcAuthorize do
  @moduledoc """
  T05 lane L18: the `/authorize` + consent leg of the Entra-shaped OIDC IdP,
  plus the rotating refresh-token store and its reuse-detection law.

  Mounted inside the existing `Smalt.Identity.OidcIdp` Bandit router as two
  disclosed one-line delegations (an issuer is one origin — discovery,
  token and authorize on one port; a second listener would not be
  Entra-shaped). See r-t05a + r-t05b:

      get  "/:tenant/authorize", do: Smalt.Identity.OidcAuthorize.get_authorize(conn)
      post "/:tenant/authorize", do: Smalt.Identity.OidcAuthorize.post_consent(conn)

  Flow (T02 auto-submit-form pattern, auto-approve consent):

    - `GET /{tenant}/authorize` — validates the authorization request, then
      serves 200 HTML auto-submit consent form. Hidden inputs carry the full
      request; `onload` submits it; `<noscript>` keeps it usable without JS.
    - `POST /{tenant}/authorize` — re-validates, mints the code through
      `Smalt.Identity.OidcCodeStore.insert/2` (challenge + method +
      client_id + redirect_uri + nonce + sub bound into the record) and
      302s to the client redirect_uri with `code` + `state`.

  Redirect URI law (T02 `validate_acs/1` precedent): the redirect_uri must
  be an http(s) URL on a loopback host or an exact member of the `:oidc_idp`
  / `:allowed_redirect_uris` config allowlist; otherwise a typed 400 — the
  IdP never 302s a code to an arbitrary destination.

  Refresh tokens: rotating, shadow-ETS stored (`:smalt_oidc_refresh_tokens`,
  same lazy `:global.trans` + heir-to-init law as `OidcCodeStore`). Rotation
  is an atomic false→true consume flip (`:ets.select_replace`); presenting a
  consumed token is reuse and revokes the whole token family
  (`:ets.select_delete` by family id).
  """

  # ------------------------------------------------------------------
  # Authorize + consent leg (conn handlers delegated from OidcIdp)
  # ------------------------------------------------------------------

  @doc "GET /{tenant}/authorize — validate the authorization request, then render the auto-approve consent form."
  def get_authorize(conn) do
    params = conn.query_params

    case validate_authorize(params) do
      :ok ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html; charset=utf-8")
        |> Plug.Conn.send_resp(200, consent_form(tenant_of(conn), params))

      {:error, reason} ->
        send_json_error(conn, reason)
    end
  end

  @doc """
  POST /{tenant}/authorize — the consent form target. Validates the request
  a second time, mints the authorization code, 302s to the client.
  """
  def post_consent(conn) do
    params = conn.body_params
    tenant = tenant_of(conn)

    with :ok <- validate_authorize(params),
         {:ok, code} <- mint_code(tenant, params) do
      conn
      |> Plug.Conn.put_resp_header("location", redirect_location(params, code))
      |> Plug.Conn.send_resp(302, "")
    else
      {:error, reason} -> send_json_error(conn, reason)
    end
  end

  # ------------------------------------------------------------------
  # Validation law (public for court use, per the T02 validate_acs pattern)
  # Errors are `{:error, {status, code, desc}}` tuples feeding typed JSON
  # refusals.
  # ------------------------------------------------------------------

  @doc """
  Full authorization-request validation. `:ok` or
  `{:error, {status, error_code, description}}`.
  """
  def validate_authorize(params) when is_map(params) do
    with :ok <- require_client_id(params),
         :ok <- validate_redirect_uri(params["redirect_uri"]),
         :ok <- require_response_type_code(params),
         :ok <- require_pkce(params) do
      require_scope(params)
    end
  end

  @doc """
  Redirect URI law (T02 `validate_acs/1` precedent): the redirect_uri must
  be an http(s) URL on a loopback host or an exact member of the `:oidc_idp`
  / `:allowed_redirect_uris` config allowlist; otherwise a typed refusal —
  the IdP never 302s a code to an arbitrary destination.
  """
  def validate_redirect_uri(uri) do
    cond do
      not is_binary(uri) or uri == "" ->
        {:error, {400, "invalid_request", "redirect_uri required"}}

      uri in allowed_redirect_uris() ->
        :ok

      true ->
        case URI.new(uri) do
          {:ok, %URI{scheme: scheme, host: host}}
          when scheme in ["http", "https"] and is_binary(host) ->
            if loopback_host?(host),
              do: :ok,
              else:
                {:error,
                 {400, "invalid_request", "redirect_uri not allowed (loopback or allowlisted only)"}}

          _ ->
            {:error,
             {400, "invalid_request", "redirect_uri not allowed (loopback or allowlisted only)"}}
        end
    end
  end

  defp require_client_id(params) do
    case params["client_id"] do
      v when is_binary(v) and v != "" -> :ok
      _ -> {:error, {400, "invalid_request", "client_id required"}}
    end
  end

  defp require_response_type_code(params) do
    case params["response_type"] do
      "code" -> :ok
      _ -> {:error, {400, "unsupported_response_type", "only response_type=code is supported"}}
    end
  end

  defp require_pkce(params) do
    with :ok <- require_challenge(params),
         :ok <- check_challenge_method(params["code_challenge_method"]) do
      :ok
    end
  end

  defp require_challenge(params) do
    case params["code_challenge"] do
      v when is_binary(v) and v != "" -> :ok
      _ -> {:error, {400, "invalid_request", "code_challenge required (PKCE)"}}
    end
  end

  defp check_challenge_method(nil), do: :ok

  defp check_challenge_method(method) when method in ["S256", "plain"] do
    :ok
  end

  defp check_challenge_method(_) do
    {:error, {400, "invalid_request", "code_challenge_method must be S256 or plain"}}
  end

  defp require_scope(params) do
    case params["scope"] do
      scope when is_binary(scope) ->
        if "openid" in String.split(scope, " "),
          do: :ok,
          else: {:error, {400, "invalid_scope", "scope must include openid"}}

      _ ->
        :ok
    end
  end

  defp allowed_redirect_uris do
    case Application.get_env(:smalt, :oidc_idp, []) do
      kw when is_list(kw) -> Keyword.get(kw, :allowed_redirect_uris, [])
      _ -> []
    end
  end

  defp loopback_host?(host) do
    host in ["localhost", "::1", "[::1]"] or String.starts_with?(host, "127.")
  end

  # ------------------------------------------------------------------
  # Code minting
  # ------------------------------------------------------------------

  defp mint_code(tenant, params) do
    code = "l18-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    :ok =
      Smalt.Identity.OidcCodeStore.insert(code, %{
        "client_id" => params["client_id"],
        "redirect_uri" => params["redirect_uri"],
        "code_challenge" => params["code_challenge"],
        "code_challenge_method" => params["code_challenge_method"] || "plain",
        "sub" => consent_subject(),
        "tenant" => tenant,
        "nonce" => params["nonce"]
      })

    {:ok, code}
  end

  defp consent_subject do
    case Application.get_env(:smalt, :oidc_idp, []) do
      kw when is_list(kw) -> Keyword.get(kw, :subject, "smalt-user")
      _ -> "smalt-user"
    end
  end

  defp redirect_location(params, code) do
    uri = URI.parse(params["redirect_uri"])

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.merge(%{"code" => code})
      |> Map.merge(state_param(params))

    URI.to_string(%{uri | query: URI.encode_query(query)})
  end

  defp state_param(params) do
    case params["state"] do
      state when is_binary(state) and state != "" -> %{"state" => state}
      _ -> %{}
    end
  end

  # ------------------------------------------------------------------
  # Consent form (T02 auto-submit pattern)
  # ------------------------------------------------------------------

  defp consent_form(tenant, params) do
    action = "/" <> tenant <> "/authorize"
    sorted = Enum.sort(params)

    inputs =
      sorted
      |> Enum.map(fn {k, v} -> ~s(<input type="hidden" name="#{esc(k)}" value="#{esc(v)}"/>) end)
      |> Enum.join()

    "<!DOCTYPE html><html><head><title>Permissions</title></head>" <>
      "<body onload=\"document.forms[0].submit()\">" <>
      "<h2>smalt IdP</h2>" <>
      "<p>Continue to " <> esc(params["client_id"] || "") <> "?</p>" <>
      ~s(<form method="POST" action="#{esc(action)}">) <>
      inputs <>
      ~s(<noscript><input type="submit" value="Continue"/></noscript></form></body></html>)
  end

  defp esc(s) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  # ------------------------------------------------------------------
  # Refresh tokens: rotating, shadow-ETS, reuse-detected family revocation
  # ------------------------------------------------------------------

  @refresh_table :smalt_oidc_refresh_tokens
  @refresh_ttl 86_400

  @doc """
  Mints the first refresh token of a new family for a redeemed code record.
  Called by the token leg on authorization-code success.
  """
  def mint_refresh_token(record, client_id) do
    ensure_refresh_table()

    rt = "rt-" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    family = "fam-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    :ets.insert(@refresh_table, {rt, refresh_record(record, client_id, family), false})

    rt
  end

  @doc """
  The refresh_token grant, delegated from the `OidcIdp` token endpoint.
  Rotates the token (atomic consume flip) and mints fresh tokens; a
  re-presented (consumed) token is reuse and revokes the whole family.
  """
  def refresh_grant(conn) do
    params = conn.body_params

    with {:ok, {rt, record}} <- lookup_consumable(conn.body_params["refresh_token"]),
         :ok <- check_refresh_client(record, params["client_id"]),
         :ok <- consume(rt) do
      new_rt = "rt-" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      :ets.insert(@refresh_table, {new_rt, record, false})

      id_token =
        record
        |> Smalt.Identity.OidcIdp.id_token_claims(effective_client_id(params, record))
        |> mint_id_token()

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, refresh_response(id_token, new_rt))
    else
      {:error, reason} -> send_json_error(conn, reason)
    end
  end

  # Lookup + typed classification: unknown | consumed (reuse → revoke
  # family) | consumable.
  defp lookup_consumable(rt) do
    ensure_refresh_table()

    case :ets.lookup(@refresh_table, rt) do
      [] ->
        {:error, {400, "invalid_grant", "refresh token not found"}}

      [{^rt, record, true}] ->
        revoke_family(record["family_id"])

        {:error,
         {400, "invalid_grant", "refresh token reuse detected; token family revoked"}}

      [{^rt, record, false}] ->
        {:ok, {rt, record}}

      _ ->
        {:error, {400, "invalid_grant", "refresh token not found"}}
    end
  end

  defp check_refresh_client(_record, nil), do: :ok

  defp check_refresh_client(record, client_id) do
    if record["client_id"] == client_id do
      :ok
    else
      {:error, {400, "invalid_client", "client_id mismatch"}}
    end
  end

  defp effective_client_id(params, record) do
    case params["client_id"] do
      cid when is_binary(cid) and cid != "" -> cid
      _ -> record["client_id"]
    end
  end

  # Atomic single-use flip: only a row still in `false` state flips to
  # `true`; a loser of the flip is a concurrent re-presenter — the same
  # reuse law applies.
  defp consume(rt) do
    case :ets.select_replace(@refresh_table, [
           {{rt, :"$2", false}, [], [{{rt, :"$2", true}}]}
         ]) do
      1 ->
        :ok

      _ ->
        case :ets.lookup(@refresh_table, rt) do
          [{^rt, record, true}] ->
            revoke_family(record["family_id"])

            {:error,
             {400, "invalid_grant", "refresh token reuse detected; token family revoked"}}

          _ ->
            {:error, {400, "invalid_grant", "refresh token not found"}}
        end
    end
  end

  defp refresh_record(record, client_id, family) do
    %{
      "family_id" => family,
      "client_id" => client_id,
      "sub" => record["sub"] || "smalt-user",
      "tenant" => record["tenant"] || "organizations",
      "created_at" => System.system_time(:second)
    }
  end

  defp refresh_response(id_token, new_rt) do
    Jason.encode!(%{
      "token_type" => "Bearer",
      "scope" => "openid profile email",
      "expires_in" => 3600,
      "ext_expires_in" => 3600,
      "access_token" => "smalt-at-" <> random_string(),
      "refresh_token" => new_rt,
      "refresh_token_expires_in" => @refresh_ttl,
      "id_token" => id_token
    })
  end

  @doc """
  Revokes every live token of a family (reuse-detection law; also public
  for court use).
  """
  def revoke_family(family_id) do
    ensure_refresh_table()

    :ets.select_delete(@refresh_table, [
      {{:"$1", %{"family_id" => :"$2"}, :_}, [{:==, :"$2", family_id}], [true]}
    ])
  end

  @doc "Court peek: refresh-token row (`nil` when unknown)."
  def refresh_row(rt) do
    ensure_refresh_table()

    case :ets.lookup(@refresh_table, rt) do
      [{^rt, record, consumed}] -> %{token: rt, record: record, consumed: consumed}
      [] -> nil
    end
  end

  @doc "Court: number of live refresh-token rows."
  def refresh_count do
    ensure_refresh_table()
    :ets.info(@refresh_table, :size)
  end

  defp ensure_refresh_table do
    if :ets.whereis(@refresh_table) == :undefined do
      create_refresh_table()
    end
  end

  defp create_refresh_table do
    :global.trans({{__MODULE__, :refresh_table_lock}, node()}, fn ->
      if :ets.whereis(@refresh_table) == :undefined do
        # Same erts-17.1 law as OidcCodeStore: the `:heir` must be a real
        # pid (`Process.whereis(:init)`), not the `:init` atom.
        :ets.new(@refresh_table, [
          :named_table,
          :public,
          :set,
          {:read_concurrency, true},
          {:heir, Process.whereis(:init), nil}
        ])
      end
    end)

    :ok
  end

  # ------------------------------------------------------------------
  # ID-token minting on the refresh leg (RS256 via the dev key, kid in
  # header — same byte shape as OidcIdp's code-grant mint)
  # ------------------------------------------------------------------

  defp mint_id_token(claims) do
    header = %{"alg" => "RS256", "typ" => "JWT", "kid" => current_kid()}
    b64 = &Smalt.Identity.OidcJwks.b64url/1

    signing_input = b64.(Jason.encode!(header)) <> "." <> b64.(Jason.encode!(claims))

    signing_input <> "." <> b64.(Smalt.Identity.OidcJwks.sign(signing_input))
  end

  defp current_kid do
    case Smalt.Identity.OidcJwks.jwk() do
      {:ok, %{"kid" => kid}} -> kid
      _ -> "smalt-dev"
    end
  end

  defp random_string do
    Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end

  # ------------------------------------------------------------------
  # Shared helpers
  # ------------------------------------------------------------------

  defp send_json_error(conn, {status, code, desc}) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(%{"error" => code, "error_description" => desc}))
  end

  defp tenant_of(conn), do: Enum.at(conn.path_info, 0)
end
