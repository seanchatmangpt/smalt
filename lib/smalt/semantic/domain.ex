defmodule Smalt.Semantic.Domain do
  @moduledoc """
  Minimal Ash domain projecting the substrate's own state (read path over
  `Smalt.Store`) as a semantic surface.

  Architecture (docs/SEMANTIC_PROJECTION.md):

      Smalt.Store (ETS, canonical substrate state)
          |
          v  manual read (Smalt.Semantic.StoreRead)
      Ash resources (Smalt.Semantic.*)
          |           \
          v            v
   AshR2RML mapping  AshEx4pm evidence pattern
   (virtual RDF      (admission standing: observed
    projection)       != authorized; read-only)
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Smalt.Semantic.Resource)
    resource(Smalt.Semantic.LedgerEntry)
    resource(Smalt.Semantic.Evidence)
  end
end
