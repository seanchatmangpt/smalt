defmodule Smalt.Webhooks.SignatureTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn
  alias Smalt.Webhooks.{Plug, Signature}

  @secret "whsec_test_secret"
  @payload ~s({"id":"evt_test_webhook","object":"event"})
  @t 1_492_774_577

  defp hdr(t \\ @t), do: Signature.stripe_header(@payload, @secret, t)

  test "stripe round trip verifies" do
    assert :ok = Signature.verify_stripe(@payload, hdr(), @secret, now: @t + 10)
  end

  test "stale timestamp refused, tolerance boundary inclusive" do
    assert {:error, :timestamp_stale} =
             Signature.verify_stripe(@payload, hdr(), @secret, now: @t + 301)

    assert :ok = Signature.verify_stripe(@payload, hdr(), @secret, now: @t + 300)
  end

  test "missing, malformed, tampered" do
    assert {:error, :missing_header} = Signature.verify_stripe(@payload, nil, @secret)
    assert {:error, :malformed_header} = Signature.verify_stripe(@payload, "garbage", @secret)
    assert {:error, :malformed_header} = Signature.verify_stripe(@payload, "t=#{@t}", @secret)

    assert {:error, :no_valid_signature} =
             Signature.verify_stripe(@payload <> "x", hdr(), @secret, now: @t)

    assert {:error, :no_valid_signature} =
             Signature.verify_stripe(@payload, hdr(), "other", now: @t)
  end

  test "multiple v1, any may match" do
    good = Signature.stripe_sign(@payload, @secret, @t)
    h = "t=#{@t},v1=#{String.duplicate("0", 64)},v1=#{good}"
    assert :ok = Signature.verify_stripe(@payload, h, @secret, now: @t)
  end

  test "svix round trip and refusal" do
    secret = "whsec_" <> Base.encode64("k3y-bytes")
    sig = Signature.svix_sign(@payload, secret, "msg_1", @t)
    h = %{"svix-id" => "msg_1", "svix-timestamp" => "#{@t}", "svix-signature" => "v1,AAAA #{sig}"}
    assert :ok = Signature.verify_svix(@payload, h, secret, now: @t)

    assert {:error, :no_valid_signature} =
             Signature.verify_svix(@payload, %{h | "svix-id" => "msg_2"}, secret, now: @t)

    assert {:error, :missing_header} = Signature.verify_svix(@payload, %{}, secret)

    assert {:error, :timestamp_stale} =
             Signature.verify_svix(@payload, h, secret, now: @t + 1000)
  end

  describe "plug" do
    defp run(body, header, opts \\ []) do
      conn = conn(:post, "/hook", body)
      conn = if header, do: put_req_header(conn, "stripe-signature", header), else: conn
      Plug.call(conn, Keyword.merge([secret: @secret, now: @t], opts))
    end

    test "valid passes through" do
      conn = run(@payload, hdr())
      refute conn.halted
      assert conn.assigns.raw_body == @payload
    end

    test "missing, stale, bad are typed 400" do
      c = run(@payload, nil)
      assert c.status == 400 and c.halted
      assert c.resp_body =~ "missing_header"

      c = run(@payload, hdr(), now: @t + 999)
      assert c.status == 400 and c.resp_body =~ "timestamp_stale"

      c = run("tampered", hdr())
      assert c.status == 400 and c.resp_body =~ "no_valid_signature"
    end
  end
end
