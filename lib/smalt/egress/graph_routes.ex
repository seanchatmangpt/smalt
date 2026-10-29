defmodule Smalt.Egress.GraphRoutes do
  @moduledoc """
  Microsoft Graph v1.0 stub surface (AZURE-FIDELITY lane 13) — the minimal
  read-only Graph face the portal console depends on, documented-conformant
  envelope shapes per learn.microsoft.com Graph v1.0 API reference:

    - `GET /v1.0/servicePrincipals`        — list the emulator's SPs
    - `GET /v1.0/servicePrincipals/{id}`   — single SP (typed Graph 404)
    - `GET /v1.0/applications`             — list application registrations
    - `GET /v1.0/oauth2PermissionGrants`   — list delegated permission grants

  Bearer auth composes with the existing STS (`Smalt.Auth.Bearer.verify_bearer/1`,
  the same verifier the ARM gateway mints for) — no new crypto. Auth refusals
  render the documented Graph error envelope
  (`{"error":{"code","message","innerError":{...}}}`, HTTP 401).

  ## Seeding

  The SP/application seed is derived from the existing STS client
  registrations: the identity the STS mints for (mint claims
  `appid: 00000000-0000-0000-0000-000000000000`, display name
  `workspace-console`) is always present, and operators can register further
  clients via

      config :smalt, :graph, service_principals: [%{"appId" => "...", ...}, ...]

  (string-keyed Graph `servicePrincipal` objects; rendered verbatim into the
  `value` array). The registry is read per request — a config flip is live
  without restart.

  Fallthrough router: unmatched conns pass through un-halted (same contract as
  the other `Smalt.Egress.*Routes` sub-routers; mounting into the
  `w6r_fallthrough` mods list in `Smalt.EgressRouter` is the coordinator's
  one-line integration step, deliberately outside this lane's lease).
  """

  use Plug.Router
  import Smalt.EgressRouter, except: [match: 2, match: 3, dispatch: 2]

  # STS mint identity (lib/smalt/arm_gateway/router.ex issue_token/2):
  # the emulator STS mints every token with this appid — the console SP.
  @sts_mint_app_id "00000000-0000-0000-0000-000000000000"
  @console_sp_id "11111111-1111-1111-1111-111111111111"
  @console_app_id "22222222-2222-2222-2222-222222222222"

  plug :match
  plug :dispatch

  # -- servicePrincipals --------------------------------------------------------

  get "/v1.0/servicePrincipals" do
    authorized(conn, fn c -> list(c, :servicePrincipals) end)
  end

  get "/v1.0/servicePrincipals/:id" do
    authorized(conn, fn c ->
      case Enum.find(service_principals(), &(&1["id"] == id)) do
        nil -> graph_error(c, 404, "NotFoundError", "Resource '#{id}' does not exist or one of its queried reference-property objects is missing.")
        sp -> send_json(c, 200, sp)
      end
    end)
  end

  # -- applications -------------------------------------------------------------

  get "/v1.0/applications" do
    authorized(conn, fn c -> list(c, :applications) end)
  end

  # -- auditLogs/signIns (AF-L14-GAP-1 closure) ---------------------------------

  # Documented Graph sign-in logs surface, assembled from the STS mint ring
  # (Smalt.Egress.SignIns). $filter subset: createdDateTime ge/le.
  get "/v1.0/auditLogs/signIns" do
    authorized(conn, fn c -> sign_ins(c) end)
  end

  # -- oauth2PermissionGrants ---------------------------------------------------

  # Tenant-prefixed forms (real Graph clients mint per-tenant authorities):
  # /{tenantId}/v1.0/* admits the same surfaces — the tenant segment is
  # informational (the bearer's tid remains the scope law).
  get "/:tenant_id/v1.0/servicePrincipals" do
    authorized(conn, fn c -> list(c, :servicePrincipals) end)
  end

  get "/:tenant_id/v1.0/auditLogs/signIns" do
    authorized(conn, fn c -> sign_ins(c) end)
  end

  get "/v1.0/oauth2PermissionGrants" do
    authorized(conn, fn c -> list(c, :oauth2PermissionGrants) end)
  end

  # -- internals ------------------------------------------------------------------

  defp authorized(conn, fun) do
    case Smalt.Auth.Bearer.verify_bearer(conn) do
      :ok ->
        fun.(conn)

      {:refuse, code, msg} ->
        # Documented Graph 401 shape (learn.microsoft.com/graph/errors):
        # error.code / error.message / error.innerError with request ids.
        graph_error(conn, 401, code, msg)
    end
  end

  defp graph_error(conn, status, code, msg) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      status,
      Jason.encode!(%{
        "error" => %{
          "code" => code,
          "message" => msg,
          "innerError" => %{
            "request-id" => request_id(conn),
            "client-request-id" =>
              conn |> get_req_header("client-request-id") |> List.first() || request_id(conn)
          }
        }
      })
    )
    |> halt()
  end

  defp request_id(conn) do
    case get_req_header(conn, "request-id") do
      [v | _] -> v
      [] -> "smalt-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
    end
  end

  # Documented collection envelope: {"@odata.context": ..., "value": [...]}.
  defp list(conn, :servicePrincipals) do
    odata_list(conn, "#servicePrincipals", service_principals())
  end

  defp list(conn, :applications) do
    odata_list(conn, "#applications", applications())
  end

  defp list(conn, :oauth2PermissionGrants) do
    # No delegated grants are seeded by the emulator STS (client-credentials
    # flow only) — the documented conformant empty envelope.
    odata_list(conn, "#oauth2PermissionGrants", [])
  end

  # Sign-in logs: the mint ring newest-first, under the documented collection
  # envelope. $filter subset: `createdDateTime ge <dt>` / `le <dt>` joined by
  # `and`. Any other property/operator -> documented Graph 400 BadRequest.
  defp sign_ins(conn) do
    filter = conn |> fetch_query_params() |> Map.get(:query_params) |> Map.get("$filter")

    case parse_created_filter(filter) do
      {:ok, filter} ->
        rows =
          Smalt.Egress.SignIns.events()
          |> Enum.filter(filter)
          |> Enum.map(&Smalt.Egress.SignIns.to_row/1)

        odata_list(conn, "#signIns", rows)

      :error ->
        graph_error(
          conn,
          400,
          "BadRequest",
          "Unsupported $filter. Only 'createdDateTime ge/le <datetime>' (conjunctive) is supported."
        )
    end
  end

  defp parse_created_filter(nil), do: {:ok, fn _ -> true end}

  defp parse_created_filter(raw) when is_binary(raw) do
    raw
    |> String.split(" and ")
    |> Enum.reduce_while({:ok, []}, fn clause, {:ok, acc} ->
      case String.split(clause, " ") do
        ["createdDateTime", op, val] when op in ["ge", "le"] ->
          case DateTime.from_iso8601(String.trim(val, "'")) do
            {:ok, dt, _} -> {:cont, {:ok, [{op, dt} | acc]}}
            _ -> {:halt, :error}
          end

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      :error ->
        :error

      {:ok, clauses} ->
        {:ok,
         fn event ->
           Enum.all?(clauses, fn
             {"ge", dt} -> DateTime.compare(event.created_at, dt) != :lt
             {"le", dt} -> DateTime.compare(event.created_at, dt) != :gt
           end)
         end}
    end
  end

  defp parse_created_filter(_), do: :error

  defp odata_list(conn, fragment, value) do
    send_json(conn, 200, %{
      "@odata.context" => "#{odata_authority(conn)}/v1.0/$metadata#{fragment}",
      "value" => value
    })
  end

  defp odata_authority(conn) do
    "#{conn.scheme}://#{conn.host}:#{conn.port}"
  end

  # -- seed registry ----------------------------------------------------------------

  @doc "Graph servicePrincipal objects served by /v1.0/servicePrincipals."
  def service_principals do
    case Application.get_env(:smalt, :graph, []) do
      kw when is_list(kw) ->
        case Keyword.get(kw, :service_principals) do
          sps when is_list(sps) and sps != [] -> sps
          _ -> default_sps()
        end

      _ ->
        default_sps()
    end
  end

  @doc "Graph application objects served by /v1.0/applications."
  def applications do
    Enum.map(service_principals(), fn sp ->
      %{
        "id" => sp["appId"] |> console_app_id(),
        "appId" => sp["appId"],
        "displayName" => sp["displayName"],
        "signInAudience" => "AzureADMultipleOrgs",
        "identifierUris" => [],
        "requiredResourceAccess" => []
      }
    end)
  end

  defp console_app_id(@sts_mint_app_id), do: @console_app_id
  defp console_app_id(app_id) when is_binary(app_id), do: deterministic_app_id(app_id)

  # Deterministic derived GUID (app registrations need their own object id);
  # md5-of-appId keeps the listing stable across restarts without storing it.
  defp deterministic_app_id(app_id) do
    :md5 |> :crypto.hash(app_id) |> Base.encode16(case: :lower) |> dash_guid()
  end

  defp dash_guid(hex32) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary-size(12)>> =
      hex32

    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end

  # Default seed: the identity the emulator STS mints for — the portal's
  # workspace-console service principal (appId == the STS mint appid).
  defp default_sps do
    [
      %{
        "id" => @console_sp_id,
        "appId" => @sts_mint_app_id,
        "displayName" => "workspace-console",
        "servicePrincipalType" => "Application",
        "accountEnabled" => true,
        "appOwnerOrganizationId" => @sts_mint_app_id,
        "appRoles" => []
      }
    ]
  end
end
