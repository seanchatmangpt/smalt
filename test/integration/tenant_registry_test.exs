defmodule Smalt.Test.Integration.TenantRegistryTest do
  @moduledoc """
  C1-TENANT closure court (divergence lane D2) — GET /tenants over the real
  wire after a real STS mint under a foreign tenant.

  Law: the persisted mint registry (the sign-ins ring,
  `Smalt.Egress.SignIns`, which every successful token-endpoint mint already
  feeds) is the source for the tenant list: home tenant always present
  (tenantCategory "Home"), every minted foreign tenant listed with a distinct
  `id` = "/tenants/{tenantId}", documented ARM TenantListResult envelope.
  Chicago discipline: real HTTP mint + real HTTP list, assertions on final
  wire state, no mocks.
  """

  use ExUnit.Case, async: false

  @home "00000000-0000-0000-0000-000000000000"
  @mint_tenant "courtroom-ai"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:smalt)
    :timer.sleep(1500)
    :ok
  end

  defp arm_base do
    "http://127.0.0.1:" <> Integer.to_string(Application.fetch_env!(:smalt, :arm_port))
  end

  defp mint(tenant) do
    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(:post,
        {String.to_charlist("#{arm_base()}/#{tenant}/oauth2/v2.0/token"), [],
         ~c"application/x-www-form-urlencoded",
         "grant_type=client_credentials&client_id=tenant-registry-court&client_secret=x&scope=s"},
        [],
        []
      )

    %{"access_token" => token} = Jason.decode!(body)
    token
  end

  defp fetch_tenants(token) do
    {:ok, {{_, status, _}, _, body}} =
      :httpc.request(:get,
        {String.to_charlist("#{arm_base()}/tenants"),
         [{~c"authorization", ~c"Bearer " ++ String.to_charlist(token)}]},
        [],
        []
      )

    {status, body}
  end

  test "mint under courtroom-ai -> /tenants lists it with a distinct id; home always present" do
    Smalt.Egress.SignIns.clear()
    token = mint(@mint_tenant)

    {200, body} = fetch_tenants(token)
    assert %{"value" => rows} = Jason.decode!(body)

    home = Enum.find(rows, &(&1["tenantId"] == @home))
    assert %{"tenantCategory" => "Home", "displayName" => "Sovereign"} = home
    assert home["id"] == "/tenants/#{@home}"

    minted = Enum.find(rows, &(&1["tenantId"] == @mint_tenant))
    assert %{"id" => id, "displayName" => @mint_tenant} = minted
    assert id == "/tenants/#{@mint_tenant}"
    assert id != home["id"]

    # Documented envelope: every row carries the required members; no
    # duplicate tenantIds; minted rows carry no tenantCategory (only the home
    # tenant is "Home" in real ARM).
    assert length(rows) >= 2
    assert rows == Enum.uniq_by(rows, & &1["tenantId"])

    for row <- rows do
      assert is_binary(row["id"]) and is_binary(row["tenantId"])
    end

    assert Enum.all?(rows, &(&1["tenantCategory"] in [nil, "Home"]))
  end
end
