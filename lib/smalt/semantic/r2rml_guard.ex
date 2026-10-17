defmodule Smalt.Semantic.R2RMLGuard do
  @moduledoc """
  Compile-time guard for the dev/test-only `AshR2RML.Resource` extension
  (`{:ash_r2rml, path: "../ash_r2rml", only: [:dev, :test], optional: true}`).

  Expansion is conditional on ash_r2rml being a loaded compile-time dep:
  the `r2rml` DSL block is dropped WITHOUT expansion when absent, so
  `lib/smalt/semantic/*.ex` compile under MIX_ENV=prod without ash_r2rml.

  The `extensions: [AshR2RML.Resource]` option stays a compile-time LITERAL
  on purpose: Spark derives section-macro imports from the literal and
  silently skips a missing module's import (mechanism verified 2026-10-17:
  the only prod compile error is the unimported `r2rml` section macro,
  which this guard drops). Any indirection (module attribute, macro call)
  in the extensions option makes Spark silently drop the extension from
  the import set even in dev, so it must not be used here.
  """

  # AST-branch-dropping guard: `block` is received as unevaluated AST. When
  # ash_r2rml is absent it is dropped WITHOUT expansion, so the `r2rml`
  # section macro need not exist in prod. When present, spliced raw (no
  # quote/hygiene context) so spark's section macros expand normally.
  defmacro if_r2rml(do: block) do
    if Code.ensure_loaded?(AshR2RML.Resource) do
      block
    else
      :ok
    end
  end
end
