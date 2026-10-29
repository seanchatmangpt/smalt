# S-4 fallthrough-halt mutation-court witness (w6r_fallthrough, lane W2-6).
#
# Usage: mix run scripts/shim_court/fallthrough_halt_witness.exs <mode>
#
# Modes:
#   before - unmodified router: a GET that CosmosRoutes answers is SENT exactly
#            once, conn.state == :sent, no exception escapes EgressRouter.call.
#   after  - shimmed router (w6r `conn.state in [:sent, :chunked]` halt arm
#            dropped, SHIM-COURT marker): the sent conn falls through to the
#            blob splat / 404 catch-all and Plug.Conn.AlreadySentError escapes
#            EgressRouter.call. Reproducing the witnessed wire_norm kd07
#            AlreadySentError defect IS the AFTER flip.
#
# Real dispatch through the real EgressRouter over the real Store ETS - no
# mocks (Chicago). Harness mirrors scripts/shim_court/wire_norm_witness.exs.

mode = List.first(System.argv())

# Optional override: compile a shimmed COPY of egress_router.ex over the
# already-loaded compiled module (court sets SHIM_SRC; lib.sh baselines and
# restores the temp copy, lib/smalt/egress_router.ex is never touched).
shim_src = System.get_env("SHIM_SRC")

Application.put_env(:smalt, :auth_mode, :anonymous)

if Process.whereis(Smalt.Store) == nil do
  {:ok, _} = Smalt.Store.start_link([])
  Smalt.Store.init([])
end

Smalt.Store.clear()

# Load the shimmed router copy AFTER deps/projects are compiled and Store is
# up, redefining Smalt.EgressRouter in this VM only.
if shim_src && shim_src != "" do
  compiled = Code.compile_file(shim_src)

  if List.keymember?(compiled, Smalt.EgressRouter, 0) do
    IO.puts("[witness] shimmed Smalt.EgressRouter loaded from #{shim_src}")
  else
    IO.puts(:stderr, "[witness] compile_file did not define Smalt.EgressRouter: #{inspect(Keyword.keys(compiled))}")
    System.halt(1)
  end
end

opts = Smalt.EgressRouter.init([])

dispatch = fn method, path, extra_headers, body ->
  conn =
    Plug.Test.conn(method, path, body)
    |> Plug.Conn.put_req_header("x-ms-version", "2021-12-02")
    |> then(fn conn ->
      Enum.reduce(extra_headers, conn, fn {k, v}, c ->
        Plug.Conn.put_req_header(c, k, v)
      end)
    end)

  conn = Smalt.EgressRouter.call(conn, opts)

  %{
    state: conn.state,
    status: conn.status,
    body: conn.resp_body,
    header: fn name ->
      case Plug.Conn.get_resp_header(conn, name) do
        [] -> nil
        [v] -> v
        vs -> vs
      end
    end
  }
end

# Shared fixture: cosmos db/coll/doc, matching the wire_norm kd07 leg.
{:ok, _status, _h, _db} = Smalt.DataPlane.Cosmos.create_db("court_db")
{:ok, _status, _h, _coll} = Smalt.DataPlane.Cosmos.create_collection("court_db", "court_coll", %{"id" => "pk"})
{:ok, 201, _h, _} = Smalt.DataPlane.Cosmos.create_doc("court_db", "court_coll", %{"id" => "d1", "v" => 1}, %{})

cosmos_get = fn ->
  dispatch.(:get, "/dbs/court_db/colls/court_coll/docs", [], nil)
end

case mode do
  "before" ->
    r = cosmos_get.()
    parsed = Jason.decode!(r.body)

    if r.state == :sent and r.status == 200 and is_map(parsed) and is_list(parsed["Documents"]) do
      IO.puts("BEFORE-HOLDS: single sent response, state=:sent status=#{r.status}, no exception escaped")
    else
      IO.puts(:stderr, "[witness] before-mode failed: state=#{inspect(r.state)} status=#{inspect(r.status)} body=#{inspect(r.body)}")
      System.halt(1)
    end

  "after" ->
    result =
      try do
        r = cosmos_get.()
        {:no_raise, r}
      rescue
        # Plug wraps send-time errors in WrapperError (reason carries the real one).
        e in Plug.Conn.WrapperError -> {:raised_wrapped, e}
        e in Plug.Conn.AlreadySentError -> {:raised, e}
      end

    unwrap = fn
      %Plug.Conn.WrapperError{kind: :error, reason: %Plug.Conn.AlreadySentError{} = inner} -> {:raised, inner}
      %Plug.Conn.AlreadySentError{} = inner -> {:raised, inner}
      other -> {:other, other}
    end

    case result do
      {:raised, e} ->
        IO.puts("AFTER-FLIP: #{Exception.format(:error, e)} — sent conn fell through, defect reproduced")

      {kind, e} when kind in [:raised_wrapped, :other] ->
        inner = unwrap.(e)
        if match?({:raised, _}, inner) do
          {:raised, real} = inner
          IO.puts("AFTER-FLIP (wrapped): #{Exception.format(:error, real)} — sent conn fell through, defect reproduced")
        else
          IO.puts(:stderr, "[witness] after-mode raised an unexpected error: #{inspect(e)}")
          System.halt(1)
        end

      {:no_raise, r} ->
        IO.puts(:stderr, "[witness] after-mode did NOT flip: no AlreadySentError; state=#{inspect(r.state)} status=#{inspect(r.status)} body=#{inspect(r.body)}")
        System.halt(1)
    end

  _ ->
    IO.puts(:stderr, "[witness] unknown mode: #{inspect(mode)}")
    System.halt(2)
end
