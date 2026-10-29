defmodule Smalt.ArmGateway.Providers.ContainerGroupsRouter do
  @moduledoc """
  Pass-through provider plug for the ARM `Microsoft.ContainerInstance`
  control plane (T-10, window v26.10.28). Mounted in
  `Smalt.ArmGateway.Router` BEFORE `plug(:match)` (same composition style as
  `Smalt.EventGrid.PushRouterPlug` in the egress mux): `call/2` matches the
  containerGroups path shapes, answers them via
  `Smalt.DataPlane.ContainerGroups`, and returns the conn UNCHANGED for any
  other path — the main router never sees (and cannot mis-route) a shape
  this plug owns.

  Owned shapes (segment casing is matched case-insensitively; wire ids keep
  the client's casing):

      PUT/GET/DELETE /subscriptions/:sub/resourceGroups/:rg/providers/Microsoft.ContainerInstance/containerGroups/:name
      GET            /subscriptions/:sub/resourceGroups/:rg/providers/Microsoft.ContainerInstance/containerGroups
      GET            /subscriptions/:sub/providers/Microsoft.ContainerInstance/containerGroups
      GET            .../containerGroups/:name/containers/:container/logs   (typed refusal — never fake logs)

  - PUT validates the real containerGroup schema at the engine, 201 on
    create / 200 on the idempotent re-PUT.
  - GET renders the simulated control-plane-only lifecycle
    (`provisioningState: Succeeded` + `instanceView` Running).
  - LIST is the ARM list envelope (value + nextLink, page size 100,
    `maxitempages`/`$skip` exactly like the main router).
  - DELETE is an LRO: 202 + Location + Retry-After through
    `Smalt.ArmGateway.LRO` (the sweeper drives it terminal, `az container
    delete` completes).
  - The logs action answers `NotSupportedOnSubstrate` — execution is
    permanently out of scope per the design law, so no log stream is ever
    fabricated.
  - `api-version` is gated against the real ACI ladder
    (`ContainerGroups.api_versions/0`; the type has no Registry map row, so
    this plug carries the pin itself).

  Any DEEPER unknown shape under the containerGroups subtree is owned too —
  a typed 404 ResourceNotFound, never a fall-through to the unadmitted-type
  machinery of the main router. Every answer HALTS (Plug.Builder skips
  `:match` / `:dispatch` on a halted conn — no double dispatch); everything
  unmatched returns the conn untouched, unhalted.
  """

  @behaviour Plug

  alias Smalt.ArmGateway.LRO
  alias Smalt.DataPlane.ContainerGroups

  @page_size 100

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: path} = conn, _opts) do
    case shape(Enum.map(path, &String.downcase/1), path) do
      nil -> conn
      shape -> dispatch(conn, shape)
    end
  end

  def call(conn, _opts), do: conn

  # --- path shapes ---------------------------------------------------------------------

  # {downcased_path, original_path} -> owned shape | nil (pass through).
  defp shape(
         [
           "subscriptions",
           _sub,
           "resourcegroups",
           _rg,
           "providers",
           "microsoft.containerinstance",
           "containergroups" | _rest
         ],
         orig
       ) do
    {:rg, Enum.at(orig, 1), Enum.at(orig, 3), Enum.slice(orig, 7..-1//1)}
  end

  defp shape(
         ["subscriptions", _sub, "providers", "microsoft.containerinstance", "containergroups"],
         orig
       ) do
    {:sub_list, Enum.at(orig, 1)}
  end

  defp shape(_down, _orig), do: nil

  # --- dispatch --------------------------------------------------------------------------

  defp dispatch(conn, {:rg, sub, rg, rest}) do
    conn = Plug.Conn.fetch_query_params(conn)

    # Names come from the ORIGINAL segments (wire ids keep the client's
    # casing; only the structural segments match case-insensitively).
    case rest do
      [] ->
        case conn.method do
          "GET" -> handle_list(conn, sub, rg)
          _ -> method_not_allowed(conn)
        end

      [name] ->
        case conn.method do
          "PUT" -> handle_put_group(conn, sub, rg, name)
          "GET" -> handle_get_group(conn, sub, rg, name)
          "DELETE" -> handle_delete_group(conn, sub, rg, name)
          _ -> method_not_allowed(conn)
        end

      [name, seg, container, action] ->
        if String.downcase(seg) == "containers" and String.downcase(action) == "logs" do
          case conn.method do
            "GET" -> handle_logs(conn, sub, rg, name, container)
            _ -> method_not_allowed(conn)
          end
        else
          arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The requested containerGroups resource shape is not served by this control plane.",
            conn.request_path
          )
        end

      _other ->
        arm_error(
          conn,
          404,
          "ResourceNotFound",
          "The requested containerGroups resource shape is not served by this control plane.",
          conn.request_path
        )
    end
  end

  defp dispatch(conn, {:sub_list, sub}) do
    conn = Plug.Conn.fetch_query_params(conn)

    case conn.method do
      "GET" ->
        case check_api_version(conn) do
          :ok -> send_list(conn, ContainerGroups.list_groups_subscription(sub))
          {:respond, conn} -> conn
        end

      _ ->
        method_not_allowed(conn)
    end
  end

  # --- verbs ------------------------------------------------------------------------------

  defp handle_put_group(conn, sub, rg, name) do
    case check_api_version(conn) do
      :ok ->
        case request_body(conn) do
          {:ok, body, conn} ->
            case ContainerGroups.put_group(sub, rg, name, body) do
              {:ok, view, created?} ->
                send_json(conn, if(created?, do: 201, else: 200), Jason.encode!(view))

              {:error, code, message, target} ->
                arm_error(conn, 400, code, message, target)
            end

          {:error, conn} ->
            arm_error(
              conn,
              400,
              "InvalidRequestContent",
              "The request content was invalid and could not be deserialized."
            )
        end

      {:respond, conn} ->
        conn
    end
  end

  defp handle_get_group(conn, sub, rg, name) do
    case check_api_version(conn) do
      :ok ->
        case ContainerGroups.get_group(sub, rg, name) do
          {:ok, view} ->
            send_json(conn, 200, Jason.encode!(view))

          :error ->
            arm_error(conn, 404, "ResourceNotFound", "The Resource '#{name}' was not found.",
              ContainerGroups.group_wire_id(sub, rg, name))
        end

      {:respond, conn} ->
        conn
    end
  end

  # THE LAW (T-10): a delete is an ARM LRO — 202 + Location + Retry-After via
  # Smalt.ArmGateway.LRO (the sweeper flips it terminal; az container delete
  # completes), and the record is gone before the answer leaves.
  defp handle_delete_group(conn, sub, rg, name) do
    case check_api_version(conn) do
      :ok ->
        case ContainerGroups.delete_group(sub, rg, name) do
          :ok ->
            op = LRO.start_op(ContainerGroups.group_wire_id(sub, rg, name))
            authority = Smalt.Auth.Bearer.request_authority(conn)

            conn
            |> Plug.Conn.put_resp_header("location", "#{authority}#{op["id"]}")
            |> Plug.Conn.put_resp_header("retry-after", "1")
            |> send_json(202, "")

          :error ->
            arm_error(conn, 404, "ResourceNotFound", "The Resource '#{name}' was not found.",
              ContainerGroups.group_wire_id(sub, rg, name))
        end

      {:respond, conn} ->
        conn
    end
  end

  defp handle_list(conn, sub, rg) do
    case check_api_version(conn) do
      :ok -> send_list(conn, ContainerGroups.list_groups(sub, rg))
      {:respond, conn} -> conn
    end
  end

  # THE LAW (T-10, fail-closed): the logs action NEVER fabricates a log
  # stream. A missing group/container is an honest 404; an existing one
  # answers the typed NotSupportedOnSubstrate constant.
  defp handle_logs(conn, sub, rg, name, container) do
    case check_api_version(conn) do
      :ok ->
        case ContainerGroups.get_group(sub, rg, name) do
          {:ok, group} ->
            if container_exists?(group, container) do
              send_refusal(conn, ContainerGroups.logs_refusal(name, container))
            else
              arm_error(
                conn,
                404,
                "ResourceNotFound",
                "The container '#{container}' of container group '#{name}' was not found.",
                ContainerGroups.group_wire_id(sub, rg, name) <> "/containers/" <> container
              )
            end

          :error ->
            arm_error(conn, 404, "ResourceNotFound", "The Resource '#{name}' was not found.",
              ContainerGroups.group_wire_id(sub, rg, name))
        end

      {:respond, conn} ->
        conn
    end
  end

  defp container_exists?(group, container) do
    containers = get_in(group, ["properties", "containers"]) || []
    Enum.any?(containers, fn c -> is_map(c) and c["name"] == container end)
  end

  # --- api-version gate -------------------------------------------------------------------

  # The type carries NO Registry map row (T-10 ticket evidence), so the gate
  # pins the real ACI ladder carried by the engine (missing -> 400
  # MissingApiVersionParameter; unlisted -> 400 InvalidApiVersionParameter
  # naming the latest — the main router's vocabulary).
  defp check_api_version(conn) do
    version = conn.query_params["api-version"]

    cond do
      is_nil(version) ->
        {:respond,
         arm_error(
           conn,
           400,
           "MissingApiVersionParameter",
           "The api-version query parameter is required."
         )}

      version in ContainerGroups.api_versions() ->
        :ok

      true ->
        {:respond,
         arm_error(
           conn,
           400,
           "InvalidApiVersionParameter",
           "The api-version '#{version}' is invalid. The latest supported api-version for " <>
             "'#{ContainerGroups.full_type()}' is '#{ContainerGroups.latest_api_version()}'."
         )}
    end
  end

  # --- wire helpers -----------------------------------------------------------------------

  # Body seam, dual-mode: when the plug rides the main mux, Plug.Parsers has
  # already decoded the body into conn.body_params (and consumed the stream);
  # when dispatched in-process (the court), body_params is empty and the raw
  # body is read + decoded here. Decode rides the JsonCompat engine seam like
  # the rest of the gateway.
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

  # ARM list envelope with nextLink pagination: page size 100, `maxitempages`
  # (default 1) caps pages per response; when items remain the response
  # carries an absolute nextLink continuing at $skip (main-router law).
  defp send_list(conn, items) do
    skip = int_query_param(conn, "$skip", 0)
    pages = max(int_query_param(conn, "maxitempages", 1), 1)
    page = Enum.slice(items, skip, @page_size * pages)

    body =
      if length(items) > skip + length(page) do
        %{"value" => page, "nextLink" => next_link(conn, skip + length(page))}
      else
        %{"value" => page}
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
    query =
      conn.query_params
      |> Map.take(["api-version"])
      |> Map.put("maxitempages", Integer.to_string(max(int_query_param(conn, "maxitempages", 1), 1)))
      |> Map.put("$skip", skip)
      |> URI.encode_query()

    "#{Smalt.Auth.Bearer.request_authority(conn)}#{conn.request_path}?#{query}"
  end

  # ARM error envelope (C1 row 1b shape, shared with the main router):
  # target names the offending path when one exists; innererror present-but-
  # empty; api-version 400s carry no target (query-param failures have no
  # path component).
  defp arm_error(conn, status, code, message, target \\ nil)

  defp arm_error(conn, status, code, message, nil) do
    send_json(conn, status,
      Jason.encode!(%{"error" => %{"code" => code, "message" => message, "innererror" => %{}}})
    )
  end

  defp arm_error(conn, status, code, message, target) do
    send_json(
      conn,
      status,
      Jason.encode!(%{
        "error" => %{"code" => code, "message" => message, "target" => target, "innererror" => %{}}
      })
    )
  end

  # The typed refusal constant rendered verbatim as the error envelope (the
  # logs law: the constant reaches the wire unrewritten).
  defp send_refusal(conn, refusal) do
    send_json(conn, 400, Jason.encode!(%{"error" => refusal}))
  end

  defp method_not_allowed(conn) do
    arm_error(conn, 405, "MethodNotAllowed", "The method is not allowed on this resource.",
      conn.request_path)
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
    # Pass-through protocol: a HALTED conn makes Plug.Builder skip the rest
    # of the gateway chain (:match / :dispatch never run on an answered conn
    # — dispatching again would be an AlreadySentError crash). Every answer
    # this plug renders funnels through here, so every owned shape halts.
    |> Plug.Conn.halt()
  end
end
