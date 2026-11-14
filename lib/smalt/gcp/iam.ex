defmodule Smalt.GCP.IAM do
  @moduledoc """
  IAM v1 (serviceAccounts, get/set IamPolicy with etag CAS, testIamPermissions)
  and Resource Manager v3 (projects get/search). State in :persistent_term,
  RMW serialized by `:global.trans/2`.
  """
  alias Smalt.GCP.Identity

  @roles %{
    "roles/viewer" => ~w(resourcemanager.projects.get iam.serviceAccounts.get iam.serviceAccounts.list),
    "roles/editor" => ~w(resourcemanager.projects.get iam.serviceAccounts.get iam.serviceAccounts.list iam.serviceAccounts.create)
  }

  def register_project(id, number \\ nil) do
    :persistent_term.put({__MODULE__, :project, id}, %{
      "name" => "projects/#{number || :erlang.phash2(id, 900_000_000) + 100_000_000}",
      "projectId" => id,
      "displayName" => id,
      "state" => "ACTIVE",
      "parent" => "organizations/0"
    })

    :ok
  end

  def projects do
    for {{__MODULE__, :project, _}, v} <- :persistent_term.get(), do: v
  end

  def create_service_account(project, account_id) do
    email = "#{account_id}@#{project}.iam.gserviceaccount.com"

    sa = %{
      "name" => "projects/#{project}/serviceAccounts/#{email}",
      "email" => email,
      "projectId" => project,
      "uniqueId" => Integer.to_string(:erlang.phash2(email, 4_294_967_296)),
      "displayName" => account_id
    }

    :persistent_term.put({__MODULE__, :sa, email}, sa)
    sa
  end

  def get_policy(resource) do
    :persistent_term.get({__MODULE__, :policy, resource}, nil) || with_etag(%{"version" => 1, "bindings" => []})
  end

  defp with_etag(p) do
    etag = :crypto.hash(:sha256, :erlang.term_to_binary(p["bindings"])) |> binary_part(0, 8) |> Base.encode64()
    Map.put(p, "etag", etag)
  end

  @doc "CAS set: {:ok, policy} | {:error, :aborted}"
  def set_policy(resource, policy) do
    :global.trans({{__MODULE__, resource}, self()}, fn ->
      cur = get_policy(resource)

      if policy["etag"] in [nil, cur["etag"]] do
        new = with_etag(%{"version" => policy["version"] || 1, "bindings" => policy["bindings"] || []})
        :persistent_term.put({__MODULE__, :policy, resource}, new)
        {:ok, new}
      else
        {:error, :aborted}
      end
    end)
  end

  def test_permissions(resource, perms, member) do
    granted =
      for b <- get_policy(resource)["bindings"], member in (b["members"] || []), p <- Map.get(@roles, b["role"], []), do: p

    Enum.filter(perms, &(&1 in granted))
  end

  def err(conn, status, code, msg),
    do: Identity.json(conn, status, %{error: %{code: status, message: msg, status: code}})

  ## ---- dispatch (host already resolved by Router) ----

  def serve(conn, :iam, ["v1", "projects", proj, "serviceAccounts"]) do
    case conn.method do
      "POST" ->
        id = conn.body_params["accountId"]
        if is_binary(id), do: Identity.json(conn, 200, create_service_account(proj, id)), else: err(conn, 400, "INVALID_ARGUMENT", "accountId required")

      _ ->
        accts = for {{__MODULE__, :sa, _}, %{"projectId" => ^proj} = v} <- :persistent_term.get(), do: v
        Identity.json(conn, 200, %{"accounts" => accts})
    end
  end

  def serve(conn, :iam, ["v1", "projects", proj, "serviceAccounts", rest]) do
    {email, action} = split_action(rest)

    case {conn.method, action, :persistent_term.get({__MODULE__, :sa, email}, nil)} do
      {_, _, nil} -> err(conn, 404, "NOT_FOUND", "Unknown service account")
      {"GET", nil, sa} -> Identity.json(conn, 200, sa)
      {"POST", "getIamPolicy", _} -> Identity.json(conn, 200, get_policy("sa:#{proj}/#{email}"))
      {"POST", "setIamPolicy", _} -> do_set(conn, "sa:#{proj}/#{email}")
      {"POST", "testIamPermissions", _} -> do_test(conn, "sa:#{proj}/#{email}")
      _ -> err(conn, 404, "NOT_FOUND", "no such method")
    end
  end

  def serve(conn, :crm, ["v3", "projects:search"]) do
    Identity.json(conn, 200, %{"projects" => projects()})
  end

  def serve(conn, :crm, ["v3", "projects", rest]) do
    {id, action} = split_action(rest)

    case {action, :persistent_term.get({__MODULE__, :project, id}, nil)} do
      {_, nil} -> err(conn, 403, "PERMISSION_DENIED", "Permission denied on resource project #{id}.")
      {nil, p} -> Identity.json(conn, 200, p)
      {"getIamPolicy", _} -> Identity.json(conn, 200, get_policy("project:#{id}"))
      {"setIamPolicy", _} -> do_set(conn, "project:#{id}")
      {"testIamPermissions", _} -> do_test(conn, "project:#{id}")
      _ -> err(conn, 404, "NOT_FOUND", "no such method")
    end
  end

  def serve(conn, _, _), do: err(conn, 404, "NOT_FOUND", "Method not found.")

  defp split_action(seg) do
    case String.split(seg, ":", parts: 2) do
      [a, b] -> {a, b}
      [a] -> {a, nil}
    end
  end

  defp do_set(conn, res) do
    case set_policy(res, conn.body_params["policy"] || %{}) do
      {:ok, p} -> Identity.json(conn, 200, p)
      {:error, :aborted} -> err(conn, 409, "ABORTED", "There were concurrent policy changes. Please retry the whole read-modify-write with exponential backoff.")
    end
  end

  defp do_test(conn, res) do
    member = conn.params["member"] || conn.body_params["member"] || ""
    perms = conn.body_params["permissions"] || []
    Identity.json(conn, 200, %{"permissions" => test_permissions(res, perms, member)})
  end
end
