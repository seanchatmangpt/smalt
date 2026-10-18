defmodule Smalt.Semantic.LedgerEntry do
  @moduledoc """
  Semantic projection of one Confidential Ledger Merkle transaction receipt
  (read path over `Smalt.Store.list/1` on `:smalt_ledger_transactions`,
  written by `Smalt.Security.LedgerWriter`).

  Evidence-flavored per ex4pm's admission pattern: a Merkle-chained receipt
  being projected is EVIDENCE that an append was observed — it is not an
  authorization or a claim that any downstream consequence is ALIVE.
  """

  # Compile-time Ash config, set here because config/config.exs is outside
  # this lane's owned files. See docs/SEMANTIC_PROJECTION.md.
  Application.put_env(:ash, :default_string_length_count, :codepoints, persistent: true)

  # AshR2RML.Resource is dev/test-only; the `r2rml` section is guarded by
  # Smalt.Semantic.R2RMLGuard so MIX_ENV=prod compiles without ash_r2rml.
  # The extensions option stays a compile-time LITERAL (Spark section-import
  # requirement — see Smalt.Semantic.R2RMLGuard moduledoc). Lane G2.
  import Smalt.Semantic.R2RMLGuard, only: [if_r2rml: 1]

  use Ash.Resource,
    domain: Smalt.Semantic.Domain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshR2RML.Resource]

  attributes do
    attribute(:tx_id, :string, allow_nil?: false, primary_key?: true, public?: true)
    attribute(:sub_ledger_id, :string, public?: true)
    attribute(:merkle_root, :string, public?: true)
    attribute(:prev_hash, :string, public?: true)
    attribute(:data_hash, :string, public?: true)
    attribute(:timestamp, :string, public?: true)
  end

  actions do
    read :read do
      manual(Smalt.Semantic.StoreRead)
      primary?(true)
    end
  end

  if_r2rml do
    r2rml do
      table_name("smalt_ledger_transactions")
      class("https://ggen.io/ontology/smalt#LedgerEntry")

      subject do
        template("https://ggen.io/data/smalt/ledger-entry/{tx_id}")
      end

      property(:sub_ledger_id, "https://ggen.io/ontology/smalt#subLedgerId")
      property(:merkle_root, "https://ggen.io/ontology/smalt#merkleRoot")
      property(:prev_hash, "https://ggen.io/ontology/smalt#prevHash")
      property(:data_hash, "https://ggen.io/ontology/smalt#dataHash")
    end
  end
end
