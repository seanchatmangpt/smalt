# SCVD-T7 wire courts (writer lane, v26.10.20 wave).
#
# Same ramp claims as the internal concurrency courts, driven through the real
# Plug wire face (Smalt.EgressRouter via Plug.Test): real router, real ETS,
# real bytes on the conn. No mocks, no sleeps — Task.async_stream with hard
# timeouts so a hang is a typed exit, never a stuck suite.
defmodule Smalt.Integration.ScvdWireCourtsTest do
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.Cosmos
  alias Smalt.DataPlane.PartitionKey

  @pk_header "x-ms-documentdb-partitionkey"

  setup do
    case GenServer.start_link(Smalt.Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  defp call(method, path, opts \\ []) do
    headers =
      Keyword.get(opts, :headers, [])
      |> Kernel.++(if opts[:no_version], do: [], else: [{"x-ms-version", "2023-11-03"}])

    method
    |> Plug.Test.conn(path, opts[:body])
    |> then(fn c -> Enum.reduce(headers, c, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end) end)
    |> Smalt.EgressRouter.call([])
  end

  # -- wire (a) 64 concurrent cosmos doc create+read ------------------------------

  @tag :scvd
  test "wire (a) 64 concurrent doc create+read over the plug face" do
    db = "scvdw-a-" <> Integer.to_string(System.unique_integer([:positive]))
    coll = "scvdw-a"

    assert {:ok, 201, _, _} = Cosmos.create_db(db)

    assert {:ok, 201, _, _} =
             Cosmos.create_collection(db, coll, %{"partitionKey" => %{"paths" => ["/pk"]}})

    results =
      1..64
      |> Task.async_stream(
        fn i ->
          id = "wdoc-#{i}-#{System.unique_integer([:positive])}"
          body = Jason.encode!(%{"id" => id, "pk" => 1, "v" => i})

          create =
            call(:post, "/dbs/#{db}/colls/#{coll}/docs",
              headers: [{@pk_header, "[1]"}, {"content-type", "application/json"}],
              body: body
            )

          if create.status != 201 do
            {:create_fail, id, create.status}
          else
            read =
              call(:get, "/dbs/#{db}/colls/#{coll}/docs/#{id}",
                headers: [{@pk_header, "[1]"}]
              )

            body_out = Jason.decode!(IO.iodata_to_binary(read.resp_body))

            if read.status == 200 and body_out["id"] == id,
              do: {:ok, id},
              else: {:read_fail, id, read.status}
          end
        end,
        max_concurrency: 64,
        timeout: 20_000
      )
      |> Enum.map(fn {:ok, res} -> res end)

    assert length(results) == 64
    Enum.each(results, fn r -> assert {:ok, _id} = r end)
    ids = Enum.map(results, fn {:ok, id} -> id end)
    assert length(Enum.uniq(ids)) == 64

    Cosmos.drop_container(db, coll)
    Cosmos.drop_db(db)
  end

  # -- wire (b) 32 concurrent blob PUT/GET byte-equal -----------------------------

  @tag :scvd
  test "wire (b) 32 concurrent blob PUT/GET byte-equal over the plug face" do
    account = "scvdw-b"
    container = "scvdw-b"

    assert call(:put, "/#{account}/#{container}?restype=container").status == 201

    payload_base = :crypto.strong_rand_bytes(32 * 1024)

    results =
      1..32
      |> Task.async_stream(
        fn i ->
          name = "wblob-#{i}-#{System.unique_integer([:positive])}"
          content = payload_base <> <<i::64>> <> :crypto.strong_rand_bytes(512)

          put =
            call(:put, "/#{account}/#{container}/#{name}",
              headers: [{"x-ms-blob-type", "BlockBlob"}],
              body: content
            )

          if put.status != 201 do
            {:put_fail, name, put.status}
          else
            get = call(:get, "/#{account}/#{container}/#{name}")

            if get.status == 200 and IO.iodata_to_binary(get.resp_body) == content,
              do: {:ok, name},
              else: {:get_fail, name, get.status}
          end
        end,
        max_concurrency: 32,
        timeout: 20_000
      )
      |> Enum.map(fn {:ok, res} -> res end)

    assert length(results) == 32
    Enum.each(results, fn r -> assert {:ok, _name} = r end)
    names = Enum.map(results, fn {:ok, n} -> n end)
    assert length(Enum.uniq(names)) == 32

    call(:delete, "/#{account}/#{container}?restype=container")
  end

  # -- wire (d) typed refusals on the wire -----------------------------------------

  @tag :scvd
  test "wire (d) concurrent oversized/invalid payloads answer typed wire errors" do
    account = "scvdw-d"
    container = "scvdw-d"

    assert call(:put, "/#{account}/#{container}?restype=container").status == 201

    big_blob = String.duplicate("y", 1_048_577)

    statuses =
      1..24
      |> Task.async_stream(
        fn i ->
          case rem(i, 3) do
            0 ->
              # Oversized blob PUT -> 413 with the Azure XML error envelope.
              conn =
                call(:put, "/#{account}/#{container}/big-#{i}",
                  headers: [{"x-ms-blob-type", "BlockBlob"}],
                  body: big_blob
                )

              body = IO.iodata_to_binary(conn.resp_body)

              if conn.status == 413 and body =~ "RequestBodyTooLarge",
                do: :typed,
                else: {:fail, :blob_toobig, conn.status, body}

            1 ->
              # Control-character blob name -> 400 InvalidResourceName envelope.
              conn =
                call(:put, "/#{account}/#{container}/bad%0Aname-#{i}",
                  headers: [{"x-ms-blob-type", "BlockBlob"}],
                  body: "x"
                )

              body = IO.iodata_to_binary(conn.resp_body)

              if conn.status == 400 and body =~ "InvalidResourceName",
                do: :typed,
                else: {:fail, :blob_badname, conn.status, body}

            _ ->
              # Cosmos invalid doc id ("a/b" grammar violation) -> 400 BadRequest.
              conn =
                call(:post, "/dbs/scvdw-d/colls/scvdw-d/docs",
                  headers: [{@pk_header, "[1]"}, {"content-type", "application/json"}],
                  body: Jason.encode!(%{"id" => "bad/id-#{i}", "pk" => 1})
                )

              body = IO.iodata_to_binary(conn.resp_body)

              if conn.status == 400 and body =~ "BadRequest",
                do: :typed,
                else: {:fail, :cosmos_badid, conn.status, body}
          end
        end,
        max_concurrency: 24,
        timeout: 20_000
      )
      |> Enum.map(fn
        {:ok, res} -> res
        {:exit, reason} -> {:exit, reason}
      end)

    assert length(statuses) == 24
    assert Enum.all?(statuses, &(&1 == :typed))

    call(:delete, "/#{account}/#{container}?restype=container")
  end
end
