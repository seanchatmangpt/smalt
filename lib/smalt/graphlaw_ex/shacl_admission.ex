defmodule Smalt.GraphlawEx.ShaclAdmission do
  @moduledoc false

  # WO-09 (v26.10.31): SHACL admission through the canonical ontology
  # (priv/ontologies/public-cloud-core.ttl) on the REAL pinned GraphLaw wasm
  # engine via AshGraphLaw.Capability.Shacl. The engine is a deriver, never an
  # authorizer (AshGraphLaw.Host boundary): a conforming shacl response is not
  # authority — this module mints a receipt over (shapes, data, digest) and
  # Smalt.GraphlawEx.AdmissionGate stays the host-side commit validator.
  #
  # Dependency posture (loud typed refusals, no silent skips): :ash_graphlaw is
  # dev/test-only in mix.exs (hex-publish promotion is the WO-10 residual).
  # When the dep is absent, admit/2 answers
  # {:refused, :smalt_graphlaw_engine_absent, _} — fail-closed, never a fake
  # admit. Same for an unpinned digest (:smalt_graphlaw_engine_unpinned), an
  # unreadable ontology (:smalt_shapes_unreadable) and a non-conforming
  # instance (:smalt_shacl_violation).
  #
  # Seam note for lib/smalt/arm_gateway/engine/policy.ex (post-strip, NOT
  # edited in this lane): policy.ex check_shape/3 currently hand-rolls the ARM
  # fence (check_admitted/2 + validator-crash rescue, lines ~107-149). Post-strip
  # it becomes:
  #
  #     def check_shape(conn, full_type, payload) do
  #       with {:ok, ttl} <- ShaclAdmission.instance_data(full_type, payload),
  #            {:ok, envelope} <- ShaclAdmission.admit_envelope(ttl),
  #            :ok <-
  #              AdmissionGate.gate("PUT", envelope,
  #                engine_digest_key: :gl_engine_digest,
  #                body: envelope.payload_bytes
  #              ) do
  #         :ok
  #       else
  #         {:refused, code, details} -> send_graphlaw_refusal(conn, {code, details})
  #       end
  #     end
  #
  # with the ARM-coupled fence semantics moving into SHACL shapes owned by lane 8
  # in public-cloud-core.ttl.

  @digest_key :gl_engine_digest
  @shapes_relpath "ontologies/public-cloud-core.ttl"
  @manifest_relpath "graphlaw/MANIFEST.json"

  @typedoc "Result of admit/2."
  @type admission :: {:ok, map()} | {:refused, atom(), map()}

  @doc """
  The canonical ontology shapes graph (Turtle text). Fails closed: a missing
  ontology file is {:error, {:shapes_unreadable, path}}.
  """
  @spec shapes_graph() :: {:ok, String.t()} | {:error, {:shapes_unreadable, String.t()}}
  def shapes_graph do
    path = shapes_path()

    case File.read(path) do
      {:ok, text} -> {:ok, text}
      _ -> {:error, {:shapes_unreadable, path}}
    end
  end

  @doc """
  The artifact.sha256 from the pinned engine MANIFEST.json, or nil when the
  manifest is unreadable. Same nil-means-refuse rule as
  AshGraphLaw.WasmConfig.expected_sha256/1.
  """
  @spec expected_engine_digest() :: String.t() | nil
  def expected_engine_digest do
    case read_manifest() do
      %{"artifact" => %{"sha256" => sha}} when is_binary(sha) -> sha
      _ -> nil
    end
  end

  @doc """
  Pins :gl_engine_digest (persistent_term) from MANIFEST.json artifact.sha256.
  Idempotent; answers the pinned digest. A nil manifest leaves the term unset
  so every downstream gate refuses :smalt_engine_drift — never a silent
  unpinned admit.
  """
  @spec pin() :: String.t() | nil
  def pin do
    case expected_engine_digest() do
      nil -> nil
      digest -> put_pin(digest)
    end
  end

  @doc "The current pinned digest (:gl_engine_digest), nil when unpinned."
  @spec pinned_digest() :: String.t() | nil
  def pinned_digest do
    :persistent_term.get(@digest_key, nil)
  rescue
    _ -> nil
  end

  defp put_pin(digest) do
    :persistent_term.put(@digest_key, digest)
    digest
  end

  @doc """
  Runs SHACL admission of one instance Turtle document against the canonical
  shapes on the REAL engine.

  Opts:

    - :engine_opts — call opts for AshGraphLaw.Capability.Shacl.run/2
      ([server: pid] of a started AshGraphLaw.Host). Required when no host is
      started under the default AshGraphLaw.Host name.
    - :engine_digest — overrides the pinned digest (test seam; production
      callers omit it so the MANIFEST pin is used).
    - :shape_iri — informative receipt field naming the governing shape.
    - :shapes — Turtle text overriding the canonical ontology (court seam;
      production callers omit it). WO-09 note: the in-flight
      public-cloud-core.ttl currently carries a bnode with two sh:pattern
      values (lane 8's lease, ~lines 217-218), which the engine refuses at
      shapes-graph meta-validation, so until lane 8's fix lands the canonical
      file is engine-rejected wholesale and courts exercise the canonical
      shape #2 via this override. Fail-closed: the override is explicit opt,
      never a default.

  Refusals: :smalt_shapes_unreadable, :smalt_graphlaw_engine_absent,
  :smalt_graphlaw_engine_unpinned, :smalt_shacl_violation,
  :smalt_graphlaw_engine_error.
  """
  @spec admit(String.t(), keyword()) :: admission()
  def admit(data, opts \\ []) when is_binary(data) do
    with {:ok, shapes} <- shapes_or_override(opts),
         {:ok, shacl} <- shacl_module(),
         {:ok, digest} <- ensure_digest(opts) do
      run_shacl(shacl, shapes, data, opts, digest)
    else
      {:error, {:shapes_unreadable, path}} ->
        {:refused, :smalt_shapes_unreadable, %{path: path}}

      {:error, {:shapes_override_not_binary, _}} = err ->
        {:refused, :smalt_shapes_unreadable, %{override: inspect(err)}}

      {:error, :ash_graphlaw_not_loaded} ->
        {:refused, :smalt_graphlaw_engine_absent, %{dep: :ash_graphlaw}}

      {:refused, _, _} = refused ->
        refused
    end
  end

  @doc """
  Runs admit/2 and, on success, returns the 5-key admission envelope for
  Smalt.GraphlawEx.AdmissionGate.gate/3 (receipt + digest + payload bytes, so
  the gate's byte-exact payload check has a body to match). Refusals pass
  through unchanged.
  """
  @spec admit_envelope(String.t(), keyword()) ::
          {:ok, map()} | {:refused, atom(), map()}
  def admit_envelope(data, opts \\ []) do
    with {:ok, receipt} <- admit(data, opts) do
      {:ok,
       %{
         admitted_mutation: true,
         payload_bytes: data,
         receipt_blake3: receipt.receipt_sha256,
         engine_digest: receipt.engine_digest,
         ocel_frame: %{shape: receipt.shape_iri, data_bytes: receipt.data_bytes}
       }}
    end
  end

  ## ── internal ─────────────────────────────────────────────────────────────

  defp run_shacl(shacl, shapes, data, opts, digest) do
    # admit/2 opts double as the AshGraphLaw call opts: [server: pid] passed
    # by the caller flows straight to Capability.Shacl.run/2; :engine_opts
    # (when present) replaces them wholesale; admit-specific keys
    # (:engine_digest, :shape_iri) are stripped so they never reach the wire.
    engine_opts =
      opts[:engine_opts] || Keyword.drop(opts, [:engine_digest, :shape_iri])

    case apply(shacl, :run, [[shapes: shapes, data: %{text: data}], engine_opts]) do
      {:ok, result} ->
        if Map.get(result, :conforms) do
          {:ok, mint_receipt(data, digest, opts)}
        else
          {:refused, :smalt_shacl_violation, %{results: Map.get(result, :results, [])}}
        end

      {:error, refusal} ->
        {:refused, :smalt_graphlaw_engine_error, engine_refusal_details(refusal)}
    end
  end

  defp mint_receipt(data, digest, opts) do
    shape_iri = opts[:shape_iri] || "tosca:ObjectStorageShape"
    payload = "#{digest}|#{shape_iri}|#{data}"

    <<receipt::binary-size(64)>> =
      :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)

    %{
      admitted: true,
      engine_digest: digest,
      shape_iri: shape_iri,
      data_bytes: byte_size(data),
      receipt_sha256: receipt
    }
  end

  defp engine_refusal_details(%{code: code} = refusal) when is_atom(code) do
    %{code: code, message: Map.get(refusal, :message)}
  end

  defp engine_refusal_details(refusal), do: %{code: :unknown, raw: inspect(refusal)}

  defp shapes_or_override(opts) do
    case opts[:shapes] do
      nil -> shapes_graph()
      ttl when is_binary(ttl) -> {:ok, ttl}
      other -> {:error, {:shapes_override_not_binary, other}}
    end
  end

  defp shapes_path do
    case Application.get_env(:smalt, :graphlaw_shacl, []) do
      [] -> Path.join(:code.priv_dir(:smalt), @shapes_relpath)
      kw when is_list(kw) -> Path.join(:code.priv_dir(:smalt), kw[:shapes_path] || @shapes_relpath)
      _ -> Path.join(:code.priv_dir(:smalt), @shapes_relpath)
    end
  end

  defp read_manifest do
    configured = Application.get_env(:smalt, :graphlaw_shacl, [])

    path =
      case configured do
        kw when is_list(kw) ->
          # LANE14 disclosed unblock (compile-freeze SLA): the in-flight guard
          # is_binary(kw[:manifest_path]) is unlawful (Access.get/2 in guard).
          # Semantics preserved: binary manifest_path wins, all else falls back.
          case kw[:manifest_path] do
            p when is_binary(p) -> p
            _ -> manifest_path_from_priv_dir()
          end

        _ -> manifest_path_from_priv_dir()
      end

    with path when is_binary(path) <- path,
         {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body) do
      json
    else
      _ -> nil
    end
  end

  defp manifest_path_from_priv_dir do
    case :code.priv_dir(:ash_graphlaw) do
      {:error, _} -> nil
      dir when is_list(dir) -> Path.join(List.to_string(dir), @manifest_relpath)
      dir when is_binary(dir) -> Path.join(dir, @manifest_relpath)
    end
  end

  defp shacl_module do
    mod = Module.concat([AshGraphLaw, Capability, Shacl])

    if Code.ensure_loaded?(mod) do
      {:ok, mod}
    else
      {:error, :ash_graphlaw_not_loaded}
    end
  end

  defp ensure_digest(opts) do
    case opts[:engine_digest] || pinned_digest() do
      nil -> {:refused, :smalt_graphlaw_engine_unpinned, %{}}
      digest -> {:ok, digest}
    end
  end
end
