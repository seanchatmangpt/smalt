defmodule Smalt.DataPlane.CosmosAuthz do
  @moduledoc """
  Cosmos DB users / permissions / resource tokens (lane w6h, wave-6).

  Real Azure Cosmos DB resource-token model, emulator scale:

  * **Users** — `POST/GET/ routes under /dbs/{db}/users[/{user_id}]`. A user
    is a container for permissions, keyed `(db, user_id)` atomically.
  * **Permissions** — CRUD under `/dbs/{db}/users/{user}/permissions`. A
    permission binds a `resource` (resourceLink, e.g. `dbs/mydb/colls/c`)
    to a `permissionMode` (`Read` | `All`).
  * **Resource token face** — reading a permission (GET, or the directive's
    POST alias on the permission path) returns the record with a `token`
    field: `type=resource&ver=1.0&sig=<opaque>`. The sig is an opaque
    server-minted token stored in the node-local token table (emulator
    scale: token = capability, not an HMAC recomputation — the admission
    decision is the table lookup, which is the real system's semantics:
    token valid iff the server can bind it to a live permission grant).
  * **Admission** — a data-plane request presenting
    `Authorization: type=resource&ver=1.0&sig=<token>` is admitted only when
    the token resolves to a live grant whose resourceLink is a
    segment-boundary prefix of the requested resource AND the
    permissionMode covers the method (Read → GET/HEAD only; All → any
    method). Unknown/expired token or out-of-scope request: typed 401,
    fail-closed (directive-pinned).

  Table ownership (shadow-table law, certificates.ex pattern): tables are
  created lazily with `{:heir, Process.whereis(:init), []}` so they are
  node-permanent regardless of which process first touches them; the exists
  check and the insert of a create are ONE `:ets.insert_new/2` so the
  create-on-existing silent overwrite is structurally impossible.
  """

  @users_table :smalt_cosmos_users
  @perms_table :smalt_cosmos_permissions
  @tokens_table :smalt_cosmos_resource_tokens

  # Resource-token TTL: real Azure resource tokens are bounded by the master
  # key's 1h maximum; the emulator pins 1 hour from mint.
  @token_ttl_ms :timer.hours(1)

  @modes ["Read", "All"]

  @type resp :: {:ok, pos_integer(), map()} | {:error, pos_integer(), map()}

  # ---------------------------------------------------------------------------
  # Tables (shadow-table law)
  # ---------------------------------------------------------------------------

  @doc "Lazily create the users/permissions/tokens tables (heir = :init)."
  @spec ensure_tables :: :ok
  def ensure_tables do
    for t <- [@users_table, @perms_table, @tokens_table] do
      if :ets.info(t) == :undefined do
        try do
          :ets.new(t, [
            :set,
            :public,
            :named_table,
            {:heir, Process.whereis(:init), []},
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> :ok
        end
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Users
  # ---------------------------------------------------------------------------

  @doc "POST /dbs/{db}/users — 201 with the user record, 409 on existing id."
  @spec create_user(binary, binary) :: resp
  def create_user(db, user_id) do
    ensure_tables()
    row = new_row(db, user_id, "dbs/#{enc(db)}/users/#{enc(user_id)}/")

    case :ets.insert_new(@users_table, {key(db, user_id), row}) do
      true -> {:ok, 201, with_links(row, db)}
      false -> {:error, 409, conflict("UserConflict", user_id)}
    end
  end

  @doc "GET /dbs/{db}/users — user feed."
  @spec list_users(binary) :: {:ok, map()}
  def list_users(db) do
    ensure_tables()

    users =
      @users_table
      |> :ets.tab2list()
      |> Enum.filter(fn {{d, _}, _} -> d == db end)
      |> Enum.map(fn {_, row} -> with_links(row, db) end)
      |> Enum.sort_by(& &1["id"])

    {:ok, %{"_rid" => rid_for(db), "Users" => users, "_count" => length(users)}}
  end

  @doc "GET /dbs/{db}/users/{user} — 200 or 404."
  @spec get_user(binary, binary) :: resp
  def get_user(db, user_id) do
    ensure_tables()

    case :ets.lookup(@users_table, key(db, user_id)) do
      [{_, row}] -> {:ok, 200, with_links(row, db)}
      [] -> {:error, 404, not_found("NotFound", "Entity with id #{user_id} not found")}
    end
  end

  @doc """
  DELETE /dbs/{db}/users/{user} — 204; cascades the user's permissions and
  their resource tokens (a dead user cannot hold live capability).
  """
  @spec delete_user(binary, binary) :: :ok | resp
  def delete_user(db, user_id) do
    ensure_tables()
    drop_permissions_for(db, user_id)

    case :ets.lookup(@users_table, key(db, user_id)) do
      [{_, _}] ->
        :ets.delete(@users_table, key(db, user_id))
        :ok

      [] ->
        {:error, 404, not_found("NotFound", "Entity with id #{user_id} not found")}
    end
  end

  # ---------------------------------------------------------------------------
  # Permissions
  # ---------------------------------------------------------------------------

  @doc """
  POST /dbs/{db}/users/{user}/permissions — body `{id, permissionMode,
  resource}`. 201 with the record; 409 on existing id; 400 typed on missing
  id/resource or a mode outside `Read|All`; 404 on unknown user.
  """
  @spec create_permission(binary, binary, map()) :: resp
  def create_permission(db, user_id, body) do
    ensure_tables()

    case get_user(db, user_id) do
      {:ok, 200, _} ->
        perm_id = body["id"]
        mode = body["permissionMode"] || "All"
        resource = body["resource"]

        cond do
          not is_binary(perm_id) or perm_id == "" ->
            {:error, 400, bad_request("Required property 'id' is missing")}

          mode not in @modes ->
            {:error, 400, bad_request("permissionMode must be Read or All")}

          not is_binary(resource) or resource == "" ->
            {:error, 400, bad_request("Required property 'resource' is missing")}

          true ->
            row = %{
              "id" => perm_id,
              "permissionMode" => mode,
              "resource" => resource,
              "_rid" => rid_for("#{db}/#{user_id}/#{perm_id}"),
              "_self" => "dbs/#{enc(db)}/users/#{enc(user_id)}/permissions/#{enc(perm_id)}/",
              "_ts" => System.system_time(:second),
              "_etag" => etag()
            }

            case :ets.insert_new(@perms_table, {key(db, user_id, perm_id), row}) do
              true -> {:ok, 201, with_links(row, db)}
              false -> {:error, 409, conflict("PermissionConflict", perm_id)}
            end
        end

      {:error, 404, reason} ->
        {:error, 404, reason}
    end
  end

  @doc "GET /dbs/{db}/users/{user}/permissions — permission feed."
  @spec list_permissions(binary, binary) :: {:ok, map()}
  def list_permissions(db, user_id) do
    ensure_tables()

    with {:ok, _, _} <- get_user(db, user_id) do
      perms =
        @perms_table
        |> :ets.tab2list()
        |> Enum.filter(fn {{d, u, _}, _} -> d == db and u == user_id end)
        |> Enum.map(fn {_, row} -> with_links(row, db) end)
        |> Enum.sort_by(& &1["id"])

      {:ok, %{"_rid" => rid_for("#{db}/#{user_id}"), "Permissions" => perms, "_count" => length(perms)}}
    end
  end

  @doc """
  GET (or POST, directive alias) /dbs/{db}/users/{user}/permissions/{perm} —
  200 with the record PLUS `token` (`type=resource&ver=1.0&sig=...`). The
  token is minted once per permission and stored in the token table with a
  1h expiry; re-reads refresh the mint only after expiry.
  """
  @spec get_permission(binary, binary, binary) :: resp
  def get_permission(db, user_id, perm_id) do
    ensure_tables()

    with {:ok, _, _} <- get_user(db, user_id),
         {:ok, row} <- lookup_permission(db, user_id, perm_id) do
      token = mint_or_refresh_token(db, user_id, perm_id, row)
      {:ok, 200, Map.put(with_links(row, db), "token", token_string(token))}
    end
  end

  # POST alias — same face as GET (real Azure issues tokens on permission
  # read; the directive pins POST as the mint face, so POST admits too).
  @doc "POST alias of `get_permission/3` (resource-token mint face)."
  @spec issue_token(binary, binary, binary) :: resp
  def issue_token(db, user_id, perm_id), do: get_permission(db, user_id, perm_id)

  @doc "DELETE /dbs/{db}/users/{user}/permissions/{perm} — 204 or 404."
  @spec delete_permission(binary, binary, binary) :: :ok | resp
  def delete_permission(db, user_id, perm_id) do
    ensure_tables()

    with {:ok, row} <- lookup_permission(db, user_id, perm_id) do
      revoke_token(row[:token_sig])
      :ets.delete(@perms_table, key(db, user_id, perm_id))
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Resource-token admission (called from the Bearer plug seam)
  # ---------------------------------------------------------------------------

  @doc """
  Admission face for `Authorization: type=resource&ver=1.0&sig=<token>` on
  /dbs paths. `:ok` admits; `{:refuse, code, reason}` refuses (typed 401 by
  the plug). Scope law: token's resourceLink must be a segment-boundary
  prefix of the request path resource; mode law: `Read` covers GET/HEAD
  only, `All` covers any method. Unknown/expired token: refuse.
  """
  @spec verify_resource(Plug.Conn.t()) :: :ok | {:refuse, binary, binary}
  def verify_resource(conn) do
    ensure_tables()

    with {:ok, token} <- resource_sig(conn),
         {:ok, grant} <- live_grant(token) do
      cond do
        in_scope?(grant, conn.request_path) and mode_covers?(grant, conn.method) -> :ok
        true -> {:refuse, "InvalidAuthenticationToken", "ResourceTokenScopeExceeded"}
      end
    else
      {:error, :not_resource} ->
        {:refuse, "InvalidAuthenticationToken", "MalformedResourceToken"}

      {:error, :expired} ->
        {:refuse, "InvalidAuthenticationToken", "ResourceTokenExpired"}

      {:error, :unknown_token} ->
        {:refuse, "InvalidAuthenticationToken", "ResourceTokenNotFound"}
    end
  end

  defp resource_sig(conn) do
    case get_req_header_first(conn, "authorization") do
      value when is_binary(value) ->
        case String.split(value, "sig=", parts: 2) do
          [prefix, sig] ->
            type_ok = String.starts_with?(prefix, "type=resource&")
            ver_ok = String.contains?(prefix, "&ver=1.0&") or prefix == "type=resource&ver=1.0&"
            sig_ok = byte_size(sig) > 0 and not String.contains?(sig, " ")

            if type_ok and ver_ok and sig_ok do
              {:ok, sig}
            else
              {:error, :not_resource}
            end

          _ ->
            {:error, :not_resource}
        end

      _ ->
        {:error, :not_resource}
    end
  end

  defp get_req_header_first(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [v | _] -> v
      [] -> nil
    end
  end

  defp live_grant(sig) do
    case :ets.lookup(@tokens_table, sig) do
      [{^sig, grant, expires_at}] ->
        if System.system_time(:millisecond) < expires_at do
          {:ok, Map.put(grant, "token_sig", sig)}
        else
          :ets.delete(@tokens_table, sig)
          {:error, :expired}
        end

      [] ->
        {:error, :unknown_token}
    end
  end

  # Segment-boundary prefix: "dbs/mydb" covers /dbs/mydb,
  # /dbs/mydb/colls, /dbs/mydb/colls/c/docs — but NOT /dbs/mydb2.
  defp in_scope?(grant, request_path) do
    link = grant["resource_link"] || ""
    path = String.trim_leading(request_path, "/")
    path = String.replace_trailing(path, "/", "")
    path == link or String.starts_with?(path, link <> "/")
  end

  defp mode_covers?(grant, method) do
    case grant["permission_mode"] do
      "All" -> true
      "Read" -> method in ["GET", "HEAD"]
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Token mint
  # ---------------------------------------------------------------------------

  defp mint_or_refresh_token(db, user_id, perm_id, row) do
    grant = %{
      "db" => db,
      "user" => user_id,
      "perm" => perm_id,
      "resource_link" => normalize_link(row["resource"]),
      "permission_mode" => row["permissionMode"]
    }

    case :ets.lookup(@perms_table, key(db, user_id, perm_id)) do
      [{_, %{token_sig: sig} = stored}] when is_binary(sig) ->
        case :ets.lookup(@tokens_table, sig) do
          [{^sig, ^grant, expires_at}] when is_integer(expires_at) ->
            if System.system_time(:millisecond) < expires_at do
              sig
            else
              :ets.delete(@tokens_table, sig)
              mint_new(grant, stored)
            end


          _ ->
            :ets.delete(@tokens_table, sig)
            mint_new(grant, stored)
        end

      _ ->
        mint_new(grant, row)
    end
  end

  defp mint_new(grant, stored_row) do
    sig = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    expires = now_ms() + @token_ttl_ms
    :ets.insert(@tokens_table, {sig, grant, expires})

    stored =
      if is_map(stored_row), do: Map.put(stored_row, :token_sig, sig), else: stored_row

    :ets.update_element(@perms_table, key(grant["db"], grant["user"], grant["perm"]),
      {2, stored}
    )
    sig
  end

  defp token_string(sig), do: "type=resource&ver=1.0&sig=" <> sig

  defp revoke_token(sig) when is_binary(sig) do
    :ets.delete(@tokens_table, sig)
    :ok
  end

  defp revoke_token(_), do: :ok

  defp drop_permissions_for(db, user_id) do
    for {{d, u, p}, row} <- :ets.tab2list(@perms_table), d == db and u == user_id do
      revoke_token(row[:token_sig])
      :ets.delete(@perms_table, key(db, user_id, p))
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp new_row(db, id, self_link) do
    %{
      "id" => id,
      "_rid" => rid_for("#{db}/#{id}"),
      "_self" => self_link,
      "_ts" => System.system_time(:second),
      "_etag" => etag()
    }
  end

  # Atom fields ride the row as atoms (:token_sig); wire map is string-keyed
  # only — with_links/2 strips non-string-keyed internal fields.
  defp with_links(row, db) do
    row
    |> Enum.filter(fn {k, v} -> is_binary(k) and not is_nil(v) end)
    |> Map.new()
    |> Map.put("permissions", "dbs/#{enc(db)}/" <> permissions_suffix(row))
  end

  defp permissions_suffix(%{"_self" => self_link}) do
    case String.split(self_link, "/users/") do
      [_, rest] -> rest
      _ -> ""
    end
  end

  defp permissions_suffix(_), do: ""

  defp lookup_permission(db, user_id, perm_id) do
    case :ets.lookup(@perms_table, key(db, user_id, perm_id)) do
      [{_, row}] -> {:ok, row}
      [] -> {:error, 404, not_found("NotFound", "Entity with id #{perm_id} not found")}
    end
  end

  defp normalize_link(link), do: String.trim_leading(link, "/")

  defp key(db, user_id), do: {db, user_id}
  defp key(db, user_id, perm_id), do: {db, user_id, perm_id}

  defp rid_for(seed), do: Base.url_encode64(:crypto.hash(:md5, seed), padding: false)

  defp enc(seg), do: URI.encode_www_form(seg)

  defp etag, do: "\"" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower) <> "\""

  defp now_ms, do: System.system_time(:millisecond)

  defp not_found(code, msg), do: %{"code" => code, "message" => msg}
  defp conflict(code, id), do: %{"code" => code, "message" => "Entity with id #{id} already exists"}
  defp bad_request(msg), do: %{"code" => "BadRequest", "message" => msg}
end
