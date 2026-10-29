defmodule Smalt.ArmGateway.Providers.ResourceHealthRouter do
  @moduledoc """
  T-14 pass-through ARM mux for `Microsoft.ResourceHealth` (service health
  lane): mounted BEFORE `:match` on `Smalt.ArmGateway.Router` (see the
  r12-t14 receipt wiring patch), it answers the Microsoft.ResourceHealth
  faces through the chaos-coupled engine (`Smalt.DataPlane.ResourceHealth`)
  and falls through UNCHANGED for every other path.

  ## Faces

      GET /subscriptions/:sub/resourceGroups/:rg/providers/Microsoft.ResourceHealth/availabilityStatuses
      GET /subscriptions/:sub/providers/Microsoft.ResourceHealth/events
      GET /subscriptions/:sub/resourceGroups/:rg/providers/Microsoft.ResourceHealth/events
      GET /subscriptions/:sub/resourceGroups/:rg/providers/{type}/{name}/providers/Microsoft.ResourceHealth/availabilityStatuses/current
      GET /subscriptions/:sub/resourceGroups/:rg/providers/{type}/{name}/providers/Microsoft.ResourceHealth/availabilityStatuses

  (both `resourceGroups` and `resourcegroups` casing, mirroring the main
  router's convention).

  ## Precedence law (per-resource faces)

  The per-resource availabilityStatuses faces compose with the pre-existing
  V9 computed-health lane (`Smalt.ArmGateway.ResourceHealth` +
  `Smalt.Arm.ResourceHealth`): if the chaos engine OWNS the resource's
  state (explicit transition record or the `:resource_health_unavailable`
  marker — `Engine.chaos_status/1`), the engine's row answers; otherwise
  the V9 seam answers, so recorded `:smalt_arm_health` transitions and the
  synthetic-Available law stay byte-identical and the V9 court remains
  green. The RG-scope list and both events faces are new here and are
  served purely by the engine.

  ## Gate law

  `api-version` presence is enforced exactly like the V9 faces (the
  registry carries no Microsoft.ResourceHealth entry, so under the default
  non-strict gate any well-formed version passes; missing -> 400
  MissingApiVersionParameter). Scope existence is honoured at the scope
  faces: unknown subscription -> 404 SubscriptionNotFound, unknown RG ->
  404 ResourceGroupNotFound (same envelope vocabulary as the main router).
  """

  import Plug.Conn

  alias Smalt.ArmGateway.ResourceHealth, as: Seam
  alias Smalt.DataPlane.ResourceHealth, as: Engine
  alias Smalt.Store

  def init(opts), do: opts

  # -- pass-through entry -------------------------------------------------------

  def call(%Plug.Conn{path_info: ["subscriptions", sub, rg_seg, rg | tail]} = conn, _opts)
      when rg_seg in ["resourceGroups", "resourcegroups"] do
    conn = Plug.Conn.fetch_query_params(conn)

    cond do
      tail == ["providers", "Microsoft.ResourceHealth", "availabilityStatuses"] ->
        availability_scope(conn, sub, rg)

      tail == ["providers", "Microsoft.ResourceHealth", "events"] ->
        events_scope(conn, sub, rg)

      true ->
        case split_resource_face(tail) do
          {:current, type_and_name} -> availability_current(conn, sub, rg, type_and_name)
          {:list, type_and_name} -> availability_list_resource(conn, sub, rg, type_and_name)
          :miss -> conn
        end
    end
  end

  def call(
        %Plug.Conn{
          path_info: ["subscriptions", sub, "providers", "Microsoft.ResourceHealth", "events"]
        } = conn,
        _opts
      ) do
    conn = Plug.Conn.fetch_query_params(conn)
    events_subscription(conn, sub)
  end

  # NOT a Microsoft.ResourceHealth face: pass through unchanged so the main
  # router's plugs and :match/:dispatch own it (byte-identical pass-through).
  def call(conn, _opts), do: conn

  # -- per-resource faces (engine-first, V9 seam fallback) ------------------------

  defp availability_current(conn, sub, rg, type_and_name) do
    case gate(conn) do
      :cont ->
        rid = resource_id(sub, rg, type_and_name)

        case Engine.chaos_status(rid) do
          {:ok, rec} ->
            ok(conn, Engine.availability_wire(rec))

          :error ->
            {type, name} = type_and_name(type_and_name)
            render(conn, Seam.get_current(sub, rg, type, name))
        end

      {:respond, conn} -> conn
    end
  end

  defp availability_list_resource(conn, sub, rg, type_and_name) do
    case gate(conn) do
      :cont ->
        rid = resource_id(sub, rg, type_and_name)

        case Engine.chaos_status(rid) do
          {:ok, rec} ->
            ok(conn, %{"value" => [Engine.availability_wire(rec)]})

          :error ->
            {type, name} = type_and_name(type_and_name)
            render(conn, Seam.list_for_resource(sub, rg, type, name))
        end

      {:respond, conn} -> conn
    end
  end

  # -- scope faces (pure engine) -------------------------------------------------

  defp availability_scope(conn, sub, rg) do
    case gate(conn) do
      :cont ->
        case rg_exists?(sub, rg) do
          true ->
            ok(conn, %{
              "value" =>
                rg_id(sub, rg)
                |> Engine.list()
                |> Enum.map(&Engine.availability_wire/1)
            })

          false ->
            rg_not_found(conn, sub, rg)
        end

      {:respond, conn} -> conn
    end
  end

  defp events_scope(conn, sub, rg) do
    case gate(conn) do
      :cont ->
        case rg_exists?(sub, rg) do
          true ->
            ok(conn, %{
              "value" =>
                rg_id(sub, rg)
                |> Engine.events()
                |> Enum.map(&Engine.event_wire/1)
            })

          false ->
            rg_not_found(conn, sub, rg)
        end

      {:respond, conn} -> conn
    end
  end

  defp events_subscription(conn, sub) do
    case gate(conn) do
      :cont ->
        case Store.get(:smalt_subscriptions, sub) do
          {:ok, _sub} ->
            ok(conn, %{
              "value" =>
                "/subscriptions/#{sub}"
                |> Engine.events()
                |> Enum.map(&Engine.event_wire/1)
            })

          :error ->
            arm_error(conn, 404, "SubscriptionNotFound", "The subscription '#{sub}' could not be found.")
        end

      {:respond, conn} -> conn
    end
  end

  # -- helpers -------------------------------------------------------------------

  # api-version presence gate (registry has no ResourceHealth entry; default
  # non-strict mode passes any value — identical to the V9 faces' behavior).
  defp gate(conn) do
    case conn.query_params["api-version"] do
      nil ->
        {:respond,
         arm_error(conn, 400, "MissingApiVersionParameter", "The api-version query parameter is required.")}

      _version ->
        :cont
    end
  end

  defp render(conn, {:ok, 200, env}), do: ok(conn, env)
  defp render(conn, {:error, 404, err}), do: arm_error(conn, 404, err["error"]["code"], err["error"]["message"])

  defp ok(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
    |> halt()
  end

  defp arm_error(conn, status, code, message) do
    body =
      Jason.encode!(%{
        "error" => %{
          "code" => code,
          "message" => message,
          # Real AAD/ARM shape: innererror present-but-empty when there is
          # nothing further to nest (send_arm_error law of the main router).
          "innererror" => %{}
        }
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end

  # Per-resource face suffixes: [..., "providers", "Microsoft.ResourceHealth",
  # "availabilityStatuses"(| "/current")]. The front must carry at least a
  # provider ns + one type segment + the name (>= 3 segments).
  defp split_resource_face(tail) do
    case Enum.split(tail, -4) do
      {front, ["providers", "Microsoft.ResourceHealth", "availabilityStatuses", "current"]} ->
        face(front, :current)

      _ ->
        case Enum.split(tail, -3) do
          {front, ["providers", "Microsoft.ResourceHealth", "availabilityStatuses"]} ->
            face(front, :list)

          _ ->
            :miss
        end
    end
  end

  defp face(front, kind) when length(front) >= 3, do: {kind, front}
  defp face(_front, _kind), do: :miss

  defp type_and_name(front) do
    name = List.last(front)

    type =
      front
      |> Enum.slice(0..-2//1)
      |> Enum.join("/")

    {type, name}
  end

  defp resource_id(sub, rg, type_and_name) do
    {type, name} = type_and_name(type_and_name)
    "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/#{type}/#{name}"
  end

  defp rg_id(sub, rg), do: "/subscriptions/#{sub}/resourceGroups/#{rg}"

  # RG scope faces honour scope existence with the main router's vocabulary
  # (:smalt_resource_groups, downcased id key — do_rg_get law).
  defp rg_exists?(sub, rg) do
    match?({:ok, _}, Store.get(:smalt_resource_groups, String.downcase(rg_id(sub, rg))))
  end

  defp rg_not_found(conn, sub, rg) do
    arm_error(conn, 404, "ResourceGroupNotFound", "Resource group '#{rg}' could not be found.")
  end
end
