defmodule Smalt.RuntimeContracts.Support do
  @moduledoc """
  Shared in-process helpers for runtime integration contract modules.

  Dispatches real router plug pipelines through `Plug.Test.conn/4` — no
  sockets, no ports, no Bandit — so each contract check is a fast in-process
  probe of the real routers. Assertion helpers raise `Smalt.RuntimeContracts.Support.AssertionError`,
  which `run/1` catches and converts into a per-contract failures list so
  `Smalt.RuntimeContracts.verify/0` produces a full verdict map in one pass.
  """

  @typedoc "One failed assertion inside a contract check."
  @type failure :: %{check: atom(), detail: String.t()}

  @typedoc "Result of a single contract module's check/0."
  @type result :: %{
          name: atom(),
          pass: boolean(),
          checks: non_neg_integer(),
          failures: [failure()]
        }

  @doc """
  Dispatches a request through the real plug router in-process.

  Returns `%{status, headers (lowercased string map), body (binary)}`.
  """
  @spec dispatch(module(), String.t(), String.t(), keyword()) :: %{
          status: non_neg_integer(),
          headers: %{String.t() => String.t()},
          body: binary()
        }
  def dispatch(router, method, path, opts \\ []) do
    body = Keyword.get(opts, :body)
    headers = Keyword.get(opts, :headers, [])

    # The routers parse bodies through Plug.Parsers (:json), so a body without
    # a json content-type arrives as an empty body_params map — mirror the
    # real wire, where every client sends application/json (compliance-court
    # parity, c1/c3 helper defaults).
    headers =
      if body != nil and
           not Enum.any?(headers, fn {k, _} ->
             String.downcase(to_string(k)) == "content-type"
           end) do
        [{"content-type", "application/json"} | headers]
      else
        headers
      end

    conn =
      Plug.Test.conn(method, path, body)

    conn =
      Enum.reduce(headers, conn, fn {k, v}, acc ->
        Plug.Conn.put_req_header(acc, String.downcase(to_string(k)), to_string(v))
      end)

    conn = router.call(conn, [])

    %{
      status: conn.status || 500,
      headers: Map.new(conn.resp_headers, fn {k, v} -> {String.downcase(k), v} end),
      body: IO.iodata_to_binary(conn.resp_body || "")
    }
  end

  @doc """
  Executes a list of `{check_id, fun}` assertions under `name`, collecting
  failures into a `result` map. Each fun runs real code and raises on
  violation (via `assert/2`). A failure does not abort the remaining checks.
  """
  @spec contract(atom(), [{atom(), (-> term())}]) :: result()
  def contract(name, checks) when is_atom(name) and is_list(checks) do
    outcomes =
      Enum.map(checks, fn {check_id, fun} ->
        case safe_run(fun) do
          :ok -> {:pass, check_id}
          {:fail, detail} -> {:fail, check_id, detail}
        end
      end)

    failures =
      for {:fail, id, detail} <- outcomes, into: [] do
        %{check: id, detail: detail}
      end

    %{
      name: name,
      pass: failures == [],
      checks: length(outcomes),
      failures: failures
    }
  end

  defp safe_run(fun) do
    fun.()
    :ok
  rescue
    e -> {:fail, Exception.format(:error, e, __STACKTRACE__)}
  catch
    :exit, e -> {:fail, "exit: #{inspect(e)}"}
    kind, e -> {:fail, "#{kind}: #{inspect(e)}"}
  end

  @doc "Raises on falsey; the message becomes the failure detail."
  @spec assert(term(), String.t()) :: :ok
  def assert(value, message)

  def assert(value, _message) when value not in [nil, false], do: :ok

  def assert(_value, message), do: raise(__MODULE__.AssertionError, message: message)

  @doc "Raises unless left == right (==/2 semantics)."
  def assert_equal(left, right, _message) when left == right, do: :ok

  def assert_equal(left, right, message),
    do:
      raise(__MODULE__.AssertionError,
        message: "#{message} (expected #{inspect(right)}, got #{inspect(left)})"
      )

  defmodule AssertionError do
    defexception [:message]
  end
end
