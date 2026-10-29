defmodule Smalt.PPlan.ReceiptEngine do
  @moduledoc """
  P-PLAN / PROV-O provenance receipt engine over a DETS bag.

  Records provenance steps (`record_step/2`) as `prov_step` records in a DETS
  bag, each hash-chained to its predecessor (`prev_hashes`), then seals a run
  (`seal_receipt/3`) into a receipt map carrying:

    * `phi_lease_final` — the final lease epoch observed for the run
    * `merkle_root` — a 32-byte epoch-ordered Merkle root over the step hashes
    * `ntriples` — PROV-O N-Triples serialization of the sealed run
    * `signature` — `signer.(root)` when a signer fun is supplied (POWL-8
      lands the PQC ManagedHsm signer); `nil` for the default unsigned receipt

  ## DETS shape (pinned)

  A bag keyed by the `run_id`: one bag per run, duplicate bag entries are the
  steps in insertion order. DETS bags preserve insertion order on `:dets.lookup`
  for a fixed file, which the seal walk relies on for stable tie-breaking when
  two steps share a lease epoch (the epoch sort is stable per Erlang's
  `Enum.sort_by/3`).

  ## PROV-O Agent chain (GAP-6a, pplan half)

  The sealed run names a responsible agent: a neutral, domain-blind
  `urn:smalt:agent:<session>` IRI (override with the `:agent` opt), typed
  `prov:Agent`, with `prov:wasAssociatedWith` (Activity→Agent) and
  `prov:wasAttributedTo` (Entity→Agent) edges — the same chain shape as
  `Smalt.Powl2.Andon`. Time relations ride where the receipt carries
  timestamps: each Activity gets `prov:endedAtTime` and each generated Entity
  `prov:generatedAtTime` (ISO8601 from the step `ts`). `verify_chain/1` fails
  closed on a serialization missing any chain term.

  The DETS file is caller-owned: `open/2` / `close/1` bracket a run. Tests use
  a temp file with `on_exit` cleanup; production passes a durable path.

  ## Hash law

  A step's hash is `sha256(term_to_binary(canonical_step))` over the ordered
  field tuple `{epoch, seq, act_iri, entity_iri, delta_hash, prev_hashes}` —
  NOT over the raw wall-clock ts (ts is observational, not semantically
  load-bearing; including it would make re-recorded identical steps hash
  differently). The chain law: `prev_hashes` of step N are the hashes of every
  prior step in the same run, so the Merkle root over `[h1..hN]` commits to
  the whole chain.
  """

  @typedoc "Run identifier (binary)."
  @type run_id :: String.t()

  @typedoc "Lease epoch (monotone integer per lease)."
  @type epoch :: non_neg_integer()

  @typedoc "A recorded provenance step."
  @type step :: %{
          required(:run_id) => run_id(),
          required(:epoch) => epoch(),
          required(:seq) => non_neg_integer(),
          required(:act_iri) => String.t(),
          required(:entity_iri) => String.t(),
          required(:delta_hash) => String.t(),
          required(:prev_hashes) => [String.t()],
          required(:hash) => String.t(),
          required(:ts) => integer()
        }

  @typedoc "A sealed receipt."
  @type receipt :: %{
          required(:run_id) => run_id(),
          required(:phi_lease_final) => epoch() | nil,
          required(:merkle_root) => binary(),
          required(:ntriples) => String.t(),
          required(:signature) => binary() | nil,
          required(:agent) => String.t(),
          required(:step_count) => non_neg_integer()
        }

  @dets_auto_save 5_000

  # PROV-O / P-PLAN vocab IRIs (GAP-6a). Defined BEFORE all uses: a module
  # attribute read above its definition silently expands to nil at compile
  # time (witnessed: verify_chain/1 raised ArgumentError on "<" <> @prov and
  # the agent type triple emitted a nil predicate — bk129r receipt).
  @prov "http://www.w3.org/ns/prov#"
  @rdf_type "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
  # P-PLAN vocabulary (canonical purl namespace; e.g. p-plan:correspondsToStep)
  @pplan "http://purl.org/net/p-plan#"

  @doc """
  Opens (creates if absent) the DETS bag file at `path` for a run. Returns
  `{:ok, run_id}` — the run id doubles as the DETS table name reference via the
  returned handle in `seal_receipt/3`; internally the table is named by
  CHARLIST (never an atom — atom-law, SPOF-B A-5) derived from the
  caller-supplied unique name.
  """
  @spec open(run_id(), String.t()) :: {:ok, run_id()} | {:error, term()}
  def open(run_id, path) when is_binary(run_id) and is_binary(path) do
    file = Path.expand(path)
    File.mkdir_p!(Path.dirname(file))

    case :dets.open_file(dets_name(run_id), file: String.to_charlist(file), type: :duplicate_bag, repair: true, auto_save: @dets_auto_save) do
      {:ok, _} -> {:ok, run_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Flushes and closes the DETS file for the run."
  @spec close(run_id()) :: :ok
  def close(run_id) do
    name = dets_name(run_id)

    case :dets.info(name) do
      :undefined -> :ok
      _ -> :dets.close(name)
    end

    :ok
  end

  @doc """
  Records one provenance step: hashes `delta` (`term_to_binary` + sha256, hex),
  chains to every prior step hash in the run, and inserts the `prov_step` bag
  record. Returns the recorded step.
  """
  @spec record_step(run_id(), %{
          required(:epoch) => epoch(),
          required(:act) => String.t(),
          required(:delta) => term(),
          optional(:ts) => integer()
        }) :: step()
  def record_step(run_id, %{epoch: epoch, act: act, delta: delta} = fields)
      when is_integer(epoch) and epoch >= 0 and is_binary(act) do
    prior = prior_hashes(run_id)
    seq = length(prior)
    delta_hash = hex(:crypto.hash(:sha256, :erlang.term_to_binary(delta)))
    ts = Map.get(fields, :ts, System.system_time(:nanosecond))

    step = %{
      run_id: run_id,
      epoch: epoch,
      seq: seq,
      act_iri: act_iri(run_id, act, seq),
      entity_iri: entity_iri(run_id, seq, delta_hash),
      delta_hash: delta_hash,
      prev_hashes: prior,
      hash: nil,
      ts: ts
    }

    step = %{step | hash: step_hash(step)}
    :dets.insert(dets_name(run_id), {run_id, step})
    step
  end

  @doc """
  Seals the run: epoch-ordered (insertion-order tie-break) Merkle root over the
  step hashes, PROV-O N-Triples serialization, final lease epoch. `signer` is
  an optional 1-arity fun applied to the merkle root (default: identity —
  unsigned receipt, `signature: nil`; the PQC ManagedHsm signer lands in
  POWL-8). An empty run seals with a 32-byte root over no leaves (sha256 of
  empty binary) and `phi_lease_final: nil`.

  Opts:

    * `:session` — session id (default current node inspect)
    * `:agent` — responsible-agent IRI (default `urn:smalt:agent:<session>`;
      the neutral, domain-blind GAP-6a chain agent)
  """
  @spec seal_receipt(run_id(), epoch() | nil, (binary() -> binary()) | nil, keyword()) ::
          receipt()
  def seal_receipt(run_id, phi_lease_final \\ nil, signer \\ nil, opts \\ [])
      when is_list(opts) do
    steps =
      run_id
      |> steps()
      |> Enum.sort_by(&{&1.epoch, &1.seq})

    root = merkle_root(Enum.map(steps, & &1.hash))
    signature = if signer, do: signer.(root), else: nil
    session = Keyword.get(opts, :session, to_string(node()))
    agent = Keyword.get(opts, :agent, "urn:smalt:agent:#{session}")

    %{
      run_id: run_id,
      phi_lease_final: phi_lease_final || max_epoch(steps),
      merkle_root: root,
      ntriples: ntriples(run_id, steps, agent),
      signature: signature,
      agent: agent,
      step_count: length(steps)
    }
  end

  @doc """
  Fail-closed chain verifier over an emitted N-Triples block (GAP-6a): `:ok`
  only when the block carries the full Agent chain — the `prov:Agent` type
  triple plus `prov:wasAssociatedWith` (Activity→Agent) and
  `prov:wasAttributedTo` (Entity→Agent) edges. Any missing term returns
  `{:error, missing_terms}` — a receipt that dropped the Agent chain is
  refused downstream, never silently admitted.
  """
  @spec verify_chain(String.t()) :: :ok | {:error, [String.t()]}
  def verify_chain(nt) when is_binary(nt) do
    required = [
      ~s(<http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/ns/prov#Agent> .),
      "<" <> @prov <> "wasAssociatedWith>",
      "<" <> @prov <> "wasAttributedTo>"
    ]

    missing = Enum.reject(required, &String.contains?(nt, &1))
    if missing == [], do: :ok, else: {:error, missing}
  end

  @doc "Recorded steps of a run, in DETS insertion order (unsorted)."
  @spec steps(run_id()) :: [step()]
  def steps(run_id) do
    if :dets.info(dets_name(run_id)) == :undefined do
      []
    else
      steps_lookup(run_id)
    end
  end

  defp steps_lookup(run_id) do
    case :dets.lookup(dets_name(run_id), run_id) do
      :undefined -> []
      tuples -> Enum.map(tuples, fn {_k, step} -> step end)
    end
  end

  # ---- internals ----

  defp prior_hashes(run_id), do: Enum.map(steps(run_id), & &1.hash)

  defp act_iri(run_id, act, seq), do: "urn:smalt:act:#{run_id}:#{act}:#{seq}"

  defp entity_iri(run_id, seq, delta_hash),
    do: "urn:smalt:entity:#{run_id}:#{seq}:#{delta_hash}"

  # Hash over the semantically load-bearing ordered tuple; ts excluded (see
  # moduledoc hash law).
  defp step_hash(%{epoch: e, seq: s, act_iri: a, entity_iri: en, delta_hash: d, prev_hashes: p}) do
    hex(:crypto.hash(:sha256, :erlang.term_to_binary({e, s, a, en, d, p})))
  end

  @doc false
  def merkle_root([]), do: :crypto.hash(:sha256, "")
  def merkle_root([only]), do: decode(only)

  def merkle_root(hashes) do
    hashes
    |> Enum.map(&decode/1)
    |> next_level()
    |> merkle_root_bin()
  end

  defp next_level([only]), do: [only]

  defp next_level(level) do
    level
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.map(fn
      [a, b] -> pair_hash(a, b)
      [a] -> pair_hash(a, a)
    end)
  end

  # Single odd leaf is hashed with ITSELF (Bitcoin-style), not carried up
  # unpinned: an unpinned odd leaf lets a re-order at the boundary change the
  # root without changing any leaf.
  defp merkle_root_bin([only]), do: only

  defp merkle_root_bin(level), do: merkle_root_bin(next_level(level))

  defp pair_hash(a, b), do: :crypto.hash(:sha256, a <> b)

  defp decode(hex), do: Base.decode16!(hex, case: :lower)

  defp max_epoch([]), do: nil
  defp max_epoch(steps), do: steps |> Enum.map(& &1.epoch) |> Enum.max()

  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp dets_name(run_id) do
    # SPOF-B / A-5 (atom law, frame_codec class): the previous shape minted
    # `String.to_atom("smalt_pplan_receipt_" <> run_id)` per run — atoms are
    # never GC'd, so a long-lived node running unique run_ids grew the atom
    # table monotonically (the "caller-lifetime bracket" comment was invalid
    # for the atom table). DETS accepts non-atom table names: the charlist
    # name is byte-identical in behavior (:dets.info/1, insert, lookup, close
    # all accept it) and mints ZERO atoms (proven: atom_count delta 0 across
    # distinct names, vs +1 per atom-name mint). The caller-lifetime bracket
    # for the FILE is unchanged — `close/1` still closes the dets.
    ~c"smalt_pplan_receipt_" ++ String.to_charlist(run_id)
  end

  # ---- PROV-O N-Triples serialization ----

  defp ntriples(run_id, steps, agent) do
    run = "<urn:smalt:run:" <> run_id <> ">"
    agent_iri = "<" <> agent <> ">"

    run_lines = [
      iri_line(run, "<" <> @rdf_type <> ">", "<" <> @prov <> "Entity>"),
      iri_line(run, "<" <> @pplan <> "correspondsToStep>", "<urn:smalt:pplan:step:" <> run_id <> ">"),
      iri_line(agent_iri, "<" <> @rdf_type <> ">", "<" <> @prov <> "Agent>"),
      iri_line(run, "<" <> @prov <> "wasAttributedTo>", agent_iri)
    ]

    {step_lines, _} =
      steps
      |> Enum.with_index()
      |> Enum.flat_map_reduce(nil, fn {step, idx}, prev_entity ->
        act = "<" <> step.act_iri <> ">"
        entity = "<" <> step.entity_iri <> ">"
        plan_step = "<urn:smalt:pplan:step:" <> run_id <> ":" <> Integer.to_string(idx) <> ">"
        ended = iso8601(step.ts)

        lines = [
          iri_line(act, @rdf_type, "<" <> @prov <> "Activity>"),
          iri_line(entity, @rdf_type, "<" <> @prov <> "Entity>"),
          iri_line(entity, "<" <> @prov <> "wasGeneratedBy>", act),
          iri_line(act, "<" <> @pplan <> "correspondsToStep>", plan_step),
          iri_line(act, "<" <> @prov <> "wasDerivedFrom>", prev_entity || run),
          iri_line(act, "<" <> @prov <> "wasAssociatedWith>", agent_iri),
          iri_line(entity, "<" <> @prov <> "wasAttributedTo>", agent_iri),
          lit_line(act, "<" <> @prov <> "endedAtTime>",
            ~s("#{ended}"^^<http://www.w3.org/2001/XMLSchema#dateTime>)),
          lit_line(entity, "<" <> @prov <> "generatedAtTime>",
            ~s("#{ended}"^^<http://www.w3.org/2001/XMLSchema#dateTime>)),
          lit_line(entity, "<" <> @prov <> "value>",
            ~s("#{step.delta_hash}"^^<http://www.w3.org/2001/XMLSchema#hexBinary>))
        ]

        {lines, step.entity_iri}
      end)

    Enum.join(run_lines ++ step_lines, "\n")
  end

  defp iso8601(ns) when is_integer(ns) do
    ns
    |> DateTime.from_unix(:nanosecond)
    |> case do
      {:ok, dt} -> dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      # Out-of-range injectable ts: keep the raw integer rather than crash.
      {:error, _} -> Integer.to_string(ns)
    end
  end

  defp iri_line(subj, pred, obj_iri), do: subj <> " " <> pred <> " " <> obj_iri <> " ."

  defp lit_line(subj, pred, literal), do: subj <> " " <> pred <> " " <> literal <> " ."
end
