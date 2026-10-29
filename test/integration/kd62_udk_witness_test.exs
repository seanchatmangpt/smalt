defmodule Smalt.Integration.Kd62UdkWitnessTest do
  # KD-62 close lane (W13-F): plug-conn witness court — real router, real
  # BlobStorage ETS, no mocks. Asserts the wire bytes of
  # `POST /{account}?comp=userdelegationkey` (typed user-delegation-key
  # envelope backed by real service metadata) and the K1 SAS-only refusal.
  use ExUnit.Case, async: false

  @account "acct-kd62"

  defp call(method, path, opts \\ []) do
    body = opts[:body]
    headers = opts[:headers] || []

    conn =
      Plug.Test.conn(method, path, body)
      |> Plug.Conn.put_req_header("x-ms-version", "2023-11-03")
      |> then(fn c -> Enum.reduce(headers, c, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end) end)

    Smalt.EgressRouter.call(conn, [])
  end

  describe "KD-62 user delegation key envelope" do
    test "POST comp=userdelegationkey answers the typed envelope" do
      conn =
        call(:post, "/#{@account}?comp=userdelegationkey",
          body: "<Key><Start>2026-10-20T00:00:00Z</Start><Expiry>2026-10-20T02:00:00Z</Expiry></Key>"
        )

      assert conn.status == 200

      assert %{
               "signedObject" => %{"account" => acc, "service" => "b", "version" => version},
               "tenant" => tenant,
               "user" => user,
               "delegatedUser" => delegated,
               "issuedTo" => issued_to,
               "value" => value,
               "expiry" => expiry
             } = Jason.decode!(conn.resp_body)

      assert acc == @account
      assert version == "2021-12-02"
      assert tenant == "00000000-0000-0000-0000-000000000000"
      assert user == delegated
      assert issued_to == "127.0.0.1"
      # real key material: 44-char base64 (32-byte HMAC output)
      assert byte_size(value) == 44
      assert expiry == "2026-10-20T02:00:00Z"

      # value is a REAL HMAC over the UDK string-to-sign with the
      # deterministic per-account dev key — independent recomputation matches
      expected_key = Base.encode64(:crypto.hash(:sha256, @account <> "smalt-dev-sb"))

      expected_value =
        Base.encode64(
          :crypto.mac(
            :hmac,
            :sha256,
            expected_key,
            Enum.join([@account, "b", "2021-12-02", "2026-10-20T00:00:00Z", expiry], "\n")
          )
        )

      assert value == expected_value
    end

    test "default window [now, now+1h] when the body is empty" do
      conn = call(:post, "/#{@account}?comp=userdelegationkey", body: "")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert %{"expiry" => expiry} = body
      {:ok, dt, _} = DateTime.from_iso8601(expiry)
      delta = DateTime.diff(dt, DateTime.utc_now(), :second)
      assert delta in 3500..3700
    end

    test "unknown comp on the account POST arm stays typed 404" do
      conn = call(:post, "/#{@account}?comp=somethingelse", body: "")
      assert conn.status == 404
      assert conn.resp_body =~ "RouteNotFound"
    end
  end

  describe "KD-62 SAS-only admission face" do
    test "SAS-only URI gets the typed refusal, never MissingXMsVersion" do
      conn =
        call(:post, "/#{@account}?comp=userdelegationkey&sig=AAA%3D&se=2099-01-01T00:00:00Z",
          headers: []

      )

      assert conn.status in [401, 403]
      refute conn.resp_body =~ "MissingXMsVersion"
    end
  end
end
