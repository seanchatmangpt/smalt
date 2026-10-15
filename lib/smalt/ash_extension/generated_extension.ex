defmodule Smalt.AshExtension.SubstrateResource do
  @moduledoc """
  Spark.Dsl.Extension for `smalt`.

  Manufactured by ash-extension-pack from an admitted `aex:AshExtensionSpec` --
  do not hand-edit; regenerate from the spec instead.
  """

  @substrate %Spark.Dsl.Section{
    name: :substrate,
    describe: "Store table + matter-scope for the substrate read idiom.",
    schema: [
      store_table: [type: :atom, doc: "Store table the manual read path scans."],
      matter_scope: [type: {:list, :atom}, doc: "Matter-scope tags enforced on the read surface."]
    ],
    entities: [],
    singleton_entity_keys: [:substrate]
  }

  use Spark.Dsl.Extension,
    sections: [@substrate],
    transformers: [Smalt.AshExtension.SubstrateResource.Persist],
    verifiers: [Smalt.AshExtension.SubstrateResource.Verify]
end
