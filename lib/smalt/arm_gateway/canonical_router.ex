defmodule Smalt.ArmGateway.CanonicalRouter do
  @moduledoc """
  Ash-dispatched ARM child-resource face (wave v26.10.29, W2).

  Pass-through plug mounted immediately before `plug(:match)` in
  `Smalt.ArmGateway.Router` (same seam as FunctionsRouter, r13). Claims ONLY
  deep provider-child shapes that today fall through to the catch-all
  `match _` -> `RouteNotFound` (router.ex), and only when every clause holds:

  1. `config :smalt, :ash_gateway` is truthy — DEFAULT OFF (W5), so the mount
     is inert until courts pass;
  2. `conn.halted == false` and method in PUT/GET/PATCH/DELETE;
  3. path shape `/subscriptions/:sub/resourceGroups/:rg/providers/:ns/<rest>`;
  4. `rest` has >= 3 segments and its 3rd segment is not "providers" — the
     existing router families own `[type]` (LIST), `[type, name]` (CRUD) and
     `[type, name, "providers" | _]` (nested), so they always win;
  5. `{ns, type_path}` resolves via `Smalt.AshGen.Registry` (longest-first),
     guarded by `Code.ensure_loaded?/1` — a missing generated registry
     degrades to full pass-through, never a compile error.

  Existing routes win structurally: pre-`:match` plugs cannot consult the
  matcher, so clause 4 encodes the exclusion list. Drift contract: any future
  route that covers a deeper shape must extend the claim predicate here, or
  this plug shadows it (same seam contract as the r13 provider receipts).

  Parity posture: shape-shallow (KD-188) — arm_id/name/location/tags/
  properties envelope only; policies are KD-189 (flag-on prerequisite).
  """

  @behaviour Plug

  @claim_methods ["PUT", "GET", "PATCH", "DELETE"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(
        %Plug.Conn{halted: false, method: method, path_info: ["subscriptions", sub, rg_seg, rg, "providers", ns | rest]} =
          conn,
        _opts
      )
      when method in @claim_methods and length(rest) >= 3 and
             (rg_seg == "resourceGroups" or rg_seg == "resourcegroups") do
    # Claim ladder (clauses 4–6):
    #   exclusion: [type, name, "providers" | _] = existing nested family;
    #   api-version presence required (absence passes to the legacy 400,
    #   byte-parity);
    #   no-shadowing: the top-level type must NOT be legacy-admitted —
    #   legacy Registry types keep every face they own (deep child paths of
    #   admitted tops are answered by the legacy child family, witnessed in
    #   the court); the Ash face serves only the bicep-expanded type set
    #   (181 of 201 Network type-paths, receipted).
    if claim?(conn, ns, rest) do
      case resolve(ns, rest) do
        nil -> conn
        {resource_module, _api_version} -> dispatch(conn, resource_module, sub, rg, ns, rest)
      end
    else
      conn
    end
  end

  defp claim?(conn, ns, rest) do
    length(rest) >= 3 and
      not match?([_t1, _n1, "providers" | _], rest) and
      conn.query_string =~ "api-version=" and
      gateway_enabled?() and
      registry_ready?() and
      legacy_free?(ns, rest)
  end

  defp legacy_free?(ns, rest) do
    top = rest |> Enum.take_every(2) |> hd()
    not Smalt.Registry.admitted?(ns <> "/" <> top)
  end

  def call(conn, _opts), do: conn

  defp gateway_enabled?, do: Application.get_env(:smalt, :ash_gateway, false) in [true, "true"]

  defp registry_ready? do
    Code.ensure_loaded?(Smalt.AshGen.Registry) and
      function_exported?(Smalt.AshGen.Registry, :lookup, 2)
  end

  # rest = [type, name, childType, childName, ...] — type_path candidates
  # longest-first ("a/b" before "a").
  defp resolve(ns, rest) do
    type_segs = Enum.take_every(rest, 2)

    Enum.find_value(length(type_segs)..1//-1, fn take ->
      Smalt.AshGen.Registry.lookup(ns, type_segs |> Enum.take(take) |> Enum.join("/"))
    end)
  end

  defp arm_id(sub, rg, ns, rest) do
    "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/#{ns}/#{Enum.join(rest, "/")}"
    |> String.downcase()
  end

  defp dispatch(conn, resource_module, sub, rg, ns, rest) do
    id = arm_id(sub, rg, ns, rest)

    case conn.method do
      m when m in ["PUT", "PATCH"] -> arm_put(conn, resource_module, id, rest)
      "GET" -> arm_get(conn, resource_module, id, rest)
      "DELETE" -> arm_delete(conn, resource_module, id)
    end
  end

  defp arm_put(conn, resource_module, id, rest) do
    body = conn.body_params || %{}

    attrs = %{
      arm_id: id,
      name: List.last(rest),
      location: body["location"],
      tags: body["tags"] || %{},
      properties: body["properties"] || %{}
    }

    case Ash.create(resource_module, attrs, action: :arm_put) do
      {:ok, record} ->
        conn |> put_json() |> send_resp(201, Jason.encode!(envelope(record, resource_module)))

      {:error, %Ash.Error.Invalid{} = err} ->
        conn
        |> put_json()
        |> send_resp(400, Jason.encode!(%{"error" => %{"code" => "InvalidResource", "message" => message(err)}}))

      {:error, other} ->
        conn
        |> put_json()
        |> send_resp(500, Jason.encode!(%{"error" => %{"code" => "AshError", "message" => inspect(other)}}))
    end
  end

  defp arm_get(conn, resource_module, id, rest) do
    if rem(length(rest), 2) == 0 do
      q = Ash.Query.for_read(resource_module, :get_by_arm_id, %{arm_id: id})

      case Ash.read(q) do
        {:ok, [record]} ->
          conn |> put_json() |> send_resp(200, Jason.encode!(envelope(record, resource_module)))

        {:ok, []} ->
          conn
          |> put_json()
          |> send_resp(404, Jason.encode!(%{"error" => %{"code" => "ResourceNotFound", "message" => id}}))

        {:error, err} ->
          conn |> put_json() |> send_resp(500, Jason.encode!(%{"error" => %{"message" => inspect(err)}}))
      end
    else
      # collection under a parent: prefix scan over the ETS datalayer
      prefix = id <> "/"

      case Ash.read(resource_module) do
        {:ok, records} ->
          matched = Enum.filter(records, &(String.starts_with?(&1.arm_id, prefix)))
          conn |> put_json() |> send_resp(200, Jason.encode!(%{"value" => Enum.map(matched, &envelope(&1, resource_module))}))

        {:error, err} ->
          conn |> put_json() |> send_resp(500, Jason.encode!(%{"error" => %{"message" => inspect(err)}}))
      end
    end
  end

  defp arm_delete(conn, resource_module, id) do
    q = Ash.Query.for_read(resource_module, :get_by_arm_id, %{arm_id: id})

    with {:ok, [record]} <- Ash.read(q),
         :ok <- Ash.destroy(record, action: :arm_delete) do
      conn |> put_json() |> send_resp(200, Jason.encode!(%{"status" => "Deleted"}))
    else
      {:ok, []} ->
        conn |> put_json() |> send_resp(404, Jason.encode!(%{"error" => %{"code" => "ResourceNotFound", "message" => id}}))

      err ->
        conn |> put_json() |> send_resp(500, Jason.encode!(%{"error" => %{"message" => inspect(err)}}))
    end
  end

  defp envelope(record, resource_module) do
    %{
      "id" => record.arm_id,
      "name" => record.name,
      "type" => resource_module |> Module.split() |> Enum.drop(2) |> Enum.join("/"),
      "location" => record.location,
      "tags" => record.tags,
      "properties" => record.properties,
      "provisioningState" => record.provisioning_state
    }
  end

  defp message(err), do: inspect(err)
  defp put_json(conn), do: Plug.Conn.put_resp_content_type(conn, "application/json")
  defp send_resp(conn, status, body), do: conn |> Plug.Conn.send_resp(status, body) |> Plug.Conn.halt()
end
