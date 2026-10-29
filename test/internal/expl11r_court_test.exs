# EXPL11-R — repair court for EXPL-11 F2 (delivery truth, positive leg) and
# F4 (empty plane selection refuses typed).
#
# F2 falsifier (dead-handler leg) is owned by EXPL11-R2
# (expl11r2_wps_service_events_court_test.exs); this court adds the leg R2
# does not carry: a real loopback handler that answers 200, proving the
# witness flips to delivered=true — the non-laundering claim must hold in
# BOTH directions (a witness that can never show `true` would be just as
# vacuous as one that always shows `true`).
#
# F4: `config :smalt, :planes, []` must refuse boot typed — the empty
# selection boots zero plane surfaces, a "successful" emulator with no
# planes.
#
# Chicago: real Bandit handler, real Erlang HTTP-client POST, real app-env
# transitions.
# Run:
#   MIX_BUILD_ROOT=_build-expl11r mix test test/internal/expl11r_court_test.exs

Code.require_file("poll_helper.exs", __DIR__)

defmodule Internal.Expl11r.Court do
  use ExUnit.Case, async: false

  alias SmaltTest.Internal.Poll

  setup do
    prior_planes = Application.get_env(:smalt, :planes)
    prior_url = Application.get_env(:smalt, :web_pubsub_event_handler_url)

    on_exit(fn ->
      Application.put_env(:smalt, :planes, prior_planes)
      Application.put_env(:smalt, :web_pubsub_event_handler_url, prior_url)
    end)

    %{prior_planes: prior_planes, prior_url: prior_url}
  end

  ## -- F2 positive leg: real 200 handler flips delivered=true -------------------

  @tag :expl11r
  test "F2+: live 200 handler — witness carries delivered=true, status=delivered" do
    port = free_port()

    {:ok, bandit} =
      Bandit.start_link(
        plug: {__MODULE__.OkHandler, []},
        scheme: :http,
        port: port,
        thousand_island_options: [read_timeout: 10_000]
      )

    Application.put_env(:smalt, :web_pubsub_event_handler_url, "http://127.0.0.1:#{port}/events")

    hub = "expl11r-f2p-#{System.unique_integer([:positive])}"
    :ok = Smalt.WebPubSub.Events.connect(hub, "c-f2p", "u1")

    {:ok, ev} =
      Poll.eventually(
        fn ->
          case Enum.find(Smalt.WebPubSub.events(), fn ev -> ev["hub"] == hub and ev["delivered"] == true end) do
            nil -> :pending
            ev -> {:ok, ev}
          end
        end,
        timeout_ms: 10_000
      )

    assert ev["delivered"] == true
    assert ev["delivery_status"] == "delivered"

    GenServer.stop(bandit)
  end

  ## -- F4: empty plane selection refuses typed ---------------------------------

  @tag :expl11r
  test "F4: resolve() with config planes=[] raises {:invalid_plane, []}" do
    Application.put_env(:smalt, :planes, [])

    assert_raise Smalt.Planes.InvalidPlane, ~r/:invalid_plane, \[\]/, fn ->
      Smalt.Planes.resolve()
    end
  end

  @tag :expl11r
  test "F4: non-empty selection still valid; SMALT_PLANES='' still :all" do
    Application.put_env(:smalt, :planes, [:control])
    assert [:control] = Smalt.Planes.resolve()

    Application.put_env(:smalt, :planes, :all)
    assert :all = Smalt.Planes.resolve()

    System.put_env("SMALT_PLANES", "")
    assert :all = Smalt.Planes.resolve()
  after
    System.delete_env("SMALT_PLANES")
  end

  test "F4: unknown name still refuses (no regression in the JA-R1 guard)" do
    Application.put_env(:smalt, :planes, [:control, :bogus_plane])

    assert_raise Smalt.Planes.InvalidPlane, ~r/:invalid_plane, :bogus_plane/, fn ->
      Smalt.Planes.resolve()
    end
  end

  ## -- handlers / helpers --------------------------------------------------------

  defmodule OkHandler do
    @moduledoc "Real loopback CloudEvents handler: 200 on POST, records nothing."
    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      Plug.Conn.send_resp(conn, 200, "")
    end
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end
end
