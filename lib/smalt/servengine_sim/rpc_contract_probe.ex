defmodule Smalt.ServengineSim.RpcContractProbe do
  @moduledoc """
  In-process simulator and contract probe for ServEngine's
  `POST /internal-api/rpc/run` AshTypescript RPC surface.

  Simulates the live boundary and application contracts of `xaas`:

    * Auth & boundary guards (`RequireInternalApiToken` + `ValidateRpcFieldsSpec`):
      Bearer token check (401), malformed `fields`/`metadata_fields` shape
      refusal (400 `invalid_fields_spec`), and tenant resolution arm
      (`x-tenant-id` / `acting-entity-id` / payload `tenant` -> 400
      `tenant_required` / `unknown_tenant`).
    * `morning_view`: generic `:action` returning a typed map where `fields`
      selection is **required** (`missing_required_parameter` when omitted,
      `empty_fields_array` when `[]`), with recursive nested map field
      validation/projection and role-gated money redaction (null-never-zero).
    * `list_clients` / `list_work_orders`: tenant-scoped `:read` actions with
      required `fields` selection, `input` search, `filter`, `sort`, offset
      `page` envelope parity, and relationship projection.
    * `check_in` / `check_out`: tenant-scoped Visit `:update` actions with
      optional `fields` selection (`%{}` when omitted/empty), Visit FSM status
      guards (`en_route -> on_site`, `in_progress -> work_complete`), DL-4 dual
      clock mode/window/budget laws, and S-42 server-side haversine geofencing.

  Exposes both a `Plug` interface (`call/2`) for HTTP/Plug.Test dispatch and
  `check/0` for a single-pass in-process contract probe verdict.
  """

  use Plug.Router
  use Plug.ErrorHandler

  @behaviour Smalt.RuntimeContracts.Contract

  alias Smalt.RuntimeContracts.Support

  @default_token "local-dev"
  @default_radius_m 150.0
  @earth_radius_m 6_371_000.0
  @money_roles ~w(executive_admin finance_controller)
  @platform_view_actions ~w(list_tenants list_marketplace_providers)

  @wo_states ~w(draft ingested matching dispatched in_progress pending_audit completed invoiced closed_out cancelled)
  @open_wo_states ~w(ingested matching dispatched in_progress pending_audit)
  @invoice_states ~w(draft submitted approved sent paid overdue disputed void)
  @sp_states ~w(onboarding active suspended offboarded)

  @wo_status_camel %{
    "draft" => "draft",
    "ingested" => "ingested",
    "matching" => "matching",
    "dispatched" => "dispatched",
    "in_progress" => "inProgress",
    "pending_audit" => "pendingAudit",
    "completed" => "completed",
    "invoiced" => "invoiced",
    "closed_out" => "closedOut",
    "cancelled" => "cancelled"
  }

  @morning_view_schema %{
    "generatedAt" => :primitive,
    "workOrders" => %{
      "total" => :primitive,
      "byStatus" => Map.new(Map.values(@wo_status_camel), &{&1, :primitive})
    },
    "invoices" => %{
      "total" => :primitive,
      "byStatus" => Map.new(@invoice_states, &{&1, :primitive}),
      "outstandingTotal" => :primitive,
      "overdueTotal" => :primitive,
      "paidTotal" => :primitive,
      "disputedTotal" => :primitive
    },
    "procurement" => %{
      "supplierCount" => :primitive,
      "spendTotal" => :primitive
    },
    "collections" => %{
      "outstandingCount" => :primitive,
      "overdueCount" => :primitive,
      "outstandingTotal" => :primitive,
      "overdueTotal" => :primitive
    },
    "onboarding" => %{
      "serviceProviderTotal" => :primitive,
      "byStatus" => Map.new(@sp_states, &{&1, :primitive}),
      "bans" => :primitive,
      "doNotUse" => :primitive
    },
    "sla" => %{
      "openWithDeadline" => :primitive,
      "pastDeadline" => :primitive,
      "conformancePct" => :primitive
    }
  }

  @client_fields %{
    "id" => :primitive,
    "name" => :primitive,
    "classification" => :primitive,
    "parentPrimaryClientId" => :primitive,
    "paymentTermsDays" => :primitive,
    "preferredDeliveryMethod" => :primitive,
    "insertedAt" => :primitive,
    "updatedAt" => :primitive,
    "parentPrimaryClient" => :self,
    "brands" => %{
      "id" => :primitive,
      "name" => :primitive,
      "code" => :primitive,
      "clientId" => :primitive
    },
    "contacts" => %{
      "id" => :primitive,
      "firstName" => :primitive,
      "lastName" => :primitive,
      "clientId" => :primitive
    }
  }

  @work_order_fields %{
    "id" => :primitive,
    "externalWoNumber" => :primitive,
    "workOrderNumber" => :primitive,
    "state" => :primitive,
    "priority" => :primitive,
    "trade" => :primitive,
    "subTrade" => :primitive,
    "workOrderType" => :primitive,
    "description" => :primitive,
    "currentNte" => :primitive,
    "parentWorkOrderId" => :primitive,
    "entityId" => :primitive,
    "projectCoordinatorId" => :primitive,
    "onSiteBy" => :primitive,
    "completeBy" => :primitive,
    "insertedAt" => :primitive,
    "updatedAt" => :primitive,
    "parentWorkOrder" => :self,
    "childWorkOrders" => :self
  }

  @visit_fields %{
    "id" => :primitive,
    "visitNumber" => :primitive,
    "workOrderId" => :primitive,
    "status" => :primitive,
    "scheduledTime" => :primitive,
    "checkInAt" => :primitive,
    "checkOutAt" => :primitive,
    "internalCheckInAt" => :primitive,
    "externalCheckInAt" => :primitive,
    "internalCheckOutAt" => :primitive,
    "externalCheckOutAt" => :primitive,
    "assessmentNotes" => :primitive,
    "arrivalLatitude" => :primitive,
    "arrivalLongitude" => :primitive,
    "geofenceVerified" => :primitive,
    "insertedAt" => :primitive,
    "updatedAt" => :primitive,
    "workOrder" => :work_order
  }

  plug(:match)
  plug(:dispatch)

  # ---------------------------------------------------------------------------
  # Contract behaviour & probe entrypoints
  # ---------------------------------------------------------------------------

  @impl Smalt.RuntimeContracts.Contract
  def name, do: :servengine_rpc_contract_probe

  @impl Smalt.RuntimeContracts.Contract
  def plane, do: :control_plane

  @doc """
  Executes the built-in `/internal-api/rpc/run` contract probe suite in-process
  against this simulator and returns a `Smalt.RuntimeContracts.Support.result()`.
  """
  @impl Smalt.RuntimeContracts.Contract
  def check do
    reset!()
    seed = default_seed!()

    result =
      Support.contract(:servengine_rpc_contract_probe, [
        {:auth_required_401, fn -> probe_auth_401(seed) end},
        {:invalid_fields_spec_400, fn -> probe_invalid_fields_spec(seed) end},
        {:tenant_arm_refusal_400, fn -> probe_tenant_arm(seed) end},
        {:morning_view_requires_fields, fn -> probe_morning_view_required_fields(seed) end},
        {:morning_view_selection_and_redaction, fn -> probe_morning_view_projection(seed) end},
        {:list_clients_parity, fn -> probe_list_clients(seed) end},
        {:list_work_orders_parity, fn -> probe_list_work_orders(seed) end},
        {:check_in_out_parity, fn -> probe_check_in_out(seed) end}
      ])

    reset!()
    result
  end

  # ---------------------------------------------------------------------------
  # State management (lazy unlinked Store GenServer)
  # ---------------------------------------------------------------------------

  defmodule Store do
    @moduledoc false
    use GenServer

    def start(opts \\ []) do
      GenServer.start(__MODULE__, opts, name: __MODULE__)
    end

    @impl true
    def init(_opts) do
      {:ok, initial_state()}
    end

    @impl true
    def handle_call(:get, _from, state), do: {:reply, state, state}
    def handle_call({:update, fun}, _from, state) do
      {reply, next} = fun.(state)
      {:reply, reply, next}
    end

    def handle_call(:reset, _from, _state) do
      {:reply, :ok, initial_state()}
    end

    defp initial_state do
      %{
        tenants: %{},
        clients: %{},
        sites: %{},
        work_orders: %{},
        visits: %{},
        settings: %{},
        invoices: %{},
        invoice_line_items: %{},
        suppliers: %{},
        service_providers: %{},
        alignment_rules: %{}
      }
    end
  end

  @doc "Ensures the simulator store process is running."
  @spec ensure_started() :: :ok
  def ensure_started do
    case Process.whereis(Store) do
      nil ->
        case Store.start() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  @doc "Resets all simulated ServEngine tenants and records."
  @spec reset!() :: :ok
  def reset! do
    ensure_started()
    GenServer.call(Store, :reset)
  end

  @doc "Returns a snapshot of the simulator state."
  @spec snapshot() :: map()
  def snapshot do
    ensure_started()
    GenServer.call(Store, :get)
  end

  @doc "Inserts or replaces a record in the given store bucket (`:tenants`, `:clients`, etc.)."
  @spec put_record(atom(), String.t(), map()) :: map()
  def put_record(bucket, id, record) when is_atom(bucket) and is_binary(id) and is_map(record) do
    ensure_started()

    GenServer.call(Store, {:update, fn state ->
      normalized = Map.put(record, "id", id)
      next = put_in(state, [bucket, id], normalized)
      {normalized, next}
    end})
  end

  @doc """
  Seeds a deterministic baseline dataset (2 tenants, clients, fenced/unfenced
  sites, work orders, visits, check-in/out settings, invoices, suppliers,
  service providers, alignment rules) and returns the seeded IDs.
  """
  @spec default_seed!() :: map()
  def default_seed! do
    t1 = "10000000-0000-7000-8000-000000000001"
    t2 = "10000000-0000-7000-8000-000000000002"
    c1 = "20000000-0000-7000-8000-000000000001"
    c2 = "20000000-0000-7000-8000-000000000002"
    c_other = "20000000-0000-7000-8000-000000000099"
    s1 = "30000000-0000-7000-8000-000000000001"
    s2 = "30000000-0000-7000-8000-000000000002"
    wo1 = "40000000-0000-7000-8000-000000000001"
    wo2 = "40000000-0000-7000-8000-000000000002"
    wo_other = "40000000-0000-7000-8000-000000000099"
    v_app = "50000000-0000-7000-8000-000000000001"
    v_manual = "50000000-0000-7000-8000-000000000002"
    v_other = "50000000-0000-7000-8000-000000000099"

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    on_site_by = DateTime.add(now, 3600, :second) |> DateTime.to_iso8601()
    future_deadline = DateTime.add(now, 7200, :second) |> DateTime.to_iso8601()
    past_deadline = DateTime.add(now, -3600, :second) |> DateTime.to_iso8601()
    now_iso = DateTime.to_iso8601(now)

    put_record(:tenants, t1, %{"name" => "Acme Facility Ops", "slug" => "acme-ops"})
    put_record(:tenants, t2, %{"name" => "Beta Facilities", "slug" => "beta-ops"})

    put_record(:clients, c1, %{
      "tenantId" => t1,
      "name" => "Alpha Retail",
      "classification" => "primary",
      "parentPrimaryClientId" => nil,
      "paymentTermsDays" => 30,
      "preferredDeliveryMethod" => "email",
      "insertedAt" => now_iso,
      "updatedAt" => now_iso
    })

    put_record(:clients, c2, %{
      "tenantId" => t1,
      "name" => "Zephyr Broker",
      "classification" => "secondary_broker",
      "parentPrimaryClientId" => c1,
      "paymentTermsDays" => 45,
      "preferredDeliveryMethod" => "fm_portal",
      "insertedAt" => now_iso,
      "updatedAt" => now_iso
    })

    put_record(:clients, c_other, %{
      "tenantId" => t2,
      "name" => "Foreign Client",
      "classification" => "primary",
      "parentPrimaryClientId" => nil,
      "paymentTermsDays" => 15,
      "preferredDeliveryMethod" => "email",
      "insertedAt" => now_iso,
      "updatedAt" => now_iso
    })

    # Fenced site (Austin TX) and unfenced site
    put_record(:sites, s1, %{
      "tenantId" => t1,
      "name" => "Store #101",
      "latitude" => 30.2672,
      "longitude" => -97.7431,
      "geofenceRadiusMeters" => 150
    })

    put_record(:sites, s2, %{
      "tenantId" => t1,
      "name" => "Store #102 (Unfenced)",
      "latitude" => nil,
      "longitude" => nil,
      "geofenceRadiusMeters" => nil
    })

    put_record(:work_orders, wo1, %{
      "tenantId" => t1,
      "siteId" => s1,
      "externalWoNumber" => "EXT-1001",
      "workOrderNumber" => 1001,
      "state" => "dispatched",
      "priority" => "p1_emergency",
      "trade" => "hvac",
      "subTrade" => "chiller",
      "workOrderType" => "reactive",
      "description" => "Walk-in freezer compressor fault",
      "currentNte" => "1500.00",
      "parentWorkOrderId" => nil,
      "entityId" => nil,
      "projectCoordinatorId" => nil,
      "onSiteBy" => on_site_by,
      "completeBy" => future_deadline,
      "insertedAt" => now_iso,
      "updatedAt" => now_iso
    })

    put_record(:work_orders, wo2, %{
      "tenantId" => t1,
      "siteId" => s2,
      "externalWoNumber" => "EXT-1002",
      "workOrderNumber" => 1002,
      "state" => "in_progress",
      "priority" => "p2_urgent",
      "trade" => "electrical",
      "subTrade" => nil,
      "workOrderType" => "preventative",
      "description" => "Main panel thermal inspection",
      "currentNte" => "750.00",
      "parentWorkOrderId" => wo1,
      "entityId" => nil,
      "projectCoordinatorId" => nil,
      "onSiteBy" => on_site_by,
      "completeBy" => past_deadline,
      "insertedAt" => now_iso,
      "updatedAt" => now_iso
    })

    put_record(:work_orders, wo_other, %{
      "tenantId" => t2,
      "siteId" => s2,
      "externalWoNumber" => "BETA-9001",
      "workOrderNumber" => 9001,
      "state" => "ingested",
      "priority" => "p3_standard",
      "trade" => "plumbing",
      "subTrade" => nil,
      "workOrderType" => "reactive",
      "description" => "Other tenant leak",
      "currentNte" => "500.00",
      "parentWorkOrderId" => nil,
      "entityId" => nil,
      "projectCoordinatorId" => nil,
      "onSiteBy" => nil,
      "completeBy" => nil,
      "insertedAt" => now_iso,
      "updatedAt" => now_iso
    })

    put_record(:settings, wo1, %{
      "workOrderId" => wo1,
      "mode" => "app",
      "expectedWindowMinutes" => 30,
      "proposalBudgetMinutes" => 60,
      "isTrackingRequired" => true
    })

    put_record(:settings, wo2, %{
      "workOrderId" => wo2,
      "mode" => "manual",
      "expectedWindowMinutes" => 30,
      "proposalBudgetMinutes" => 45,
      "isTrackingRequired" => false
    })

    put_record(:visits, v_app, %{
      "tenantId" => t1,
      "workOrderId" => wo1,
      "visitNumber" => 1,
      "status" => "en_route",
      "scheduledTime" => on_site_by,
      "checkInAt" => nil,
      "checkOutAt" => nil,
      "internalCheckInAt" => nil,
      "externalCheckInAt" => nil,
      "internalCheckOutAt" => nil,
      "externalCheckOutAt" => nil,
      "assessmentNotes" => nil,
      "arrivalLatitude" => nil,
      "arrivalLongitude" => nil,
      "geofenceVerified" => false,
      "insertedAt" => now_iso,
      "updatedAt" => now_iso
    })

    put_record(:visits, v_manual, %{
      "tenantId" => t1,
      "workOrderId" => wo2,
      "visitNumber" => 2,
      "status" => "en_route",
      "scheduledTime" => on_site_by,
      "checkInAt" => nil,
      "checkOutAt" => nil,
      "internalCheckInAt" => nil,
      "externalCheckInAt" => nil,
      "internalCheckOutAt" => nil,
      "externalCheckOutAt" => nil,
      "assessmentNotes" => nil,
      "arrivalLatitude" => nil,
      "arrivalLongitude" => nil,
      "geofenceVerified" => false,
      "insertedAt" => now_iso,
      "updatedAt" => now_iso
    })

    put_record(:visits, v_other, %{
      "tenantId" => t2,
      "workOrderId" => wo_other,
      "visitNumber" => 1,
      "status" => "en_route",
      "scheduledTime" => nil,
      "checkInAt" => nil,
      "checkOutAt" => nil,
      "internalCheckInAt" => nil,
      "externalCheckInAt" => nil,
      "internalCheckOutAt" => nil,
      "externalCheckOutAt" => nil,
      "assessmentNotes" => nil,
      "arrivalLatitude" => nil,
      "arrivalLongitude" => nil,
      "geofenceVerified" => false,
      "insertedAt" => now_iso,
      "updatedAt" => now_iso
    })

    put_record(:invoices, "60000000-0000-7000-8000-000000000001", %{
      "tenantId" => t1,
      "status" => "sent",
      "totalAmount" => "125.50"
    })

    put_record(:invoices, "60000000-0000-7000-8000-000000000002", %{
      "tenantId" => t1,
      "status" => "draft",
      "totalAmount" => "200.00"
    })

    put_record(:invoice_line_items, "61000000-0000-7000-8000-000000000001", %{
      "tenantId" => t1,
      "side" => "ap",
      "invoiceStatus" => "sent",
      "lineTotal" => "50.00"
    })

    put_record(:suppliers, "70000000-0000-7000-8000-000000000001", %{"tenantId" => t1, "name" => "SupplyCo"})

    put_record(:service_providers, "80000000-0000-7000-8000-000000000001", %{
      "tenantId" => t1,
      "status" => "active",
      "doNotUse" => false
    })

    put_record(:service_providers, "80000000-0000-7000-8000-000000000002", %{
      "tenantId" => t1,
      "status" => "onboarding",
      "doNotUse" => true
    })

    put_record(:alignment_rules, "90000000-0000-7000-8000-000000000001", %{
      "tenantId" => t1,
      "kind" => "ban"
    })

    %{
      tenant_id: t1,
      tenant_slug: "acme-ops",
      other_tenant_id: t2,
      other_tenant_slug: "beta-ops",
      client_ids: [c1, c2],
      other_client_id: c_other,
      site_fenced_id: s1,
      site_unfenced_id: s2,
      work_order_ids: [wo1, wo2],
      other_work_order_id: wo_other,
      visit_app_id: v_app,
      visit_manual_id: v_manual,
      visit_other_id: v_other,
      on_site_by: on_site_by
    }
  end

  # ---------------------------------------------------------------------------
  # HTTP Routes (POST /internal-api/rpc/run + OPTIONS preflight)
  # ---------------------------------------------------------------------------

  options "/internal-api/rpc/run" do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "POST, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "authorization, content-type, x-tenant-id, acting-entity-id, x-actor-role")
    |> send_resp(204, "")
  end

  post "/internal-api/rpc/run" do
    ensure_started()

    with :ok <- authenticate(conn),
         {:ok, params, conn} <- decode_body(conn),
         :ok <- validate_fields_spec(params),
         {:ok, ctx} <- resolve_tenant_arm(conn, params) do
      response = execute_rpc(params, ctx)
      json_resp(conn, 200, response)
    else
      {:error, status, body} ->
        json_resp(conn, status, body)
    end
  end

  match _ do
    json_resp(conn, 404, %{"error" => "not_found"})
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{reason: reason}) do
    json_resp(conn, 500, %{
      "error" => "internal_error",
      "detail" => Exception.message(reason)
    })
  end

  # ---------------------------------------------------------------------------
  # Boundary guards: Auth -> JSON decode -> ValidateRpcFieldsSpec -> Tenant Arm
  # ---------------------------------------------------------------------------

  defp authenticate(conn) do
    expected = Application.get_env(:smalt, :servengine_internal_api_token, @default_token)

    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 ->
        if Plug.Crypto.secure_compare(token, expected) do
          :ok
        else
          {:error, 401, %{"error" => "unauthorized", "detail" => "missing or invalid Bearer token"}}
        end

      _ ->
        {:error, 401, %{"error" => "unauthorized", "detail" => "missing or invalid Bearer token"}}
    end
  end

  defp decode_body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
    {:ok, raw, conn} = read_body(conn, length: 4_000_000)

    if byte_size(String.trim(raw)) == 0 do
      {:ok, %{}, conn}
    else
      case Jason.decode(raw) do
        {:ok, %{} = map} -> {:ok, map, conn}
        {:ok, _other} -> {:error, 400, %{"error" => "invalid_json", "detail" => "request body must be a JSON object"}}
        {:error, _} -> {:error, 400, %{"error" => "invalid_json", "detail" => "malformed JSON request body"}}
      end
    end
  end

  defp decode_body(%Plug.Conn{body_params: %{} = map} = conn), do: {:ok, map, conn}

  defp validate_fields_spec(params) do
    with :ok <- check_field_spec_key(params, "fields"),
         :ok <- check_field_spec_key(params, "metadata_fields") do
      :ok
    end
  end

  defp check_field_spec_key(params, key) do
    case Map.get(params, key) do
      nil ->
        :ok

      value when is_list(value) ->
        if Enum.all?(value, &valid_field_spec_element?/1) do
          :ok
        else
          reject_fields_spec(key, value)
        end

      value ->
        reject_fields_spec(key, value)
    end
  end

  defp valid_field_spec_element?(v) when is_binary(v), do: true
  defp valid_field_spec_element?(v) when is_atom(v), do: not is_boolean(v) and not is_nil(v)
  defp valid_field_spec_element?(%{}), do: true
  defp valid_field_spec_element?(_), do: false

  defp reject_fields_spec(key, value) do
    {:error, 400,
     %{
       "error" => "invalid_fields_spec",
       "message" =>
         "`#{key}` must be a list of field names (strings) or nested field maps; " <>
           "got: #{inspect(value, limit: 20)}",
       "key" => key
     }}
  end

  defp resolve_tenant_arm(conn, params) do
    role = header_value(conn, "x-actor-role") || "dispatch"
    header_tenant = header_value(conn, "x-tenant-id") || header_value(conn, "acting-entity-id")
    payload_tenant = non_empty_string(params["tenant"])
    state = snapshot()

    cond do
      header_tenant != nil ->
        case find_tenant(state, header_tenant) do
          {:ok, tenant} -> {:ok, %{tenant_id: tenant["id"], tenant_slug: tenant["slug"], role: role, state: state}}
          :error -> {:error, 400, tenant_refusal_body({:unknown_tenant, header_tenant})}
        end

      payload_tenant != nil ->
        case find_tenant(state, payload_tenant) do
          {:ok, tenant} -> {:ok, %{tenant_id: tenant["id"], tenant_slug: tenant["slug"], role: role, state: state}}
          :error -> {:error, 400, tenant_refusal_body({:unknown_tenant, payload_tenant})}
        end

      params["action"] in @platform_view_actions ->
        {:ok, %{tenant_id: nil, tenant_slug: nil, role: role, platform_view: true, state: state}}

      true ->
        {:error, 400, tenant_refusal_body(:tenant_required)}
    end
  end

  defp find_tenant(state, id_or_slug) do
    case Map.get(state.tenants, id_or_slug) do
      %{} = t ->
        {:ok, t}

      nil ->
        case Enum.find(Map.values(state.tenants), &(&1["slug"] == id_or_slug)) do
          %{} = t -> {:ok, t}
          nil -> :error
        end
    end
  end

  defp tenant_refusal_body(:tenant_required) do
    %{
      "error" => "tenant_required",
      "detail" =>
        "no tenant identity asserted: send the payload `tenant` field (tenant id or slug), " <>
          "x-tenant-id (tenant id or slug), x-org-id, or acting-entity-id; " <>
          "refusing instead of defaulting to a tenant"
    }
  end

  defp tenant_refusal_body({:unknown_tenant, value}) do
    %{
      "error" => "unknown_tenant",
      "detail" =>
        "tenant #{inspect(value)} does not resolve to a real tenant (by id or slug); " <>
          "refusing instead of defaulting to a tenant"
    }
  end

  # ---------------------------------------------------------------------------
  # RPC Dispatch
  # ---------------------------------------------------------------------------

  defp execute_rpc(params, ctx) do
    case non_empty_string(params["action"]) do
      nil ->
        rpc_failure([missing_param_error("action")])

      "morning_view" ->
        run_morning_view(params, ctx)

      "list_clients" ->
        run_read_action("Client", @client_fields, :clients, params, ctx, &filter_clients/3)

      "list_work_orders" ->
        run_read_action("WorkOrder", @work_order_fields, :work_orders, params, ctx, &filter_work_orders/3)

      "check_in" ->
        run_check_in(params, ctx)

      "check_out" ->
        run_check_out(params, ctx)

      "list_tenants" ->
        run_list_tenants(params, ctx)

      other ->
        rpc_failure([action_not_found_error(other)])
    end
  end

  # ---------------------------------------------------------------------------
  # morning_view (generic :action returning typed map — fields REQUIRED)
  # ---------------------------------------------------------------------------

  defp run_morning_view(params, ctx) do
    with :ok <- require_non_empty_fields(params),
         {:ok, template} <- compile_fields(@morning_view_schema, params["fields"], "map", []) do
      computed = compute_morning_view(ctx.state, ctx.tenant_id, ctx.role)
      %{"success" => true, "data" => project_value(computed, template)}
    else
      {:error, errors} -> rpc_failure(errors)
    end
  end

  defp compute_morning_view(state, tenant_id, role) do
    money? = role in @money_roles
    wos = tenant_rows(state.work_orders, tenant_id)
    invs = tenant_rows(state.invoices, tenant_id)
    lines = tenant_rows(state.invoice_line_items, tenant_id)
    suppliers = tenant_rows(state.suppliers, tenant_id)
    sps = tenant_rows(state.service_providers, tenant_id)
    rules = tenant_rows(state.alignment_rules, tenant_id)

    wo_by_status =
      for s <- @wo_states, into: %{} do
        {@wo_status_camel[s], Enum.count(wos, &(&1["state"] == s))}
      end

    now = DateTime.utc_now()

    open_with_deadline_rows =
      Enum.filter(wos, fn wo ->
        wo["state"] in @open_wo_states and is_binary(wo["completeBy"])
      end)

    open_with_deadline = length(open_with_deadline_rows)

    past_deadline =
      Enum.count(open_with_deadline_rows, fn wo ->
        case DateTime.from_iso8601(wo["completeBy"]) do
          {:ok, dt, _} -> DateTime.compare(dt, now) == :lt
          _ -> false
        end
      end)

    inv_by_status =
      for s <- @invoice_states, into: %{} do
        {s, Enum.count(invs, &(&1["status"] == s))}
      end

    sum_inv = fn statuses ->
      if money? do
        invs
        |> Enum.filter(&(&1["status"] in statuses))
        |> sum_decimals("totalAmount")
      else
        nil
      end
    end

    spend_total =
      if money? do
        lines
        |> Enum.filter(&(&1["side"] == "ap" and &1["invoiceStatus"] != "void"))
        |> sum_decimals("lineTotal")
      else
        nil
      end

    sp_by_status =
      for s <- @sp_states, into: %{} do
        {s, Enum.count(sps, &(&1["status"] == s))}
      end

    %{
      "generatedAt" => DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      "workOrders" => %{
        "total" => Enum.sum(Map.values(wo_by_status)),
        "byStatus" => wo_by_status
      },
      "invoices" => %{
        "total" => Enum.sum(Map.values(inv_by_status)),
        "byStatus" => inv_by_status,
        "outstandingTotal" => sum_inv.(~w(sent overdue)),
        "overdueTotal" => sum_inv.(~w(overdue)),
        "paidTotal" => sum_inv.(~w(paid)),
        "disputedTotal" => sum_inv.(~w(disputed))
      },
      "procurement" => %{
        "supplierCount" => length(suppliers),
        "spendTotal" => spend_total
      },
      "collections" => %{
        "outstandingCount" => inv_by_status["sent"] + inv_by_status["overdue"],
        "overdueCount" => inv_by_status["overdue"],
        "outstandingTotal" => sum_inv.(~w(sent overdue)),
        "overdueTotal" => sum_inv.(~w(overdue))
      },
      "onboarding" => %{
        "serviceProviderTotal" => Enum.sum(Map.values(sp_by_status)),
        "byStatus" => sp_by_status,
        "bans" => Enum.count(rules, &(&1["kind"] == "ban")),
        "doNotUse" => Enum.count(sps, &(&1["doNotUse"] == true))
      },
      "sla" => %{
        "openWithDeadline" => open_with_deadline,
        "pastDeadline" => past_deadline,
        "conformancePct" => conformance_pct(open_with_deadline, past_deadline)
      }
    }
  end

  defp conformance_pct(0, _past), do: nil

  defp conformance_pct(total, past) do
    pct = (total - past) * 100.0 / total
    :erlang.float_to_binary(pct, decimals: 2)
  end

  defp sum_decimals(rows, key) do
    total_cents =
      Enum.reduce(rows, 0, fn row, acc ->
        acc + parse_cents(Map.get(row, key))
      end)

    format_cents(total_cents)
  end

  defp parse_cents(nil), do: 0
  defp parse_cents(v) when is_integer(v), do: v * 100
  defp parse_cents(v) when is_float(v), do: round(v * 100)

  defp parse_cents(v) when is_binary(v) do
    case Float.parse(v) do
      {f, ""} -> round(f * 100)
      _ -> 0
    end
  end

  defp format_cents(0), do: "0"

  defp format_cents(cents) do
    sign = if cents < 0, do: "-", else: ""
    a = abs(cents)
    whole = Integer.to_string(div(a, 100))
    frac = a |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    sign <> whole <> "." <> frac
  end

  # ---------------------------------------------------------------------------
  # Read actions: list_clients, list_work_orders, list_tenants
  # ---------------------------------------------------------------------------

  defp run_read_action(resource_name, schema, bucket, params, ctx, filter_fn) do
    with :ok <- require_non_empty_fields(params),
         {:ok, template} <- compile_fields(schema, params["fields"], resource_name, []) do
      rows =
        ctx.state
        |> Map.fetch!(bucket)
        |> Map.values()
        |> Enum.filter(&(&1["tenantId"] == ctx.tenant_id))
        |> filter_fn.(params["input"] || %{}, params["filter"])
        |> apply_sort(params["sort"])
        |> Enum.map(&hydrate_relations(&1, bucket, ctx.state))

      data = paginate_and_project(rows, params["page"], template)
      %{"success" => true, "data" => data}
    else
      {:error, errors} -> rpc_failure(errors)
    end
  end

  defp run_list_tenants(params, ctx) do
    tenant_schema = %{"id" => :primitive, "name" => :primitive, "slug" => :primitive}

    with :ok <- require_non_empty_fields(params),
         {:ok, template} <- compile_fields(tenant_schema, params["fields"], "Tenant", []) do
      rows = ctx.state.tenants |> Map.values() |> apply_sort(params["sort"])
      %{"success" => true, "data" => paginate_and_project(rows, params["page"], template)}
    else
      {:error, errors} -> rpc_failure(errors)
    end
  end

  defp filter_clients(rows, _input, nil), do: rows

  defp filter_clients(rows, _input, filter) when is_map(filter) do
    apply_filter(rows, filter)
  end

  defp filter_clients(rows, _input, _), do: rows

  defp filter_work_orders(rows, input, filter) do
    rows =
      case non_empty_string(input["search"]) do
        nil ->
          rows

        term ->
          needle = String.downcase(term)

          Enum.filter(rows, fn row ->
            Enum.any?(~w(externalWoNumber description trade), fn k ->
              row |> Map.get(k, "") |> to_string() |> String.downcase() |> String.contains?(needle)
            end)
          end)
      end

    if is_map(filter), do: apply_filter(rows, filter), else: rows
  end

  defp apply_filter(rows, %{"and" => clauses}) when is_list(clauses) do
    Enum.reduce(clauses, rows, fn c, acc -> apply_filter(acc, c) end)
  end

  defp apply_filter(rows, %{"or" => clauses}) when is_list(clauses) do
    Enum.filter(rows, fn row -> Enum.any?(clauses, &(apply_filter([row], &1) != [])) end)
  end

  defp apply_filter(rows, filter) when is_map(filter) do
    Enum.filter(rows, fn row ->
      Enum.all?(filter, fn {field, cond_val} ->
        val = Map.get(row, field)

        case cond_val do
          %{"eq" => target} -> val == target
          %{"neq" => target} -> val != target
          %{"in" => targets} when is_list(targets) -> val in targets
          %{"isNil" => true} -> is_nil(val)
          %{"isNil" => false} -> not is_nil(val)
          %{} = nested -> match_nested_filter(val, nested)
          scalar -> val == scalar
        end
      end)
    end)
  end

  defp match_nested_filter(val, nested) do
    Enum.all?(nested, fn
      {"eq", target} -> val == target
      {"in", targets} when is_list(targets) -> val in targets
      _ -> true
    end)
  end

  defp apply_sort(rows, nil), do: rows
  defp apply_sort(rows, ""), do: rows

  defp apply_sort(rows, sort_spec) do
    fields =
      case sort_spec do
        s when is_binary(s) -> String.split(s, ",", trim: true)
        list when is_list(list) -> Enum.map(list, &to_string/1)
        _ -> []
      end

    Enum.reduce(Enum.reverse(fields), rows, fn token, acc ->
      {desc?, key} =
        case token do
          "-" <> rest -> {true, rest}
          "+" <> rest -> {false, rest}
          other -> {false, other}
        end

      sorter = if desc?, do: :desc, else: :asc
      Enum.sort_by(acc, &Map.get(&1, key), sorter)
    end)
  end

  defp paginate_and_project(rows, nil, template) do
    Enum.map(rows, &project_value(&1, template))
  end

  defp paginate_and_project(rows, page, template) when is_map(page) do
    limit = normalize_pos_int(page["limit"], 50)
    offset = normalize_non_neg_int(page["offset"], 0)
    total = length(rows)
    sliced = rows |> Enum.drop(offset) |> Enum.take(limit)
    has_more = offset + length(sliced) < total

    base = %{
      "results" => Enum.map(sliced, &project_value(&1, template)),
      "hasMore" => has_more,
      "limit" => limit,
      "offset" => offset,
      "type" => "offset"
    }

    if page["count"] == true, do: Map.put(base, "count", total), else: base
  end

  defp hydrate_relations(row, :clients, state) do
    parent =
      case row["parentPrimaryClientId"] do
        nil -> nil
        pid -> Map.get(state.clients, pid)
      end

    row
    |> Map.put("parentPrimaryClient", parent)
    |> Map.put_new("brands", [])
    |> Map.put_new("contacts", [])
  end

  defp hydrate_relations(row, :work_orders, state) do
    parent =
      case row["parentWorkOrderId"] do
        nil -> nil
        pid -> Map.get(state.work_orders, pid)
      end

    children =
      state.work_orders
      |> Map.values()
      |> Enum.filter(&(&1["parentWorkOrderId"] == row["id"]))

    row
    |> Map.put("parentWorkOrder", parent)
    |> Map.put("childWorkOrders", children)
  end

  defp hydrate_relations(row, :visits, state) do
    wo = Map.get(state.work_orders, row["workOrderId"])
    Map.put(row, "workOrder", wo)
  end

  # ---------------------------------------------------------------------------
  # Update actions: check_in, check_out (fields OPTIONAL)
  # ---------------------------------------------------------------------------

  defp run_check_in(params, ctx) do
    with {:ok, template} <- compile_optional_update_fields(params),
         {:ok, visit_id} <- require_identity(params),
         {:ok, visit} <- fetch_tenant_visit(ctx.state, visit_id, ctx.tenant_id),
         {:ok, input} <- validate_check_in_input(params["input"]),
         {:ok, updated_visit} <- apply_check_in(visit, input, ctx.state) do
      persist_and_project_visit(updated_visit, template, ctx.state)
    else
      {:error, errors} -> rpc_failure(errors)
    end
  end

  defp run_check_out(params, ctx) do
    with {:ok, template} <- compile_optional_update_fields(params),
         {:ok, visit_id} <- require_identity(params),
         {:ok, visit} <- fetch_tenant_visit(ctx.state, visit_id, ctx.tenant_id),
         {:ok, input} <- validate_check_out_input(params["input"]),
         {:ok, updated_visit} <- apply_check_out(visit, input, ctx.state) do
      persist_and_project_visit(updated_visit, template, ctx.state)
    else
      {:error, errors} -> rpc_failure(errors)
    end
  end

  defp compile_optional_update_fields(params) do
    case params["fields"] do
      nil -> {:ok, []}
      [] -> {:ok, []}
      fields when is_list(fields) -> compile_fields(@visit_fields, fields, "Visit", [])
    end
  end

  defp require_identity(params) do
    case non_empty_string(params["identity"]) do
      nil -> {:error, [missing_param_error("identity")]}
      id -> {:ok, id}
    end
  end

  defp fetch_tenant_visit(state, visit_id, tenant_id) do
    case Map.get(state.visits, visit_id) do
      %{"tenantId" => ^tenant_id} = visit ->
        {:ok, visit}

      _ ->
        {:error,
         [
           %{
             "type" => "not_found",
             "message" => "Record not found",
             "shortMessage" => "Not found",
             "vars" => %{"id" => visit_id},
             "fields" => ["identity"],
             "path" => [],
             "details" => %{}
           }
         ]}
    end
  end

  defp validate_check_in_input(nil), do: {:error, [missing_param_error("input")]}

  defp validate_check_in_input(input) when is_map(input) do
    with {:ok, internal_dt, internal_iso} <- parse_required_dt(input, "internalCheckInAt"),
         {:ok, external_dt, external_iso} <- parse_optional_dt(input, "externalCheckInAt"),
         {:ok, lat} <- parse_coord(input["arrivalLatitude"], "arrivalLatitude", -90.0, 90.0),
         {:ok, lon} <- parse_coord(input["arrivalLongitude"], "arrivalLongitude", -180.0, 180.0) do
      {:ok,
       %{
         internal_dt: internal_dt,
         internal_iso: internal_iso,
         external_dt: external_dt,
         external_iso: external_iso,
         lat: lat,
         lon: lon
       }}
    end
  end

  defp validate_check_in_input(_), do: {:error, [invalid_arg_error("input", "INVALID_INPUT", %{})]}

  defp validate_check_out_input(nil), do: {:error, [missing_param_error("input")]}

  defp validate_check_out_input(input) when is_map(input) do
    with {:ok, internal_dt, internal_iso} <- parse_required_dt(input, "internalCheckOutAt"),
         {:ok, external_dt, external_iso} <- parse_optional_dt(input, "externalCheckOutAt") do
      {:ok,
       %{
         internal_dt: internal_dt,
         internal_iso: internal_iso,
         external_dt: external_dt,
         external_iso: external_iso
       }}
    end
  end

  defp validate_check_out_input(_), do: {:error, [invalid_arg_error("input", "INVALID_INPUT", %{})]}

  defp apply_check_in(visit, input, state) do
    wo = Map.get(state.work_orders, visit["workOrderId"])
    settings = Map.get(state.settings, visit["workOrderId"])
    site = wo && Map.get(state.sites, wo["siteId"])

    with :ok <- guard_visit_transition(visit["status"], "en_route"),
         :ok <- guard_check_in_mode(settings, input.external_dt),
         :ok <- guard_external_window(settings, wo && wo["onSiteBy"], input.external_dt),
         {:ok, geofence_verified} <- evaluate_geofence(settings, site, input.lat, input.lon) do
      now_iso = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

      {:ok,
       visit
       |> Map.put("status", "on_site")
       |> Map.put("internalCheckInAt", input.internal_iso)
       |> Map.put("externalCheckInAt", input.external_iso)
       |> Map.put("arrivalLatitude", format_coord(input.lat))
       |> Map.put("arrivalLongitude", format_coord(input.lon))
       |> Map.put("geofenceVerified", geofence_verified)
       |> Map.put("updatedAt", now_iso)}
    end
  end

  defp apply_check_out(visit, input, state) do
    settings = Map.get(state.settings, visit["workOrderId"])

    with :ok <- guard_visit_transition(visit["status"], "in_progress"),
         :ok <- guard_external_budget(settings, visit["externalCheckInAt"], input.external_dt) do
      now_iso = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

      {:ok,
       visit
       |> Map.put("status", "work_complete")
       |> Map.put("internalCheckOutAt", input.internal_iso)
       |> Map.put("externalCheckOutAt", input.external_iso)
       |> Map.put("updatedAt", now_iso)}
    end
  end

  defp guard_visit_transition(current, expected_from) do
    if current == expected_from do
      :ok
    else
      {:error,
       [
         invalid_arg_error(
           "status",
           "INVALID_VISIT_STATUS_TRANSITION",
           %{"current" => current, "required" => expected_from}
         )
       ]}
    end
  end

  defp guard_check_in_mode(settings, external_dt) do
    mode = settings && settings["mode"]

    if mode in ["app", "ivr"] and is_nil(external_dt) do
      {:error, [invalid_arg_error("externalCheckInAt", "EXTERNAL_CHECK_IN_REQUIRED_FOR_MODE", %{"mode" => mode})]}
    else
      :ok
    end
  end

  defp guard_external_window(_settings, nil, _external_dt), do: :ok
  defp guard_external_window(_settings, _anchor, nil), do: :ok

  defp guard_external_window(%{"expectedWindowMinutes" => w}, anchor_iso, external_dt)
       when is_integer(w) and w >= 0 do
    case DateTime.from_iso8601(anchor_iso) do
      {:ok, anchor, _} ->
        if abs(DateTime.diff(external_dt, anchor, :second)) <= w * 60 do
          :ok
        else
          {:error, [invalid_arg_error("externalCheckInAt", "EXTERNAL_CHECK_IN_OUTSIDE_WINDOW", %{"windowMinutes" => w})]}
        end

      _ ->
        :ok
    end
  end

  defp guard_external_window(_settings, _anchor, _external_dt), do: :ok

  defp guard_external_budget(_settings, nil, _external_out), do: :ok
  defp guard_external_budget(_settings, _external_in, nil), do: :ok

  defp guard_external_budget(%{"proposalBudgetMinutes" => b}, external_in_iso, external_out)
       when is_integer(b) and b >= 0 do
    case DateTime.from_iso8601(external_in_iso) do
      {:ok, external_in, _} ->
        duration = DateTime.diff(external_out, external_in, :second)

        if duration >= 0 and duration <= b * 60 do
          :ok
        else
          {:error,
           [invalid_arg_error("externalCheckOutAt", "EXTERNAL_CHECK_OUT_BUDGET_EXCEEDED", %{"budgetMinutes" => b})]}
        end

      _ ->
        :ok
    end
  end

  defp guard_external_budget(_settings, _external_in, _external_out), do: :ok

  defp evaluate_geofence(settings, site, lat, lon) do
    coords? = not is_nil(lat) and not is_nil(lon)
    fence? = site != nil and not is_nil(site["latitude"]) and not is_nil(site["longitude"])
    tracking? = (settings && settings["isTrackingRequired"]) == true

    cond do
      coords? and fence? ->
        dist = haversine_m(lat, lon, site["latitude"], site["longitude"])
        radius = (site["geofenceRadiusMeters"] || @default_radius_m) * 1.0

        if dist <= radius do
          {:ok, true}
        else
          {:error,
           [
             invalid_arg_error("arrivalLatitude", "GEOFENCE_OUT_OF_FENCE", %{
               "distanceM" => Float.round(dist, 1),
               "radiusM" => radius
             })
           ]}
        end

      tracking? and not coords? ->
        {:error, [invalid_arg_error("arrivalLatitude", "GEOFENCE_UNVERIFIED", %{"trackingRequired" => true})]}

      not coords? and not fence? ->
        {:ok, false}

      true ->
        {:error, [invalid_arg_error("arrivalLatitude", "GEOFENCE_UNVERIFIED", %{})]}
    end
  end

  defp haversine_m(lat1, lon1, lat2, lon2) do
    p1 = lat1 * :math.pi() / 180.0
    p2 = lat2 * :math.pi() / 180.0
    dp = (lat2 - lat1) * :math.pi() / 180.0
    dl = (lon2 - lon1) * :math.pi() / 180.0

    a = :math.pow(:math.sin(dp / 2), 2) + :math.cos(p1) * :math.cos(p2) * :math.pow(:math.sin(dl / 2), 2)
    2 * @earth_radius_m * :math.asin(min(1.0, :math.sqrt(a)))
  end

  defp persist_and_project_visit(updated_visit, [], _state) do
    put_record(:visits, updated_visit["id"], updated_visit)
    %{"success" => true, "data" => %{}}
  end

  defp persist_and_project_visit(updated_visit, template, state) do
    put_record(:visits, updated_visit["id"], updated_visit)
    hydrated = hydrate_relations(updated_visit, :visits, state)
    %{"success" => true, "data" => project_value(hydrated, template)}
  end

  # ---------------------------------------------------------------------------
  # Shared Field Selection Validator & Recursive Projector
  # ---------------------------------------------------------------------------

  defp require_non_empty_fields(params) do
    case params["fields"] do
      nil -> {:error, [missing_param_error("fields")]}
      [] -> {:error, [empty_fields_array_error()]}
      list when is_list(list) -> :ok
    end
  end

  defp compile_fields(_schema, [], _type_label, _path), do: {:error, [empty_fields_array_error()]}

  defp compile_fields(schema, fields, type_label, path) when is_list(fields) do
    Enum.reduce_while(fields, {:ok, {[], MapSet.new()}}, fn spec, {:ok, {acc, seen}} ->
      case compile_one_field(schema, spec, type_label, path, seen) do
        {:ok, entry, next_seen} -> {:cont, {:ok, {[entry | acc], next_seen}}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, {rev, _seen}} -> {:ok, Enum.reverse(rev)}
      {:error, _} = err -> err
    end
  end

  defp compile_one_field(schema, field_name, type_label, path, seen) when is_binary(field_name) do
    with :ok <- check_duplicate(field_name, path, seen),
         {:ok, spec} <- lookup_field_spec(schema, field_name, type_label, path) do
      case spec do
        :primitive ->
          {:ok, {:prim, field_name}, MapSet.put(seen, field_name)}

        _nested ->
          {:error, [requires_field_selection_error(field_name, path)]}
      end
    end
  end

  defp compile_one_field(schema, %{} = nested_map, type_label, path, seen) do
    Enum.reduce_while(nested_map, {:ok, {[], seen}}, fn {key, sub_fields}, {:ok, {acc, cur_seen}} ->
      with :ok <- check_duplicate(key, path, cur_seen),
           {:ok, spec} <- lookup_field_spec(schema, key, type_label, path),
           {:ok, sub_schema, sub_label} <- resolve_nested_schema(spec, schema, key, path, type_label),
           true <- is_list(sub_fields) and sub_fields != [] do
        case compile_fields(sub_schema, sub_fields, sub_label, path ++ [key]) do
          {:ok, sub_template} ->
            {:cont, {:ok, {[{:nested, key, sub_template} | acc], MapSet.put(cur_seen, key)}}}

          {:error, _} = err ->
            {:halt, err}
        end
      else
        false ->
          err =
            if sub_fields == [],
              do: empty_fields_array_error(),
              else: invalid_field_format_error(key, path)

          {:halt, {:error, [err]}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, {[{:nested, _, _} = single], next_seen}} -> {:ok, single, next_seen}
      {:ok, {entries, next_seen}} -> {:ok, {:multi, Enum.reverse(entries)}, next_seen}
      {:error, _} = err -> err
    end
  end

  defp compile_one_field(_schema, other, _type_label, path, _seen) do
    {:error, [invalid_field_format_error(other, path)]}
  end

  defp check_duplicate(field, path, seen) do
    if MapSet.member?(seen, field) do
      {:error, [duplicate_field_error(field, path)]}
    else
      :ok
    end
  end

  defp lookup_field_spec(schema, field, type_label, path) do
    case Map.fetch(schema, field) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, [unknown_field_error(field, type_label, path)]}
    end
  end

  defp resolve_nested_schema(:primitive, _schema, key, path, _type_label) do
    {:error, [field_no_nesting_error(key, path)]}
  end

  defp resolve_nested_schema(:self, schema, key, _path, _type_label), do: {:ok, schema, key}
  defp resolve_nested_schema(:work_order, _schema, _key, _path, _type_label), do: {:ok, @work_order_fields, "WorkOrder"}

  defp resolve_nested_schema(%{} = sub_schema, _schema, key, _path, type_label) do
    label = if type_label == "map", do: "map", else: key
    {:ok, sub_schema, label}
  end

  defp project_value(nil, _template), do: nil

  defp project_value(list, template) when is_list(list) do
    Enum.map(list, &project_value(&1, template))
  end

  defp project_value(%{} = map, template) do
    Enum.reduce(template, %{}, fn
      {:prim, k}, acc ->
        Map.put(acc, k, Map.get(map, k))

      {:nested, k, sub_template}, acc ->
        Map.put(acc, k, project_value(Map.get(map, k), sub_template))

      {:multi, entries}, acc ->
        Enum.reduce(entries, acc, fn
          {:nested, k, sub_template}, inner ->
            Map.put(inner, k, project_value(Map.get(map, k), sub_template))
        end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Input parsers & helpers
  # ---------------------------------------------------------------------------

  defp parse_required_dt(input, key) do
    case non_empty_string(input[key]) do
      nil -> {:error, [missing_param_error(key)]}
      iso -> parse_iso_dt(iso, key)
    end
  end

  defp parse_optional_dt(input, key) do
    case Map.get(input, key) do
      nil -> {:ok, nil, nil}
      "" -> {:ok, nil, nil}
      iso when is_binary(iso) -> parse_iso_dt(iso, key)
      _ -> {:error, [invalid_arg_error(key, "INVALID_DATETIME", %{})]}
    end
  end

  defp parse_iso_dt(iso, key) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> {:ok, dt, DateTime.to_iso8601(dt)}
      {:error, _} -> {:error, [invalid_arg_error(key, "INVALID_DATETIME", %{"value" => iso})]}
    end
  end

  defp parse_coord(nil, _key, _min, _max), do: {:ok, nil}

  defp parse_coord(val, key, min_v, max_v) do
    parsed =
      cond do
        is_float(val) -> {:ok, val}
        is_integer(val) -> {:ok, val * 1.0}
        is_binary(val) ->
          case Float.parse(val) do
            {f, ""} -> {:ok, f}
            _ -> :error
          end
        true -> :error
      end

    case parsed do
      {:ok, f} when f >= min_v and f <= max_v -> {:ok, f}
      _ -> {:error, [invalid_arg_error(key, "INVALID_COORDINATE", %{"min" => min_v, "max" => max_v})]}
    end
  end

  defp format_coord(nil), do: nil
  defp format_coord(f) when is_float(f), do: Float.to_string(f)

  defp tenant_rows(bucket_map, tenant_id) do
    bucket_map |> Map.values() |> Enum.filter(&(&1["tenantId"] == tenant_id))
  end

  defp header_value(conn, name) do
    case get_req_header(conn, name) do
      [val | _] -> non_empty_string(val)
      _ -> nil
    end
  end

  defp non_empty_string(v) when is_binary(v) and byte_size(v) > 0, do: v
  defp non_empty_string(_), do: nil

  defp normalize_pos_int(v, _default) when is_integer(v) and v > 0, do: v
  defp normalize_pos_int(_, default), do: default

  defp normalize_non_neg_int(v, _default) when is_integer(v) and v >= 0, do: v
  defp normalize_non_neg_int(_, default), do: default

  defp json_resp(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  # ---------------------------------------------------------------------------
  # AshTypescript RPC Error Builders
  # ---------------------------------------------------------------------------

  defp rpc_failure(errors), do: %{"success" => false, "errors" => errors}

  defp missing_param_error(param) do
    %{
      "type" => "missing_required_parameter",
      "message" => "Required parameter #{param} is missing or empty",
      "shortMessage" => "Missing required parameter",
      "vars" => %{"parameter" => param},
      "fields" => [],
      "path" => [],
      "details" => %{"suggestion" => "Ensure #{param} parameter is provided and not empty"}
    }
  end

  defp empty_fields_array_error do
    %{
      "type" => "empty_fields_array",
      "message" => "Fields array cannot be empty",
      "shortMessage" => "Empty fields array",
      "vars" => %{},
      "fields" => [],
      "path" => [],
      "details" => %{"suggestion" => "Provide at least one field name in the fields array"}
    }
  end

  defp action_not_found_error(action) do
    %{
      "type" => "action_not_found",
      "message" => "RPC action #{action} not found",
      "shortMessage" => "Action not found",
      "vars" => %{"actionName" => action},
      "fields" => [],
      "path" => [],
      "details" => %{}
    }
  end

  defp unknown_field_error(field, "map", path) do
    full = full_path(path, field)

    %{
      "type" => "unknown_map_field",
      "message" => "Unknown field #{full} for map return type",
      "shortMessage" => "Unknown map field",
      "vars" => %{"field" => full},
      "fields" => [full],
      "path" => path,
      "details" => %{}
    }
  end

  defp unknown_field_error(field, resource, path) do
    full = full_path(path, field)

    %{
      "type" => "unknown_field",
      "message" => "Unknown field #{full} for resource #{resource}",
      "shortMessage" => "Unknown field",
      "vars" => %{"field" => full, "resource" => resource},
      "fields" => [full],
      "path" => path,
      "details" => %{}
    }
  end

  defp requires_field_selection_error(field, path) do
    full = full_path(path, field)

    %{
      "type" => "requires_field_selection",
      "message" => "Map #{full} requires field selection",
      "shortMessage" => "Field selection required",
      "vars" => %{"field" => full},
      "fields" => [full],
      "path" => path,
      "details" => %{}
    }
  end

  defp field_no_nesting_error(field, path) do
    full = full_path(path, field)

    %{
      "type" => "field_does_not_support_nesting",
      "message" => "Field #{full} does not support nested field selection",
      "shortMessage" => "Field does not support nesting",
      "vars" => %{"field" => full},
      "fields" => [full],
      "path" => path,
      "details" => %{}
    }
  end

  defp duplicate_field_error(field, path) do
    full = full_path(path, field)

    %{
      "type" => "duplicate_field",
      "message" => "Field #{full} was requested multiple times",
      "shortMessage" => "Duplicate field",
      "vars" => %{"field" => full},
      "fields" => [full],
      "path" => path,
      "details" => %{}
    }
  end

  defp invalid_field_format_error(spec, path) do
    %{
      "type" => "invalid_field_format",
      "message" => "Invalid field specification format",
      "shortMessage" => "Invalid field format",
      "vars" => %{},
      "fields" => [],
      "path" => path,
      "details" => %{"fieldSpec" => inspect(spec)}
    }
  end

  defp invalid_arg_error(field, message, vars) do
    %{
      "type" => "invalid_changes",
      "message" => message,
      "shortMessage" => "Invalid changes",
      "vars" => vars,
      "fields" => [field],
      "path" => [],
      "details" => %{}
    }
  end

  defp full_path([], field), do: field
  defp full_path(path, field), do: Enum.join(path ++ [field], ".")

  # ---------------------------------------------------------------------------
  # Built-in Contract Probe Checks (for check/0)
  # ---------------------------------------------------------------------------

  defp dispatch_rpc(body, headers \\ []) do
    all_headers =
      [
        {"authorization", "Bearer #{@default_token}"},
        {"content-type", "application/json"},
        {"accept", "application/json"}
      ] ++ headers

    resp = Support.dispatch(__MODULE__, "POST", "/internal-api/rpc/run", body: Jason.encode!(body), headers: all_headers)
    {resp.status, Jason.decode!(resp.body)}
  end

  defp probe_auth_401(seed) do
    resp =
      Support.dispatch(__MODULE__, "POST", "/internal-api/rpc/run",
        body: Jason.encode!(%{"action" => "morning_view", "tenant" => seed.tenant_slug, "fields" => ["generatedAt"]}),
        headers: [{"content-type", "application/json"}]
      )

    Support.assert_equal(resp.status, 401, "missing bearer token must 401")
    Support.assert_equal(Jason.decode!(resp.body)["error"], "unauthorized", "401 error code")
  end

  defp probe_invalid_fields_spec(seed) do
    {status, body} =
      dispatch_rpc(%{"action" => "morning_view", "tenant" => seed.tenant_slug, "fields" => "generatedAt"})

    Support.assert_equal(status, 400, "non-list fields spec must 400")
    Support.assert_equal(body["error"], "invalid_fields_spec", "400 invalid_fields_spec error")
  end

  defp probe_tenant_arm(_seed) do
    {s1, b1} = dispatch_rpc(%{"action" => "list_clients", "fields" => ["id"]})
    Support.assert_equal(s1, 400, "missing tenant must 400")
    Support.assert_equal(b1["error"], "tenant_required", "tenant_required error")

    {s2, b2} = dispatch_rpc(%{"action" => "list_clients", "tenant" => "no-such-tenant", "fields" => ["id"]})
    Support.assert_equal(s2, 400, "unknown tenant must 400")
    Support.assert_equal(b2["error"], "unknown_tenant", "unknown_tenant error")
  end

  defp probe_morning_view_required_fields(seed) do
    {200, missing} = dispatch_rpc(%{"action" => "morning_view", "tenant" => seed.tenant_slug})
    Support.assert_equal(missing["success"], false, "morning_view without fields must refuse")
    Support.assert_equal(hd(missing["errors"])["type"], "missing_required_parameter", "missing fields type")

    {200, empty} = dispatch_rpc(%{"action" => "morning_view", "tenant" => seed.tenant_slug, "fields" => []})
    Support.assert_equal(empty["success"], false, "morning_view with [] fields must refuse")
    Support.assert_equal(hd(empty["errors"])["type"], "empty_fields_array", "empty fields type")
  end

  defp probe_morning_view_projection(seed) do
    fields = [
      "generatedAt",
      %{"workOrders" => ["total", %{"byStatus" => ["dispatched", "inProgress"]}]},
      %{"invoices" => ["total", "outstandingTotal"]},
      %{"sla" => ["openWithDeadline", "pastDeadline", "conformancePct"]}
    ]

    {200, non_money} = dispatch_rpc(%{"action" => "morning_view", "tenant" => seed.tenant_slug, "fields" => fields})
    Support.assert_equal(non_money["success"], true, "morning_view succeeds with fields")
    Support.assert_equal(Map.keys(non_money["data"]) |> Enum.sort(), ["generatedAt", "invoices", "sla", "workOrders"], "selected top-level keys only")
    Support.assert_equal(non_money["data"]["invoices"]["outstandingTotal"], nil, "non-money role redacts money to nil")

    {200, fin} =
      dispatch_rpc(
        %{"action" => "morning_view", "tenant" => seed.tenant_slug, "fields" => fields},
        [{"x-actor-role", "finance_controller"}]
      )

    Support.assert_equal(fin["data"]["invoices"]["outstandingTotal"], "125.50", "finance role sees money total")
  end

  defp probe_list_clients(seed) do
    {200, res} =
      dispatch_rpc(%{
        "action" => "list_clients",
        "tenant" => seed.tenant_slug,
        "fields" => ["id", "name", "classification"],
        "sort" => "-name",
        "page" => %{"limit" => 1, "offset" => 0, "count" => true}
      })

    Support.assert_equal(res["success"], true, "list_clients succeeds")
    Support.assert_equal(res["data"]["count"], 2, "tenant-scoped client count")
    Support.assert_equal(res["data"]["hasMore"], true, "pagination hasMore")
    Support.assert_equal(hd(res["data"]["results"])["name"], "Zephyr Broker", "sort=-name puts Zephyr first")
  end

  defp probe_list_work_orders(seed) do
    {200, res} =
      dispatch_rpc(%{
        "action" => "list_work_orders",
        "tenant" => seed.tenant_slug,
        "input" => %{"search" => "freezer"},
        "fields" => ["id", "externalWoNumber", "state"]
      })

    Support.assert_equal(res["success"], true, "list_work_orders succeeds")
    Support.assert_equal(length(res["data"]), 1, "search filters to matching WO")
    Support.assert_equal(hd(res["data"])["externalWoNumber"], "EXT-1001", "matching WO externalWoNumber")
  end

  defp probe_check_in_out(seed) do
    {200, ci} =
      dispatch_rpc(%{
        "action" => "check_in",
        "tenant" => seed.tenant_slug,
        "identity" => seed.visit_app_id,
        "input" => %{
          "internalCheckInAt" => seed.on_site_by,
          "externalCheckInAt" => seed.on_site_by,
          "arrivalLatitude" => 30.2672,
          "arrivalLongitude" => -97.7431
        },
        "fields" => ["id", "status", "geofenceVerified"]
      })

    Support.assert_equal(ci["success"], true, "check_in succeeds")
    Support.assert_equal(ci["data"]["status"], "on_site", "visit transitions to on_site")
    Support.assert_equal(ci["data"]["geofenceVerified"], true, "geofenceVerified computed server-side")

    put_record(:visits, seed.visit_app_id, Map.put(snapshot().visits[seed.visit_app_id], "status", "in_progress"))

    {200, co} =
      dispatch_rpc(%{
        "action" => "check_out",
        "tenant" => seed.tenant_slug,
        "identity" => seed.visit_app_id,
        "input" => %{
          "internalCheckOutAt" => seed.on_site_by,
          "externalCheckOutAt" => seed.on_site_by
        }
      })

    Support.assert_equal(co["success"], true, "check_out with omitted fields succeeds")
    Support.assert_equal(co["data"], %{}, "mutation with omitted fields returns %{}")
  end
end
