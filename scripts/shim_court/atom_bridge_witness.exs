# atom_bridge_witness.exs — KD-45 shim-court witness (real TCP, Chicago-style).
#
# Exercises Smalt.Amqp.AtomBridge.serve/2 over a REAL loopback socket: a
# listener accepts, hands the socket to the bridge, and a client sends the
# exact request shape ServiceBusAdministrationClient emits
# (PUT /{queue}?api-version=... with content-type: application/atom+xml;type=entry).
#
# Modes (env WITNESS_MODE, run via `mix run --no-start`):
#   before — PUT must return 201 Created with the full 12-field
#            QueueDescription XML (LockDuration parsed from the ATOM body);
#            anything else exits 1 (old signature absent).
#   after  — PUT must return 405 MethodNotAllowed (the neutered signature);
#            a 201 here means the shim was INERT — vacuity, exit 1.

defmodule Witness do
  def read_all(sock, acc \\ <<>>) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} -> read_all(sock, <<acc::binary, data::binary>>)
      {:error, :closed} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  def wait_table(_t, 0), do: raise("store table never materialized")

  def wait_table(t, n) do
    if :ets.info(t) == :undefined do
      Process.sleep(50)
      wait_table(t, n - 1)
    end
  end
end

mode = System.fetch_env!("WITNESS_MODE")

# The bridge only needs the Store ETS tables (:smalt_resources) — NOT the
# full app (fixed ports collide with a running substrate; witnessed 05:06
# as :eaddrinuse). Start the single Store GenServer directly.
{:ok, _store} = Smalt.Store.start_link([])
Witness.wait_table(:smalt_resources, 40)

# -- real listener + bridge handoff -------------------------------------------

{:ok, lsock} =
  :gen_tcp.listen(0, [
    :binary,
    packet: :raw,
    active: false,
    reuseaddr: true,
    ip: {127, 0, 0, 1}
  ])

{:ok, port} = :inet.port(lsock)

acceptor =
  Task.async(fn ->
    {:ok, sock} = :gen_tcp.accept(lsock)
    # Same handoff shape the AMQP connection's HTTP sniff uses: the bridge
    # serves one request off the broker-owned socket; the caller closes.
    Smalt.Amqp.AtomBridge.serve(sock)
    :gen_tcp.close(sock)
  end)

# -- the SDK-shaped PUT --------------------------------------------------------

queue = "atom-court-#{System.system_time(:nanosecond)}"

body = """
<?xml version="1.0" encoding="utf-8"?>
<entry xmlns="http://www.w3.org/2005/Atom">
  <content type="application/xml">
    <QueueDescription xmlns="http://schemas.microsoft.com/netservices/2010/10/servicebus/connect">
      <LockDuration>PT45S</LockDuration>
      <RequiresSession>false</RequiresSession>
      <MaxDeliveryCount>7</MaxDeliveryCount>
    </QueueDescription>
  </content>
</entry>
"""

req = [
  "PUT /#{queue}?api-version=2021-10 HTTP/1.1\r\n",
  "Host: localhost:#{port}\r\n",
  "Content-Type: application/atom+xml;type=entry\r\n",
  "Content-Length: #{byte_size(body)}\r\n",
  "Connection: close\r\n\r\n",
  body
]

{:ok, csock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false])
:ok = :gen_tcp.send(csock, req)
{:ok, resp} = Witness.read_all(csock)
:gen_tcp.close(csock)
Task.await(acceptor, 10_000)
:gen_tcp.close(lsock)

status =
  case Regex.run(~r/HTTP\/1\.1 (\d{3})/, resp) do
    [_, code] -> String.to_integer(code)
    _ -> :no_http_response
  end

# Landed signature: 201 + full 12-field QueueDescription with the requested
# LockDuration echoed from the parsed ATOM body.
landed? =
  status == 201 and
    String.contains?(resp, "<QueueDescription") and
    String.contains?(resp, "<LockDuration>PT45S</LockDuration>") and
    String.contains?(resp, "<MaxDeliveryCount>10</MaxDeliveryCount>")

case mode do
  "before" ->
    if landed? do
      IO.puts(
        "[BEFORE] PUT /#{queue} -> 201, 12-field QueueDescription (LockDuration PT45S parsed) — old signature holds"
      )

      # Round-trip the ATOM record into the store: GET must find it.
      {:ok, _} =
        Smalt.Store.get(
          :smalt_resources,
          "/subscriptions/emulator-atom/resourcegroups/emulator/providers/microsoft.servicebus/namespaces/emulator/queues/#{queue}"
        )

      IO.puts("[BEFORE] store round-trip: queue record readable via Store.get")
    else
      IO.puts(
        :stderr,
        "[FAIL:BEFORE] expected 201 + QueueDescription(LockDuration PT45S), got status=#{inspect(status)}\n#{resp}"
      )

      System.halt(1)
    end

  "after" ->
    if status == 405 do
      IO.puts("[AFTER] PUT /#{queue} -> 405 MethodNotAllowed — shim flipped the bridge (non-vacuous)")
    else
      IO.puts(
        :stderr,
        "[FAIL:AFTER] expected neutered 405, got status=#{inspect(status)} — shim inert\n#{resp}"
      )

      System.halt(1)
    end

  other ->
    IO.puts(:stderr, "[FAIL] unknown WITNESS_MODE #{inspect(other)}")
    System.halt(2)
end
