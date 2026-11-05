defmodule Smalt.Aoq.Arrow.Boot do
  @moduledoc """
  Boot-write path for the `{:aoq, :arrow_schemas}` registry (spec §5,
  `docs/jira/v26.11.5/aq-architecture-spec.md`, LANE-52).

  Loads the schema bundle through `Smalt.Aoq.Arrow.Loader.load/1`
  (decode → four-tier court → BLAKE3 digest re-derivation) and returns
  the verified registry map for `Smalt.Aoq.Tables.boot/1`'s
  `:arrow_schemas` opt — the ONLY lawful write path for the registry
  (`Smalt.Aoq.Tables` seals its tables at boot; post-boot writes refuse).

  Fail-open-to-fallback, loud about the refusal: a corrupt, missing, or
  court-refused bundle never blocks the plane. `registry/1` logs the
  typed refusal at `:error` level and returns the compile-time fallback
  registry (`Smalt.Aoq.Tables.fallback_arrow_schemas/0`) so the AoQ
  supervisor subtree still boots byte-identically with the pre-bundle
  behaviour. A verified (or shipped-empty) bundle yields the bundle's
  own schemas.

  The supervisor's init therefore is one line:

      Tables.boot(arrow_schemas: Smalt.Aoq.Arrow.Boot.registry())
  """

  require Logger

  alias Smalt.Aoq.Arrow.Bundle
  alias Smalt.Aoq.Arrow.Loader
  alias Smalt.Aoq.Tables

  @doc """
  Load-verify the Arrow schema bundle and return the registry map for
  `Smalt.Aoq.Tables.boot/1`.

  - `path` (default: `Smalt.Aoq.Arrow.Bundle.default_path/0`) — the
    bundle file to load.
  - `fallback` (default: the compile-time registry) — returned instead
    of raising when the bundle refuses; test seam only.

  Never raises and never returns an error — a refusal is a loud log
  (`:error` level, full typed reason) plus the fallback map.
  """
  @spec registry(Path.t(), %{term() => term()}) :: %{term() => term()}
  def registry(path \\ Bundle.default_path(), fallback \\ Tables.fallback_arrow_schemas()) do
    case Loader.load(path) do
      {:ok, schemas} ->
        schemas

      {:error, reason} ->
        Logger.error(
          "AOQ Arrow bundle REFUSED at boot (path=#{path}): " <>
            "#{inspect(reason)} — falling back to the compile-time registry; " <>
            "the plane boots with the fallback schemas"
        )

        fallback
    end
  end
end
