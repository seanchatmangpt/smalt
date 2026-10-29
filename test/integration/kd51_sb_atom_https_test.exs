defmodule Smalt.Integration.Kd51SbAtomHttpsTest do
  use ExUnit.Case, async: false

  # KD-COVERS: KD-51 — flat Service Bus ATOM management URL space over HTTPS
  # (ArmGateway.Router alias routes + TlsTwinDispatch api-version= clause).
  # Wire witness with the real azure-servicebus 7.15 admin client:
  # docs/jira/v26.10.20/receipts/kd51-admin-urlspace-witness.md; this file pins the routes through the real
  # router + real store (no mocks).

  alias Plug.Conn
  import Plug.Test

  @sb_xmlns "http://schemas.microsoft.com/netservices/2010/10/servicebus/connect"
  @atom_key_prefix String.downcase(
                     "/subscriptions/emulator-atom/resourceGroups/emulator/providers/Microsoft.ServiceBus/namespaces/emulator/queues/"
                   )

  defp dispatch(conn), do: Smalt.ArmGateway.Router.call(conn, [])

  test "flat PUT/GET/DELETE /{queue} round-trips through the ARM router" do
    name = "kd51-test-#{System.system_time(:millisecond)}"

    conn =
      "PUT"
      |> conn("/#{name}?api-version=2024-05", "<entry/>")
      |> Conn.put_req_header("content-type", "application/atom+xml;type=entry;charset=utf-8")
      |> dispatch()

    assert conn.status in [200, 201]
    assert conn.resp_body =~ "QueueDescription"
    assert conn.resp_body =~ "<QueueName>#{name}</QueueName>"

    get =
      "GET"
      |> conn("/#{name}?api-version=2024-05")
      |> dispatch()

    assert get.status == 200
    assert get.resp_body =~ "QueueDescription"

    del =
      "DELETE"
      |> conn("/#{name}?api-version=2024-05")
      |> dispatch()

    assert del.status == 200

    gone =
      "GET"
      |> conn("/#{name}?api-version=2024-05")
      |> dispatch()

    assert gone.status == 404
  end

  test "atom body QueueDescription properties parse into the ARM-shaped record" do
    name = "kd51-props-#{System.system_time(:millisecond)}"

    atom_body = """
    <?xml version="1.0" encoding="utf-8"?>
    <entry xmlns="http://www.w3.org/2005/Atom">
      <content type="application/xml">
        <QueueDescription xmlns="#{@sb_xmlns}">
          <LockDuration>PT2M</LockDuration>
          <MaxDeliveryCount>7</MaxDeliveryCount>
          <RequiresSession>true</RequiresSession>
        </QueueDescription>
      </content>
    </entry>
    """

    conn =
      "PUT"
      |> conn("/#{name}?api-version=2024-05", atom_body)
      |> Conn.put_req_header("content-type", "application/atom+xml;type=entry;charset=utf-8")
      |> dispatch()

    assert conn.status in [200, 201]

    {:ok, record} =
      Smalt.Store.get(:smalt_resources, @atom_key_prefix <> String.downcase(name))

    assert record["properties"]["lockDuration"] == "PT2M"
    assert record["properties"]["maxDeliveryCount"] == 7
    assert record["properties"]["requiresSession"] == true
  end

  test "single-segment storage service face is not captured by the atom alias" do
    conn =
      "GET"
      |> conn("/someaccount?restype=service&comp=properties")
      |> dispatch()

    assert conn.status == 404
    refute conn.resp_body =~ "QueueDescription"
  end
end
