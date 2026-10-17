# GAP-AUD1-01 comp-whitelist witness (lane W-5, v26.10.14).
# Usage: mix run --no-start scripts/shim_court/comp_whitelist_witness.exs after|before
#
#   after  — LANDED behavior must hold: every unimplemented blob comp answers a
#            typed 400 InvalidQueryParameter (x-ms-error-code header) and the
#            blob body is UNCHANGED. Exit 0 iff all pass.
#   before — SHIMMED behavior must show the original corruption: PUT with an
#            unimplemented comp OVERWRITES the blob body (the AUD-1 headline
#            corruption class). Exit 0 iff corruption is witnessed.
#
# Chicago-school: real router, real store, real blob — no mocks.
import Plug.Test
import Plug.Conn

alias Smalt.DataPlane.BlobStorage

defmodule CompWhitelistWitness do
  def boot do
    case Process.whereis(Smalt.Store) do
      nil -> {:ok, _} = Smalt.Store.start_link([])
      _ -> :ok
    end

    BlobStorage.ensure_policy_table()
    BlobStorage.ensure_block_table()

    Enum.each(Smalt.Store.table_names(), &:ets.delete_all_objects(&1))
    :ets.delete_all_objects(:smalt_blob_policy)
    :ets.delete_all_objects(:smalt_blob_blocks)
    :ok
  end
end

CompWhitelistWitness.boot()
{:ok, _} = BlobStorage.create_container("acc1", "cont1", %{"immutable" => false})
{:ok, _} = BlobStorage.put_blob("acc1", "cont1", "victim.bin", "original-body")

comps = ~w(appendblock snapshot page pagelist tags query tier expiry seal lease copy)

mode = System.argv() |> List.first()

route = fn comp, method ->
  (method |> to_string() |> String.downcase() |> String.to_existing_atom())
  |> Plug.Test.conn("/acc1/cont1/victim.bin?comp=#{comp}", "corruption-payload")
  |> Plug.Conn.put_req_header("content-type", "application/xml")
  |> Plug.Conn.put_req_header("x-ms-version", "2021-12-02")
  |> Smalt.EgressRouter.call(Smalt.EgressRouter.init([]))
end

corrupt = fn ->
  case BlobStorage.get_blob("acc1", "cont1", "victim.bin") do
    {:ok, %{"content" => "original-body"}} -> false
    _ -> true
  end
end

case mode do
  "after" ->
    failures =
      for comp <- comps do
        conn = route.(comp, :put)

        body_ok? = conn.resp_body =~ "The comp value '#{comp}' is not supported"

        cond do
          conn.status != 400 -> "#{comp}: status #{conn.status} != 400"
          Plug.Conn.get_resp_header(conn, "x-ms-error-code") != ["InvalidQueryParameter"] ->
            "#{comp}: missing x-ms-error-code InvalidQueryParameter"

          not body_ok? -> "#{comp}: message mismatch"
          true -> nil
        end
      end

    # GET arm: unimplemented comps must not serve blob content
    get_failures =
      for comp <- ~w(pagelist tags) do
        conn = route.(comp, :get)

        cond do
          conn.status != 400 -> "GET #{comp}: status #{conn.status} != 400"
          conn.resp_body =~ "original-body" -> "GET #{comp}: blob content leaked"
          true -> nil
        end
      end

    corruption = corrupt.()

    problems = Enum.reject(failures ++ get_failures, &is_nil/1)

    cond do
      problems != [] ->
        IO.inspect(problems, label: "AFTER failures")
        System.stop(1)

      corruption ->
        IO.puts("AFTER FAIL: blob body was modified")
        System.stop(1)

      true ->
        IO.puts(
          "AFTER PASS: all #{length(comps)} unimplemented PUT comps -> typed 400; GET comps refused; body unchanged"
        )

        System.stop(0)
    end

  "before" ->
    # Shimmed: the generic Put Blob fallback must absorb at least one
    # unimplemented comp and overwrite the body (the corruption class).
    conn = route.("snapshot", :put)

    if corrupt.() do
      IO.puts("BEFORE PASS: corruption witnessed — comp=snapshot overwrote blob body (status #{conn.status})")
      System.stop(0)
    else
      IO.puts("BEFORE FAIL: no corruption observed under shim — gate would be vacuous")
      System.stop(1)
    end

  _ ->
    IO.puts("usage: comp_whitelist_witness.exs after|before")
    System.stop(2)
end
