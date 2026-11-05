defmodule Smalt.ArmGateway.Providers.ManagementPoliciesRouter do
  @moduledoc """
  Pass-through provider plug for the ARM storage account managementPolicies
  child route (KD-188). # KD-COVERS: KD-188

  Same composition as the S2 ContainerAppsRouter: mounted BEFORE
  `plug(:match)` in `Smalt.ArmGateway.Router`, claims ONLY the
  /subscriptions/:sub/resourceGroups/:rg/providers/Microsoft.Storage/storageAccounts/:acct/managementPolicies[/:name]
  shape and returns the conn UNCHANGED for everything else. Every answer
  HALTS. api-version is gated through the shared
  `Smalt.ArmGateway.Plug.Common.check_api_version/2` against the
  Microsoft.Storage account ladder (KD-78 monotonic admission; latest
  2023-05-01).

  Verb law: PUT/GET/DELETE only — real Azure has no PATCH on
  managementPolicies, so PATCH answers the typed 405 MethodNotAllowed.

  Wire law lives in `Smalt.ArmGateway.StorageManagementPolicies`
  (singleton-name law, parent-account 404 StorageAccountNotFound, DELETE
  synchronous 200).
  """

  @behaviour Plug

  alias Smalt.ArmGateway.Plug.Common
  alias Smalt.ArmGateway.StorageManagementPolicies

  @claim_methods ["PUT", "GET", "DELETE"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: path_info} = conn, _opts) do
    clauses = Enum.map(path_info, &String.downcase/1)

    case shape(clauses, path_info) do
      nil -> conn
      shape -> dispatch(conn, shape)
    end
  end

  def call(conn, _opts), do: conn

  # The provider namespace, "storageAccounts" and "managementPolicies"
  # segments are matched downcased; "resourcegroups" is the case-normalized
  # sibling convention (ContainerAppsRouter parity). `orig` carries the
  # client's original casing for id construction.
  defp shape(
         ["subscriptions", _sub, "resourcegroups", _rg, "providers", "microsoft.storage", "storageaccounts",
          acct, "managementpolicies" | rest],
         orig
       ) do
    case rest do
      [] -> {:policy, Enum.at(orig, 1), Enum.at(orig, 3), Enum.at(orig, 7), nil}
      [name] -> {:policy, Enum.at(orig, 1), Enum.at(orig, 3), Enum.at(orig, 7), name}
      _ -> nil
    end
  end

  defp shape(_clauses, _orig), do: nil

  # -- dispatch ----------------------------------------------------------------

  defp dispatch(conn, {:policy, sub, rg, acct, name}) do
    cond do
      conn.method not in @claim_methods and not (name == nil and conn.method == "GET") ->
        method_not_allowed(conn)

      true ->
        conn = Plug.Conn.fetch_query_params(conn)
        api_gate(conn, fn c -> handle(c, sub, rg, acct, name) end)
    end
  end

  defp handle(conn, sub, rg, acct, nil = _name) do
    # Collection-level GET is not a real Azure face: the policy child is
    # always addressed by name. Typed 404, not a fabricated list.
    not_found(conn, policy_id(sub, rg, acct, "default"))
  end

  defp handle(conn, sub, rg, acct, name) do
    case conn.method do
      "PUT" -> put_policy(conn, sub, rg, acct, name)
      "GET" -> get_policy(conn, sub, rg, acct, name)
      "DELETE" -> delete_policy(conn, sub, rg, acct, name)
    end
  end

  # -- verb handlers -----------------------------------------------------------

  defp put_policy(conn, sub, rg, acct, name) do
    with {:ok, body, conn} <- request_body(conn),
         {:ok, record, created?} <- StorageManagementPolicies.put(sub, rg, acct, name, body) do
      send_json(conn, if(created?, do: 201, else: 200), record)
    else
      {:error, {:bad_name, bad}} ->
        arm_error(conn, 400, "ManagementPolicyNameInvalid",
          "Management policy name must be 'default'; '#{bad}' is not a valid managementPolicies name.")

      {:error, :bad_properties} ->
        arm_error(conn, 400, "InvalidRequestContent",
          "The request content was invalid: managementPolicies PUT requires a map 'properties' member.")

      {:error, :no_account} ->
        account_not_found(conn, sub, rg, acct)

      {:error, conn} ->
        arm_error(conn, 400, "InvalidRequestContent",
          "The request content was invalid and could not be deserialized.")
    end
  end

  defp get_policy(conn, sub, rg, acct, name) do
    case StorageManagementPolicies.get(sub, rg, acct, name) do
      {:ok, record} -> send_json(conn, 200, record)
      {:error, :no_account} -> account_not_found(conn, sub, rg, acct)
      {:error, :absent} -> not_found(conn, policy_id(sub, rg, acct, name))
    end
  end

  defp delete_policy(conn, sub, rg, acct, name) do
    case StorageManagementPolicies.delete(sub, rg, acct, name) do
      :ok -> send_json(conn, 200, "")
      {:error, :no_account} -> account_not_found(conn, sub, rg, acct)
      {:error, :absent} -> not_found(conn, policy_id(sub, rg, acct, name))
    end
  end

  # -- api-version gate ---------------------------------------------------------

  defp api_gate(conn, fun) do
    case Common.check_api_version(conn, "Microsoft.Storage/storageAccounts") do
      :ok -> fun.(conn)
      # Common.send_arm_error already SENT; halt so the next plug in the
      # 9443 chain never double-sends on this conn.
      {:respond, conn} -> Plug.Conn.halt(conn)
    end
  end

  # -- wire helpers -------------------------------------------------------------

  defp request_body(conn) do
    case conn.body_params do
      params when is_map(params) and map_size(params) > 0 ->
        {:ok, params, conn}

      _ ->
        case Plug.Conn.read_body(conn) do
          {:ok, raw, conn} ->
            case Smalt.JsonCompat.decode(raw) do
              {:ok, decoded} -> {:ok, decoded, conn}
              {:error, _} -> {:error, conn}
            end

          _other ->
            {:error, conn}
        end
    end
  end

  defp account_id(sub, rg, acct) do
    "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.Storage/storageAccounts/#{acct}"
  end

  defp policy_id(sub, rg, acct, name) do
    account_id(sub, rg, acct) <> "/managementPolicies/#{name}"
  end

  defp arm_error(conn, status, code, message) do
    send_json(conn, status,
      Jason.encode!(%{"error" => %{"code" => code, "message" => message, "innererror" => %{}}}))
  end

  # The real-Azure managementPolicies error code for a missing parent
  # storage account.
  defp account_not_found(conn, sub, rg, acct) do
    send_json(conn, 404,
      Jason.encode!(%{
        "error" => %{
          "code" => "StorageAccountNotFound",
          "message" => "The storage account #{account_id(sub, rg, acct)} was not found.",
          "target" => account_id(sub, rg, acct),
          "innererror" => %{}
        }
      }))
  end

  defp not_found(conn, target) do
    send_json(conn, 404,
      Jason.encode!(%{
        "error" => %{
          "code" => "ResourceNotFound",
          "message" => "The Resource #{target} was not found.",
          "target" => target,
          "innererror" => %{}
        }
      }))
  end

  defp method_not_allowed(conn) do
    arm_error(conn, 405, "MethodNotAllowed", "The method is not allowed on this resource.")
  end

  defp send_json(conn, status, body) when is_map(body) do
    send_json(conn, status, Jason.encode!(body))
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
    |> Plug.Conn.halt()
  end
end
