defmodule SmaltTest.Azsim.ControlPlaneTest do
  @moduledoc """
  AZB-05 — Control plane profile (ARM) acceptance court.

  Spec surface: `:plane :control` profile
  (`config/env/az_prod_control.exs`: `:arm_gateway port→:arm_port 9443,
  strict_version_validation: true`; `:graph_law enforcement: :fail_closed`).

  Behaviors under court:

    * strict_version_validation: an api-version request naming an UNADMITTED
      provider/type is refused 400 InvalidApiVersionParameter with
      NoRegisteredProviderFound in the message (refusal-tier vocabulary from
      docs/jira/v26.10.18/rewrite-drafts/apiversion-refusal.md). Default mode
      (no profile) keeps the KD-78 permissive pass-through — the default boot
      is byte-identical.
    * monotonic gate unchanged: 1999-01-01 on an admitted type is 400
      InvalidApiVersionParameter naming the latest supported version (KD-78).
    * fail_closed: a configured-but-unavailable graphlaw engine yields a typed
      503 EngineUnavailable (:engine_unavailable) and ZERO admission — the
      resource is never persisted.
    * the :fail_open face of the same engine-down state keeps the historical
      400 InvalidResourceShape — the anti-vacuity flip surface.
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Store

  @opts Router.init([])
  @sub "00000000-0000-0000-0000-000000000000"

  setup do
    ensure_store()
    Store.clear()

    Store.put(:smalt_subscriptions, @sub, %{
      "id" => "/subscriptions/#{@sub}",
      "subscriptionId" => @sub,
      "displayName" => "AZB-05 control plane",
      "state" => "Enabled"
    })

    :ok
  end

  defp call(conn), do: Router.call(conn, @opts)

  defp ensure_store do
    case Store.start_link([]) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        if :ets.info(:smalt_subscriptions) == :undefined do
          pid = Process.whereis(Store)
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> ensure_store()
          after
            250 -> :ok
          end
        else
          :ok
        end
    end
  end

  @control_profile_keys [:arm_port, :arm_gateway, :graph_law]

  test "control plane profile file carries the AZB-05 spec keys" do
    {kw, _} =
      Code.eval_file(Path.join([File.cwd!(), "config/env/az_prod_control.exs"]))

    config_rows =
      kw
      |> Enum.filter(&match?({:config, :smalt, _, _}, &1))
      |> Enum.map(fn {:config, :smalt, key, value} -> {key, value} end)

    assert {:arm_port, 9443} in config_rows
    assert {:arm_gateway, [strict_version_validation: true]} in config_rows
    assert {:graph_law, [enforcement: :fail_closed]} in config_rows
    # Port single-source law (AZB-04): the :arm_gateway profile keyword list
    # carries NO port key — the flat :arm_port is the single source.
    {_, arm_gateway_kw} = Enum.find(config_rows, &match?({:arm_gateway, _}, &1))
    refute Keyword.has_key?(arm_gateway_kw, :port)
    refute Enum.any?(config_rows, fn {k, _} -> k not in @control_profile_keys end)
  end

  test "profile maps onto flat config keys (one source per port)" do
    # Simulate the runtime profile import the way config/runtime.exs does and
    # confirm the accessors read exactly the profile values.
    SmaltTest.Env.with(
      [
        arm_port: 9443,
        arm_gateway: [strict_version_validation: true],
        graph_law: [enforcement: :fail_closed]
      ],
      fn ->
        assert Smalt.Config.arm_port() == 9443
        assert Smalt.Config.arm_gateway() == [strict_version_validation: true]
        assert Smalt.Config.graph_law() == [enforcement: :fail_closed]
      end
    )
  end

  describe "strict_version_validation" do
    test "unadmitted provider type is refused 400 InvalidApiVersionParameter / NoRegisteredProviderFound" do
      SmaltTest.Env.with(
        [arm_gateway: [strict_version_validation: true]],
        fn ->
          conn =
            conn(
              :put,
              "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Contoso/widgets/w-1?api-version=2021-12-02",
              %{"location" => "eastus"}
            )
            |> call()

          assert conn.status == 400
          err = Jason.decode!(conn.resp_body)["error"]
          assert err["code"] == "InvalidApiVersionParameter"
          assert err["message"] =~ "NoRegisteredProviderFound"
          assert err["message"] =~ "Microsoft.Contoso/widgets"
        end
      )
    end

    test "admitted type with unknown (beyond-latest) api-version stays 400 InvalidApiVersionParameter (KD-78)" do
      SmaltTest.Env.with([arm_gateway: [strict_version_validation: true]], fn ->
        conn =
          conn(
            :put,
            "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/azb05-a?api-version=1999-01-01",
            %{"location" => "eastus"}
          )
          |> call()

        assert conn.status == 400
        err = Jason.decode!(conn.resp_body)["error"]
        assert err["code"] == "InvalidApiVersionParameter"

        latest = Smalt.Registry.latest_version("Microsoft.Storage/storageAccounts")

        assert err["message"] =~
                 "The api-version '1999-01-01' is invalid. The latest supported api-version for 'Microsoft.Storage/storageAccounts' is '#{latest}'."
      end)
    end

    test "missing api-version stays 400 MissingApiVersionParameter under strict" do
      SmaltTest.Env.with([arm_gateway: [strict_version_validation: true]], fn ->
        conn =
          conn(
            :put,
            "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/azb05-b",
            %{"location" => "eastus"}
          )
          |> call()

        assert conn.status == 400
        assert Jason.decode!(conn.resp_body)["error"]["code"] == "MissingApiVersionParameter"
      end)
    end

    test "default mode (strict off) keeps the KD-78 permissive pass-through for unadmitted types" do
      # No :arm_gateway profile — today's behavior: the api-version gate
      # passes unadmitted types through to the admission gate (400
      # InvalidResourceShape), never the NoRegisteredProviderFound face.
      conn =
        conn(
          :put,
          "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Contoso/widgets/w-2?api-version=2021-12-02",
          %{"location" => "eastus"}
        )
        |> call()

      assert conn.status == 400
      err = Jason.decode!(conn.resp_body)["error"]
      assert err["code"] == "InvalidResourceShape"
      refute err["message"] =~ "NoRegisteredProviderFound"
    end
  end

  describe "graph_law fail_closed" do
    @engine_down [graphlaw_engine: :ash_graphlaw]

    test "engine down + fail_closed: PUT is a typed 503 :engine_unavailable and NOTHING is admitted" do
      res_id =
        String.downcase(
          "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/azb05-fc"
        )

      SmaltTest.Env.with(
        [graph_law: [enforcement: :fail_closed] ++ engine_down_env()],
        fn ->
          conn =
            put_storage_account("azb05-fc")
            |> call()

          assert conn.status == 503
          err = Jason.decode!(conn.resp_body)["error"]
          assert err["code"] == "EngineUnavailable"
          assert err["message"] =~ ":engine_unavailable"
          assert err["target"] == "AshGraphLaw.Enforcement"

          # Falsifier face: no request admitted while the engine is down.
          assert Store.get(:smalt_resources, res_id) == :error
        end
      )
    end

    test "engine down + fail_open (anti-vacuity face): same state is the historical 400 InvalidResourceShape, NOT 503" do
      SmaltTest.Env.with(
        [graph_law: [enforcement: :fail_open] ++ engine_down_env()],
        fn ->
          conn = put_storage_account("azb05-fo") |> call()

          assert conn.status == 400
          err = Jason.decode!(conn.resp_body)["error"]
          assert err["code"] == "InvalidResourceShape"
          assert err["message"] =~ "engine_unavailable"
        end
      )
    end

    test "engine down + NO profile: historical 400 face (default boot unchanged)" do
      SmaltTest.Env.with(engine_down_env(), fn ->
        conn = put_storage_account("azb05-plain") |> call()

        assert conn.status == 400
        assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidResourceShape"
      end)
    end

    defp engine_down_env do
      # Engine-down without any double: the :ash_graphlaw fast path is
      # configured but the engine module is not loadable in this env —
      # precisely Smalt.GraphLaw.Validator's {:refused, :engine_unavailable}
      # semantics (real configured-engine state, no fake).
      [graphlaw_engine: :ash_graphlaw]
    end

    test "engine up (local validation) + fail_closed: PUT still admits normally" do
      SmaltTest.Env.with([graph_law: [enforcement: :fail_closed]], fn ->
        conn = put_storage_account("azb05-up") |> call()

        assert conn.status in [200, 201]
      end)
    end
  end

  test "happy path: PUT storageAccounts admits with x-ms-request-id under the control profile" do
    SmaltTest.Env.with(
      [
        arm_gateway: [strict_version_validation: true],
        graph_law: [enforcement: :fail_closed],
        lro_delay_ms: 0
      ],
      fn ->
        conn =
          conn(
            :put,
            "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/azb05-ok?api-version=2021-12-02",
            %{"location" => "eastus", "properties" => %{"skuName" => "Standard_LRS"}}
          )
          |> put_req_header("x-ms-request-id", "azb05-req-echo-1")
          |> call()

        assert conn.status in [200, 201]

        assert %{"properties" => %{"provisioningState" => "Succeeded"}} =
                 Jason.decode!(conn.resp_body)

        assert get_resp_header(conn, "x-ms-request-id") == ["azb05-req-echo-1"]
      end
    )
  end

  defp put_storage_account(name) do
    conn(
      :put,
      "/subscriptions/#{@sub}/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/#{name}?api-version=2021-12-02",
      %{"location" => "eastus", "properties" => %{"skuName" => "Standard_LRS"}}
    )
  end
end
