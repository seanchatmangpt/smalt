# X-1 blocklist mutation-court witness (lane X-1, v26.10.14).
#
# Standalone (`mix run --no-start scripts/shim_court/blocklist_witness.exs <after|before>`):
# boots a minimal ETS store substrate and drives the wire surface
# (EgressRouter) through stage -> commit -> download.
#
#   after  — committed body byte-equals the concatenated staged blocks, and
#            Get Block List answers application/xml with the Azure shape
#            (exit 0 = the LANDED outcome holds).
#   before — the PRE-FIX corruption: the committed body is the Put Block List
#            request XML (exit 0 = the old signature holds under the shim).
#
# Real collaborators only: real ETS Store, real router dispatch, no doubles.

import Plug.Test
import Plug.Conn

defmodule BlocklistWitness do

  @account "courtacct"
  @container "courtcont"

  def run("after") do
    boot()

    b1 = :crypto.strong_rand_bytes(64 * 1024)
    b2 = :crypto.strong_rand_bytes(64 * 1024)
    expected = b1 <> b2
    id1 = Base.encode64("court-blk-1")
    id2 = Base.encode64("court-blk-2")

    stage(id1, b1)
    stage(id2, b2)

    commit_xml =
      "<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList><Latest>" <>
        id1 <> "</Latest><Latest>" <> id2 <> "</Latest></BlockList>"

    commit = call(:put, "/#{@account}/#{@container}/court.bin?comp=blocklist", commit_xml)

    if commit.status != 201 do
      IO.puts("AFTER-FAIL: commit status #{commit.status}")
      exit({:shutdown, 1})
    end

    get = call(:get, "/#{@account}/#{@container}/court.bin", "")

    if get.status != 200 or get.resp_body != expected do
      IO.puts("AFTER-FAIL: body mismatch (status #{get.status}, #{byte_size(get.resp_body)} bytes)")
      exit({:shutdown, 1})
    end

    list = call(:get, "/#{@account}/#{@container}/court.bin?comp=blocklist&blocklisttype=all", "")

    ct = get_resp_header(list, "content-type") |> List.first()

    if list.status != 200 or not String.contains?(ct || "", "application/xml") do
      IO.puts("AFTER-FAIL: blocklist content-type #{inspect(ct)}")
      exit({:shutdown, 1})
    end

    if not String.contains?(list.resp_body, "<CommittedBlocks>") or
         not String.contains?(list.resp_body, "<Name>#{id1}</Name>") do
      IO.puts("AFTER-FAIL: blocklist XML shape missing")
      exit({:shutdown, 1})
    end

    IO.puts("AFTER OK: byte-equality + application/xml blocklist witnessed")
  end

  def run("before") do
    boot()

    b1 = :crypto.strong_rand_bytes(16 * 1024)
    b2 = :crypto.strong_rand_bytes(16 * 1024)
    id1 = Base.encode64("court-blk-1")
    id2 = Base.encode64("court-blk-2")

    stage(id1, b1)
    stage(id2, b2)

    commit_xml =
      "<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList><Latest>" <>
        id1 <> "</Latest><Latest>" <> id2 <> "</Latest></BlockList>"

    commit = call(:put, "/#{@account}/#{@container}/court.bin?comp=blocklist", commit_xml)

    if commit.status != 201 do
      IO.puts("BEFORE-FAIL: commit refused (#{commit.status}) — old signature absent")
      exit({:shutdown, 1})
    end

    get = call(:get, "/#{@account}/#{@container}/court.bin", "")

    # Old signature: the blob body IS the commit request XML.
    if get.resp_body == commit_xml do
      IO.puts("BEFORE OK: corruption witnessed (body == request XML, #{byte_size(get.resp_body)} bytes)")
    else
      IO.puts("BEFORE-FAIL: body is not the request XML — old signature absent")
      exit({:shutdown, 1})
    end
  end

  defp stage(id, content) do
    conn = call(:put, "/#{@account}/#{@container}/court.bin?comp=block&blockid=#{id}", content)

    if conn.status != 201 do
      IO.puts("WITNESS-FAIL: Put Block refused (#{conn.status})")
      exit({:shutdown, 1})
    end
  end

  defp call(method, path, body) do
    method
    |> Plug.Test.conn(path, body)
    |> Plug.Conn.put_req_header("content-type", "application/octet-stream")
    |> Plug.Conn.put_req_header("x-ms-version", "2021-12-02")
    |> Smalt.EgressRouter.call(Smalt.EgressRouter.init([]))
  end

  defp boot do
    case Process.whereis(Smalt.Store) do
      nil -> {:ok, _} = Smalt.Store.start_link([])
      _ -> :ok
    end

    Smalt.DataPlane.BlobStorage.ensure_policy_table()
    Smalt.DataPlane.BlobStorage.ensure_block_table()

    # Clean substrate for the court's keys only.
    Enum.each(Smalt.Store.table_names(), &:ets.delete_all_objects(&1))
    :ets.delete_all_objects(:smalt_blob_policy)
    :ets.delete_all_objects(:smalt_blob_blocks)

    # immutable=false: the court exercises plain (non-WORM) block commit.
    create =
      :put
      |> Plug.Test.conn("/#{@account}/#{@container}?restype=container", "")
      |> Plug.Conn.put_req_header("x-ms-immutable-policy", "false")
      |> Plug.Conn.put_req_header("content-type", "application/octet-stream")
      |> Plug.Conn.put_req_header("x-ms-version", "2021-12-02")
      |> Smalt.EgressRouter.call(Smalt.EgressRouter.init([]))

    if create.status != 201 do
      IO.puts("WITNESS-FAIL: container create refused (#{create.status})")
      exit({:shutdown, 1})
    end

    :ok
  end
end

mode = System.argv() |> List.first()
:ok = BlocklistWitness.run(mode)
System.halt(0)
