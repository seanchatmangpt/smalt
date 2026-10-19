defmodule SmaltTest.Azsim.TopologyTest do
  @moduledoc """
  AZB-10 — Cross-plane wiring court (loopback only, zero egress).

  Accept legs over REAL sockets — the falsifier is any cross-plane call
  resolved in-process (no socket):

    1. Token minted from the identity-plane STS over the wire (real TCP to the
       ARM listener, the identity surface per AZB-09) is ACCEPTED by the data
       plane (real TCP to the egress listener; cross-seat acceptance rides the
       mint-time trusted-authority registry). A token signed by a foreign key
       is refused 401 (signature). A token with a foreign issuer claim
       (correct secret) is refused 401 (issuer) — the anti-vacuity target.
    2. ARM resource PUT emits Event Grid `Microsoft.Resources.ResourceWriteSuccess`
       to the integration plane: Event Grid topic fan-out delivers to a live
       subscriber AND the Service Bus bridge queue yields the same event to a
       QueueStore subscriber.
    3. Egress guard: non-loopback/non-peer endpoints are refused typed
       (`R_missing_authority`) with telemetry + counter; the cross-plane wire
       legs complete with a DELTA OF 0 refused connects (zero egress).

  Anti-vacuity (witnessed in receipt): disabling the issuer check flips
  the foreign-issuer test from PASS to FAIL.
  """

  use ExUnit.Case, async: false
  import SmaltTest.Wire, only: [http_request: 3, http_request: 4]

  alias Smalt.Amqp.QueueStore
  alias Smalt.EgressRouter.Peers
  alias Smalt.Messaging.EventGrid
  alias SmaltTest.Env

  @secret "smalt-azb10-topology-test-secret-0123456789abcdef"
  @foreign_secret "smalt-azb10-foreign-key-not-ours-0123456789"
  @foreign_iss "https://evil.example/00000000-0000-0000-0000-000000000000/v2.0"
  @bridge_queue "resourcewritesuccess"

  setup do
    assert :ok = SmaltTest.Lifecycle.ensure_store_up()

    # Enforce-mode pin for the whole module (restored on_exit by Env).
    Env.put_restored(auth_mode: :enforce, sts_signing_secret: @secret)

    :ok
  end

  # ===========================================================================
  # 1. Peer config + resolution (config-driven, loopback)
  # Config gap named per dispatch caveat: AZB-07/AZB-08 receipts are
  # outstanding; the :peers profile keys land HERE and the read site consumes
  # the app env directly (Smalt.Config is ontology-generated — no hand-edits).
  # ===========================================================================

  test "every plane profile pins :peers with loopback-only endpoints" do
    for profile <- ~w(control identity data integration) do
      path = Path.join([File.cwd!(), "config/env/az_prod_#{profile}.exs"])
      [{:smalt, kw}] = Config.Reader.read!(path, env: :test)

      peers = Keyword.fetch!(kw, :peers)
      assert is_list(peers) and peers != []

      for {plane, endpoint} <- peers do
        assert is_atom(plane)
        assert %URI{host: host} = URI.parse(endpoint)
        assert host in ["127.0.0.1", "localhost", "::1"], "#{profile}: #{endpoint}"
      end
    end
  end

  test "peer resolution is config-driven (no in-process shortcut)" do
    Env.with([peers: [identity: "https://127.0.0.1:9444"]], fn ->
      assert Peers.resolve(:identity) == "https://127.0.0.1:9444"
      assert Peers.resolve(:unknown_plane) == nil
    end)
  end

  # ===========================================================================
  # 2. Cross-plane token over the wire (identity STS -> data plane)
  # ===========================================================================

  test "identity-plane STS token accepted by data plane over the wire" do
    refused0 = Peers.refused_connects()

    arm_port = Smalt.Config.arm_port()
    egress_port = Application.get_env(:smalt, :egress_port, 8443)

    # -- identity plane: mint a token over a REAL socket ------------------------
    {:ok, token} = mint_over_wire(arm_port)

    # -- data plane: the minted token is accepted at the SIBLING seat -----------
    res =
      http_request(egress_port, "GET", "/dbs", headers: [
        {"authorization", "Bearer " <> token}
      ])

    assert res.status == 200, "data plane refused the identity-plane token: #{res.status} #{res.body}"

    # Zero egress over the wire legs.
    assert Peers.refused_connects() - refused0 == 0
  end

  test "token signed by foreign key refused 401 (signature)" do
    egress_port = Application.get_env(:smalt, :egress_port, 8443)

    token = mint_local(%{"iss" => "http://127.0.0.1:9443/organizations/v2.0"}, @foreign_secret)

    res =
      http_request(egress_port, "GET", "/dbs", headers: [
        {"authorization", "Bearer " <> token}
      ])

    assert res.status == 401, "foreign-signed token was accepted: #{res.status}"

    body = Jason.decode!(res.body)
    assert body["error"]["code"] == "InvalidAuthenticationToken"
    assert body["error"]["message"] == "SignatureVerificationFailed"
  end

  @tag :azb10_foreign_issuer
  test "foreign issuer claim refused 401 (anti-vacuity target)" do
    egress_port = Application.get_env(:smalt, :egress_port, 8443)

    token = mint_local(%{"iss" => @foreign_iss}, @secret)

    res =
      http_request(egress_port, "GET", "/dbs", headers: [
        {"authorization", "Bearer " <> token}
      ])

    assert res.status == 401, "foreign-issuer token was accepted: #{res.status}"

    body = Jason.decode!(res.body)
    assert body["error"]["message"] == "IssuerMismatch"
  end

  # ===========================================================================
  # 3. ARM PUT => ResourceWriteSuccess to integration plane
  # ===========================================================================

  test "ARM resource PUT emits ResourceWriteSuccess to integration plane" do
    arm_port = Smalt.Config.arm_port()
    refused0 = Peers.refused_connects()

    # Integration-plane subscribers: Event Grid topic subscriber + Service Bus
    # bridge queue subscriber.
    :ok = EventGrid.subscribe("resources", "azb10-topology", self())

    name = "azb10sa" <> unique()
    path = resource_path(name)

    # i24-warnings lane unblock fix (compile-freeze SLA, disclosed): the call
    # below originally passed a bare header list + `body:` keyword — an arity-5
    # call against http_request/4 that could not compile. Normalized to the
    # http_request/4 opts form.
    res =
      http_request(arm_port, "PUT", path,
        headers: [
          {"authorization", "Bearer " <> mint_local()},
          {"content-type", "application/json"}
        ],
        body:
          Jason.encode!(%{
            "location" => "eastus",
            "properties" => %{"skuName" => "Standard_LRS", "name" => name}
          })
      )

    assert res.status in [200, 201, 202], "resource PUT failed: #{res.status} #{res.body}"

    uri =
      "/subscriptions/s/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/#{name}"

    # Event Grid fan-out: subscriber receives the write-success event.
    assert_receive {:event_grid, "resources", "azb10-topology", _id, event}, 5_000
    assert event.event_type == "Microsoft.Resources.ResourceWriteSuccess"
    assert event.data["resourceUri"] == uri

    # Service Bus bridge: a QueueStore subscriber receives the same event.
    assert {:ok, body} = bridge_dequeue()
    assert body["event_type"] == "Microsoft.Resources.ResourceWriteSuccess"
    assert body["data"]["resourceUri"] == uri

    assert Peers.refused_connects() - refused0 == 0
  end

  # ===========================================================================
  # 4. Egress guard (typed refusal + telemetry, fail-closed)
  # ===========================================================================

  test "egress guard: peer endpoint allowed; non-peer non-loopback refused" do
    Env.with([peers: [identity: "https://127.0.0.1:9444"]], fn ->
      assert Peers.guard("https://127.0.0.1:9444/tenants") == :ok
      assert Peers.guard("https://peer-identity:9444/some/path") == {:refused, :R_missing_authority}
      assert Peers.guard("https://127.0.0.1:9444") == :ok
    end)
  end

  test "egress guard refusal counted and instrumented (R_missing_authority)" do
    parent = self()
    test_ref = make_ref()

    :telemetry.attach(
      "azb10-egress-refused",
      [:smalt, :egress, :refused],
      fn _name, _measure, _meta, ^test_ref -> send(parent, :refused_seen) end,
      test_ref
    )

    refused0 = Peers.refused_connects()

    assert Peers.guard("https://stranger.example.net/x") == {:refused, :R_missing_authority}

    assert_receive :refused_seen, 5_000
    assert Peers.refused_connects() - refused0 == 1

    :telemetry.detach("azb10-egress-refused")
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp mint_over_wire(arm_port) do
    form =
      URI.encode_query(%{
        "grant_type" => "client_credentials",
        "client_id" => "azb10-client",
        "client_secret" => "azb10-secret"
      })

    res =
      http_request(arm_port, "POST", "/organizations/oauth2/v2.0/token", headers: [
        {"content-type", "application/x-www-form-urlencoded"}
      ],
      body: form)

    assert res.status == 200, "wire mint failed: #{res.status} #{res.body}"
    {:ok, Jason.decode!(res.body)["access_token"]}
  end

  defp mint_local(claims_override \\ %{}, secret \\ @secret) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "aud" => "https://management.azure.com",
          "iss" => "http://127.0.0.1:9443/organizations/v2.0",
          "iat" => now,
          "nbf" => now,
          "exp" => now + 3600
        },
        claims_override
      )

    {:ok, token, _} = Joken.generate_and_sign(%{}, claims, Joken.Signer.create("HS256", secret))
    token
  end

  defp resource_path(name) do
    api_v = Smalt.Registry.latest_version("Microsoft.Storage/storageAccounts") || "2021-04-01"

    "/subscriptions/s/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/#{name}" <>
      "?api-version=#{api_v}"
  end

  # Drains the Service Bus bridge queue until the ResourceWriteSuccess event is
  # found or the queue is empty (bounded; message-based, no Process.sleep).
  defp bridge_dequeue do
    bridge_dequeue(@bridge_queue, 200)
  end

  defp bridge_dequeue(_queue, 0), do: :empty

  defp bridge_dequeue(queue, n) do
    case QueueStore.dequeue_matching(queue) do
      {:ok, msg, lock} ->
        case Jason.decode(msg.body) do
          {:ok, %{"event_type" => "Microsoft.Resources.ResourceWriteSuccess"}} = ok ->
            :ok = QueueStore.complete(queue, msg.seq)
            ok

          _other ->
            :ok = QueueStore.complete(queue, msg.seq)
            bridge_dequeue(queue, n - 1)
        end

      :empty ->
        :empty
    end
  end

  defp unique, do: System.unique_integer([:positive]) |> Integer.to_string()
end
