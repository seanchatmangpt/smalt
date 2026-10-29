defmodule Smalt.Egress.KvRoutes do
  @moduledoc """
  w6R structural split of Smalt.EgressRouter (BEAM implementation limit,
  function '__MODULE__'/1+14): Key Vault keys/secrets/certs + deleted* surfaces arm, verbatim relocation.
  Fallthrough router — unmatched conns pass through un-halted; the main
  router's blob splat + 404 catch-all handle everything else, unchanged.
  """
  use Plug.Router
  # The KV/secret helper family comes from the AppConfigRoutes import below;
  # excluded here so the two imports stay unambiguous (EgressRouter's copies
  # went public alongside).
  import Smalt.EgressRouter,
    except: [
      match: 2,
      match: 3,
      dispatch: 2,
      public_secret_record: 1,
      list_secret_record: 1,
      secret_params: 1,
      secret_expiry: 1,
      maybe_put_content_type: 2,
      policy_has_claim?: 1,
      policy_has_ops_list?: 1
    ]
  alias Smalt.Store
  alias Smalt.DataPlane.KeyVaultActions
  import Smalt.Egress.AppConfigRoutes, except: [match: 2, dispatch: 2]
  plug :match
  plug :dispatch

  # KD-COVERS: KD-126 — EC arm for the HTTP create seam. Mirrors the library
  # seam (KeyVaultActions @ec_curves): OTP curve atom, DER OID, coordinate
  # width, digest, wire alg.
  @ec_curves %{
    "P-256" => %{curve: :secp256r1, oid: {1, 2, 840, 10045, 3, 1, 7}, coord: 32, md: :sha256, alg: "ES256"},
    "P-384" => %{curve: :secp384r1, oid: {1, 3, 132, 0, 34}, coord: 48, md: :sha384, alg: "ES384"}
  }



  # KD-COVERS: KD-33
  post "/keys/:name/create" do
    with_valid_body(conn, fn conn -> kv_key_put(conn, name, conn.body_params) end)
  end

  # KD-COVERS: KD-10, KD-75 — real Azure createKey/updateKey share the PUT verb
  # (PUT /keys/{name}?api-version=7.x → 200 KeyBundle, create-or-replace);
  # unrouted PUT previously fell to the blob catch-all 400 MissingXMsVersion.
  # Mirrors the POST /keys/:name/create arm exactly (same store rows).
  put "/keys/:name" do
    with_valid_body(conn, fn conn -> kv_key_put(conn, name, conn.body_params) end)
  end

  defp kv_key_put(conn, name, key_params) do
    kty = Map.get(key_params, "kty", "RSA-HSM")
    crv = Map.get(key_params, "crv", "P-256")
    release_policy = Map.get(key_params, "release_policy")

    with {:ok, jwk_fields, key_material} <- jwk_for_kty(kty, name, crv, release_policy),
         :ok <- validate_release_policy(release_policy) do
        # GAP-A2-08/10: the kid carries the version suffix (SDK witness) and the
        # version is kept in a list on the row so /keys/{name}/{version} and
        # /keys/{name}/{version}/{action} can resolve it.
        version = Integer.to_string(System.unique_integer([:positive]))

        key_record = %{
          "kid" => "https://#{conn.host}:8443/keys/#{name}/#{version}",
          "versions" => [version],
          "key" =>
            %{
              "kid" => "https://#{conn.host}:8443/keys/#{name}/#{version}",
              "kty" => kty
            }
            |> Map.merge(jwk_fields),
          "attributes" => %{
            "enabled" => true,
            "exportable" => not is_nil(release_policy),
            "created" => System.system_time(:second)
          },
          "release_policy" => release_policy,
          "key_material" => key_material
        }

        # Lens7 fail-closed: a missing vault table is server not-ready, never
        # a client-fault-shaped 400 from a rescued ArgumentError.
        if :ets.info(:smalt_vault_keys) == :undefined do
          route_not_ready(conn)
        else
          # Re-create accumulates versions: latest record rides the bare name,
          # each version also lands under its own {name, version} row.
          prior_versions =
            case Store.get(:smalt_vault_keys, name) do
              {:ok, %{"versions" => vs}} when is_list(vs) -> vs
              _ -> []
            end

          key_record = Map.update!(key_record, "versions", &(&1 ++ prior_versions))
          Store.put(:smalt_vault_keys, name, key_record)

          Store.put(
            :smalt_vault_keys,
            {name, version},
            Map.put(key_record, "is_version_row", true)
          )

          # the private DER never leaves the vault; project the public record
          # (SHIM-COURT-KV86: internal bookkeeping stripped too).
          send_json(
            conn,
            200,
            # R111: release_policy stays public (egress_dispatch_test.exs:415)
            Map.drop(key_record, ["key_material", "is_version_row", "versions"])
          )
        end
      else
        {:kty_error, kty} ->
          blob_error(conn, 400, %{
            "error" => %{
              "code" => "UnsupportedKeyType",
              "message" => "kty #{kty} is not supported"
            }
          })

        {:policy_error, message} ->
          blob_error(conn, 400, %{
            "error" => %{"code" => "InvalidParameter", "message" => message}
          })
      end
  end

  # Azure parity: POST /keys/{name}/rotate mints a new version from the SAME
  # policy (kty/key_ops/release_policy carried; old versions retained). Literal
  # route, NOT the kv_crypto_dispatch catch-all: the common rotate body is
  # EMPTY and with_valid_body? refuses %{} — rotation must not demand a body.
  # Defined before /keys/:name/:action so the literal wins.
  post "/keys/:name/rotate" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.rotate_key(name, conn.body_params))
    end)
  end

  # Azure parity: GET/PUT /keys/{name}/rotationpolicy. Literal routes defined
  # BEFORE the /keys/:name/:action catch-all so the literal segment wins.
  get "/keys/:name/rotationpolicy" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.get_rotation_policy(name))
    end)
  end

  put "/keys/:name/rotationpolicy" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.set_rotation_policy(name, conn.body_params))
    end)
  end

  # Real JsonWebKey form: RSA carries n = base64url modulus, e = base64url
  # exponent ("AQAB" for 65537); oct carries k = base64url key material (the
  # derived AES key is deterministic per name — disclosed dev material).
  # The RSA private key is generated once at create and its DER cached in the
  # row ("key_material") for later crypto ops.
  defp jwk_for_kty(kty, _name, _crv, policy) when kty in ["RSA", "RSA-HSM"] do
    key = :public_key.generate_key({:rsa, 2048, 65537})
    der = :public_key.der_encode(:RSAPrivateKey, key)
    n = elem(key, 2)
    e = elem(key, 3)

    {:ok,
     %{
       "kty" => kty,
       "key_ops" => jwk_key_ops(kty, policy),
       "n" => Base.url_encode64(:binary.encode_unsigned(n), padding: false),
       "e" => Base.url_encode64(:binary.encode_unsigned(e), padding: false)
     }, der}
  end

  # SHIM-COURT: oct material is derived from the key NAME (and version), never
  # the kty — two different oct keys must project different JWK "k" values.
  defp jwk_for_kty(kty, name, _crv, policy) when kty in ["oct", "oct-HSM"] do
    k = Smalt.DataPlane.KeyVaultActions.derive_oct_key(name)

    {:ok,
     %{
       "kty" => kty,
       "key_ops" => jwk_key_ops(kty, policy),
       "k" => Base.url_encode64(k, padding: false)
     }, nil}
  end

  # KD-COVERS: KD-126 — the EC arm the v26.10.19 EC-keys wave left at the
  # library seam only (KeyVaultActions.create_key/2): the wire create route
  # answered 400 UnsupportedKeyType for {"kty":"EC"}. Same shape as the RSA
  # arm: real EC keypair at create, private DER cached under "key_material"
  # for the sign/verify crypto actions (KeyVaultActions.key_material/3
  # reuses it via ensure_ec), public JWK projects crv/x/y in the real
  # JsonWebKey EC form (base64url, fixed width, unsigned). EC-HSM accepted
  # per Azure kty grammar; an unknown crv is a typed 400 InvalidParameter
  # (via the policy_error channel).
  defp jwk_for_kty(kty, _name, crv, policy) when kty in ["EC", "EC-HSM"] do
    curve = Map.get(@ec_curves, crv)

    if curve do
      {pub_point, priv} = :crypto.generate_key(:ecdh, curve.curve)
      priv_rec = {:ECPrivateKey, 1, priv, {:namedCurve, curve.oid}, pub_point, <<>>}
      der = :public_key.der_encode(:ECPrivateKey, priv_rec)
      bits = curve.coord * 8
      <<4, x::unsigned-big-size(^bits), y::unsigned-big-size(^bits)>> = pub_point

      {:ok,
       %{
         "kty" => kty,
         "key_ops" => jwk_key_ops(kty, policy),
         "crv" => crv,
         "x" => Base.url_encode64(<<x::unsigned-big-size(bits)>>, padding: false),
         "y" => Base.url_encode64(<<y::unsigned-big-size(bits)>>, padding: false)
       }, der}
    else
      {:policy_error, "unsupported EC crv #{crv}"}
    end
  end

  defp jwk_for_kty(kty, _name, _crv, _policy), do: {:kty_error, kty}

  # Default ops per key type, intersected with an explicit release-policy
  # `allowed_operations` list when one is present (Azure contract: the JWK
  # body advertises the ops the key may perform).
  defp jwk_key_ops(kty, policy) do
    default =
      if kty in ["oct", "oct-HSM"] do
        ["encrypt", "decrypt", "wrapKey", "unwrapKey"]
      else
        ["encrypt", "decrypt", "sign", "verify", "wrapKey", "unwrapKey"]
      end

    # SHIM-COURT: both spellings accepted; an explicit EMPTY list is deny-all
    # (key_ops []), absent/nil falls back to the defaults — empty ≠ absent.
    case policy do
      %{} = p when is_map_key(p, "allowed_operations") or is_map_key(p, "allowedOperations") ->
        ops = p["allowed_operations"] || p["allowedOperations"]

        if is_list(ops) do
          allowed = Enum.map(ops, &to_string/1)
          Enum.filter(default, &(&1 in allowed))
        else
          default
        end

      _ ->
        default
    end
  end

  # Accept BOTH smalt's `allowed_operations` form and the real Azure release
  # policy grammar (`anyOf`/`allOf`/`claim`/`equals`, nested; `version`,
  # `contentType` siblings). Stored verbatim; validated minimally: somewhere in
  # the structure there must be a claim/equals assertion or an explicit
  # allowed_operations list.
  # KD-COVERS: KD-17
  defp validate_release_policy(nil), do: :ok

  defp validate_release_policy(policy) when is_map(policy) do
    if policy_has_claim?(policy) or policy_has_ops_list?(policy) do
      :ok
    else
      {:policy_error,
       "release_policy must be an Azure anyOf/allOf/claim/equals structure or an allowed_operations list"}
    end
  end

  defp validate_release_policy(_),
    do: {:policy_error, "release_policy must be a JSON object"}

  defp policy_has_claim?(%{"claim" => _}), do: true

  defp policy_has_claim?(policy) when is_map(policy) do
    Enum.any?(policy, fn {_k, v} -> policy_has_claim?(v) end)
  end

  defp policy_has_claim?(list) when is_list(list), do: Enum.any?(list, &policy_has_claim?/1)
  defp policy_has_claim?(_), do: false

  defp policy_has_ops_list?(policy),
    do: is_list(policy["allowed_operations"] || policy["allowedOperations"])

  get "/keys/:name" do
    if :ets.info(:smalt_vault_keys) == :undefined do
      route_not_ready(conn)
    else
      case Store.get(:smalt_vault_keys, name) do
        # SHIM-COURT-KV86: strip internal bookkeeping fields, not just key_material.
        {:ok, key_record} ->
          send_json(
            conn,
            200,
            # R111: release_policy stays public (egress_dispatch_test.exs:415)
            Map.drop(key_record, ["key_material", "is_version_row", "versions"])
          )

        :error ->
          blob_error(conn, 404, not_found_error("KeyNotFound"))
      end
    end
  end

  post "/keys/:name/release" do
    # R143 (GAP S8): real AKV Secure Key Release requires ?api-version=7.x on
    # every request; a missing/wrong version is a typed 400 InvalidApiVersion
    # before any key/policy lookup. Mirrors the Sentinel DCR-ingest gate
    # (Sentinel.ingest/4 head pattern-match in data_plane/sentinel.ex).
    case check_akv_api_version(conn) do
      :ok ->
        case Smalt.DataPlane.SKR.release(name, conn) do
          # Lane 19 (v26.10.14) item 1: KV/SKR envelope pins must not see blob-plane
          # headers (F5 law). blob_error/3 stamps x-ms-request-id/x-ms-version on
          # the release 200 — rendered through send_json like every other KV route.
          {:ok, status, body} -> send_json(conn, status, body)
          {:error, status, body} -> send_json(conn, status, body)
        end

      {:error, status, body} ->
        send_json(conn, status, body)
    end
  end

  # ---------------------------------------------------------------------------
  # Key Vault crypto actions (Smalt.DataPlane.KeyVaultActions)
  # ---------------------------------------------------------------------------
  get "/keys" do
    with_route(conn, KeyVaultActions, fn conn ->
      case KeyVaultActions.list_keys() do
        # Lane 19 (v26.10.14) item 5: the previous `elem/2` catch-all raised
        # ArgumentError on a non-3-tuple return (unhandled 500 outside
        # safe_dispatch). Merge lane (v26.10.28, gate unblock): the fallback
        # arms were proven unreachable by the Elixir 1.20 type system
        # (list_keys/0 is closed over {:ok, status, body} | {:error, _}) and
        # removed under --warnings-as-errors.
        {:ok, status, body} ->
          send_json(conn, status, body)
      end
    end)
  end

  get "/keys/:name/versions" do
    with_route(conn, KeyVaultActions, fn conn ->
      maxresults = kv_page_param(conn.query_params["maxresults"], 25, 1, 25)
      skip = kv_page_param(conn.query_params["$skip"], 0, 0, nil)

      case KeyVaultActions.list_versions_paged(name,
             maxresults: maxresults,
             skip: skip
           ) do
        {:ok, status, body} -> blob_error(conn, status, body)
        {:error, status, body} -> blob_error(conn, status, body)
      end
    end)
  end

  # GAP-A2-08: versioned key fetch — GET /keys/{name}/{version} serves that
  # key version's record (resolved from the {name, version} row the create
  # route stores). Unknown version -> 404 KeyNotFound. Defined AFTER
  # /keys/:name/versions so the literal segment wins.
  get "/keys/:name/:version" do
    if :ets.info(:smalt_vault_keys) == :undefined do
      route_not_ready(conn)
    else
      case Store.get(:smalt_vault_keys, {name, version}) do
        {:ok, key_record} ->
          # SHIM-COURT-KV86: strip internal bookkeeping fields from the wire record.
          send_json(
            conn,
            200,
            # R111: release_policy stays public (egress_dispatch_test.exs:415)
            Map.drop(key_record, ["key_material", "is_version_row", "versions"])
          )

        :error ->
          # R137: the R52 blob fallback here was dead code — the R99
          # reserved-namespace fence refuses every /keys first segment before
          # this route can serve, and the :2188 whitelist re-home made the
          # fallback obsolete. KeyNotFound 404 stands.
          blob_error(conn, 404, not_found_error("KeyNotFound"))
      end
    end
  end

  # w6bc: KV randomnumbers face — literal route defined BEFORE the
  # /keys/:name/:action catch-all so it never shadows the crypto dispatch.
  post "/keys/:name/randomnumbers" do
    with_route(conn, KeyVaultActions, fn conn ->
      with_valid_body(conn, fn conn ->
        kv_respond(conn, KeyVaultActions.random_numbers(name, conn.body_params))
      end)
    end)
  end

  # Case-insensitive crypto action suffix: encrypt/decrypt/sign/verify/
  # wrapKey/unwrapKey. Defined AFTER the literal /keys/:name/create and
  # /keys/:name/release routes so it never shadows them; an unrecognized
  # action re-emits the catch-all 404 so behavior is unchanged.
  post "/keys/:name/:action" do
    kv_crypto_dispatch(conn, name, nil, action)
  end

  # GAP-A2-10: versioned crypto URLs — /keys/{name}/{version}/encrypt|decrypt|
  # sign|verify|wrapKey|unwrapKey route to the same handlers as the unversioned
  # form, resolving the named version (SDK CryptographyClient wire shape).
  # KD-COVERS: KD-16
  post "/keys/:name/:version/:action" do
    kv_crypto_dispatch(conn, name, version, action)
  end

  # KD-COVERS: KD-11
  patch "/keys/:name" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.update_key_properties(name, conn.body_params))
    end)
  end

  # KD-COVERS: KD-11
  patch "/keys/:name/:version" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.update_key_properties(name, conn.body_params, version))
    end)
  end

  # KV soft-delete plane (wave I16/L1, 2026-10-17): key_vault_actions.ex has
  # implemented the full deleted-key lifecycle since the 26.10.14 lane, but
  # zero routes exposed it — every deleted-key wire shape answered the
  # catch-all 404 (KD-13/KD-75 class). Handlers are tuple-shaped for
  # kv_respond/2; routes go through with_route like their /keys siblings.
  delete "/keys/:name" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.delete_key(name))
    end)
  end

  get "/deletedkeys" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.list_deleted_keys())
    end)
  end

  get "/deletedkeys/:name" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.get_deleted_key(name))
    end)
  end

  post "/deletedkeys/:name/recover" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.recover_deleted_key(name))
    end)
  end

  post "/deletedkeys/:name/purge" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.purge_deleted_key(name))
    end)
  end

  # Real Azure Key Vault purge shape (TS wf6 finding): KeyClient.purgeDeletedKey
  # sends bare `DELETE /deletedkeys/{name}` (204), NOT `POST .../purge`. The
  # POST shape was unrouted on the twin and fell through to the blob guarded
  # catch-all (`/{account}/{container}`), answering 400 MissingXMsVersion.
  delete "/deletedkeys/:name" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.purge_deleted_key(name))
    end)
  end

  # KD-102: deleted-secrets plane — the secrets twin of /deletedkeys above.
  # Same bundle shape (recoveryId/deletedDate/scheduledPurgeDate), same
  # recover-200 / purge-204 / purge-protection-409 contracts. List/read are
  # namespaced from deleted keys by {:secret, name} tuple keys in the shared
  # deleted-bundle table (see KeyVaultActions).
  get "/deletedsecrets" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.list_deleted_secrets())
    end)
  end

  get "/deletedsecrets/:name" do
    with_route(conn, KeyVaultActions, fn conn ->
      secret_tenant_gate(conn, name, fn scoped_name ->
        kv_respond(conn, KeyVaultActions.get_deleted_secret(scoped_name))
      end)
    end)
  end

  post "/deletedsecrets/:name/recover" do
    with_route(conn, KeyVaultActions, fn conn ->
      secret_tenant_gate(conn, name, fn scoped_name ->
        kv_respond(conn, KeyVaultActions.recover_deleted_secret(scoped_name))
      end)
    end)
  end

  post "/deletedsecrets/:name/purge" do
    with_route(conn, KeyVaultActions, fn conn ->
      secret_tenant_gate(conn, name, fn scoped_name ->
        kv_respond(conn, KeyVaultActions.purge_deleted_secret(scoped_name))
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # G5 tenant fence (CZ2 law; shared helper Smalt.Auth.TenantLaw): the
  # /secrets plane is scoped by the bearer tid. Point arms read the gate
  # first: a name that exists only under ANOTHER tenant's namespace answers
  # the typed 403 Forbidden (never a 404 lie); otherwise the arm proceeds on
  # the tenant-scoped key (home tenant -> the byte-identical legacy key, so
  # every pre-fence court passes unchanged). List projects the caller's
  # namespace only.
  # ---------------------------------------------------------------------------
  defp secret_tenant_gate(conn, name, fun) do
    tenant = Smalt.Auth.TenantLaw.resolve_tenant(conn)
    scoped = Smalt.Auth.TenantLaw.tenant_scoped_key(tenant, name)

    if secret_foreign?(tenant, name, scoped) do
      send_json(conn, 403, Smalt.Auth.TenantLaw.mismatch_response())
    else
      fun.(scoped)
    end
  end

  # True when `name` exists in the vault table ONLY under a namespace that is
  # not `tenant`'s: the bare legacy key itself, or a "{other_tid}/{name}"
  # scoped row (bare-name binaries AND {name, version} tuple version rows).
  defp secret_foreign?(tenant, name, own) do
    Enum.any?(Store.keys(:smalt_vault_secrets), fn
      k when is_binary(k) ->
        k != own and (k == name or foreign_prefixed_name?(k, name, tenant))

      {n, _v} when is_binary(n) ->
        n != own and (n == name or foreign_prefixed_name?(n, name, tenant))

      _ ->
        false
    end)
  end

  defp foreign_prefixed_name?(k, name, tenant) do
    if String.ends_with?(k, "/#{name}") do
      binary_part(k, 0, byte_size(k) - byte_size(name) - 1) != tenant
    else
      false
    end
  end

  # List-namespace predicate: a binary bare-name row `k` is in the caller's
  # namespace iff tenant_scoped_key(t, unscoped_name(k)) == k. Home rows
  # (no "/") match only for the home tenant; "{tid}/{name}" rows match only
  # for tid.
  defp secret_in_namespace?(k, tenant) when is_binary(k) do
    unscoped =
      case String.split(k, "/", parts: 2) do
        [_before, name] -> name
        [name] -> name
      end

    Smalt.Auth.TenantLaw.tenant_scoped_key(tenant, unscoped) == k
  end

  defp secret_in_namespace?(_k, _tenant), do: false

  defp kv_page_param(nil, default, _min, _max), do: default

  defp kv_page_param(v, default, min, nil) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= min -> n
      _ -> default
    end
  end

  defp kv_page_param(v, default, min, max) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= min and n <= max -> n
      _ -> default
    end
  end

  defp kv_page_param(_, default, _min, _max), do: default

  # KD-COVERS: KD-151 — relaxed api-version gate for the /secrets faces:
  # absent api-version stays admitted (real SDK faces always send it; legacy
  # probes omit it), 7.x admitted, anything else (future 2099-01-01, bad
  # date-formats) is a typed 400 InvalidApiVersion per the KV 7.4 contract.
  defp check_akv_api_version_relaxed(conn) do
    case Map.get(conn.query_params, "api-version", "") do
      "" -> :ok
      v -> if Regex.match?(~r/^7\.\d+$/, v), do: :ok, else: check_akv_api_version(conn)
    end
  end

  @doc false
  def guid_version do
    <<a::32, b::16, c_lo::12, _::4, d_lo::14, _::2, e::48>> = :crypto.strong_rand_bytes(16)

    <<a::32, b::16, 4::4, c_lo::12, 2::2, d_lo::14, e::48>>
    |> Base.encode16(case: :lower)
    |> then(fn <<h1::binary-size(8), h2::binary-size(4), h3::binary-size(4),
                 h4::binary-size(4), h5::binary-size(12)>> ->
      "#{h1}-#{h2}-#{h3}-#{h4}-#{h5}"
    end)
  end

  defp kv_crypto_dispatch(conn, name, version, action) do
    with_route(conn, KeyVaultActions, fn conn ->
      with_valid_body(conn, fn conn ->
        case String.downcase(action) do
          "encrypt" ->
            kv_respond(conn, KeyVaultActions.encrypt(name, conn.body_params, version))

          "decrypt" ->
            kv_respond(conn, KeyVaultActions.decrypt(name, conn.body_params, version))

          "sign" ->
            kv_respond(conn, KeyVaultActions.sign(name, conn.body_params, version))

          "verify" ->
            kv_respond(conn, KeyVaultActions.verify(name, conn.body_params, version))

          "wrapkey" ->
            kv_respond(conn, KeyVaultActions.key_wrap(name, conn.body_params, version))

          "unwrapkey" ->
            kv_respond(conn, KeyVaultActions.key_unwrap(name, conn.body_params, version))

          _other ->
            blob_error(conn, 404, %{
              "error" => %{
                "code" => "RouteNotFound",
                "message" => "No route matches #{conn.method} #{conn.request_path}"
              }
            })
        end
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Key Vault Secrets (/secrets) — lane 345 (v26.10.16) item 8 (data plane)
  # Wire shape mirrors the /keys envelope: KV {"error":{...}} refusals,
  # id "https://{host}:8443/secrets/{name}/{version}", typed SecretNotFound.
  # Accepts BOTH the minimal body {value, attributes?} and the KV REST
  # attributes shape {enabled, expires|exp, contentType}.
  # ---------------------------------------------------------------------------
  get "/secrets" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      # G5 tenant fence: the list is the caller's namespace only. Key shape
      # after the fence: home rows are the bare legacy name, foreign rows are
      # "{tid}/{name}" — a row is MINE iff tenant_scoped_key(t, unscoped) == k
      # (version rows are {name, version} tuples and never list entries — same
      # as the pre-fence face, where Store.list mapped the bare-name rows only
      # in the single-tenant world).
      tenant = Smalt.Auth.TenantLaw.resolve_tenant(conn)

      rows =
        if tenant == Smalt.Auth.TenantLaw.home_tenant() do
          # Legacy law: home list is byte-identical to the pre-fence face.
          Enum.map(Store.list(:smalt_vault_secrets), &list_secret_record/1)
        else
          Store.keys(:smalt_vault_secrets)
          |> Enum.filter(&secret_in_namespace?(&1, tenant))
          |> Enum.map(fn k ->
            {:ok, record} = Store.get(:smalt_vault_secrets, k)
            list_secret_record(record)
          end)
        end

      send_json(conn, 200, %{"value" => rows})
    end
  end

  put "/secrets/:name" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      secret_tenant_gate(conn, name, fn scoped_name ->
        # Body keeps the historical `name` spelling — rebound to the
        # tenant-scoped key (home tenant: byte-identical legacy key).
        # V20b (scoped-key class, wire id): the SecretBundle `id` is the
        # DOCUMENTED wire shape https://{host}/secrets/{name}/{version} —
        # tenant identity rides the bearer, never the URL path. Storage
        # stays scoped; the stored id is built from the UNSCOPED route
        # name, so a foreign tenant's bundles never leak the internal
        # "{tid}/{name}" storage key onto the wire (home tenant: byte-
        # identical legacy id, wire_name == scoped_name).
        wire_name = name
        name = scoped_name
        with_valid_body(conn, fn conn ->
        # KD-COVERS: KD-151 — the KV 7.4 contract refuses a future/invalid
        # api-version with a typed 400 before any lookup (aligns the KV face
        # to the KD-78 monotonic-admission ceiling; 2099-01-01 is future).
        case check_akv_api_version_relaxed(conn) do
          {:error, status, body} ->
            send_json(conn, status, body)

          :ok ->
            case secret_params(conn.body_params) do
              {:ok, value, attrs_in} ->
                # KD-COVERS: KD-150 — Azure KV secret ids are
                # https://{vault}.vault.azure.net/secrets/{name}/{version-GUID};
                # loopback host + numeric version was a wire divergence.
                version = Smalt.Egress.KvRoutes.guid_version()

                # KD-COVERS: KD-184/KD-185 — every PUT mints a version that is
                # RETAINED: a version row lands under {name, version} and the
                # bare-name row keeps a newest-first "versions" index. Each
                # version carries a node-monotonic "created_seq"
                # (System.unique_integer/1) so latest resolution is LAST-WRITE
                # ordered, never lexically-greatest-UUID ordered.
                seq = System.unique_integer([:positive, :monotonic])

                prior_versions =
                  case Store.get(:smalt_vault_secrets, name) do
                    {:ok, %{"versions" => vs}} when is_list(vs) -> vs
                    # legacy pre-S3 row: seed the index from its live version
                    {:ok, %{"version" => v}} when is_binary(v) -> [v]
                    _ -> []
                  end

                now = System.system_time(:second)

                record =
                  %{
                    "value" => value,
                    "id" =>
                      "https://#{conn.host}.vault.azure.net/secrets/#{wire_name}/#{version}",
                    "attributes" =>
                      %{
                        "enabled" => Map.get(attrs_in, "enabled", true),
                        "created" => now,
                        "updated" => now
                      }
                      |> Map.merge(secret_expiry(attrs_in)),
                    "version" => version,
                    "created_seq" => seq,
                    "versions" => [version | prior_versions]
                  }
                  |> maybe_put_content_type(attrs_in)

                existed? = match?({:ok, _}, Store.get(:smalt_vault_secrets, name))

                # KD-COVERS: KD-149 — real Azure answers 201 on FIRST create,
                # 200 on update/re-set (KV secrets 7.4 contract). Re-set still
                # accumulates the new version as the latest (mirrors the /keys
                # re-create version-accumulation contract).
                Store.put(:smalt_vault_secrets, name, record)
                Store.put(:smalt_vault_secrets, {name, version}, Map.put(record, "is_version_row", true))
                send_json(conn, if(existed?, do: 200, else: 201), public_secret_record(record))

              :error ->
                blob_error(conn, 400, %{
                  "error" => %{
                    "code" => "InvalidParameter",
                    "message" => "secret body requires a string \"value\""
                  }
                })
            end
        end

      end)
      end)
    end
  end

  get "/secrets/:name" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      secret_tenant_gate(conn, name, fn scoped_name ->
        # KD-COVERS: KD-151 — future/invalid api-version is a typed 400 on the
        # GET face too (witness kv-secret-get-badapi).
        case check_akv_api_version_relaxed(conn) do
        {:error, status, body} ->
          send_json(conn, status, body)

        :ok ->
          # KD-COVERS: KD-184 — latest resolves by LAST-WRITE, never by
          # lexically-greatest version UUID. The bare-name row is maintained
          # as the last write; when a retained versions index exists, the
          # index head (insert order = write order) re-resolves the exact
          # version row so latest and the version-addressed read agree byte
          # for byte on id/value.
          case latest_secret(scoped_name) do
            {:ok, record} -> send_json(conn, 200, public_secret_record(record))
            :error -> blob_error(conn, 404, not_found_error("SecretNotFound"))
          end
        end
      end)
    end
  end

  # KD-COVERS: KD-184 — latest = last write. Resolution order: the versions
  # index head (insert order, maintained newest-first by every writer) resolved
  # against its retained version row, else the bare-name row (the last write
  # by construction, incl. legacy pre-S3 rows). Lexical UUID order is never
  # consulted.
  defp latest_secret(name) do
    case Store.get(:smalt_vault_secrets, name) do
      {:ok, %{"versions" => [head | _]} = _record} when is_binary(head) ->
        case Store.get(:smalt_vault_secrets, {name, head}) do
          {:ok, row} -> {:ok, row}
          :error -> Store.get(:smalt_vault_secrets, name)
        end

      other ->
        other
    end
  end

  # w6bn: secrets PATCH — attributes-only update (enabled/exp/nbf + tags
  # merge), value never rotates; version omitted -> latest, mismatched
  # version -> 404 SecretNotFound. Engine: KeyVaultActions.
  # update_secret_properties/3.
  patch "/secrets/:name" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      secret_tenant_gate(conn, name, fn scoped_name ->
        with_valid_body(conn, fn conn ->
          kv_respond(conn, KeyVaultActions.update_secret_properties(scoped_name, conn.body_params))
        end)
      end)
    end
  end

  patch "/secrets/:name/:version" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      secret_tenant_gate(conn, name, fn scoped_name ->
        with_valid_body(conn, fn conn ->
          kv_respond(
            conn,
            KeyVaultActions.update_secret_properties(scoped_name, conn.body_params, version)
          )
        end)
      end)
    end
  end

  # KD-102 (secrets soft-delete plane): DELETE is a soft delete — the live row
  # moves to the deleted-bundle table and the response is the deleted-secret
  # bundle (id/attributes + recoveryId/deletedDate/scheduledPurgeDate), exactly
  # the real Azure SecretBundle delete contract. Live GET then 404s by
  # construction; recover/purge ride /deletedsecrets below.
  delete "/secrets/:name" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      secret_tenant_gate(conn, name, fn scoped_name ->
        kv_respond(conn, KeyVaultActions.delete_secret(scoped_name))
      end)
    end
  end

  # KD-LITH-WIRE-2 (closes tape af-14): GET /secrets/{name}/versions answers
  # the documented KV 7.4 versions-list shape — 200 {value: [SecretBundle...],
  # nextLink} — projected from the KD-S3 retained version rows, newest-first
  # (the bare-name row's "versions" index is maintained newest-first by every
  # writer; legacy pre-S3 rows seed a single-entry index from their live
  # version). nextLink is absent: the full history fits one page (the /keys
  # versions face answers the same absent-nextLink shape). An unknown or
  # fully-scrubbed name answers 200 with an empty value — the list face
  # reports what exists, never a 404 lie.
  get "/secrets/:name/versions" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      secret_tenant_gate(conn, name, fn scoped_name ->
        case check_akv_api_version_relaxed(conn) do
          {:error, status, body} ->
            send_json(conn, status, body)

          :ok ->
            versions =
              case Store.get(:smalt_vault_secrets, scoped_name) do
                {:ok, %{"versions" => vs}} when is_list(vs) -> vs
                {:ok, %{"version" => v}} when is_binary(v) -> [v]
                _ -> []
              end

            value =
              versions
              |> Enum.map(fn v ->
                case Store.get(:smalt_vault_secrets, {scoped_name, v}) do
                  {:ok, row} ->
                    # V20a (scoped-key class): a versions-list bundle carries the
                    # documented SecretBundle "version" member (real Azure
                    # answers it on every entry; KD-S3 internal bookkeeping —
                    # versions index / created_seq / is_version_row — still
                    # never leaves the vault). public_secret_record/1 drops
                    # "version" for the point faces; the list face keeps it.
                    Map.drop(row, ["versions", "created_seq", "is_version_row"])

                  :error ->
                    # Legacy pre-S3 row: the only version lives on the bare row.
                    case Store.get(:smalt_vault_secrets, scoped_name) do
                      {:ok, %{"version" => ^v} = record} -> public_secret_record(record)
                      _ -> nil
                    end
                end
              end)
              |> Enum.reject(&is_nil/1)

            send_json(conn, 200, %{"value" => value})
        end
      end)
    end
  end


  # ---------------------------------------------------------------------------
  # Key Vault Certificates (KD-104, Smalt.DataPlane.Certificates)
  # ---------------------------------------------------------------------------
  post "/certificates/:name/create" do
    with_valid_body(conn, fn conn ->
      case Smalt.DataPlane.Certificates.create(name, conn, conn.body_params) do
        {:ok, status, body} -> send_json(conn, status, body)
        {:error, status, body} -> send_json(conn, status, body)
      end
    end)
  end

  # Certificate issuers + contacts (wave-6 lane w6c). The 2-segment literals
  # (/certificates/issuers, /certificates/contacts) MUST precede the
  # get/delete "/certificates/:name" catch-alls below — Plug router matches
  # in definition order and the catch-all captures "issuers"/"contacts" as
  # a :name.
  get "/certificates/issuers" do
    case Smalt.DataPlane.Certificates.list_issuers() do
      {:ok, status, body} -> send_json(conn, status, body)
    end
  end

  get "/certificates/contacts" do
    case Smalt.DataPlane.Certificates.get_contacts() do
      {:ok, status, body} -> send_json(conn, status, body)
      {:error, status, body} -> send_json(conn, status, body)
    end
  end

  put "/certificates/contacts" do
    with_valid_body(conn, fn conn ->
      case Smalt.DataPlane.Certificates.put_contacts(conn, conn.body_params) do
        {:ok, status, body} -> send_json(conn, status, body)
        {:error, status, body} -> send_json(conn, status, body)
      end
    end)
  end

  delete "/certificates/contacts" do
    case Smalt.DataPlane.Certificates.delete_contacts() do
      {:ok, status, body} -> send_json(conn, status, body)
      {:error, status, body} -> send_json(conn, status, body)
    end
  end

  put "/certificates/issuers/:name" do
    with_valid_body(conn, fn conn ->
      case Smalt.DataPlane.Certificates.put_issuer(name, conn, conn.body_params) do
        {:ok, status, body} -> send_json(conn, status, body)
        {:error, status, body} -> send_json(conn, status, body)
      end
    end)
  end

  get "/certificates/issuers/:name" do
    case Smalt.DataPlane.Certificates.get_issuer(name) do
      {:ok, status, body} -> send_json(conn, status, body)
      {:error, status, body} -> send_json(conn, status, body)
    end
  end

  delete "/certificates/issuers/:name" do
    case Smalt.DataPlane.Certificates.delete_issuer(name) do
      {:ok, status, body} -> send_json(conn, status, body)
      {:error, status, body} -> send_json(conn, status, body)
    end
  end

  # Create-LRO operation face (wf4 finding): the SDK poller polls
  # GET .../pending until `status: "completed"`; the mint is synchronous, so
  # the record exists and completes on first observation. Unknown pending ->
  # typed 404 PendingCertificateNotFound.
  get "/certificates/:name/pending" do
    case Smalt.DataPlane.Certificates.get_pending(name) do
      {:ok, status, body} -> send_json(conn, status, body)
      {:error, status, body} -> send_json(conn, status, body)
    end
  end

  get "/certificates" do
    {:ok, status, body} = Smalt.DataPlane.Certificates.list()
    send_json(conn, status, body)
  end

  get "/certificates/:name" do
    case Smalt.DataPlane.Certificates.get(name) do
      {:ok, status, body} -> send_json(conn, status, body)
      {:error, status, body} -> send_json(conn, status, body)
    end
  end

  # Soft delete (deleted-certificates class, parity with /deletedkeys and
  # /deletedsecrets): the live row moves to the {:deleted, name} tuple row in
  # the same heir'd table and the response is the deletedCertificate bundle
  # (recoveryId/deletedDate/scheduledPurgeDate). Live GET then 404s by
  # construction; recover/purge ride /deletedcertificates below.
  delete "/certificates/:name" do
    case Smalt.DataPlane.Certificates.delete(name) do
      {:ok, status, body} -> send_json(conn, status, body)
      {:error, status, body} -> send_json(conn, status, body)
    end
  end

  get "/deletedcertificates" do
    # list_deleted/0 always succeeds ({:ok, 200, map}); the dead {:error, ...}
    # clause here failed `mix compile --warnings-as-errors`, which is the
    # ggen_igniter.sync terminal verify gate (wave-4 MCP lane unblock, 2026-10-20).
    case Smalt.DataPlane.Certificates.list_deleted() do
      {:ok, status, body} -> send_json(conn, status, body)
    end
  end

  get "/deletedcertificates/:name" do
    case Smalt.DataPlane.Certificates.get_deleted(name) do
      {:ok, status, body} -> send_json(conn, status, body)
      {:error, status, body} -> send_json(conn, status, body)
    end
  end

  post "/deletedcertificates/:name/recover" do
    case Smalt.DataPlane.Certificates.recover(name) do
      {:ok, status, body} -> send_json(conn, status, body)
      {:error, status, body} -> send_json(conn, status, body)
    end
  end

  post "/deletedcertificates/:name/purge" do
    case Smalt.DataPlane.Certificates.purge(name) do
      {:ok, status, body} -> send_json(conn, status, body)
      {:error, status, body} -> send_json(conn, status, body)
    end
  end

  # KD-COVERS: KD-103 — the wire arm for the backup/restore falsifier:
  # real Azure restore is `POST /secrets/restore` (body {"value": blob}),
  # NOT a per-name path, so it must be routed as a fixed segment BEFORE the
  # `/:name/...` parameterized faces (a bare /secrets/restore used to fall
  # through to the blob catch-all with a typed MissingXMsVersion refusal).
  post "/secrets/restore" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      with_valid_body(conn, fn conn ->
        case conn.body_params do
          %{"value" => blob} when is_binary(blob) ->
            case Smalt.DataPlane.VaultData.restore_secret(blob, conn.host) do
              {:ok, :created} ->
                send_json(conn, 201, %{"status" => "restored"})

              {:error, "Conflict", msg} ->
                blob_error(conn, 409, %{
                  "error" => %{"code" => "Conflict", "message" => msg}
                })

              {:error, code, msg} ->
                blob_error(conn, 400, %{"error" => %{"code" => code, "message" => msg}})
            end

          _ ->
            blob_error(conn, 400, %{
              "error" => %{
                "code" => "InvalidParameter",
                "message" => "restore body requires a string \"value\" (the backup blob)"
              }
            })
        end
      end)
    end
  end

  # KD-COVERS: KD-103 (keys face) — same wire shape, `POST /keys/restore`.
  post "/keys/restore" do
    if :ets.info(:smalt_vault_keys) == :undefined do
      route_not_ready(conn)
    else
      with_valid_body(conn, fn conn ->
        case conn.body_params do
          %{"value" => blob} when is_binary(blob) ->
            case Smalt.DataPlane.KeyVaultActions.restore_key(blob) do
              {:ok, status, key} -> send_json(conn, status, key)
              {:error, status, body} -> send_json(conn, status, body)
            end

          _ ->
            blob_error(conn, 400, %{
              "error" => %{
                "code" => "InvalidParameter",
                "message" => "restore body requires a string \"value\" (the backup blob)"
              }
            })
        end
      end)
    end
  end

  # KD-103 (capability wave 1): backup/restore via VaultData — the refusal
  # sites became real surfaces when backup_secret/restore_secret landed.
  post "/secrets/:name/backup" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      case Smalt.DataPlane.VaultData.backup_secret(name) do
        {:ok, envelope} -> send_json(conn, 200, envelope)
        :error -> blob_error(conn, 404, not_found_error("SecretNotFound"))
      end
    end
  end

  post "/secrets/:name/restore" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      with_valid_body(conn, fn conn ->
        case conn.body_params do
          %{"value" => blob} when is_binary(blob) ->
            case Smalt.DataPlane.VaultData.restore_secret(blob, conn.host) do
              {:ok, :created} ->
                send_json(conn, 201, %{"status" => "restored"})

              # merge lane (v26.10.28, gate unblock): the former
              # `{:ok, :conflict}` 409 arm was proven unreachable by the
              # Elixir 1.20 type system — restore_secret/2 signals conflict
              # via {:error, "Conflict", msg}, handled at the twin restore
              # arm — and was removed under --warnings-as-errors.
              {:error, code, msg} ->
                blob_error(conn, 400, %{"error" => %{"code" => code, "message" => msg}})
            end

          _ ->
            blob_error(conn, 400, %{
              "error" => %{
                "code" => "InvalidParameter",
                "message" => "restore body requires a string \"value\" (the backup blob)"
              }
            })
        end
      end)
    end
  end

  # KD-COVERS: KD-185 — retained version history. Every secret PUT stores a
  # full version row under {name, version}; a version-addressed GET serves
  # THAT version's value + attributes with 200 (real Azure parity), and the
  # typed 404 SecretNotFound is reserved for genuinely UNKNOWN versions.
  # Legacy rows written before the raise (bare row only, no version rows) keep
  # answering 200 when the segment names the live latest version.
  get "/secrets/:name/:version" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      # G5 tenant fence (same defect class G4 hit on the delete arm): the
      # version-addressed read MUST resolve inside the CALLER's namespace —
      # the PUT that wrote the version went through secret_tenant_gate, so an
      # ungated legacy-key read here 404s the caller's own write whenever the
      # caller tid is not the home default. Gate + scoped read: home tenant ->
      # byte-identical legacy keys (200 with the retained value); foreign ->
      # typed 403.
      secret_tenant_gate(conn, name, fn scoped_name ->
        case Store.get(:smalt_vault_secrets, {scoped_name, version}) do
          {:ok, row} ->
            send_json(conn, 200, public_secret_record(row))

          :error ->
            case Store.get(:smalt_vault_secrets, scoped_name) do
              {:ok, %{"version" => ^version} = record} ->
                send_json(conn, 200, public_secret_record(record))

              _ ->
                blob_error(conn, 404, not_found_error("SecretNotFound"))
            end
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Key Vault managed storage accounts (w6b landed module; w6bl route mount).
  # Azure KV 2016-10-01 REST shape over the landed faces — kv_respond renders
  # the {:ok, status, map} / {:error, status, map} tuples directly.
  # ---------------------------------------------------------------------------
  get "/managedstorage" do
    with_route(conn, Smalt.DataPlane.KVManagedStorage, fn conn ->
      kv_respond(conn, Smalt.DataPlane.KVManagedStorage.list())
    end)
  end

  put "/managedstorage/:name" do
    with_route(conn, Smalt.DataPlane.KVManagedStorage, fn conn ->
      kv_respond(conn, Smalt.DataPlane.KVManagedStorage.create(name, conn, conn.body_params))
    end)
  end

  get "/managedstorage/:name" do
    with_route(conn, Smalt.DataPlane.KVManagedStorage, fn conn ->
      kv_respond(conn, Smalt.DataPlane.KVManagedStorage.get(name))
    end)
  end

  delete "/managedstorage/:name" do
    with_route(conn, Smalt.DataPlane.KVManagedStorage, fn conn ->
      kv_respond(conn, Smalt.DataPlane.KVManagedStorage.delete(name))
    end)
  end

  get "/managedstorage/:name/keys" do
    with_route(conn, Smalt.DataPlane.KVManagedStorage, fn conn ->
      kv_respond(conn, Smalt.DataPlane.KVManagedStorage.keys(name))
    end)
  end

  post "/managedstorage/:name/regeneratestorageaccountkey" do
    with_route(conn, Smalt.DataPlane.KVManagedStorage, fn conn ->
      kv_respond(conn, Smalt.DataPlane.KVManagedStorage.regenerate_key(name))
    end)
  end

  get "/deletedmanagedstorage" do
    with_route(conn, Smalt.DataPlane.KVManagedStorage, fn conn ->
      kv_respond(conn, Smalt.DataPlane.KVManagedStorage.list_deleted())
    end)
  end

  get "/deletedmanagedstorage/:name" do
    with_route(conn, Smalt.DataPlane.KVManagedStorage, fn conn ->
      kv_respond(conn, Smalt.DataPlane.KVManagedStorage.get_deleted(name))
    end)
  end

  post "/deletedmanagedstorage/:name/recover" do
    with_route(conn, Smalt.DataPlane.KVManagedStorage, fn conn ->
      kv_respond(conn, Smalt.DataPlane.KVManagedStorage.recover(name))
    end)
  end

  post "/deletedmanagedstorage/:name/purge" do
    with_route(conn, Smalt.DataPlane.KVManagedStorage, fn conn ->
      kv_respond(conn, Smalt.DataPlane.KVManagedStorage.purge(name))
    end)
  end

  put "/managedstorage/:name/sas/:sasdef" do
    with_route(conn, Smalt.DataPlane.KVManagedStorage, fn conn ->
      kv_respond(
        conn,
        Smalt.DataPlane.KVManagedStorage.put_sas(name, sasdef, conn, conn.body_params)
      )
    end)
  end

  get "/managedstorage/:name/sas" do
    with_route(conn, Smalt.DataPlane.KVManagedStorage, fn conn ->
      kv_respond(conn, Smalt.DataPlane.KVManagedStorage.list_sas(name))
    end)
  end

  get "/managedstorage/:name/sas/:sasdef" do
    with_route(conn, Smalt.DataPlane.KVManagedStorage, fn conn ->
      kv_respond(conn, Smalt.DataPlane.KVManagedStorage.get_sas(name, sasdef))
    end)
  end

  delete "/managedstorage/:name/sas/:sasdef" do
    with_route(conn, Smalt.DataPlane.KVManagedStorage, fn conn ->
      kv_respond(conn, Smalt.DataPlane.KVManagedStorage.delete_sas(name, sasdef))
    end)
  end

  # ---------------------------------------------------------------------------
  # Azure App Configuration (/kv) — v26.10.16 lane 520 (C7 console gap)
  # KD-COVERS: KD-53. Wire contract per
  # docs/jira/v26.10.16/sdk-results/appconfig-console-gap.md. Storage:
  # :smalt_appconfig ETS keyed {key, label}; etag = sha256 content hash
  # (quoted). Feature-flag content type is an opaque passthrough (client-side
  # evaluation concern). Same KV challenge/tokenless posture as /secrets
  # (kv_challenge_guard above now covers the /kv prefix).
  # ---------------------------------------------------------------------------
end
