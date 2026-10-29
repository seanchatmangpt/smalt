defmodule Smalt.PPlan.ReceiptEngineTest do
  use ExUnit.Case, async: false

  alias Smalt.PPlan.ReceiptEngine

  @dets_root_tmp "tmp/pplan_receipt_engine_test"

  setup context do
    dir =
      Path.join([
        File.cwd!(),
        @dets_root_tmp,
        "#{context.test}-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    {:ok, dir: dir, path: Path.join(dir, "steps.dets")}
  end

  test "4-step run: 32-byte merkle root, ntriples faces, epoch ordering", %{path: path} do
    run_id = "run4-#{System.unique_integer([:positive])}"
    {:ok, ^run_id} = ReceiptEngine.open(run_id, path)

    on_exit(fn -> ReceiptEngine.close(run_id) end)

    for {epoch, act} <- [{1, "arm-put"}, {2, "blob-put"}, {2, "queue-send"}, {3, "kv-get"}] do
      ReceiptEngine.record_step(run_id, %{epoch: epoch, act: act, delta: {:put, act, epoch}})
    end

    receipt = ReceiptEngine.seal_receipt(run_id)

    assert is_binary(receipt.merkle_root) and byte_size(receipt.merkle_root) == 32
    assert receipt.step_count == 4
    # phi_lease_final defaults to the max observed epoch.
    assert receipt.phi_lease_final == 3
    assert is_nil(receipt.signature)

    # Epoch ordering: ntriples activities appear in ascending epoch order.
    acts = Regex.scan(~r/urn:smalt:act:[^>]+/, receipt.ntriples) |> List.flatten() |> Enum.uniq()
    assert length(acts) == 4
    epochs = Enum.map(acts, fn act_iri -> act_iri |> String.split(":") |> List.last() end)
    # act IRI embeds seq; seq order == epoch order by construction of the seal walk.
    assert epochs == Enum.sort(epochs)

    assert receipt.ntriples =~ "http://www.w3.org/ns/prov#Activity"
    assert receipt.ntriples =~ "http://purl.org/net/p-plan#correspondsToStep"

    # Chain: step 4 chains to steps 1..3.
    steps = ReceiptEngine.steps(run_id) |> Enum.sort_by(&{&1.epoch, &1.seq})
    last = Enum.at(steps, 3)
    assert length(last.prev_hashes) == 3
    assert last.prev_hashes == Enum.map(Enum.slice(steps, 0, 3), & &1.hash)
  end

  test "deterministic re-seal: same steps, same receipt (root + ntriples)", %{path: path} do
    run_id = "reredo-#{System.unique_integer([:positive])}"
    {:ok, ^run_id} = ReceiptEngine.open(run_id, path)
    on_exit(fn -> ReceiptEngine.close(run_id) end)

    for epoch <- [1, 2, 3] do
      ReceiptEngine.record_step(run_id, %{epoch: epoch, act: "op", delta: {:d, epoch}})
    end

    receipt = ReceiptEngine.seal_receipt(run_id)
    resealed = ReceiptEngine.seal_receipt(run_id)
    assert resealed.merkle_root == receipt.merkle_root
    assert resealed.ntriples == receipt.ntriples
    assert resealed == receipt

    # A new step changes the root (root commits to the chain).
    ReceiptEngine.record_step(run_id, %{epoch: 4, act: "op", delta: {:d, 4}})
    changed = ReceiptEngine.seal_receipt(run_id)
    assert changed.merkle_root != receipt.merkle_root
  end

  test "signer fun lands in the receipt; identity default is nil", %{path: path} do
    run_id = "sig-#{System.unique_integer([:positive])}"
    {:ok, ^run_id} = ReceiptEngine.open(run_id, path)
    on_exit(fn -> ReceiptEngine.close(run_id) end)

    ReceiptEngine.record_step(run_id, %{epoch: 0, act: "op", delta: :x})

    receipt =
      ReceiptEngine.seal_receipt(run_id, nil, fn root -> "sig(" <> Base.encode16(root) <> ")" end)

    assert receipt.signature == "sig(" <> Base.encode16(receipt.merkle_root) <> ")"

    unsigned = ReceiptEngine.seal_receipt(run_id)
    assert is_nil(unsigned.signature)
  end

  test "explicit phi_lease_final is honored over max-epoch default", %{path: path} do
    run_id = "phi-#{System.unique_integer([:positive])}"
    {:ok, ^run_id} = ReceiptEngine.open(run_id, path)
    on_exit(fn -> ReceiptEngine.close(run_id) end)

    ReceiptEngine.record_step(run_id, %{epoch: 1, act: "op", delta: :x})

    assert ReceiptEngine.seal_receipt(run_id, 9).phi_lease_final == 9
    assert ReceiptEngine.seal_receipt(run_id).phi_lease_final == 1
  end

  test "steps/1 on a never-opened run returns [] (no crash)", do: _ =
         assert ReceiptEngine.steps("never-opened-#{System.unique_integer()}") == []

  test "empty run seals with 32-byte root and nil phi", %{path: path} do
    run_id = "empty-#{System.unique_integer([:positive])}"
    {:ok, ^run_id} = ReceiptEngine.open(run_id, path)
    on_exit(fn -> ReceiptEngine.close(run_id) end)

    receipt = ReceiptEngine.seal_receipt(run_id)
    assert byte_size(receipt.merkle_root) == 32
    assert is_nil(receipt.phi_lease_final)
    assert receipt.step_count == 0
  end

  # ---- GAP-6a pplan half: Agent chain court ----

  test "chain-present: sealed receipt names prov:Agent with full chain, verify_chain ok", %{
    path: path
  } do
    run_id = "chain-#{System.unique_integer([:positive])}"
    {:ok, ^run_id} = ReceiptEngine.open(run_id, path)
    on_exit(fn -> ReceiptEngine.close(run_id) end)

    ReceiptEngine.record_step(run_id, %{epoch: 1, act: "op", delta: :x})

    receipt = ReceiptEngine.seal_receipt(run_id)
    default_agent = "urn:smalt:agent:#{to_string(node())}"
    assert receipt.agent == default_agent

    # All three chain faces present: Agent typed, Activity associated, Entity attributed.
    assert receipt.ntriples =~ ~s(<#{default_agent}> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/ns/prov#Agent> .)
    assert receipt.ntriples =~ "<http://www.w3.org/ns/prov#wasAssociatedWith> <#{default_agent}> ."
    assert receipt.ntriples =~ "<http://www.w3.org/ns/prov#wasAttributedTo> <#{default_agent}> ."

    assert ReceiptEngine.verify_chain(receipt.ntriples) == :ok
  end

  test "per-term tamper: verify_chain names the missing term, fail-closed", %{path: path} do
    run_id = "tamper-#{System.unique_integer([:positive])}"
    {:ok, ^run_id} = ReceiptEngine.open(run_id, path)
    on_exit(fn -> ReceiptEngine.close(run_id) end)

    ReceiptEngine.record_step(run_id, %{epoch: 1, act: "op", delta: :x})
    nt = ReceiptEngine.seal_receipt(run_id).ntriples
    assert ReceiptEngine.verify_chain(nt) == :ok

    for {term, label} <- [
          {~s(<http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/ns/prov#Agent> .), "agent type"},
          {"<http://www.w3.org/ns/prov#wasAssociatedWith>", "wasAssociatedWith"},
          {"<http://www.w3.org/ns/prov#wasAttributedTo>", "wasAttributedTo"}
        ] do
      stripped = String.replace(nt, term, "")
      assert ReceiptEngine.verify_chain(stripped) == {:error, [term]}, "tamper: #{label}"
    end
  end

  test "agent override: :agent opt lands in receipt and every chain edge", %{path: path} do
    run_id = "override-#{System.unique_integer([:positive])}"
    {:ok, ^run_id} = ReceiptEngine.open(run_id, path)
    on_exit(fn -> ReceiptEngine.close(run_id) end)

    ReceiptEngine.record_step(run_id, %{epoch: 1, act: "op", delta: :x})
    ReceiptEngine.record_step(run_id, %{epoch: 1, act: "op2", delta: :y})

    receipt = ReceiptEngine.seal_receipt(run_id, nil, nil, agent: "urn:smalt:agent:bk129")

    assert receipt.agent == "urn:smalt:agent:bk129"
    nt = receipt.ntriples
    refute nt =~ to_string(node())
    # One type triple; one association per Activity (2); attribution per Entity + run (3).
    assert length(Regex.scan(~r/<urn:smalt:agent:bk129> .*prov#Agent> \./, nt)) == 1
    assert length(Regex.scan(~r/prov#wasAssociatedWith> <urn:smalt:agent:bk129> \./, nt)) == 2
    assert length(Regex.scan(~r/prov#wasAttributedTo> <urn:smalt:agent:bk129> \./, nt)) == 3
    assert ReceiptEngine.verify_chain(nt) == :ok
  end

  test "time relations: endedAtTime on Activity, generatedAtTime on Entity, from step ts", %{
    path: path
  } do
    run_id = "time-#{System.unique_integer([:positive])}"
    {:ok, ^run_id} = ReceiptEngine.open(run_id, path)
    on_exit(fn -> ReceiptEngine.close(run_id) end)

    ts = System.system_time(:nanosecond)
    ReceiptEngine.record_step(run_id, %{epoch: 1, act: "op", delta: :x, ts: ts})

    nt = ReceiptEngine.seal_receipt(run_id).ntriples
    iso = ts |> DateTime.from_unix!(:nanosecond) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    assert nt =~ ~s(<http://www.w3.org/ns/prov#endedAtTime> "#{iso}"^^<http://www.w3.org/2001/XMLSchema#dateTime> .)
    assert nt =~ ~s(<http://www.w3.org/ns/prov#generatedAtTime> "#{iso}"^^<http://www.w3.org/2001/XMLSchema#dateTime> .)
  end
end
