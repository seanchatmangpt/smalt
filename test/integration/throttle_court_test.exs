defmodule Smalt.Integration.ThrottleCourtTest do
  @moduledoc """
  MOONSHOT lane 9 throttling court (Chicago discipline): real plug chain, real
  ETS buckets, real router. Assertions on actual wire responses (status +
  retry-after header + typed per-plane envelope body) and real bucket state —
  never call counts, never sleeps (the clock is a real injectable module).
  """

  use ExUnit.Case, async: false

  import Plug.Conn, only: [get_resp_header: 2]

  alias Smalt.Egress.ThrottlePlug

  # Real deterministic clock module — the court advances time explicitly.
  defmodule FakeClock do
    def start_link, do: Agent.start_link(fn -> 1_000 end, name: __MODULE__)
    def now_ms, do: Agent.get(__MODULE__, & &1)
    def advance(ms), do: Agent.update(__MODULE__, &(&1 + ms))
    def stop, do: Agent.stop(__MODULE__)
  end

  setup do
    ThrottlePlug.reset!()
    {:ok, _} = FakeClock.start_link()
    prev_throttle = Application.get_env(:smalt, :throttle)
    prev_clock = Application.get_env(:smalt, :throttle_clock)

    on_exit(fn ->
      Application.put_env(:smalt, :throttle, prev_throttle)
      Application.put_env(:smalt, :throttle_clock, prev_clock)
      ThrottlePlug.reset!()
    end)

    :ok
  end

  defp enable(rate \\ 1, burst \\ 2) do
    Application.put_env(:smalt, :throttle, rate: rate, burst: burst)
    Application.put_env(:smalt, :throttle_clock, FakeClock)
  end

  defp disable do
    Application.put_env(:smalt, :throttle, rate: nil, burst: nil)
  end

  # Drains the {plane, key} bucket so the WIRE request is the exhausting one
  # (burst is spent by direct token takes, then the wire call must see 429).
  defp drain(plane, key, rate, burst) do
    for _ <- 1..burst do
      assert elem(ThrottlePlug.take_token(plane, key, rate, burst, FakeClock.now_ms()), 0)
    end
  end

  defp wire(method, path) do
    method
    |> Plug.Test.conn(path)
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> Smalt.EgressRouter.call([])
  end

  # -- config-off: zero overhead, plug short-circuits -------------------------------

  test "config-off: no bucket row is minted and the conn passes through unchanged" do
    disable()
    conn = wire("GET", "/throttleacct?comp=list&restype=service")

    # The throttle plug handed the conn on UNTOUCHED: no retry-after face, no
    # 429 — the downstream chain (auth etc.) owns the response.
    assert get_resp_header(conn, "retry-after") == []
    assert conn.status != 429

    # Zero overhead witnessed structurally: no bucket state exists at all.
    assert :ets.tab2list(:smalt_throttle_buckets) == []
  end

  test "config-off with env vars unset and rate nil: resolve is :off even after traffic" do
    disable()

    for _ <- 1..10, do: wire("GET", "/throttleacct/blob.txt")
    assert :ets.tab2list(:smalt_throttle_buckets) == []
  end

  # -- exhaustion: 429 + retry-after, one typed shape per plane ---------------------

  test "storage plane exhaustion answers the XML ServerBusy envelope with retry-after" do
    enable(1, 2)
    drain(:storage, "acct", 1, 2)

    conn = wire("PUT", "/acct/c1/b1")
    assert conn.status == 429
    assert [ra] = get_resp_header(conn, "retry-after")
    assert String.to_integer(ra) >= 1
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/xml"
    assert conn.resp_body =~ "<Error><Code>ServerBusy</Code>"
  end

  test "sb plane exhaustion answers the EventHubs JSON ServerBusy envelope" do
    enable(1, 1)
    drain(:sb, "topics", 1, 1)
    conn = wire("POST", "/topics/hub/messages")

    assert conn.status == 429
    assert [ra] = get_resp_header(conn, "retry-after")
    assert String.to_integer(ra) >= 1

    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "ServerBusy"
  end

  test "cosmos plane exhaustion answers the real Cosmos 429 face" do
    enable(1, 1)
    drain(:cosmos, "dbs", 1, 1)
    conn = wire("GET", "/dbs/db1/colls/c1/docs")

    assert conn.status == 429
    assert [ra] = get_resp_header(conn, "retry-after")
    body = Jason.decode!(conn.resp_body)
    assert body["code"] == 429
    assert body["message"] =~ "Request rate is large"
  end

  test "kv plane exhaustion answers the generic JSON error envelope" do
    enable(1, 1)
    drain(:kv, "keys", 1, 1)
    conn = wire("GET", "/keys/k1")

    assert conn.status == 429
    assert [ra] = get_resp_header(conn, "retry-after")
    assert String.to_integer(ra) >= 1
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "ServerBusy"
  end

  test "buckets are per-plane: exhausting storage does not throttle cosmos" do
    enable(1, 1)

    assert elem(ThrottlePlug.take_token(:storage, "x", 1, 1, FakeClock.now_ms()), 0)
    {allowed, _} = ThrottlePlug.take_token(:storage, "x", 1, 1, FakeClock.now_ms())
    refute allowed

    assert elem(ThrottlePlug.take_token(:cosmos, "x", 1, 1, FakeClock.now_ms()), 0)
  end

  # -- refill: deterministic clock advance recovers the bucket ----------------------

  test "refill recovers admission after clock advance (no sleeps)" do
    enable(1, 2)
    now = FakeClock.now_ms()

    assert elem(ThrottlePlug.take_token(:storage, "acct", 1, 2, now), 0)
    assert elem(ThrottlePlug.take_token(:storage, "acct", 1, 2, now), 0)
    {false, ra} = ThrottlePlug.take_token(:storage, "acct", 1, 2, now)
    assert ra >= 1

    # 1 token/s: advance 1s -> exactly one new token.
    FakeClock.advance(1_000)
    now2 = FakeClock.now_ms()
    assert elem(ThrottlePlug.take_token(:storage, "acct", 1, 2, now2), 0)
    {false, _} = ThrottlePlug.take_token(:storage, "acct", 1, 2, now2)

    # Advance 5s -> bucket refills to burst; the cap holds (no runaway accrual).
    FakeClock.advance(5_000)
    now3 = FakeClock.now_ms()

    for _ <- 1..2, do: assert(elem(ThrottlePlug.take_token(:storage, "acct", 1, 2, now3), 0))
    {false, _} = ThrottlePlug.take_token(:storage, "acct", 1, 2, now3)
  end

  test "env-var fallback admits when config is nil" do
    System.put_env("SMALT_THROTTLE_RATE", "2")
    System.put_env("SMALT_THROTTLE_BURST", "1")
    Application.put_env(:smalt, :throttle, rate: nil, burst: nil)
    Application.put_env(:smalt, :throttle_clock, FakeClock)

    try do
      conn = wire("GET", "/topics/hub/messages")
      # burst=1 consumed by this very request -> admitted (not 429).
      refute conn.status == 429
      # second request -> exhausted -> wire 429.
      conn2 = wire("GET", "/topics/hub/messages")
      assert conn2.status == 429
    after
      System.delete_env("SMALT_THROTTLE_RATE")
      System.delete_env("SMALT_THROTTLE_BURST")
    end
  end
end
