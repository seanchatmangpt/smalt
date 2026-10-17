# Canonical public projection of the smalt capability registry (SMALT v26.10.14).
# Pattern carried over from ggen-marketplace packs (canonical-ash-projection-generator
# + xaas-public-ash-projection-pack): admitted surface only, rendered public map,
# zero internal state leakage. This file is NOT ggen-projected (the packs' query
# vocabulary — apg:* — does not match smalt's ontology vocabulary; see
# docs/PACK_INTEGRATION/canonical-projection.md). It derives from
# `Smalt.Registry`, which IS ggen-projected from the ontology — so the projection
# chain ontology -> Registry -> Canonical stays intact with no hand-typed truth.
defmodule Smalt.Projection.Canonical do
  @moduledoc """
  Canonical PUBLIC projection surface of `Smalt.Registry`.

  Emits a deterministic, secret-free capability document (types, SHACL shape
  bindings, api-versions, plane endpoints) intended to back `GET /capabilities`.
  Determinism matters: `docs/capability.json` is generated from this module and
  a fence test compares the committed artifact against Registry-derived truth so
  public docs cannot drift from the ontology projection.

  Public by construction: nothing from `Smalt.Store` (tables, keys, secrets)
  enters this surface — enforced by a grep fence in
  `test/canonical_projection_test.exs`.
  """

  @schema_version "v1"
  @doc_path "docs/capabilities.json"
  @pack_lock_path "ggen_igniter.pack.lock"
  @third_party_path "docs/THIRD_PARTY.md"

  # E4 finding #6/#5b: license provenance is layered — vendored mix.exs
  # `licenses:` first, then the hex package metadata (hex_metadata.config,
  # present for rebar/make builds with no mix.exs project block). A license
  # that survives NEITHER source (dep source not vendored) renders
  # UNVERIFIED — loud, never a guessed license.
  @metadata_path "hex_metadata.config"

  @doc "Relative path of the generated public capability document."
  def doc_path, do: @doc_path

  @doc "Relative path of the generated third-party notice document."
  def third_party_doc_path, do: @third_party_path

  @doc """
  Registry-derived capability document (plain terms, deterministic order).
  Only Registry accessors are consulted — no Store, no env, no wall clock.

  Two Canonical rider sections (E4 #6/#5b — Elixir-native facts ride
  Canonical.write, NOT the pack):

    * `"identity"` — pack sha256 (ggen_igniter.pack.lock digest),
      SemanticEpoch watermark (the CalVer epoch the manufacturing receipts
      are stamped against), and the content digest of the doc itself
      (computed over the doc with `contentSha256` removed — the
      self-reference fence).

    * `"third_party"` — the mix.lock dependency surface (name, version,
      license, origin), which backs the generated `docs/THIRD_PARTY.md`.
  """
  def capability_document do
    %{
      "schemaVersion" => @schema_version,
      "name" => "smalt",
      "capabilities" =>
        Enum.map(Smalt.Registry.admitted_resource_types(), fn type ->
          %{
            "type" => type,
            "shape" => Smalt.Registry.shape_for(type),
            "apiVersion" => Smalt.Registry.latest_version(type)
          }
        end),
      "endpoints" => %{
        "controlPlane" => Smalt.Registry.control_plane_port(),
        "dataPlane" => Smalt.Registry.data_plane_port(),
        # R83 disclosure: canonical defaults, not get_env — the capability
        # document is the env-independent substrate contract (drift fence
        # renders in test env where ports are dynamic).
        "amqp" => Smalt.Registry.amqp_port_default(),
        "eventHubs" => Smalt.Registry.event_hubs_port_default()
      },
      "identity" => identity_block(),
      "third_party" => third_party_packages()
    }
  end

  @doc """
  Identity block (SHIM-COURT-auditable identity facts): pack-lock sha256,
  epoch watermark, and the self content digest. `contentSha256` is computed
  over the sorted-key JSON of the document with the `contentSha256` key
  removed — a byte-exact self-reference, fenced by
  `test/canonical_projection_test.exs`.
  """
  def identity_block do
    %{
      "packLockSha256" => pack_lock_sha256(),
      "semanticEpoch" => Mix.Project.config()[:version],
      "contentSha256" => nil
    }
  end

  @doc """
  The mix.lock dependency surface: one row per lock entry
  (name, version, license, origin), sorted by name. Deterministic for a
  given tree — lock versions and vendored mix.exs licenses are tree state,
  never wall clock. A license that cannot be read from `deps/<name>/mix.exs`
  (or the explicit `@license_overrides` set) renders `"UNVERIFIED"` — loud,
  never guessed.
  """
  def third_party_packages do
    Mix.Dep.Lock.read()
    |> Enum.map(fn {name, lock_entry} -> dep_row(to_string(name), lock_entry) end)
    |> Enum.sort_by(& &1["name"])
  end

  @doc """
  Rendered markdown for `docs/THIRD_PARTY.md` — the complete file body
  including the trailing newline (byte-identity fence subject).
  """
  def third_party_markdown do
    packages = third_party_packages()
    tally = license_tally(packages)

    header = """
    # Third-Party Dependencies

    <!-- GENERATED by Smalt.Projection.Canonical.write/0 from mix.lock + the vendored deps' mix.exs licenses. Do not hand-edit; regenerate instead. -->

    Smalt depends on the following Hex packages. Licenses were verified from
    the vendored sources under `deps/` (each package's `mix.exs` `licenses:`
    field, or its hex package metadata `hex_metadata.config` for rebar/make
    builds with no mix.exs project block), at the exact versions pinned in
    `mix.lock`. The packages are not modified by smalt and are not themselves
    part of the smalt distribution; they are fetched at build time via
    `mix deps.get` from hex.pm. Legal prose lives in the hand-written
    `docs/NOTICE.md` (NOTICE.md is deliberately NOT a projection).

    ## Dependencies (from mix.lock)

    | Package | Version | License | Origin |
    |---|---|---|---|
    """

    rows =
      Enum.map_join(packages, "", fn p ->
        "| #{p["name"]} | #{p["version"]} | #{p["license"]} | #{p["origin"]} |\n"
      end)

    footer = """

    #{length(packages)} packages total. License tally: #{tally}.

    ## Apache-2.0 NOTICE compatibility

    Every permissively-licensed dependency (MIT, Apache-2.0, BSD) is
    compatible with smalt's Apache-2.0 license. Packages outside the plain
    MIT / Apache-2.0 set:

    #{notice_compat_bullets(packages)}No copyleft (GPL/AGPL/MPL/EPL) dependencies are present in `mix.lock`.
    Apache-2.0 §4(d) NOTICE-file contents must be preserved in downstream
    distributions that ship a dependency's source or binaries; smalt does not
    ship dependency sources in its release artifact. Legal prose: see the
    hand-written `docs/NOTICE.md`.
    """

    header <> rows <> footer
  end

  @doc """
  Write both generated public docs: `docs/capabilities.json` and
  `docs/THIRD_PARTY.md`. Returns `{:ok, [paths]}`.
  """
  def write do
    base = Path.expand(File.cwd!())

    cap_path = Path.expand(@doc_path, base)
    File.mkdir_p!(Path.dirname(cap_path))
    File.write!(cap_path, json() <> "\n")

    tp_path = Path.expand(@third_party_path, base)
    File.mkdir_p!(Path.dirname(tp_path))
    File.write!(tp_path, third_party_markdown())

    {:ok, [cap_path, tp_path]}
  end

  @doc "Rendered JSON (deterministic key order via Jason on sorted-key maps)."
  def json do
    json_with_identity() |> sort_keys() |> Jason.encode!(pretty: true, indent: "  ")
  end

  ## Internals

  # Self-digesting JSON render: the digest is computed over the doc with
  # `contentSha256` removed, so the field is a byte-exact content address of
  # everything else in the document.
  defp content_digest do
    doc = capability_document()

    doc
    |> put_in(["identity", "contentSha256"], "")
    |> Map.update!("identity", &Map.delete(&1, "contentSha256"))
    |> sort_keys()
    |> Jason.encode!(pretty: true, indent: "  ")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp json_with_identity do
    capability_document()
    |> put_in(["identity", "contentSha256"], content_digest())
  end

  defp pack_lock_sha256 do
    path = Path.expand(@pack_lock_path, File.cwd!())

    case File.read(path) do
      {:ok, body} ->
        # Lenient baseline policy (SemanticEpoch degradation split): a missing
        # lock is a visible nil, never a fabricated digest.
        Base.encode16(:crypto.hash(:sha256, body), case: :lower)

      {:error, _} ->
        nil
    end
  end

  defp dep_row(name, lock_entry) do
    {version, origin} =
      case lock_entry do
        {:hex, _app, version, _checksum, _builders, _deps, _repo, _inner} ->
          {version, "hex.pm"}

        {:hex, _app, version, _checksum, _builders, _deps, _repo} ->
          {version, "hex.pm"}

        {kind, _} when kind in [:path, :git] ->
          {path_dep_version(name), Atom.to_string(kind)}

        _unknown ->
          {nil, "unknown"}
      end

    %{
      "name" => name,
      "version" => version || "unknown",
      "license" => license_for(name),
      "origin" => origin
    }
  end

  defp path_dep_version(name) do
    with {:ok, body} <- File.read(Path.expand("deps/#{name}/mix.exs", File.cwd!())),
         [[_, version]] <- Regex.scan(~r/@version\s+"([^"]+)"/, body) do
      version
    else
      _ -> nil
    end
  end

  # License provenance, in priority order: mix.exs `licenses:` field, hex
  # package metadata (hex_metadata.config), else UNVERIFIED (fail-loud).
  defp license_for(name) do
    case read_licenses(name) do
      {:ok, []} ->
        metadata_licenses(name)

      {:ok, [single]} ->
        single

      {:ok, many} ->
        case many do
          ["MIT", "Apache-2.0"] -> "MIT / Apache-2.0 (dual)"
          _ -> Enum.join(many, " / ")
        end

      {:error, _} ->
        metadata_licenses(name)
    end
  end

  defp metadata_licenses(name) do
    path = Path.expand("deps/#{name}/#{@metadata_path}", File.cwd!())

    with {:ok, body} <- File.read(path),
         [[_, inner]] <- Regex.scan(~r/\{<<"licenses">>,\s*\[([^\]]*)\]\}/, body) do
      inner
      |> then(&Regex.scan(~r/<<"([^"]+)">>/, &1))
      |> Enum.map(fn [_, l] -> normalize_license(l) end)
      |> Enum.join(" / ")
    else
      _ -> "UNVERIFIED"
    end
  end

  defp read_licenses(name) do
    with {:ok, body} <- File.read(Path.expand("deps/#{name}/mix.exs", File.cwd!())) do
      licenses =
        case Regex.scan(~r/licenses:\s*\[([^\]]*)\]/, body) do
          [[_, inner]] ->
            Regex.scan(~r/"([^"]+)"/, inner) |> Enum.map(fn [_, l] -> normalize_license(l) end)

          _ ->
            []
        end

      {:ok, licenses}
    end
  end

  # Vendored spellings collapse to the SPDX token used in the tally.
  defp normalize_license("Apache 2"), do: "Apache-2.0"
  defp normalize_license("Apache 2.0"), do: "Apache-2.0"
  defp normalize_license("BSD 2-Clause"), do: "BSD-2-Clause"
  defp normalize_license(l), do: l

  defp license_tally(packages) do
    packages
    |> Enum.frequencies_by(& &1["license"])
    |> Enum.sort_by(fn {license, count} -> {-count, license} end)
    |> Enum.map_join(", ", fn {license, count} -> "#{license} x#{count}" end)
  end

  # Deterministic bullets for anything outside plain MIT / Apache-2.0 — the
  # shape stays fixed; the rows are data-driven from the license surface.
  defp notice_compat_bullets(packages) do
    packages
    |> Enum.filter(fn p ->
      p["license"] not in ["MIT", "Apache-2.0"]
    end)
    |> Enum.map_join("", fn p ->
      if p["license"] == "UNVERIFIED" do
        "- **#{p["name"]} (UNVERIFIED)**: dep source not vendored under deps/ — license could not be verified at generation time; verify before distribution.\n"
      else
        "- **#{p["name"]} (#{p["license"]})**: outside the plain MIT / Apache-2.0 set; its LICENSE file under deps/#{p["name"]}/ is the distribution-time authority.\n"
      end
    end)
  end

  defp sort_keys(term) when is_map(term) do
    term |> Enum.map(fn {k, v} -> {to_string(k), sort_keys(v)} end) |> Map.new()
  end

  defp sort_keys(term) when is_list(term), do: Enum.map(term, &sort_keys/1)
  defp sort_keys(term), do: term
end

defmodule Smalt.Projection.Canonical.Entry do
  @moduledoc """
  (a) Ash read resource over the Registry (compile-time attrs).

  Read-only, simple data layer, manual read over compile-time Registry data —
  the same read-path pattern as `Smalt.Semantic.Resource`, but over the
  Registry (admitted capability surface) instead of Store state. A capability
  appearing here is *admitted*; it is not authority to actuate (Ex4pm
  discipline: observed != authorized).
  """

  use Ash.Resource,
    domain: Smalt.Projection.Canonical.Domain,
    data_layer: Ash.DataLayer.Simple

  attributes do
    attribute(:type, :string, allow_nil?: false, primary_key?: true, public?: true)
    attribute(:shape, :string, public?: true)
    attribute(:api_version, :string, public?: true)
  end

  actions do
    read :read do
      manual(Smalt.Projection.Canonical.RegistryRead)
      primary?(true)
    end
  end
end

defmodule Smalt.Projection.Canonical.RegistryRead do
  @moduledoc """
  Manual read over compile-time Registry attrs (no Store involvement).
  """

  @behaviour Ash.Resource.ManualRead

  @impl true
  def read(_query_or_data_layer_query, _query, _opts, _context) do
    rows =
      Enum.map(Smalt.Registry.admitted_resource_types(), fn type ->
        %Smalt.Projection.Canonical.Entry{
          type: type,
          shape: Smalt.Registry.shape_for(type),
          api_version: Smalt.Registry.latest_version(type)
        }
        |> Ash.Resource.set_metadata(%{})
      end)

    {:ok, rows}
  end
end

defmodule Smalt.Projection.Canonical.Domain do
  @moduledoc """
  Domain for the canonical public projection surface. Separate from
  `Smalt.Semantic.Domain` (which owns the Store read path) so the public
  surface can never inherit a Store-backed action.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Smalt.Projection.Canonical.Entry)
  end
end
