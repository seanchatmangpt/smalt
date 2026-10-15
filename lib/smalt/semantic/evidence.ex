defmodule Smalt.Semantic.Evidence do
  @moduledoc """
  Evidence projection of one admitted OCEL conformance deviation record
  (read path over `Smalt.Ocel.DeviationAdmission.read_all/1` on the real
  deviation ledger `tmp/ocel/deviations.jsonl`).

  Ex4pm evidence discipline, stated as vocabulary: the ledger's own status
  vocabulary is "observed". A deviation record being projected is evidence
  that a nonconforming trace was OBSERVED and durably admitted — it is not
  an authorization, a repair, or a claim that the deviation was resolved.
  """

  # Compile-time Ash config, set here because config/config.exs is outside
  # this lane's owned files. See docs/SEMANTIC_PROJECTION.md.
  Application.put_env(:ash, :default_string_length_count, :codepoints, persistent: true)

  use Ash.Resource,
    domain: Smalt.Semantic.Domain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshR2RML.Resource]

  attributes do
    attribute(:id, :string, allow_nil?: false, primary_key?: true, public?: true)
    attribute(:reference_trace_id, :string, public?: true)
    attribute(:candidate_trace_id, :string, public?: true)
    attribute(:deviating_move, :string, public?: true)
    attribute(:fitness, :float, public?: true)
    attribute(:timestamp, :string, public?: true)

    # Standing vocabulary from the deviation ledger itself ("observed");
    # honestly narrower than :authorized / :ALIVE by design.
    attribute(:status, :string, default: "observed", public?: true)
  end

  actions do
    read :read do
      manual(Smalt.Semantic.StoreRead)
      primary?(true)
    end
  end

  r2rml do
    table_name("ocel_deviations")
    class("https://ggen.io/ontology/smalt#OcelDeviationEvidence")

    subject do
      template("https://ggen.io/data/smalt/evidence/{id}")
    end

    property(:reference_trace_id, "https://ggen.io/ontology/smalt#referenceTraceId")
    property(:candidate_trace_id, "https://ggen.io/ontology/smalt#candidateTraceId")
    property(:deviating_move, "https://ggen.io/ontology/smalt#deviatingMove")
    property(:fitness, "https://ggen.io/ontology/smalt#fitness")
    property(:status, "https://ggen.io/ontology/smalt#evidenceStanding")
  end
end
