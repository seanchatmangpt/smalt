# WPS-EXP4 lane court: EXPL-4 repair falsifiers for lib/smalt/webpubsub/.
#
# Chicago discipline: real compiled modules, real Joken HS256 sign/verify,
# real Smalt.WebPubSub.Socket handle_in/2 dispatch (returns frames to the
# caller — no webserver needed, no mocks, no sleeps). F1: token verify
# fails closed on absent/empty claims and cross-hub aud. F6: missing-key
# dispatch answers the protocol error frame, socket stays alive.
#
# Context: solo (in-process, loopback-free — pure module calls).

defmodule Smalt.Internal.WpsExp4CourtTest do
  use ExUnit.Case, async: false

  @access_key "smalt-wps-dev-access-key"

  setup do
    signer = Joken.Signer.create("HS256", @access_key)
    {:ok, hand_sign: fn claims -> {:ok, t} = Joken.Signer.sign(claims, signer); t end}
  end

  # -- F1: token verify fail-closed ----------------------------------------------

  test "F1: no-aud token verifies :error", %{hand_sign: hand_sign} do
    hub = "wpsx4-f1-#{System.unique_integer([:positive])}"
    token = hand_sign.(%{"sub" => "u", "exp" => System.system_time(:second) + 600})
    assert :error = Smalt.WebPubSub.Token.verify(hub, token)
  end

  test "F1: no-exp token verifies :error (never-expires face closed)", %{hand_sign: hand_sign} do
    hub = "wpsx4-f1-#{System.unique_integer([:positive])}"

    token =
      hand_sign.(%{
        "aud" => "/webpubsub/hubs/#{hub}",
        "sub" => "u",
        "nbf" => System.system_time(:second) - 60
      })

    assert :error = Smalt.WebPubSub.Token.verify(hub, token)
  end

  test "F1: no-nbf and no-sub tokens verify :error", %{hand_sign: hand_sign} do
    hub = "wpsx4-f1-#{System.unique_integer([:positive])}"
    now = System.system_time(:second)

    no_nbf = hand_sign.(%{"aud" => "/webpubsub/hubs/#{hub}", "sub" => "u", "exp" => now + 600})
    assert :error = Smalt.WebPubSub.Token.verify(hub, no_nbf)

    no_sub = hand_sign.(%{"aud" => "/webpubsub/hubs/#{hub}", "exp" => now + 600})
    assert :error = Smalt.WebPubSub.Token.verify(hub, no_sub)
  end

  test "F1: empty sub refused", %{hand_sign: hand_sign} do
    hub = "wpsx4-f1-#{System.unique_integer([:positive])}"
    now = System.system_time(:second)

    token =
      hand_sign.(%{"aud" => "/webpubsub/hubs/#{hub}", "sub" => "", "exp" => now + 600,
        "nbf" => now - 60})

    assert :error = Smalt.WebPubSub.Token.verify(hub, token)
  end

  test "F1: hub-A token refused on hub B (aud binding)", %{hand_sign: hand_sign} do
    now = System.system_time(:second)

    token =
      hand_sign.(%{
        "aud" => "/webpubsub/hubs/hub-a",
        "sub" => "u",
        "exp" => now + 600,
        "nbf" => now - 60
      })

    assert :error = Smalt.WebPubSub.Token.verify("hub-b", token)
    assert {:ok, "u", _roles} = Smalt.WebPubSub.Token.verify("hub-a", token)
  end

  test "F1: happy path — mint/verify roundtrip unchanged" do
    hub = "wpsx4-f1-#{System.unique_integer([:positive])}"
    token = Smalt.WebPubSub.Token.mint(hub, "u1", ["webpubsub.sendToGroup.g"])
    assert {:ok, "u1", ["webpubsub.sendToGroup.g"]} = Smalt.WebPubSub.Token.verify(hub, token)
  end

  # -- F6: dispatch fallthrough ---------------------------------------------------

  def state(hub, roles),
    do: %Smalt.WebPubSub.Socket{hub: hub, user_id: "u", roles: roles, conn_id: "cid"}

  test "F6: sendToGroup missing 'group' answers the error frame, no raise" do
    st = state("wpsx4-f6", ["webpubsub.sendToGroup"])

    {:push, {:text, frame}, ^st} =
      Smalt.WebPubSub.Socket.handle_in(
        {Jason.encode!(%{"type" => "sendToGroup", "ackId" => 1, "data" => "x"}), opcode: :text},
        st
      )

    assert %{"type" => "ack", "ackId" => 1, "success" => false,
             "error" => %{"name" => "InvalidMessage"}} = Jason.decode!(frame)
  end

  test "F6: event missing 'event' key answers the error frame" do
    st = state("wpsx4-f6", [])

    {:push, {:text, frame}, ^st} =
      Smalt.WebPubSub.Socket.handle_in(
        {Jason.encode!(%{"type" => "event", "ackId" => 2}), opcode: :text},
        st
      )

    assert %{"type" => "ack", "ackId" => 2, "success" => false,
             "error" => %{"name" => "InvalidMessage"}} = Jason.decode!(frame)
  end

  test "F6: socket stays alive after an invalid frame (join still works)" do
    st = state("wpsx4-f6", ["webpubsub.joinLeaveGroup"])
    hub = "wpsx4-f6-alive-#{System.unique_integer([:positive])}"

    # Invalid frame first.
    {:push, {:text, bad}, ^st} =
      Smalt.WebPubSub.Socket.handle_in(
        {Jason.encode!(%{"type" => "sendToGroup"}), opcode: :text},
        st
      )

    assert %{"type" => "error", "message" => message} = Jason.decode!(bad)
    assert message =~ "missing required key"

    # Then a valid, permitted join — the real group registry must see it.
    # (EXPL-11-R2 compile-freeze unblock, disclosed: Socket gained a tracked
    # `groups` field for F3 terminate-leave, so join now returns an updated
    # struct; pin the unchanged fields, not the whole struct.)
    {:push, {:text, ok}, st_after} =
      Smalt.WebPubSub.Socket.handle_in(
        {Jason.encode!(%{"type" => "joinGroup", "group" => hub, "ackId" => 3}), opcode: :text},
        st
      )

    assert %{st_after | groups: []} == %{st | groups: []}

    assert %{"type" => "ack", "ackId" => 3, "success" => true} = Jason.decode!(ok)
    assert :ok = Smalt.WebPubSub.leave("wpsx4-f6", hub, self())
  end

  test "F6: leaveGroup without permission answers Forbidden (join/leave symmetry)" do
    st = state("wpsx4-f6", ["webpubsub.joinLeaveGroup.someOtherGroup"])

    {:push, {:text, frame}, ^st} =
      Smalt.WebPubSub.Socket.handle_in(
        {Jason.encode!(%{"type" => "leaveGroup", "group" => "secret", "ackId" => 4}), opcode: :text},
        st
      )

    assert %{"type" => "ack", "ackId" => 4, "success" => false,
             "error" => %{"name" => "Forbidden"}} = Jason.decode!(frame)
  end
end
