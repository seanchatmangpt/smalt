defmodule Smalt.TwilioExtTest do
  use ExUnit.Case, async: true
  alias Smalt.TwilioExt.{SilentNetworkAuth, MessagingChannel, TrustHub, MediaStreams}
  @va "VA" <> String.duplicate("0", 32)

  test "sna" do
    assert {:ok, %{"channel" => "sna", "sna" => %{"url" => _}} = v} =
             SilentNetworkAuth.create(@va, %{"To" => "+14155551234"})

    assert {:ok, %{"status" => "approved"}} = SilentNetworkAuth.check(v, :ok)
    assert {:error, %{"code" => 60605}} = SilentNetworkAuth.create(@va, %{"To" => "+14155551230"})
    assert {:error, %{"code" => 60200}} = SilentNetworkAuth.create(@va, %{"To" => "+15005550001"})
  end

  test "trailing newline / control chars refused" do
    assert {:error, %{"code" => 60200}} = SilentNetworkAuth.create(@va, %{"To" => "+14155551230\n"})
    assert {:error, %{"code" => 60200}} = SilentNetworkAuth.create(@va, %{"To" => "+14155551234\n"})
    assert {:error, %{"code" => 60200}} = SilentNetworkAuth.create(@va, %{"To" => "+1415555\r1234"})

    assert {:error, %{"code" => 21211}} =
             MessagingChannel.build(%{"To" => "whatsapp:+12345678\n", "From" => "whatsapp:+14155550000"})

    assert {:error, %{"code" => 21211}} =
             MessagingChannel.build(%{"To" => "rcs:agent\n", "From" => "rcs:agent2"})
  end

  test "channels" do
    assert {:ok, %{"channel" => "whatsapp"}} =
             MessagingChannel.build(%{"To" => "whatsapp:+14155551234", "From" => "whatsapp:+14155550000"})

    assert {:ok, %{"channel" => "rcs"}} = MessagingChannel.build(%{"To" => "rcs:agent1", "From" => "rcs:agent2"})
    assert {:error, _} = MessagingChannel.build(%{"To" => "rcs:a", "From" => "whatsapp:+14155550000"})
  end

  test "trust hub" do
    {:ok, b} = TrustHub.brand(%{"CustomerProfileBundleSid" => "BU1", "A2PProfileBundleSid" => "BU2"})
    assert {:error, _} = TrustHub.campaign(b, %{"UseCase" => "2FA", "MessageSamples" => ["x"]})
    {:ok, b} = TrustHub.approve_brand(b)

    assert {:ok, %{"campaign_status" => "IN_PROGRESS"}} =
             TrustHub.campaign(b, %{"UseCase" => "2FA", "MessageSamples" => ["x"]})

    {:ok, t} = TrustHub.shaken_stir(%{"EndUserSid" => "IT1", "Attestation" => "A"})
    assert {:ok, %{"status" => "pending-review"}} = TrustHub.submit(t)
    assert {:error, _} = TrustHub.shaken_stir(%{"EndUserSid" => "IT1", "Attestation" => "Z"})
  end

  test "media streams" do
    assert {:ok, %{"event" => "media"}} = MediaStreams.decode(MediaStreams.media("MZ1", 2, 1, <<1, 2, 3>>))
    assert {:ok, %{"event" => "start"}} = MediaStreams.decode(MediaStreams.start("MZ1", "CA1"))
    assert {:error, :unknown_event} = MediaStreams.decode(~s({"event":"x"}))
    assert {:error, :bad_payload} = MediaStreams.decode(~s({"event":"media","media":{"payload":"!!"}}))
  end
end
