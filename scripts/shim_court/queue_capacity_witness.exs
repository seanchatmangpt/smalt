# Shim-court witness for queue_capacity_court.sh.
#
# Drives the REAL Smalt.Amqp.QueueStore (Chicago: real collaborator, no mocks)
# over a standalone Smalt.Store + QueueStore GenServer — no network, no ports.
#
#   SHIM_CAP_MODE=ok      (BEFORE) 3 enqueues into a fresh queue must all be
#                         {:ok, _} — the unshimmed @capacity 4096 never refuses
#                         a 3rd message.
#   SHIM_CAP_MODE=refuse  (AFTER)  with @capacity shimmed to 1, the 1st enqueue
#                         succeeds (boundary-exactly-at-limit: count 1 >= 1
#                         fills it) and the 2nd must be {:error, :capacity}.
#
# Exit 0 = observed outcome matches the mode; exit 1 = flip absent.

mode = System.get_env("SHIM_CAP_MODE") || raise "SHIM_CAP_MODE not set"

{:ok, _} = Smalt.Store.start_link([])
{:ok, _} = Smalt.Amqp.QueueStore.start_link([])

queue = "shim-cap-#{:erlang.unique_integer([:positive])}"

results = for _ <- 1..3, do: Smalt.Amqp.QueueStore.enqueue(queue, "payload")

case mode do
  "ok" ->
    ok? = Enum.all?(results, fn r -> match?({:ok, _}, r) end)
    IO.puts("[witness] mode=ok results=#{inspect(results)}")
    if ok? do
      IO.puts("[witness] BEFORE signature holds: capacity 4096 accepts all 3 enqueues")
    else
      exit({:shim_cap_before_failed, 1})
    end

  "refuse" ->
    [r1, r2 | _] = results
    IO.puts("[witness] mode=refuse results=#{inspect(results)}")
    if match?({:ok, _}, r1) and match?({:error, :capacity}, r2) do
      IO.puts("[witness] AFTER flip holds: 1st enqueue ok (at-limit), 2nd refused {:error, :capacity}")
    else
      exit({:shim_cap_after_failed, 1})
    end

  other ->
    raise "unknown SHIM_CAP_MODE #{inspect(other)}"
end
