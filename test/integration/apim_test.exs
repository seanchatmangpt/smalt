# Integration-tier court: T-07 API Management resource model + policy
# execution (receipt r16).
#
# Chicago discipline: real Smalt.Store rows (:smalt_resources), real policy
# XML parsing (SweetXml/xmerl), real in-process Plug.Test dispatch against
# Smalt.DataPlane.ApimGateway, real JWT verification through
# Smalt.Auth.Bearer.verify_bearer/1 (STS keys, no mocks), and a REAL
# listening backend (Bandit on an OS-reserved port, ja5/sj4 pattern) so the
# Finch forwarding leg crosses an actual TCP hop. No mocks anywhere.
#
# NOT RUN from the authoring lane (compile-freeze SLA): the integrator runs
# `mix test test/integration/apim_test.exs` after applying the wiring patch
# in docs/jira/v26.10.28/receipts/r16-t07-apim.md. The court is
# self-contained: it drives the gateway plug directly, so it stays green
# with or without the router wiring.

defmodule Smalt.Integration.ApimCourtBackend do
  # The court's backend service: echoes method/path/headers so the
  # set-header leg can prove the rewrite reached the backend conn.
  @moduledoc false

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/orders/:id" do
    send_resp(
      conn,
      200,
      Jason.encode!(%{
        "backend" => "court",
        "id" => id,
        "seen" => %{
          "method" => conn.method,
          "path" => conn.request_path,
          "query" => conn.query_string,
          "headers" => Enum.into(conn.req_headers, %{})
        }
      })
    )
  end

  match _ do
    send_resp(
      conn,
      200,
      Jason.encode!(%{
        "backend" => "court",
        "seen" => %{
          "method" => conn.method,
          "path" => conn.request_path,
          "headers" => Enum.into(conn.req_headers, %{})
        }
      })
    )
  end
end

defmodule Smalt.Integration.ApimTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.DataPlane.Apim
  alias Smalt.DataPlane.ApimGateway

  @aud "https://management.azure.com"
  @tid "00000000-0000-0000-0000-000000000000"
  @sub "sub-apim-court"
  @rg "rg-apim-court"

  setup_all do
    # ja5/sj4 pattern: reserve an OS-assigned port, then bind the court
    # backend to it (avoids the fixed-port collision class entirely).
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)

    {:ok, _server} = Bandit.start_link(plug: Smalt.Integration.ApimCourtBackend, scheme: :http, port: port)

    %{backend_url: "http://127.0.0.1:#{port}"}
  end

  setup context do
    # Unique service name per test: real Store, real keys — isolation by
    # name, not by wiping shared state.
    svc = "apim-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

    {:ok, svc: svc, backend_url: context[:backend_url]}
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp seed_api(svc, backend_url) do
    api = "orders"
    op = "get-order"

    assert {:ok, 201, _} = Apim.put_service(@sub, @rg, svc, %{"location" => "eastus"})

    assert {:ok, 201, _} =
             Apim.put_api(@sub, @rg, svc, api, %{
               "properties" => %{"displayName" => api, "path" => api, "serviceUrl" => backend_url}
             })

    assert {:ok, 201, _} =
             Apim.put_operation(@sub, @rg, svc, api, op, %{
               "properties" => %{"displayName" => "Get order", "method" => "GET", "urlTemplate" => "/orders/{id}"}
             })

    {api, op}
  end

  defp put_policy_xml!(svc, scope, api, op, xml) do
    assert {:ok, _, _} = Apim.put_policy(@sub, @rg, svc, scope, api, op, "policy", xml)
    :ok
  end

  defp gw_call(method, path, opts \\ []) do
    conn =
      Plug.Test.conn(method, path, opts[:body])
      |> Map.put(:remote_ip, {127, 0, 0, 1})

    conn =
      case opts[:auth] do
        nil -> conn
        token -> Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
      end

    conn =
      case opts[:raw_auth] do
        nil -> conn
        value -> Plug.Conn.put_req_header(conn, "authorization", value)
      end

    conn
    |> Plug.Conn.put_req_header("x-apim-court", "gateway")
    |> ApimGateway.call([])
  end

  defp gw(svc, api, rest, opts \\ []) do
    gw_call(:get, "/api-gw/#{svc}/#{api}/#{rest}", opts)
  end

  defp mint_token(extra \\ %{}) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "aud" => @aud,
          "iss" => "https://login.microsoftonline.com/#{@tid}/v2.0",
          "exp" => now + 600,
          "nbf" => now,
          "tid" => @tid
        },
        extra
      )

    {:ok, token} = Smalt.Auth.StsKey.mint(claims)
    token
  end

  defp err_body(conn) do
    %{"error" => err} = Jason.decode!(conn.resp_body)
    err
  end

  # ---------------------------------------------------------------------------
  # ARM resource model
  # ---------------------------------------------------------------------------

  test "ARM CRUD: service/api/operation PUT/GET/LIST echo real ARM shapes" do
    svc = "crud-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

    {:ok, 201, service} = Apim.put_service(@sub, @rg, svc, %{"location" => "westus"})
    assert service["type"] == "Microsoft.ApiManagement/service"
    assert service["name"] == svc
    assert service["location"] == "westus"
    assert service["properties"]["provisioningState"] == "Succeeded"
    assert service["sku"]["name"] == "Developer"
    assert String.ends_with?(service["id"], "/service/#{svc}")

    # update is 200, not a second 201
    {:ok, 200, _} = Apim.put_service(@sub, @rg, svc, %{"location" => "westus"})

    # getters answer {:ok, record} | {:error, 404, code, msg} (mutators carry
    # the 200/201 face; getters are bare records).
    assert {:ok, got} = Apim.get_service(@sub, @rg, svc)
    assert got["id"] == service["id"]

    {:ok, 201, api} =
      Apim.put_api(@sub, @rg, svc, "echo", %{
        "properties" => %{"displayName" => "Echo", "path" => "echo-v1", "serviceUrl" => "http://backend"}
      })

    assert api["type"] == "Microsoft.ApiManagement/service/apis"
    assert api["properties"]["path"] == "echo-v1"

    {:ok, 201, op} =
      Apim.put_operation(@sub, @rg, svc, "echo", "greet", %{
        "properties" => %{"method" => "GET", "urlTemplate" => "/greet/{name}/{*rest}"}
      })

    assert op["type"] == "Microsoft.ApiManagement/service/apis/operations"

    # `in` demands exact map equality (same key set); the parameter maps carry
    # required/type too, so the assert is a subset-pattern match instead.
    params = op["properties"]["templateParameters"]
    assert Enum.any?(params, &match?(%{"name" => "name"}, &1))
    assert Enum.any?(params, &match?(%{"name" => "rest"}, &1))

    # parent-missing refusals carry the ARM parent message
    assert {:error, 404, "ResourceNotFound", msg} =
             Apim.put_api(@sub, @rg, "no-such-svc", "echo", %{})

    assert msg =~ "could not be found"

    # The Store is shared across the suite (isolation by NAME, not wiping):
    # list asserts are membership, never an exact single-element list.
    services = Apim.list_services(@sub, @rg)
    assert Enum.any?(services, &match?(%{"name" => ^svc}, &1))

    # DELETE cascades the child tree
    assert {:ok, 200, _} = Apim.delete_service(@sub, @rg, svc)
    assert {:error, 404, _, _} = Apim.get_api(@sub, @rg, svc, "echo")
    assert {:error, 404, _, _} = Apim.get_operation(@sub, @rg, svc, "echo", "greet")
  end

  test "policy scopes: service/api/operation all store ARM-exact policy records" do
    svc = "pol-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

    assert {:ok, 201, _} = Apim.put_service(@sub, @rg, svc, %{})
    assert {:ok, 201, _} = Apim.put_api(@sub, @rg, svc, "echo", %{})
    assert {:ok, 201, _} = Apim.put_operation(@sub, @rg, svc, "echo", "greet", %{})

    xml = "<policies><inbound><rate-limit calls=\"1\" renewal-period=\"60\"/></inbound></policies>"

    # raw-XML form (format=raw PUT face)
    assert {:ok, 201, _} = Apim.put_policy(@sub, @rg, svc, :service, nil, nil, "policy", xml)

    # ARM JSON form (az CLI / portal PUT face)
    assert {:ok, 201, _} =
             Apim.put_policy(@sub, @rg, svc, :api, "echo", nil, "policy", %{
               "properties" => %{"format" => "xml", "value" => xml}
             })

    assert {:ok, 201, _} =
             Apim.put_policy(@sub, @rg, svc, :operation, "echo", "greet", "policy", %{
               "properties" => %{"format" => "xml", "value" => xml}
             })

    assert {:ok, record} = Apim.get_policy(@sub, @rg, svc, :operation, "echo", "greet", "policy")
    assert record["properties"]["format"] == "xml"
    assert record["properties"]["value"] == xml
    assert record["type"] == "Microsoft.ApiManagement/service/apis/operations/policies"
  end

  # ---------------------------------------------------------------------------
  # malformed policy PUT -> typed 400 InvalidPolicyXml
  # ---------------------------------------------------------------------------

  test "malformed policy PUT refuses typed InvalidPolicyXml and stores nothing" do
    svc = "bad-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

    assert {:ok, 201, _} = Apim.put_service(@sub, @rg, svc, %{})

    # The policy scope parent must EXIST: the malformed refusals below then
    # provably come from the XML parse (parse runs before the parent check),
    # and the trailing valid-document PUT has a lawful parent to store under.
    assert {:ok, 201, _} = Apim.put_api(@sub, @rg, svc, "echo", %{})

    malformed = [
      # xmerl fatal: unclosed element
      "<policies><inbound><rate-limit calls=\"5\" renewal-period=\"60\"/></inbound>",
      # xmerl fatal: mismatched close tag
      "<policies><inbound></backend></policies>",
      # structural: wrong root
      "<config><inbound/></config>",
      # unsupported inbound policy element
      "<policies><inbound><choose><when condition=\"true\"/></choose></inbound></policies>",
      # missing required attribute
      "<policies><inbound><rate-limit renewal-period=\"60\"/></inbound></policies>",
      # non-integer calls
      "<policies><inbound><rate-limit calls=\"five\" renewal-period=\"60\"/></inbound></policies>",
      # set-header without name
      "<policies><inbound><set-header exists-action=\"overwrite\">x</set-header></inbound></policies>",
      # empty document
      "   "
    ]

    Enum.each(malformed, fn xml ->
      assert {:error, 400, "InvalidPolicyXml", msg} =
               Apim.put_policy(@sub, @rg, svc, :api, "echo", nil, "policy", xml),
             "expected InvalidPolicyXml for #{inspect(xml)}"

      assert is_binary(msg) and msg != ""
    end)

    # nothing was stored
    assert {:error, 404, _, _} = Apim.get_policy(@sub, @rg, svc, :api, "echo", nil, "policy")

    # and a VALID document still stores afterwards (the refusal is per-PUT)
    assert {:ok, 201, _} =
             Apim.put_policy(
               @sub,
               @rg,
               svc,
               :api,
               "echo",
               nil,
               "policy",
               "<policies><inbound><base/></inbound></policies>"
             )
  end

  # ---------------------------------------------------------------------------
  # gateway: set-header + backend forwarding
  # ---------------------------------------------------------------------------

  test "gateway forwards to the real backend with the set-header rewrite visible", %{
    svc: svc,
    backend_url: backend_url
  } do
    {api, op} = seed_api(svc, backend_url)

    put_policy_xml!(
      svc,
      :operation,
      api,
      op,
      """
      <policies>
        <inbound>
          <base/>
          <set-header name="X-Forwarded-Slice" exists-action="overwrite">smalt-apim</set-header>
        </inbound>
        <backend>
          <forward-request timeout="10"/>
        </backend>
      </policies>
      """
    )

    conn = gw(svc, api, "orders/42")

    assert conn.status == 200

    %{"backend" => "court", "id" => "42", "seen" => seen} = Jason.decode!(conn.resp_body)
    assert seen["method"] == "GET"
    assert seen["path"] =~ "/orders/42"
    assert seen["headers"]["x-forwarded-slice"] == "smalt-apim"
    # the client's own headers ride along
    assert seen["headers"]["x-apim-court"] == "gateway"
  end

  # ---------------------------------------------------------------------------
  # gateway: rate-limit fixed window
  # ---------------------------------------------------------------------------

  test "rate-limit admits 5 calls and 429s the 6th with Retry-After", %{
    svc: svc,
    backend_url: backend_url
  } do
    {api, op} = seed_api(svc, backend_url)

    put_policy_xml!(
      svc,
      :operation,
      api,
      op,
      "<policies><inbound><rate-limit calls=\"5\" renewal-period=\"60\" retry-after=\"7\"/></inbound></policies>"
    )

    # calls 1..5 forward (each reaches the real backend)
    for n <- 1..5 do
      conn = gw(svc, api, "orders/#{n}")
      assert conn.status == 200, "call #{n} should forward, got #{conn.status}"
    end

    # call 6 breaches the window
    refused = gw(svc, api, "orders/6")
    assert refused.status == 429
    assert Plug.Conn.get_resp_header(refused, "retry-after") == ["7"]

    assert %{"statusCode" => 429, "message" => "Rate limit is exceeded"} =
             Jason.decode!(refused.resp_body)

    # the window is scoped per policy target: a different operation on the
    # same api still forwards
    assert {:ok, 201, _} =
             Apim.put_operation(@sub, @rg, svc, api, "other", %{
               "properties" => %{"method" => "GET", "urlTemplate" => "/other"}
             })

    assert gw(svc, api, "other").status == 200
  end

  # ---------------------------------------------------------------------------
  # gateway: validate-jwt matrix
  # ---------------------------------------------------------------------------

  test "validate-jwt: tokenless and malformed tokens 401 with the Bearer challenge", %{
    svc: svc,
    backend_url: backend_url
  } do
    {api, op} = seed_api(svc, backend_url)

    put_policy_xml!(
      svc,
      :operation,
      api,
      op,
      "<policies><inbound><validate-jwt header-name=\"Authorization\"/></inbound></policies>"
    )

    missing = gw(svc, api, "orders/1")
    assert missing.status == 401
    assert err_body(missing)["code"] == "AuthenticationFailed"
    assert err_body(missing)["message"] =~ "token is not present"
    [challenge] = Plug.Conn.get_resp_header(missing, "www-authenticate")
    assert String.starts_with?(challenge, "Bearer ")
    assert challenge =~ "error=\"invalid_token\""

    garbage = gw(svc, api, "orders/1", auth: "not.a.jwt")
    assert garbage.status == 401
    assert err_body(garbage)["code"] == "InvalidAuthenticationToken"

    empty_scheme = gw(svc, api, "orders/1", raw_auth: "Bearer ")
    assert empty_scheme.status == 401
  end

  test "validate-jwt: valid token without the required claim 403s; with the claim forwards", %{
    svc: svc,
    backend_url: backend_url
  } do
    {api, op} = seed_api(svc, backend_url)

    put_policy_xml!(
      svc,
      :operation,
      api,
      op,
      """
      <policies>
        <inbound>
          <validate-jwt header-name="Authorization" failed-validation-error-message="Invalid JWT: missing reader role">
            <required-claims>
              <claim name="role" match="any">
                <value>reader</value>
                <value>contributor</value>
              </claim>
            </required-claims>
          </validate-jwt>
        </inbound>
      </policies>
      """
    )

    # valid STS token, but the payload lacks the claim -> 403
    no_claim = gw(svc, api, "orders/1", auth: mint_token())
    assert no_claim.status == 403
    assert err_body(no_claim)["message"] == "Invalid JWT: missing reader role"
    # 403 carries no challenge (the token authenticated fine)
    assert Plug.Conn.get_resp_header(no_claim, "www-authenticate") == []

    # token WITH the claim -> forwarded, backend saw a 3-part JWS
    ok = gw(svc, api, "orders/9", auth: mint_token(%{"role" => "reader"}))
    assert ok.status == 200
    %{"seen" => seen} = Jason.decode!(ok.resp_body)

    auth = seen["headers"]["authorization"]
    assert is_binary(auth) and String.starts_with?(auth, "Bearer ")
    assert length(String.split(auth, ".")) == 3

    # match="any": contributor satisfies too
    assert gw(svc, api, "orders/10", auth: mint_token(%{"role" => "contributor"})).status == 200
  end

  test "validate-jwt claims check the SIGNED payload, not a client-supplied one", %{
    svc: svc,
    backend_url: backend_url
  } do
    {api, op} = seed_api(svc, backend_url)

    put_policy_xml!(
      svc,
      :operation,
      api,
      op,
      "<policies><inbound><validate-jwt><required-claims><claim name=\"role\"><value>reader</value></claim></required-claims></validate-jwt></inbound></policies>"
    )

    # forge: take a valid token's header+payload shape but break the signature
    {:ok, token} = Smalt.Auth.StsKey.mint(mint_claims(%{"role" => "reader"}))
    [h, p, _s] = String.split(token, ".", parts: 3)
    forged = "#{h}.#{p}.FORGED-SIGNATURE"

    assert gw(svc, api, "orders/1", auth: forged).status == 401
  end

  defp mint_claims(extra) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "aud" => @aud,
        "iss" => "https://login.microsoftonline.com/#{@tid}/v2.0",
        "exp" => now + 600,
        "nbf" => now
      },
      extra
    )
  end

  # ---------------------------------------------------------------------------
  # gateway: path families + failure faces
  # ---------------------------------------------------------------------------

  test "ARM data-plane family: .../providers/Microsoft.ApiManagement/service/{svc}/apis/{api}/... serves the gateway", %{
    svc: svc,
    backend_url: backend_url
  } do
    {api, op} = seed_api(svc, backend_url)

    path =
      "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.ApiManagement/service/#{svc}/apis/#{api}/orders/1"

    conn = gw_call(:get, String.downcase(path))
    assert conn.status == 200
    %{"id" => "1"} = Jason.decode!(conn.resp_body)

    # the same family with an unknown api is a typed ARM 404
    bad =
      gw_call(
        :get,
        "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/microsoft.apimanagement/service/#{svc}/apis/nope/orders/1"
      )

    assert bad.status == 404
    assert err_body(bad)["code"] == "ResourceNotFound"
    _ = op
  end

  test "no-backend operation answers typed 502 BackendUnavailable" do
    svc = "nb-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

    assert {:ok, 201, _} = Apim.put_service(@sub, @rg, svc, %{})

    assert {:ok, 201, _} = Apim.put_api(@sub, @rg, svc, "orders", %{"properties" => %{"path" => "orders"}})

    assert {:ok, 201, _} =
             Apim.put_operation(@sub, @rg, svc, "orders", "get-order", %{
               "properties" => %{"method" => "GET", "urlTemplate" => "/orders/{id}"}
             })

    conn = gw(svc, "orders", "orders/1")
    assert conn.status == 502
    assert err_body(conn)["code"] == "BackendUnavailable"
  end

  test "pass-through: non-apim paths leave the conn untouched for the host router" do
    untouched = gw_call(:get, "/subscriptions/other-sub/resourcegroups/rg/providers/Microsoft.Storage/storageAccounts/acc/listKeys")
    assert untouched.state == :unset
    assert untouched.halted == false

    bare_base = gw_call(:get, "/api-gw")
    assert bare_base.state == :unset

    # unknown service inside the gateway base -> typed 404 (matched family)
    unknown = gw("no-such-service", "orders", "orders/1")
    assert unknown.status == 404
    assert err_body(unknown)["code"] == "ResourceNotFound"
  end
end
