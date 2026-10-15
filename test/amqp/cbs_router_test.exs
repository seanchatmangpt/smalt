defmodule Smalt.Amqp.CbsRouterTest do
  use ExUnit.Case, async: false

  alias Smalt.Amqp.CbsRouter

  @key Base.encode64(:crypto.strong_rand_bytes(48))

  @cbs_type "servicebus.windows.net:sastoken"

  setup do
    Application.put_env(:smalt, :sb_shared_key, @key)
    on_exit(fn -> Application.delete_env(:smalt, :sb_shared_key) end)
    table = :ets.new(:cbs_test_claims, [:set, :public, keypos: 1])

    {:ok, router} =
      CbsRouter.start_link(name: nil, table: table, audience_config: nil)

    %{router: router, table: table}
  end

  defp sas(sr, se) do
    # String-to-sign is the URL-ENCODED sr, exactly as it appears in the token
    # (SAS spec / real-SDK form; see SasVerifier.check_signature/3).
    sig =
      :crypto.mac(:hmac, :sha256, @key, "#{URI.encode_www_form(sr)}\n#{se}")
      |> Base.encode64()
      |> URI.encode_www_form()

    "SharedAccessSignature sr=#{URI.encode_www_form(sr)}&sig=#{sig}&se=#{se}&skn=RootManageSharedAccessKey"
  end

  defp now, do: System.system_time(:second)

  defp put_req(name, opts \\ []) do
    %{
      operation: Keyword.get(opts, :operation, "put-token"),
      type: Keyword.get(opts, :type, @cbs_type),
      name: name,
      expiration: Keyword.get(opts, :expiration),
      token: Keyword.get(opts, :token, sas(name, now() + 600))
    }
  end

  test "valid put-token returns 200 and caches the claim", %{router: router} do
    assert {:ok, {200, "LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY"}} =
             CbsRouter.put_token(router, put_req("sb://q/one"))

    assert CbsRouter.authorized?(router, self(), "sb://q/one")
  end

  test "delete-token removes the claim", %{router: router} do
    CbsRouter.put_token(router, put_req("sb://q/two"))

    assert {:ok, {200, "LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY"}} =
             CbsRouter.delete_token(router, put_req("sb://q/two", operation: "delete-token"))

    refute CbsRouter.authorized?(router, self(), "sb://q/two")
  end

  test "delete-token is idempotent", %{router: router} do
    req = put_req("sb://q/never", operation: "delete-token")

    assert {:ok, {200, _}} = CbsRouter.delete_token(router, req)
  end

  test "unsupported operation returns 400 UNSUPPORTED_CBS_REQUEST", %{router: router} do
    assert {:error, {400, "UNSUPPORTED_CBS_REQUEST"}} =
             CbsRouter.put_token(router, put_req("sb://q/x", operation: "renew-token"))
  end

  test "unsupported token type returns 400 UNSUPPORTED_CBS_REQUEST", %{router: router} do
    assert {:error, {400, "UNSUPPORTED_CBS_REQUEST"}} =
             CbsRouter.put_token(router, put_req("sb://q/x", type: "jwt"))
  end

  test "invalid sas returns 401 INVALID_LOCAL_SAS", %{router: router} do
    req =
      put_req("https://a.example.com/q",
        token: sas("https://b.example.com/q", now() + 600)
      )

    assert {:error, {401, "INVALID_LOCAL_SAS"}} = CbsRouter.put_token(router, req)
    refute CbsRouter.authorized?(router, self(), "https://a.example.com/q")
  end

  test "invalid cbs body shapes return 400 INVALID_CBS_BODY", %{router: router} do
    assert {:error, {400, "INVALID_CBS_BODY"}} = CbsRouter.put_token(router, :not_a_map)

    assert {:error, {400, "INVALID_CBS_BODY"}} =
             CbsRouter.put_token(router, put_req("sb://q/x", token: nil))

    bad_delete = %{
      operation: "delete-token",
      type: @cbs_type,
      name: 7,
      token: "SharedAccessSignature sr=x"
    }

    assert {:error, {400, "INVALID_CBS_BODY"}} = CbsRouter.delete_token(router, bad_delete)
  end

  test "per-connection claim cap of 128 returns 429 CLAIM_CAPACITY", %{router: router} do
    # Cap is PER-CONNECTION (per owner_ref), not total (F2): one owner alone
    # can exhaust its own ceiling.
    1..128
    |> Enum.each(fn i ->
      assert {:ok, {200, _}} = CbsRouter.put_token(router, put_req("sb://cap/q#{i}"), :owner_a)
    end)

    assert {:error, {429, "CLAIM_CAPACITY"}} =
             CbsRouter.put_token(router, put_req("sb://cap/q129"), :owner_a)

    # Existing claims are untouched.
    assert CbsRouter.authorized?(router, :owner_a, "sb://cap/q1")
  end

  test "one connection at its cap does not block another connection's put-token (F2)",
       %{router: router} do
    1..128
    |> Enum.each(fn i ->
      assert {:ok, {200, _}} = CbsRouter.put_token(router, put_req("sb://sat/q#{i}"), :saturated)
    end)

    # Saturated owner is refused...
    assert {:error, {429, "CLAIM_CAPACITY"}} =
             CbsRouter.put_token(router, put_req("sb://sat/q129"), :saturated)

    # ...but a fresh connection still gets claims through.
    assert {:ok, {200, _}} = CbsRouter.put_token(router, put_req("sb://fresh/q1"), :fresh)
    assert CbsRouter.authorized?(router, :fresh, "sb://fresh/q1")
  end

  test "refreshing an existing claim does not hit the cap", %{router: router} do
    assert {:ok, {200, _}} = CbsRouter.put_token(router, put_req("sb://r/q1"), :owner_a)

    assert {:ok, {200, _}} =
             CbsRouter.put_token(router, put_req("sb://r/q1", expiration: now() + 100), :owner_a)

    assert CbsRouter.authorized?(router, :owner_a, "sb://r/q1")
  end

  test "gc removes only expired claims", %{router: router, table: table} do
    CbsRouter.put_token(router, put_req("sb://g/live", expiration: now() + 1000), :o1)
    :ets.insert(table, {{:o2, "sb://g/dead"}, %{expires: now() - 1}})

    assert CbsRouter.gc(router) == 1
    assert CbsRouter.authorized?(router, :o1, "sb://g/live")
    refute CbsRouter.authorized?(router, :o2, "sb://g/dead")
  end

  test "expired claim is not authorized", %{router: router, table: table} do
    :ets.insert(table, {{:o3, "sb://g/exp"}, %{expires: now() - 5}})
    refute CbsRouter.authorized?(router, :o3, "sb://g/exp")
  end
end
