# Shared dispatch helpers for the incidents-as-permanent-evals replay corpus
# (test/corpus_test.exs). Loaded by corpus_test.exs BEFORE the corpus modules
# so every family shares one in-process dispatch path (Plug.Test against the
# real routers, real Store — Chicago, no mocks).
defmodule Smalt.Corpus.Helper do
  @moduledoc false

  import Plug.Test
  import Plug.Conn

  alias Smalt.ArmGateway.Router
  alias Smalt.EgressRouter
  alias Smalt.Store

  @arm_opts Router.init([])
  @egress_opts EgressRouter.init([])

  @doc "Ensure the shared Store is up and empty for a corpus test."
  def ensure_store do
    resilient_clear()
    :ok
  end

  @doc """
  i22 hardening (docs/jira/v26.10.17/receipts/i21-ets-race-fix.md): the
  window between ensure-store-up and `Store.clear/0` is racy when an async
  sibling suite tears the shared app tree down — the named ETS tables die
  mid-clear. Bounded typed retry, rescuing ONLY the exact dead-table
  ArgumentError; past the bound it raises loudly (never a silent pass).

  CANONICAL implementation (this window): the former private copies in
  test/compliance/c1_arm.exs, c3_cosmos.exs, c4_blob.exs are deleted in
  favor of this one. `post_seed` (default identity) runs inside the same
  retry window so a seed racing the same dead-table window is retried too
  — this is what c1's subscription seed needs and what its local copy
  specialized.
  """
  @retry_bound 50
  @retry_backoff_ms 10
  @dead_table_msg "table identifier does not refer to an existing ETS table"

  def resilient_clear(post_seed \\ fn -> :ok end) do
    do_resilient_clear(post_seed, @retry_bound)
  end

  defp do_resilient_clear(_post_seed, 0) do
    raise "shared Store unavailable after #{@retry_bound} retries " <>
            "(i22 corpus-seed hardening, canonical Smalt.Corpus.Helper)"
  end

  defp do_resilient_clear(post_seed, remaining) do
    SmaltTest.Lifecycle.ensure_store_up()
    Store.clear()
    post_seed.()
  rescue
    e in ArgumentError ->
      if Exception.message(e) == @dead_table_msg do
        Process.sleep(@retry_backoff_ms)
        do_resilient_clear(post_seed, remaining - 1)
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc """
  Deadline-bounded poll. `fun` returns `{:ok, value}` to stop or any other
  term to keep polling. Raises with the last observed value past the
  deadline — loud, never a silent pass. Replaces fixed-sleep-and-hope
  polling (c1 `poll_until_terminal/3`'s 20ms x 100 grid).
  """
  def assert_eventually!(label, deadline_ms, fun, poll_every_ms \\ 20) do
    started = System.monotonic_time(:millisecond)

    do_poll(label, started + deadline_ms, deadline_ms, fun, poll_every_ms, nil, started)
  end

  defp do_poll(label, deadline, deadline_ms, fun, _every, last, now) when now >= deadline do
    flunk("assert_eventually!(#{inspect(label)}) timed out after #{deadline_ms}ms; " <>
            "last observation: #{inspect(last)}")
  end

  defp do_poll(label, deadline, deadline_ms, fun, every, _last, _now) do
    case fun.() do
      {:ok, value} ->
        value

      other ->
        Process.sleep(every)
        do_poll(label, deadline, deadline_ms, fun, every, other, System.monotonic_time(:millisecond))
    end
  end

  defp flunk(msg), do: raise(ExUnit.AssertionError, message: msg)

  @doc """
  Quiescent double-read (i22 snapshot hardening, mechanism per
  docs/jira/v26.10.17/receipts/i20b-contention-mechanism.md):
  `read_fun/0` is called repeatedly until two consecutive reads AGREE (a
  torn mid-write read is discarded). Rescues only the typed faces:
  the dead-table ArgumentError and the 5000ms GenServer.call :exit cliff.
  Sleeps only after a disagreement or typed rescue — the quiet path is
  back-to-back reads, zero wall-clock. Past `:retries`, raises loudly.
  """
  @quiesce_retries 20
  @quiesce_backoff_ms 25
  @store_call_timeout_ms 5000

  def quiescent_read(read_fun, opts \\ []) do
    retries = Keyword.get(opts, :retries, @quiesce_retries)
    backoff = Keyword.get(opts, :backoff_ms, @quiesce_backoff_ms)
    do_quiescent_read(read_fun, retries, backoff, :first_read)
  end

  defp do_quiescent_read(_read_fun, 0, _backoff, _prev) do
    raise "quiescent_read: shared Store unreadable after #{@quiesce_retries} quiesce retries " <>
            "(i22 hardening) — raising loudly, never a silent pass"
  end

  defp do_quiescent_read(read_fun, remaining, backoff, prev) do
    cur = read_fun.()

    if cur == prev do
      cur
    else
      if prev != :first_read, do: Process.sleep(backoff)
      do_quiescent_read(read_fun, remaining - 1, backoff, cur)
    end
  rescue
    e in ArgumentError ->
      if Exception.message(e) == @dead_table_msg do
        Process.sleep(backoff)
        do_quiescent_read(read_fun, remaining - 1, backoff, prev)
      else
        reraise e, __STACKTRACE__
      end
  catch
    :exit, {:timeout, {GenServer, :call, [_store, _req, @store_call_timeout_ms]}} ->
      Process.sleep(backoff)
      do_quiescent_read(read_fun, remaining - 1, backoff, prev)
  end

  @doc """
  ARM control-plane dispatch (port 9443 surface): method, path, optional
  body map, optional headers list.
  """
  def arm(method, path, body \\ %{}, headers \\ []) do
    conn =
      if body == %{} and method in [:get, :head, :delete] do
        conn(method, path)
      else
        conn(method, path, Jason.encode!(body))
      end

    conn
    |> put_req_header("content-type", "application/json")
    |> then(fn c -> Enum.reduce(headers, c, fn {k, v}, c -> put_req_header(c, k, v) end) end)
    |> Router.call(@arm_opts)
  end

  @doc """
  Data-plane dispatch (port 8443 surface) through the real EgressRouter.
  `body` may be a map (JSON-encoded) or an iodata/binary.
  """
  def egress(method, path, body \\ %{}, headers \\ []) do
    payload =
      cond do
        is_map(body) and body == %{} and method in [:get, :head, :delete] -> ""
        is_map(body) -> Jason.encode!(body)
        true -> body
      end

    conn(method, path, payload)
    |> put_req_header("content-type", "application/json")
    |> then(fn c -> Enum.reduce(headers, c, fn {k, v}, c -> put_req_header(c, k, v) end) end)
    |> EgressRouter.call(@egress_opts)
  end

  @doc "Decode a JSON response body."
  def json(conn), do: Jason.decode!(conn.resp_body)

  @doc "ARM error envelope code."
  def code(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, %{"error" => %{"code" => code}}} -> code
      _ -> nil
    end
  end
end
