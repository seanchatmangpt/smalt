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
  i22 hardening (see docs/jira/v26.10.17/receipts/i21-ets-race-fix.md): the
  window between `ensure_store_up()` and `Store.clear/0` is racy when an
  async sibling suite tears the shared app tree down — the named ETS tables
  die mid-clear and `seed_default_subscription/0` raises
  `ArgumentError "table identifier does not refer to an existing ETS table"`.
  Bounded typed retry: re-run `ensure_store_up()` then `Store.clear/0`,
  rescuing ONLY that exact dead-table ArgumentError; anything past the bound
  raises loudly (never a silent pass).
  """
  @retry_bound 50
  @retry_backoff_ms 10
  @dead_table_msg "table identifier does not refer to an existing ETS table"

  def resilient_clear do
    do_resilient_clear(@retry_bound)
  end

  defp do_resilient_clear(0) do
    raise "shared Store unavailable after #{@retry_bound} retries (i22 corpus-seed hardening)"
  end

  defp do_resilient_clear(remaining) do
    SmaltTest.Lifecycle.ensure_store_up()

    Store.clear()
  rescue
    e in ArgumentError ->
      if Exception.message(e) == @dead_table_msg do
        Process.sleep(@retry_backoff_ms)
        do_resilient_clear(remaining - 1)
      else
        reraise e, __STACKTRACE__
      end
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
