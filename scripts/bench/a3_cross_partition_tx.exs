# A-3: cross-partition multi-entity atomic fan-out — transaction semantics bench.
# Run: MIX_ENV=test mix run --no-start scripts/bench/a3_cross_partition_tx.exs
#
# PURPOSE: establish mechanically (witnessed, not assumed) the transaction
# semantics of the smalt Cosmos surface:
#   T1. Does a transactional batch surface exist at all? (real Azure: batch is
#       single-partition only; cross-partition ACID does not exist in Azure)
#   T2. Sequential 3-doc fan-out across 2 partitions with a forced mid-batch
#       failure: does smalt roll back docs 1-2 when doc 3 fails?
#   T3. Mid-batch simulated crash: partial state witness.
#   T4. 2PC-simulation (compensate-write) throughput + consistency-under-kill.
#
# Verdict vocabulary: ATOMIC / NONATOMIC / UNSUPPORTED.
# KD-row candidate: GAP(cosmos-cross-partition-tx) — but the sharper finding is
# that no batch surface exists at all, so single-partition TransactionalBatch
# (which IS real Azure) is also absent.

defmodule A3 do
  alias Smalt.DataPlane.Cosmos
  alias Smalt.Store

  @db "a3db"
  @coll "a3coll"
  @table :smalt_cosmos_docs

  defp doc_key(db, coll, id), do: "#{db}/#{coll}/#{id}"

  def setup do
    case Store.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Store.clear()
    {:ok, 201, _, _} = Cosmos.create_db(@db)
    {:ok, 201, _, _} = Cosmos.create_collection(@db, @coll, %{"partitionKey" => %{"paths" => ["/pk"]}})
    :ok
  end

  def create(db, coll, id, pk) do
    body = %{"id" => id, "pk" => pk, "pad" => String.duplicate("x", 128)}

    Cosmos.create_doc(db, coll, body, %{
      "x-ms-documentdb-partitionkey" => ~s(["#{pk}"]),
      "x-ms-documentdb-is-upsert" => "true"
    })
  end

  def exists?(id), do: match?({:ok, _}, Store.get(@table, doc_key(@db, @coll, id)))

  defp j(map), do: Jason.encode!(map)

  # ---------------------------------------------------------------------------
  # T1 — batch surface existence (mechanical: module export enumeration)
  # ---------------------------------------------------------------------------
  def t1 do
    exports = Cosmos.module_info(:exports) |> Enum.map(fn {n, _} -> Atom.to_string(n) end)

    write_surface = Enum.filter(exports, &(&1 in ["create_doc", "put_doc", "delete_doc"]))
    batch_ops = Enum.filter(exports, &(&1 in ["batch", "execute_batch", "transactional_batch", "bulk", "execute_batch_async"]))

    %{
      "test" => "T1-batch-surface-exists",
      "method" => "module_info(:exports) enumeration",
      "batch_ops_found" => batch_ops,
      "write_surface" => write_surface,
      "verdict" => if(batch_ops == [], do: "UNSUPPORTED", else: "PRESENT")
    }
    |> j()
  end

  # ---------------------------------------------------------------------------
  # T2 — sequential 3-doc fan-out across 2 partitions, forced failure at doc 3
  # Failure injector: partition-key mismatch (body pk != header pk) → 400.
  # ---------------------------------------------------------------------------
  def t2 do
    batch = System.unique_integer([:positive])
    id = &"a3-t2-#{batch}-#{&1}"

    {:ok, s1, _, _} = create(@db, @coll, id.(1), "pA")
    {:ok, s2, _, _} = create(@db, @coll, id.(2), "pA")

    r3 =
      Cosmos.create_doc(@db, @coll, %{"id" => id.(3), "pk" => "pB"}, %{
        "x-ms-documentdb-partitionkey" => ~s(["pA"])
      })

    {:ok, s3, _, _} = r3

    survived1 = exists?(id.(1))
    survived2 = exists?(id.(2))

    %{
      "test" => "T2-seq-fanout-2-partitions-forced-failure",
      "doc1_status" => s1,
      "doc2_status" => s2,
      "doc3_status" => s3,
      "docs_1_2_persisted_after_doc3_failure" => survived1 and survived2,
      "rollback_verdict" => if(survived1 and survived2, do: "NONATOMIC", else: "ATOMIC"),
      "cross_partition_batch_accepted" => "n/a: no batch surface"
    }
    |> j()
  end

  # ---------------------------------------------------------------------------
  # T3 — mid-batch simulated crash: stop the batch after doc 2 (as-if process
  # death); ETS writes are committed inside each create_doc before this line,
  # so docs 1-2 of an intended 3 are already durable → partial state.
  # ---------------------------------------------------------------------------
  def t3 do
    batch = System.unique_integer([:positive])
    id = &"a3-t3-#{batch}-#{&1}"

    {:ok, s1, _, _} = create(@db, @coll, id.(1), "pA")
    {:ok, s2, _, _} = create(@db, @coll, id.(2), "pB")
    # -- simulated crash here: batch never reaches doc 3 --

    %{
      "test" => "T3-mid-batch-crash-witness",
      "intended_total" => 3,
      "doc1_status" => s1,
      "doc2_status" => s2,
      "doc1_persisted_after_crash" => exists?(id.(1)),
      "doc2_persisted_after_crash" => exists?(id.(2)),
      "partial_state_witnessed" => exists?(id.(1)) and exists?(id.(2))
    }
    |> j()
  end

  # ---------------------------------------------------------------------------
  # T4 — 2PC-simulation at app tier: compensate-write (write all; on failure
  # delete what was written). Happy-path ops/s + compensation-under-kill.
  # ---------------------------------------------------------------------------
  def t4(n \\ 2_000) do
    batch = System.unique_integer([:positive])

    # happy path: 3 sequential creates per op, no failure
    happy = fn i ->
      for d <- 1..3 do
        {:ok, 201, _, _} = create(@db, @coll, "a3-t4-#{batch}-#{i}-#{d}", if(rem(d, 2) == 0, do: "pB", else: "pA"))
      end
    end

    t0 = :erlang.monotonic_time(:millisecond)
    Enum.each(1..n, happy)
    ms = :erlang.monotonic_time(:millisecond) - t0
    ops_sec = n * 1000 / ms |> Float.round(0)
    per_op_us = Float.round(ms * 1000 / n, 1)

    # compensation path: writes 1-2 land, doc 3 fails (pk mismatch), then
    # compensating deletes of docs 1-2 → end state = zero docs.
    comp_once = fn i ->
      {:ok, _, _, _} = create(@db, @coll, "a3-cmp-#{batch}-#{i}-1", "pA")
      {:ok, _, _, _} = create(@db, @coll, "a3-cmp-#{batch}-#{i}-2", "pB")

      {:ok, 400, _, _} =
        Cosmos.create_doc(@db, @coll, %{"id" => "a3-cmp-#{batch}-#{i}-3", "pk" => "pB"}, %{
          "x-ms-documentdb-partitionkey" => ~s(["pA"])
        })

      Cosmos.delete_doc(@db, @coll, "a3-cmp-#{batch}-#{i}-1", pk_hdr("pA"))
      Cosmos.delete_doc(@db, @coll, "a3-cmp-#{batch}-#{i}-2", pk_hdr("pB"))
      :ok
    end

    # verify compensation once: end state must be all-absent
    verify_id1 = "a3-cmp-#{batch}-777-1"
    _ = comp_once.(777)

    comp_ok =
      not exists?(verify_id1) and
        not exists?("a3-cmp-#{batch}-777-2")

    # consistency-under-kill: run compensate batches and "kill" midway (stop
    # after doc 2 write, BEFORE compensation runs) — the app-tier pattern
    # cannot protect against this; witness the partial state.
    kill_id = "a3-kill-#{batch}-1"
    {:ok, _, _, _} = create(@db, @coll, kill_id, "pA")
    {:ok, _, _, _} = create(@db, @coll, "a3-kill-#{batch}-2", "pB")
    # -- kill before compensation --
    killed_partial = exists?(kill_id) and exists?("a3-kill-#{batch}-2")

    %{
      "test" => "T4-compensate-write-2pc-sim",
      "n_batches" => n,
      "happy_ops_per_sec" => ops_sec,
      "happy_us_per_batch" => per_op_us,
      "compensation_end_state_clean" => comp_ok,
      "kill_midway_partial_state" => killed_partial,
      "kill_verdict" => if(killed_partial, do: "NONATOMIC", else: "ATOMIC")
    }
    |> j()
  end

  defp pk_hdr(pk), do: %{"x-ms-documentdb-partitionkey" => ~s(["#{pk}"])}

  def run do
    setup()
    IO.puts(j(%{"lane" => "a3", "surface" => "cosmos-tx", "otp" => :erlang.system_info(:otp_release) |> List.to_string()}))
    IO.puts(t1())
    IO.puts(t2())
    IO.puts(t3())
    IO.puts(t4())
  end
end

A3.run()
