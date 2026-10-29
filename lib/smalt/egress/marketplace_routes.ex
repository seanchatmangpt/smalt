defmodule Smalt.Egress.MarketplaceRoutes do
  @moduledoc """
  AZURE-FIDELITY lane 8: Microsoft-documented Marketplace SaaS fulfillment
  face (default OFF — with the plane disabled every conn passes through
  un-halted and un-sent, so the substrate wire is byte-identical to the
  pre-lane behavior).

  Enable:

      config :smalt, :marketplace_saas,
        enabled: true,
        publisher_token: "loopback-publisher-secret",   # nil = auth open (loopback)
        tokens: %{"purchase-token-1" => purchase}

  `tokens` maps an `x-ms-marketplace-token` to the documented purchase
  record (id, subscriptionName, publisherId, offerId, planId, quantity).

  Wire shape (learn.microsoft.com partner-center/marketplace-offers
  "SaaS fulfillment Subscription APIs v2", `api-version=2018-08-31`, and
  the metering twin "Marketplace Metering Service usageEvent API"):

      POST  /saas/subscriptions/resolve?api-version=2018-08-31
            authorization: Bearer <publisher token>
            x-ms-marketplace-token: <purchase token>
      POST  /saas/subscriptions/{id}/activate?api-version=2018-08-31
            {"planId": "silver"}
      GET   /saas/subscriptions/{id}?api-version=2018-08-31
      GET   /saas/subscriptions/{id}/operations?api-version=2018-08-31
      PATCH /saas/subscriptions/{id}/operations/{opId}?api-version=2018-08-31
            {"status": "Success" | "Failure"}
      POST  /saas/usageEvent?api-version=2018-08-31   (metering twin)
            {"resourceId": "<subscriptionId>", "quantity": 5,
             "dimension": "d", "planId": "silver", "requestId": "..."}
      POST  /saas/operations?api-version=2018-08-31   (webhook record face)

  Contract (each status is a documented response class on the cited pages):

    * Resolve — 200 with the documented payload (`id`, `subscriptionName`,
      `offerId`, `planId`, `quantity`, nested `subscription` carrying
      `saasSubscriptionStatus: "PendingFulfillmentStart"`); missing or
      malformed `x-ms-marketplace-token` is 400 (documented: token missing,
      malformed, invalid, or expired); a token with no configured purchase
      record is 404; missing/mistyped bearer is 401.
    * Activate — 200 EMPTY body (documented: "There's no response body for
      this call"); unknown subscription is 404; activate on a subscription
      not in `PendingFulfillmentStart` is 409 Conflict (illegal state
      transition); a `planId` that differs from the resolved plan is 400
      (documented "Bad request: validation failed").
    * Operations — GET lists the subscription's operation objects in the
      documented shape (`id`, `activityId`, `subscription`, `offerId`,
      `planId`, `quantity`, `timeStamp`, `action`, `status`); PATCH flips a
      non-terminal operation to `"Success"` / `"Failure"` and answers 200
      `{"operationStatus": ...}`; any other status value is 400; unknown
      subscription or operation is 404; PATCH on an already-terminal
      operation is 409 Conflict.
    * Meter — only a `Subscribed` subscription is meterable; a meter on a
      subscription that is not active is the documented 409
      (`ClientConflict`); a first usage event answers 200
      `status: "Accepted"`, an exact `requestId` replay answers
      `status: "Duplicate"` (documented replay semantics).
    * State machine — `PendingFulfillmentStart -> Subscribed` is the only
      transition this surface owns; it is one-way and single-step.

  State lives in the named ETS table `:smalt_marketplace_saas` (created
  lazily on first enabled request, same discipline as the EH partition
  store). This router is a w6R fallthrough sub-router: unmatched conns
  pass through untouched.
  """

  use Plug.Router
  plug :match
  plug :dispatch

  @api_version "2018-08-31"
  @table :smalt_marketplace_saas

  # Every arm: disabled -> pass through un-halted/un-sent (w6R miss discipline);
  # sent -> halt so the conn never reaches the blob splat (kd07 class).
  post "/saas/subscriptions/resolve" do
    conn = if enabled?(), do: resolve(conn), else: conn
    halt_if_sent(conn)
  end

  post "/saas/subscriptions/:id/activate" do
    conn = if enabled?(), do: activate(conn, id), else: conn
    halt_if_sent(conn)
  end

  get "/saas/subscriptions/:id" do
    conn = if enabled?(), do: get_subscription(conn, id), else: conn
    halt_if_sent(conn)
  end

  post "/saas/operations" do
    conn = if enabled?(), do: record_operation(conn), else: conn
    halt_if_sent(conn)
  end

  get "/saas/subscriptions/:id/operations" do
    conn = if enabled?(), do: list_operations(conn, id), else: conn
    halt_if_sent(conn)
  end

  patch "/saas/subscriptions/:id/operations/:op_id" do
    conn = if enabled?(), do: patch_operation(conn, id, op_id), else: conn
    halt_if_sent(conn)
  end

  post "/saas/usageEvent" do
    conn = if enabled?(), do: usage_event(conn), else: conn
    halt_if_sent(conn)
  end

  # Fallthrough: unmatched conns pass through un-halted and un-sent — the w6R
  # sub-router miss discipline.
  match _ do
    conn
  end

  # This delegator must stop the chain the moment a response is on the wire:
  # a sent-but-un-halted conn falls through to the main router's blob splat
  # (AlreadySentError, kd07 class, witnessed lane E1 2026-10-20).
  defp halt_if_sent(conn) do
    if conn.state in [:sent, :chunked] or conn.halted do
      Plug.Conn.halt(conn)
    else
      conn
    end
  end

  # ---------------------------------------------------------------------------
  # resolve
  # ---------------------------------------------------------------------------

  defp resolve(conn) do
    with :ok <- ensure_table(),
         :ok <- bearer(conn),
         :ok <- api_version(conn),
         {:ok, token, purchase} <- marketplace_token(conn) do
      sub_id = purchase["id"]

      sub = %{
        "id" => sub_id,
        "publisherId" => purchase["publisherId"],
        "offerId" => purchase["offerId"],
        "planId" => purchase["planId"],
        "quantity" => purchase["quantity"],
        "name" => purchase["subscriptionName"],
        "status" => "PendingFulfillmentStart",
        "term" => nil,
        "operations" => %{},
        "usage" => []
      }

      true = :ets.insert(@table, {sub_id, sub})
      true = :ets.insert(@table, {{:token, token}, sub_id})

      send_json(conn, 200, %{
        "id" => sub_id,
        "subscriptionName" => purchase["subscriptionName"],
        "offerId" => purchase["offerId"],
        "planId" => purchase["planId"],
        "quantity" => purchase["quantity"],
        "subscription" => %{
          "id" => sub_id,
          "publisherId" => purchase["publisherId"],
          "offerId" => purchase["offerId"],
          "name" => purchase["subscriptionName"],
          "planId" => purchase["planId"],
          "quantity" => purchase["quantity"],
          "saasSubscriptionStatus" => "PendingFulfillmentStart"
        }
      })
    else
      {:resp, status, body} -> send_json(conn, status, body)
    end
  end

  # ---------------------------------------------------------------------------
  # activate — the PendingFulfillmentStart -> Subscribed edge
  # ---------------------------------------------------------------------------

  defp activate(conn, id) do
    with :ok <- ensure_table(),
         :ok <- bearer(conn),
         :ok <- api_version(conn),
         {:ok, sub} <- fetch_sub(id),
         {:ok, body} <- json_body(conn),
         :ok <- plan_matches(sub, body),
         :ok <- transition(sub, "Subscribed") do
      sub =
        sub
        |> Map.put("status", "Subscribed")
        |> Map.put("term", %{
          "termUnit" => "P1M",
          "startDate" => now_iso(),
          "endDate" => now_iso()
        })
        |> put_operation(%{
          "id" => uuid(),
          "activityId" => uuid(),
          "subscription" => %{"id" => id, "name" => sub["name"]},
          "offerId" => sub["offerId"],
          "publisherId" => sub["publisherId"],
          "planId" => sub["planId"],
          "quantity" => sub["quantity"],
          "timeStamp" => now_iso(),
          "action" => "Activate",
          "status" => "InProgress"
        })

      true = :ets.insert(@table, {id, sub})

      # documented: "There's no response body for this call."
      send_resp(conn, 200, "")
    else
      {:resp, status, body} -> send_json(conn, status, body)
    end
  end

  # ---------------------------------------------------------------------------
  # get subscription
  # ---------------------------------------------------------------------------

  defp get_subscription(conn, id) do
    with :ok <- ensure_table(),
         :ok <- bearer(conn),
         :ok <- api_version(conn),
         {:ok, sub} <- fetch_sub(id) do
      send_json(conn, 200, wire_subscription(sub))
    else
      {:resp, status, body} -> send_json(conn, status, body)
    end
  end

  # ---------------------------------------------------------------------------
  # operations: webhook record face + list + success/failure patch
  # ---------------------------------------------------------------------------

  defp record_operation(conn) do
    with :ok <- ensure_table(),
         :ok <- bearer(conn),
         :ok <- api_version(conn),
         {:ok, body} <- json_body(conn),
         {:ok, sub} <- fetch_sub(get_in(body, ["subscription", "id"])) do
      op = %{
        "id" => uuid(),
        "activityId" => uuid(),
        "subscription" => %{"id" => sub["id"], "name" => sub["name"]},
        "offerId" => body["offerId"] || sub["offerId"],
        "publisherId" => sub["publisherId"],
        "planId" => body["planId"] || sub["planId"],
        "quantity" => body["quantity"] || sub["quantity"],
        "timeStamp" => now_iso(),
        "action" => body["action"] || "Activate",
        "status" => "InProgress"
      }

      true = :ets.insert(@table, {sub["id"], put_operation(sub, op)})
      send_json(conn, 200, op)
    else
      {:resp, status, body} -> send_json(conn, status, body)
    end
  end

  defp list_operations(conn, id) do
    with :ok <- ensure_table(),
         :ok <- bearer(conn),
         :ok <- api_version(conn),
         {:ok, sub} <- fetch_sub(id) do
      ops =
        sub["operations"]
        |> Map.values()
        |> Enum.sort_by(& &1["timeStamp"])

      send_json(conn, 200, %{"operations" => ops})
    else
      {:resp, status, body} -> send_json(conn, status, body)
    end
  end

  defp patch_operation(conn, id, op_id) do
    with :ok <- bearer(conn),
         :ok <- api_version(conn),
         {:ok, sub} <- fetch_sub(id),
         {:ok, body} <- json_body(conn),
         {:ok, verdict} <- patch_status(body),
         {:ok, op} <- fetch_op(sub, op_id),
         :ok <- op_not_terminal(op) do
      true = :ets.insert(@table, {id, put_operation(sub, Map.put(op, "status", verdict))})
      send_json(conn, 200, %{"operationStatus" => verdict})
    else
      {:resp, status, body} -> send_json(conn, status, body)
    end
  end

  # ---------------------------------------------------------------------------
  # meter (Marketplace Metering Service usageEvent wire shape)
  # ---------------------------------------------------------------------------

  defp usage_event(conn) do
    with :ok <- ensure_table(),
         :ok <- bearer(conn),
         :ok <- api_version(conn),
         {:ok, body} <- json_body(conn),
         {:ok, sub} <- fetch_sub(body["resourceId"]),
         :ok <- meterable(sub) do
      case Enum.find(sub["usage"], &(&1["requestId"] == body["requestId"])) do
        nil ->
          event = %{
            "usageEventId" => uuid(),
            "requestId" => body["requestId"],
            "dimension" => body["dimension"],
            "quantity" => body["quantity"],
            "planId" => body["planId"] || sub["planId"],
            "messageTime" => now_iso(),
            "status" => "Accepted"
          }

          true = :ets.insert(@table, {sub["id"], Map.update!(sub, "usage", &[event | &1])})

          send_json(conn, 200, %{
            "usageEventId" => event["usageEventId"],
            "messageTime" => event["messageTime"],
            "status" => "Accepted"
          })

        prev ->
          # documented replay semantics: the same requestId answers Duplicate
          send_json(conn, 200, %{
            "usageEventId" => prev["usageEventId"],
            "messageTime" => prev["messageTime"],
            "status" => "Duplicate"
          })
      end
    else
      {:resp, status, body} -> send_json(conn, status, body)
    end
  end

  # ---------------------------------------------------------------------------
  # guards
  # ---------------------------------------------------------------------------

  defp enabled? do
    Application.get_env(:smalt, :marketplace_saas, [])[:enabled] == true
  end

  defp ensure_table do
    if :ets.info(@table) == :undefined do
      try do
        # The creating process is a Bandit request process (dies with the
        # connection), so the table needs an heir that outlives it — a plain
        # long-lived holder spawned on first use.
        heir =
          spawn(fn ->
            Process.sleep(:infinity)
          end)

        :ets.new(@table, [:set, :named_table, :public, read_concurrency: true, heir: heir])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp bearer(conn) do
    required = Application.get_env(:smalt, :marketplace_saas, [])[:publisher_token]
    header = conn |> get_req_header("authorization") |> List.first()

    cond do
      is_nil(required) ->
        :ok

      is_nil(header) ->
        {:resp, 401,
         %{"error" => %{"code" => "Unauthorized", "message" => "missing authorization token"}}}

      header != "Bearer " <> required ->
        {:resp, 401,
         %{"error" => %{"code" => "Unauthorized", "message" => "invalid authorization token"}}}

      true ->
        :ok
    end
  end

  defp api_version(conn) do
    if String.contains?(conn.query_string || "", "api-version=#{@api_version}") do
      :ok
    else
      {:resp, 400,
       %{"error" => %{"code" => "InvalidApiVersion",
                      "message" => "api-version must be #{@api_version}"}}}
    end
  end

  defp marketplace_token(conn) do
    case get_req_header(conn, "x-ms-marketplace-token") do
      [token | _] ->
        tokens = Application.get_env(:smalt, :marketplace_saas, [])[:tokens] || %{}

        case Map.fetch(tokens, token) do
          {:ok, purchase} -> {:ok, token, purchase}
          :error ->
            {:resp, 404,
             %{"error" => %{"code" => "SubscriptionNotFound",
                            "message" => "no subscription found for the marketplace token"}}}
        end

      _ ->
        {:resp, 400,
         %{"error" => %{"code" => "InvalidArgument",
                        "message" => "x-ms-marketplace-token is missing, malformed, invalid, or expired"}}}
    end
  end

  # D1 lane (athena differential D1, disclosed minimal fix): the egress
  # pipeline's route-conditional `maybe_parse_body/2` (Plug.Parsers
  # [:json, :urlencoded]) CONSUMES the raw body for JSON content-types into
  # `conn.body_params` (string keys), so a raw `Plug.Conn.read_body/1` here
  # sees "" and every content-type: application/json request answered
  # 400 "invalid JSON body" (reproduced over real TCP by the athena wire
  # runner; the in-process court missed it because its raw gen_tcp helper
  # sends no content-type). Prefer the parsed body; fall back to the raw
  # stream for clients that send no parseable content-type (court helper).
  defp json_body(conn) do
    case parsed_or_raw_body(conn) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ ->
        {:resp, 400,
         %{"error" => %{"code" => "InvalidArgument", "message" => "invalid JSON body"}}}
    end
  end

  defp parsed_or_raw_body(conn) do
    already =
      case conn.body_params do
        %Plug.Conn.Unfetched{} -> nil
        params when is_map(params) and map_size(params) > 0 -> params
        _ -> nil
      end

    if already do
      {:ok, already}
    else
      case Plug.Conn.read_body(conn) do
        {:ok, body, _conn} -> Jason.decode(body)
        _ -> {:error, :unreadable}
      end
    end
  end

  defp fetch_sub(id) do
    case :ets.lookup(@table, id) do
      [{^id, sub}] -> {:ok, sub}
      [] ->
        {:resp, 404,
         %{"error" => %{"code" => "SubscriptionNotFound",
                        "message" => "SaaS subscription with the specified subscriptionId can't be found"}}}
    end
  end

  # documented: 400 Bad request, validation failed — plan mismatch
  defp plan_matches(sub, body) do
    if body["planId"] == sub["planId"] do
      :ok
    else
      {:resp, 400,
       %{"error" => %{"code" => "BadRequest",
                      "message" => "validation failed: planId does not match the resolved plan"}}}
    end
  end

  # The state machine: PendingFulfillmentStart -> Subscribed is the only edge.
  defp transition(sub, "Subscribed") do
    if sub["status"] == "PendingFulfillmentStart" do
      :ok
    else
      {:resp, 409,
       %{"error" => %{"code" => "Conflict",
                      "message" => "illegal transition #{sub["status"]} -> Subscribed"}}}
    end
  end

  defp fetch_op(sub, op_id) do
    case Map.fetch(sub["operations"], op_id) do
      {:ok, op} -> {:ok, op}
      :error ->
        {:resp, 404,
         %{"error" => %{"code" => "OperationNotFound", "message" => "operation can't be found"}}}
    end
  end

  defp op_not_terminal(op) do
    if op["status"] in ["Success", "Failure"] do
      {:resp, 409,
       %{"error" => %{"code" => "Conflict",
                      "message" => "operation is already in a terminal state"}}}
    else
      :ok
    end
  end

  defp patch_status(body) do
    case body["status"] do
      s when s in ["Success", "Failure"] ->
        {:ok, s}

      _ ->
        {:resp, 400,
         %{"error" => %{"code" => "InvalidArgument",
                        "message" => "status must be Success or Failure"}}}
    end
  end

  # documented metering 409 class: ClientConflict — subscription not active
  defp meterable(sub) do
    if sub["status"] == "Subscribed" do
      :ok
    else
      {:resp, 409,
       %{"error" => %{"code" => "ClientConflict",
                      "message" => "subscription is not active (status: #{sub["status"]})"}}}
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp put_operation(sub, op) do
    Map.update(sub, "operations", %{op["id"] => op}, &Map.put(&1, op["id"], op))
  end

  defp wire_subscription(sub) do
    %{
      "id" => sub["id"],
      "name" => sub["name"],
      "publisherId" => sub["publisherId"],
      "offerId" => sub["offerId"],
      "planId" => sub["planId"],
      "quantity" => sub["quantity"],
      "saasSubscriptionStatus" => sub["status"],
      "term" => sub["term"]
    }
  end

  defp uuid do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
