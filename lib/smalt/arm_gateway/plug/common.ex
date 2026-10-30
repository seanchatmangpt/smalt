defmodule Smalt.ArmGateway.Plug.Common do
  @moduledoc """
  Shared wire/gate helpers for the ArmGateway front plug and route-family
  plugs (T06, v26.10.29). Extracted verbatim from the monolithic router;
  public here so family plugs import them unqualified (byte-identical
  behavior: same bodies, same typed envelopes).
  """
  import Plug.Conn
  require Logger

  alias Smalt.ArmGateway.ProviderState
  alias Smalt.ArmGateway.TagsLocks
  alias Smalt.Registry
  alias Smalt.DataPlane.Cosmos
  alias Smalt.DataPlane.VaultData

  # -- module attributes (verbatim from the monolith) --
  @page_size 100
  @affidavit_witness_table :smalt_affidavit_witnesses
  @affidavit_high_tariff_cents 5_000_000_000


  # Request-derived authority: scheme://host[:port] as the CLIENT reached us
  # (lane 90 TS court: advertising login.smalt.local — an NXDOMAIN — made
  # msal-node/azidentity follow the envelope and never reach the substrate
  # STS: endpoints_resolution_error). Single derivation shared with the auth
  # plug: forwarded headers honored ONLY from trusted proxies (fail-closed).
  def request_authority(conn), do: Smalt.Auth.Bearer.request_authority(conn)

  # "https://arm.internal:19081" -> "arm.internal" (scheme + port stripped):
  # the instance-discovery alias for THIS substrate's authority.

  def send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  # ARM list envelope with nextLink pagination (row 9): page size 100,
  # `maxitempages` (default 1) caps pages per response; when items remain the
  # response carries an absolute nextLink continuing at $skip.

  # ARM list envelope with nextLink pagination (row 9): page size 100,
  # `maxitempages` (default 1) caps pages per response; when items remain the
  # response carries an absolute nextLink continuing at $skip.
  def send_list(conn, items) do
    # Deny-by-default list fence (lens-11, measured): a record that is not a
    # map, or a map carrying any value Jason cannot encode, previously raised
    # Jason.EncodeError / Protocol.UndefinedError inside send_json — 500-ing
    # the WHOLE list forever (the poisoning record persists). Like the LRO
    # get_op/2 ownership fence (lens-9 cycle-5), a record that does not prove
    # it is a well-formed ARM resource is never surfaced.
    items = Enum.filter(items, &renderable_record?/1)

    skip = int_query_param(conn, "$skip", 0)
    pages = max(int_query_param(conn, "maxitempages", 1), 1)
    slice = Enum.slice(items, skip, pages * @page_size)
    next_skip = skip + length(slice)
    truncated? = next_skip < length(items)

    body =
      if truncated? do
        %{"value" => slice, "nextLink" => next_link(conn, next_skip)}
      else
        %{"value" => slice}
      end

    send_json(conn, 200, Jason.encode!(body))
  end

  # A record renders as an ARM resource iff it is a map every member of which
  # Jason can encode. Anything else (a raw integer/atom/tuple under a store
  # key, or a map with a tuple/pid/function value) is not provably a resource
  # and is denied by default: filtered from lists, 404 on single GET.

  # A record renders as an ARM resource iff it is a map every member of which
  # Jason can encode. Anything else (a raw integer/atom/tuple under a store
  # key, or a map with a tuple/pid/function value) is not provably a resource
  # and is denied by default: filtered from lists, 404 on single GET.
  def renderable_record?(%{} = record) do
    match?({:ok, _}, Jason.encode(record))
  end

  def renderable_record?(_), do: false

  # SHIM-COURT tags-null-when-empty (2026-10-16, lane 419 wire evidence):
  # azurerm normalizes an EMPTY tags map to null in state (real Azure omits
  # tags on untagged resources), so echoing `"tags": {}` makes every
  # refresh-only plan drift `+ tags = {}` forever. Parity law: nil/missing
  # -> null on the wire; an existing non-empty map round-trips unchanged.
  # WITNESS: /tmp/tf-rg419 single-fixture apply+refresh (lane 419).

  # SHIM-COURT tags-null-when-empty (2026-10-16, lane 419 wire evidence):
  # azurerm normalizes an EMPTY tags map to null in state (real Azure omits
  # tags on untagged resources), so echoing `"tags": {}` makes every
  # refresh-only plan drift `+ tags = {}` forever. Parity law: nil/missing
  # -> null on the wire; an existing non-empty map round-trips unchanged.
  # WITNESS: /tmp/tf-rg419 single-fixture apply+refresh (lane 419).
  def normalize_tags(nil), do: nil

  def normalize_tags(%{} = tags) do
    if map_size(tags) == 0, do: nil, else: tags
  end

  def normalize_tags(_), do: nil

  # SHIM-COURT tags (2026-10-16, lane 429 reconciliation, FR-5 re-witness
  # /tmp/tf-plan-probe.hPaBPZ): ONE law for create AND update — an RG PUT is
  # a FULL REPLACE, so omitted/null/empty tags REMOVE the stored tags and the
  # GET renders `"tags": null` (azurerm normalizes empty tags to null in
  # state; echoing `{}` drifts every refresh-only plan `+ tags = {}`).
  # Only an explicit non-empty tags map renders as a map.

  def int_query_param(conn, name, default) do
    case conn.query_params[name] do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 -> n
          _ -> default
        end
    end
  end


  def next_link(conn, skip) do
    pages = max(int_query_param(conn, "maxitempages", 1), 1)

    query =
      conn.query_params
      |> Map.take(["api-version"])
      |> Map.put("maxitempages", Integer.to_string(pages))
      |> Map.put("$skip", skip)
      |> URI.encode_query()

    "#{request_authority(conn)}#{conn.request_path}?#{query}"
  end

  # C1 row 1b: error.target names the offending path when a specific path
  # caused the failure (404 classes); absent on api-version 400s (query-param
  # failures have no path component — corpus pins target ABSENT there).

  # C1 row 1b: error.target names the offending path when a specific path
  # caused the failure (404 classes); absent on api-version 400s (query-param
  # failures have no path component — corpus pins target ABSENT there).
  def send_arm_error(conn, status, code, message, target \\ nil, details \\ []) do
    error =
      if target do
        %{
          "code" => code,
          "message" => message,
          "target" => target,
          # Real AAD/ARM shape: innererror present-but-empty when there is
          # nothing further to nest.
          "innererror" => %{}
        }
      else
        %{
          "code" => code,
          "message" => message,
          # Real AAD/ARM shape: innererror present-but-empty when there is
          # nothing further to nest.
          "innererror" => %{}
        }
      end

    error = if details == [], do: error, else: Map.put(error, "details", details)

    body = Jason.encode!(%{"error" => error})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  # KD-COVERS: KD-28 — the NSG shape tightening lives in
  # priv/shacl/smalt-shapes.ttl (NsgShape: closed true + location required),
  # compiled into this router via GraphLaw.Validator's compile-time ttl parse;
  # this refusal site is where the wire 400 surfaces.
  # GraphLaw refusal -> HTTP 400 (PINNED decision; ARM never returns 422).
  # Envelope code InvalidResourceShape, target AshGraphLaw.Enforcement.
  # Optional `details` carries per-issue SHACL detail rows (ARM error.details
  # shape); byte-identical envelope when details == [] (existing corpus rows).

  def send_rg_not_found(conn, rg_id, rg_name) do
    send_arm_error(
      conn,
      404,
      "ResourceGroupNotFound",
      "Resource group '#{rg_name}' could not be found.",
      rg_id
    )
  end

  # -- KD-113 tags leg: tags-at-scope handlers ---------------------------------

  # api-version presence check mirrors the providers listing gate (the
  # Microsoft.Resources/tags surface is not a Registry individual, so use the
  # presence-only nil form).

  # ScopeLocked (KD-113 leg b): the ROUTER owns the 409 mapping — same
  # inline-envelope law as Smalt.Policy.scope_locked_body (kept in sync).
  def lock_scope_locked_body(rg_id) do
    Jason.encode!(%{
      "error" => %{
        "code" => "ScopeLocked",
        "message" =>
          "The scope '#{rg_id}' is locked at a level that blocks this operation. " <>
            "Remove the lock (Microsoft.Authorization/locks) to proceed.",
        "target" => rg_id,
        "innererror" => %{}
      }
    })
  end

  # -- AZURE-FIDELITY lane 4 handlers -------------------------------------------

  # Write verb of the lock law: a covering ReadOnly lock answers 409
  # ScopeLocked; :ok proceeds. In-with usable (with-else renders the
  # response via the shared {:respond, conn} arm).

  def tags_scope_envelope(scope_id, tags) do
    %{
      "id" => scope_id,
      "name" => "default",
      "type" => "Microsoft.Resources/tags",
      "properties" => %{"tags" => TagsLocks.normalize_tags(tags)}
    }
  end

  # Tags at RESOURCE scope: envelope over the resource record's "tags"
  # member. A covering ReadOnly lock refuses PUT/PATCH (409 ScopeLocked,
  # pre-mutation); unknown resource -> 404 ResourceNotFound.

  # -- api-version seam (registry-driven); :ok | {:respond, conn} --------------

  def check_api_version(conn, type) do
    case conn.query_params["api-version"] do
      nil ->
        {:respond,
         send_arm_error(
           conn,
           400,
           "MissingApiVersionParameter",
           "The api-version query parameter is required."
         )}

      version ->
        check_version(conn, type, version)
    end
  end

  # AZB-05 control-plane profile: strict_version_validation widens the
  # api-version gate to UNADMITTED types. Default mode keeps today's
  # permissive pass-through (KD-78 invariant on the default boot — the
  # `:all` plane imports no profile, so the default gate is untouched).
  # Strict refusal reuses the refusal-tier vocabulary from
  # docs/jira/v26.10.18/rewrite-drafts/apiversion-refusal.md:
  # 400 InvalidApiVersionParameter, message names NoRegisteredProviderFound.

  # AZB-05 control-plane profile: strict_version_validation widens the
  # api-version gate to UNADMITTED types. Default mode keeps today's
  # permissive pass-through (KD-78 invariant on the default boot — the
  # `:all` plane imports no profile, so the default gate is untouched).
  # Strict refusal reuses the refusal-tier vocabulary from
  # docs/jira/v26.10.18/rewrite-drafts/apiversion-refusal.md:
  # 400 InvalidApiVersionParameter, message names NoRegisteredProviderFound.
  def strict_version_validation? do
    Smalt.Config.arm_gateway()[:strict_version_validation] == true
  end

  # AZB-05: fail_closed graphlaw enforcement — an unavailable engine is a
  # typed refusal (see do_check_shape), never an admission.

  # KD-78: api-version admission is MONOTONIC (real ARM semantics): any version
  # <= latest for the admitted type is accepted; only versions > latest or
  # malformed versions are refused (typed InvalidApiVersionParameter, naming
  # latest). SHIM-COURT surface: this gate is the anti-vacuity subject.
  def check_version(_conn, nil, _version), do: :ok

  def check_version(conn, raw_type, version) do
    case find_admitted(raw_type) do
      nil ->
        if strict_version_validation?() do
          {:respond,
           send_arm_error(
             conn,
             400,
             "InvalidApiVersionParameter",
             "NoRegisteredProviderFound: no registered provider '#{raw_type}' can serve api-version '#{version}'."
           )}
        else
          :ok
        end

      full_type ->
        latest = Registry.latest_version(full_type)

        case version_lte?(version, to_string(latest)) do
          true ->
            :ok

          false ->
            {:respond,
             send_arm_error(
               conn,
               400,
               "InvalidApiVersionParameter",
               "The api-version '#{version}' is invalid. The latest supported api-version for '#{full_type}' is '#{latest}'."
             )}
        end
    end
  end

  # Monotonic date comparison over `YYYY-MM-DD` (optionally suffixed, e.g.
  # `-preview`). Malformed versions are never admitted. KD-78.

  # Monotonic date comparison over `YYYY-MM-DD` (optionally suffixed, e.g.
  # `-preview`). Malformed versions are never admitted. KD-78.
  def version_lte?(version, latest) when is_binary(version) and is_binary(latest) do
    with {:ok, v_date} <- version |> version_base() |> Date.from_iso8601(),
         {:ok, l_date} <- latest |> version_base() |> Date.from_iso8601() do
      Date.compare(v_date, l_date) in [:lt, :eq]
    else
      _ -> false
    end
  end

  def version_lte?(_version, _latest), do: false

  # NOTE: splits on "-preview" only — a hypothetical "2024-01-01-preview2"
  # would leave "preview2" and fail Date.from_iso8601 (version then never
  # admitted). The corpus has no such version; malformed stays refused.
  def version_base(version) when is_binary(version) do
    case String.split(version, "-preview") do
      [base] -> normalize_base(base)
      [base | _] -> normalize_base(base)
      _ -> version
    end
  end

  def version_base(other), do: other

  # Day-less version bases ("2023-06") are normalized to day-prefixed ISO
  # ("2023-06-01") so Date.from_iso8601 admits them (e.g. api-version
  # "2023-06-preview" for Microsoft.ContainerRegistry/registries). Anything
  # not matching YYYY-MM passes through unchanged and stays refused.
  defp normalize_base(base) do
    case String.split(base, "-") do
      [y, m] when byte_size(y) == 4 and byte_size(m) == 2 ->
        if String.match?(y, ~r/^\d{4}$/) and String.match?(m, ~r/^\d{2}$/),
          do: base <> "-01",
          else: base

      _ ->
        base
    end
  end


  def find_admitted(raw_type) do
    down = String.downcase(raw_type)
    Enum.find(Registry.admitted_resource_types(), fn t -> String.downcase(t) == down end)
  end


  # Sealed-witness sideband reader (test + receipt surface).
  @doc false
  def affidavit_witness(subject) when is_binary(subject) do
    ensure_witness_table()

    case :ets.lookup(@affidavit_witness_table, subject) do
      [{^subject, witness}] -> witness
      [] -> :error
    end
  end


  def ensure_witness_table do
    if :ets.info(@affidavit_witness_table) == :undefined do
      try do
        :ets.new(@affidavit_witness_table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    @affidavit_witness_table
  end


  def affidavit_seal(record, %{subject: subject, lease_context: lease_context})
       when is_map(record) do
    state_delta = Jason.encode!(record)
    tariff = affidavit_tariff(record, state_delta)
    modality = if is_integer(tariff) and tariff < @affidavit_high_tariff_cents, do: 1, else: 2

    witness =
      case affidavit_engine_seal(state_delta, tariff, modality, lease_context) do
        {:ok, witness} -> normalize_witness(witness, tariff, modality)
        {:error, reason} -> witness_absent(reason)
      end

    ensure_witness_table()
    :ets.insert(@affidavit_witness_table, {subject, Map.put(witness, "subject", subject)})

    unless witness["sealed"] do
      Logger.warning(
        "SHIM-COURT affidavit-seal: :PQC_NOT_PROVISIONED witness-absent for #{subject} (#{witness["reason"]})"
      )
    end

    affidavit_ocel_emit(state_delta, witness)
    witness
  end

  # SHIM-COURT lane622: registry-gated OCEL sideband — one `affidavit.seal`
  # event per completed seal through Smalt.Telemetry.AffidavitOcel.seal/1
  # (matter-isolation: SHA-256 of the canonical state_delta + verdict +
  # engine receipt identity only; no receipt payloads). Fail-safe: any
  # emission failure is logged and dropped, NEVER raised into the sealer —
  # admission outcome is untouched.

  # SHIM-COURT lane622: registry-gated OCEL sideband — one `affidavit.seal`
  # event per completed seal through Smalt.Telemetry.AffidavitOcel.seal/1
  # (matter-isolation: SHA-256 of the canonical state_delta + verdict +
  # engine receipt identity only; no receipt payloads). Fail-safe: any
  # emission failure is logged and dropped, NEVER raised into the sealer —
  # admission outcome is untouched.
  def affidavit_ocel_emit(state_delta, witness) do
    verdict = if witness["sealed"], do: "admitted", else: "refused"

    engine_hash =
      case witness["receipt"] do
        nil -> "unknown"
        receipt -> "sha256:" <> (:crypto.hash(:sha256, receipt) |> Base.encode16(case: :lower))
      end

    subject_sha = :crypto.hash(:sha256, state_delta) |> Base.encode16(case: :lower)

    case Smalt.Telemetry.AffidavitOcel.seal(
           subject_sha: subject_sha,
           verdict: verdict,
           engine_hash: engine_hash
         ) do
      # {:ok, _} covers {:ok, :dropped}; both map to :ok
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("SHIM-COURT lane622: affidavit.seal OCEL dropped: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning(
        "SHIM-COURT lane622: affidavit.seal OCEL emission failed: #{Exception.message(e)}"
      )
  end

  # Tariff: Smalt.FinOps.Calculator.avoided_tariff_cents/2 (F lane, contract:
  # type :: String.t() x proxy :: %{bytes: pos_integer()}) when loaded, with a
  # single non-blocking load check; otherwise a deterministic local proxy
  # (1_000_000 cents + 100 cents per canonical byte) so the seal path stays
  # exercisable before the calculator lands.

  # Tariff: Smalt.FinOps.Calculator.avoided_tariff_cents/2 (F lane, contract:
  # type :: String.t() x proxy :: %{bytes: pos_integer()}) when loaded, with a
  # single non-blocking load check; otherwise a deterministic local proxy
  # (1_000_000 cents + 100 cents per canonical byte) so the seal path stays
  # exercisable before the calculator lands.
  def affidavit_tariff(record, state_delta) do
    if finops_loaded?() do
      proxy = %{"bytes" => byte_size(state_delta)}

      try do
        apply(Smalt.FinOps.Calculator, :avoided_tariff_cents, [
          Map.get(record, "type", "unknown"),
          proxy
        ])
      rescue
        _ -> proxy_tariff(state_delta)
      end
    else
      proxy_tariff(state_delta)
    end
  end


  def finops_loaded? do
    case :persistent_term.get({__MODULE__, :finops_loaded}, nil) do
      true ->
        true

      _cache ->
        # Single non-blocking readiness check (sleep deleted 2026-10-18: the
        # old 5x100ms retry loop is gone). The calculator module is either
        # already loaded (steady state) or the caller fails closed to
        # proxy_tariff immediately — never a blocking wait on module load.
        loaded? = match?({:module, _}, Code.ensure_loaded(Smalt.FinOps.Calculator))

        if loaded?, do: :persistent_term.put({__MODULE__, :finops_loaded}, true)

        loaded?
    end
  end


  def proxy_tariff(state_delta), do: 1_000_000 + byte_size(state_delta)

  # Prefer the D-lane 4-arity wrapper (`call_admit_and_seal/4`); when it is
  # not yet compiled, fall back to the landed `affi_admit_and_seal/1` export
  # by folding tariff/modality/lease into the canonical request document.

  # Prefer the D-lane 4-arity wrapper (`call_admit_and_seal/4`); when it is
  # not yet compiled, fall back to the landed `affi_admit_and_seal/1` export
  # by folding tariff/modality/lease into the canonical request document.
  def affidavit_engine_seal(state_delta, tariff, modality, lease_context) do
    cond do
      function_exported?(Smalt.Affidavit.WasmEngine, :call_admit_and_seal, 4) ->
        apply(Smalt.Affidavit.WasmEngine, :call_admit_and_seal, [
          state_delta,
          tariff,
          modality,
          lease_context
        ])

      function_exported?(Smalt.Affidavit.WasmEngine, :affi_admit_and_seal, 1) ->
        request =
          Jason.encode!(%{
            "op" => "admit_and_seal",
            "state_delta" => state_delta,
            "tariff_cents" => tariff,
            "modality" => modality,
            "lease_context" => lease_context
          })

        apply(Smalt.Affidavit.WasmEngine, :affi_admit_and_seal, [request])

      true ->
        {:error, :engine_unavailable}
    end
  rescue
    # JA-R1 (V3): fail-closed envelope unchanged; the crash is no longer
    # silent — every engine-down refusal here is operator-visible.
    e ->
      Logger.error(
        "arm_gateway affidavit seal: engine crash -> :engine_unavailable (#{Exception.message(e)})"
      )

      {:error, :engine_unavailable}
  catch
    # A WASM engine crash surfaces client-side as :exit (the GenServer dies
    # mid-call); the sideband must stay fail-safe through exits too.
    :exit, reason ->
      Logger.error(
        "arm_gateway affidavit seal: engine exit -> :engine_unavailable (#{inspect(reason)})"
      )

      {:error, :engine_unavailable}
  end

  # {:ok, witness} — accept the D-lane structured map
  # %{ctrt_bytes: binary(), pqc_receipt: binary()}, a generic string-keyed
  # map, or a raw sealed CTRT binary; the block always carries ctrt hex.

  # {:ok, witness} — accept the D-lane structured map
  # %{ctrt_bytes: binary(), pqc_receipt: binary()}, a generic string-keyed
  # map, or a raw sealed CTRT binary; the block always carries ctrt hex.
  def normalize_witness(%{ctrt_bytes: ctrt, pqc_receipt: receipt}, tariff, modality)
       when is_binary(ctrt) do
    %{
      "ctrt" => Base.encode16(ctrt, case: :lower),
      "receipt" => to_string(receipt),
      "tariff_cents" => tariff,
      "modality" => modality,
      "sealed" => true
    }
  end

  def normalize_witness(%{} = witness, tariff, modality) do
    witness
    |> Map.put_new("ctrt", "affidavit-wasm")
    |> Map.put_new("receipt", "sealed")
    |> Map.put("tariff_cents", tariff)
    |> Map.put("modality", modality)
    |> Map.put("sealed", true)
  end

  def normalize_witness(ctrt, tariff, modality) when is_binary(ctrt) do
    %{
      "ctrt" => Base.encode16(ctrt, case: :lower),
      "receipt" => "affidavit-wasm ctrt sealed token",
      "tariff_cents" => tariff,
      "modality" => modality,
      "sealed" => true
    }
  end

  # Typed witness-absent fallback: never a crash, admission unchanged.

  # Typed witness-absent fallback: never a crash, admission unchanged.
  def witness_absent(reason) do
    %{
      "ctrt" => nil,
      "receipt" => "PQC_NOT_PROVISIONED",
      "sealed" => false,
      "reason" => to_string(reason)
    }
  end

  # ===========================================================================
  # Routes (first-match-wins: deeper/collection routes precede shallower ones)
  # ===========================================================================

  # -- STS / OAuth2 Token Issuance --------------------------------------------

  # KD-54 $filter: support the eq-clauses a registry-backed record can answer:
  # resourceType, resourceGroup, name, location. Unknown/unparseable clauses
  # deny by default (match nothing) rather than silently listing everything.
  def subscription_resource_filter(conn, %{"id" => id} = record)
       when is_binary(id) do
    case conn.query_params["$filter"] do
      nil ->
        true

      filter when is_binary(filter) ->
        parse_filter_clauses(filter)
        |> Enum.all?(fn {field, wanted} ->
          case field do
            "resourceType" ->
              is_binary(record["type"]) and
                String.downcase(record["type"]) == String.downcase(wanted)

            "resourceGroup" ->
              rg_from_resource_id(id) == String.downcase(wanted)

            "name" ->
              is_binary(record["name"]) and record["name"] == wanted

            "location" ->
              is_binary(record["location"]) and
                String.downcase(record["location"]) == String.downcase(wanted)

            _ ->
              false
          end
        end)
    end
  end

  def subscription_resource_filter(_conn, _record), do: false

  # AZURE-FIDELITY lane 1: documented $expand semantics for list operations
  # (Resources - List, ResourceGroups - List): `$expand=createdTime,changedTime`
  # projects the resource lifecycle timestamps onto each item; the fields are
  # ABSENT unless requested (real ARM omits them by default). Rows are read
  # from ProviderState (frozen createdTime / advancing changedTime per write).

  # AZURE-FIDELITY lane 1: documented $expand semantics for list operations
  # (Resources - List, ResourceGroups - List): `$expand=createdTime,changedTime`
  # projects the resource lifecycle timestamps onto each item; the fields are
  # ABSENT unless requested (real ARM omits them by default). Rows are read
  # from ProviderState (frozen createdTime / advancing changedTime per write).
  def apply_lifecycle_expand(items, conn) when is_list(items) do
    requested =
      case conn.query_params["$expand"] do
        value when is_binary(value) ->
          value
          |> String.split(",")
          |> Enum.map(&String.trim(&1))
          |> MapSet.new()

        _ ->
          MapSet.new()
      end

    want_created = MapSet.member?(requested, "createdTime")
    want_changed = MapSet.member?(requested, "changedTime")

    if want_created or want_changed do
      Enum.map(items, fn item ->
        if is_map(item) and is_binary(item["id"]) do
          times = ProviderState.lifecycle(item["id"])

          item =
            if want_created and is_binary(times["createdTime"]),
              do: Map.put(item, "createdTime", times["createdTime"]),
              else: item

          if want_changed and is_binary(times["changedTime"]),
            do: Map.put(item, "changedTime", times["changedTime"]),
            else: item
        else
          item
        end
      end)
    else
      items
    end
  end

  def apply_lifecycle_expand(items, _conn), do: items

  # Split `a eq 'x' and b eq 'y'` into [{a, x}, {y}...]. Not a full ARM filter
  # grammar — eq/and only, quoted single-word-or-quoted values.

  # Split `a eq 'x' and b eq 'y'` into [{a, x}, {y}...]. Not a full ARM filter
  # grammar — eq/and only, quoted single-word-or-quoted values.
  def parse_filter_clauses(filter) do
    filter
    |> String.split(" and ")
    |> Enum.flat_map(fn clause ->
      case String.split(String.trim(clause), " eq ") do
        [field, value] ->
          [{String.trim(field), strip_quotes(String.trim(value))}]

        _ ->
          # Unparseable clause: clause set that can never match.
          [{"__unmatched__", ""}]
      end
    end)
  end


  def strip_quotes(value) do
    first = String.first(value)
    last = String.last(value)

    if byte_size(value) >= 2 and first == last and first in ["'", "\""] do
      binary_part(value, 1, byte_size(value) - 2)
    else
      value
    end
  end


  def rg_from_resource_id(id) do
    case Regex.run(~r{/resourcegroups?/([^/]+)}i, id) do
      [_, rg] -> String.downcase(rg)
      _ -> nil
    end
  end

  # -- Child-resource routes (declared BEFORE generic provider routes) ----------

  # Microsoft.Network/virtualNetworks/:vnet/subnets (registry type: Microsoft.Network/subnets)

  def vault_secret_sweep(swept_keys) do
    swept_keys
    |> VaultData.vault_secret_names()
    |> VaultData.drop_vault_secrets()
  end

  # Cosmos pk_meta cascade (capture-then-sweep over swept ARM store keys, same
  # shape as storage_account_names/1 + vault_secret_sweep/1). Containers drop
  # first so each `{1, db, coll}`/`"db/coll"` row is named by its own swept
  # key; then databases drop `{0, db}` plus any remaining child rows.

  # Cosmos pk_meta cascade (capture-then-sweep over swept ARM store keys, same
  # shape as storage_account_names/1 + vault_secret_sweep/1). Containers drop
  # first so each `{1, db, coll}`/`"db/coll"` row is named by its own swept
  # key; then databases drop `{0, db}` plus any remaining child rows.
  def cosmos_sweep(swept_keys) do
    colls =
      for {db, coll} <- cosmos_swept_containers(swept_keys) do
        Cosmos.drop_container(db, coll)
        {db, coll}
      end

    for db <- cosmos_swept_dbs(swept_keys, colls) do
      Cosmos.drop_db(db)
    end
  end


  def cosmos_swept_containers(keys) do
    keys
    |> Enum.flat_map(fn key ->
      case Regex.run(
             ~r/databaseaccounts\/[^\/]+\/sqldatabases\/([^\/]+)\/sqlcontainers\/([^\/]+)/i,
             key,
             capture: :all_but_first
           ) do
        [db, coll] -> [{db, coll}]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  # Databases swept either by their own key (no trailing /sqlContainers) or
  # implicitly via a swept container (reverse-topological cascade where the
  # account key carries the whole subtree).

  # Databases swept either by their own key (no trailing /sqlContainers) or
  # implicitly via a swept container (reverse-topological cascade where the
  # account key carries the whole subtree).
  def cosmos_swept_dbs(keys, colls) do
    from_containers = Enum.map(colls, &elem(&1, 0))

    from_keys =
      keys
      |> Enum.flat_map(fn key ->
        case Regex.run(~r/databaseaccounts\/[^\/]+\/sqldatabases\/([^\/]+)$/i, key,
               capture: :all_but_first
             ) do
          [db] -> [db]
          _ -> []
        end
      end)

    Enum.uniq(from_containers ++ from_keys)
  end

  # Extract storageAccount names from swept ARM store keys (capture-then-sweep
  # for the D127 data-plane cascade). Matches both store-key conventions:
  # prefixed (.../providers/microsoft.storage/storageaccounts/<acct>/...) and
  # the child-route form (.../storageaccounts/<acct>/...).
  # KD-COVERS: KD-28 — the NSG shape tightening lives in
  # priv/shacl/smalt-shapes.ttl (NsgShape: closed true + location required),
  # compiled into this router via GraphLaw.Validator's compile-time ttl parse;
  # this refusal site is where the wire 400 surfaces.
  # GraphLaw refusal -> HTTP 400 (PINNED decision; ARM never returns 422).
  # Envelope code InvalidResourceShape, target AshGraphLaw.Enforcement.
  # Optional `details` carries per-issue SHACL detail rows (ARM error.details
  # shape); byte-identical envelope when details == [] (existing corpus rows).
  def send_graphlaw_refusal(conn, reason, details \\ []) do
    error = %{
      "code" => "InvalidResourceShape",
      "message" => "GraphLaw validation failure: #{reason}",
      "target" => "AshGraphLaw.Enforcement",
      "innererror" => %{}
    }

    error = if details == [], do: error, else: Map.put(error, "details", details)

    body = Jason.encode!(%{"error" => error})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, body)
  end

  # AZB-05: typed 503 face for engine-down under :fail_closed. ARM error
  # envelope shape; code EngineUnavailable; message names the typed atom
  # :engine_unavailable (ticket vocabulary).

  def graph_law_fail_closed? do
    Smalt.Config.graph_law()[:enforcement] == :fail_closed
  end

  # GL28-2 admission gate call site (spec §3/§8). Refusals render through the
  # pinned GraphLaw refusal face (send_graphlaw_refusal/3: 400
  # InvalidResourceShape envelope, message names the typed SMALT-* code) — the
  # router pins "ARM never returns 422" on send_graphlaw_refusal; a 422 face is
  # a coordinator flip if the GL28-2 court corpus wants one.

  def send_engine_unavailable(conn) do
    body =
      Jason.encode!(%{
        "error" => %{
          "code" => "EngineUnavailable",
          "message" =>
            "graphlaw validation engine is unavailable (:engine_unavailable); request refused fail-closed, never admitted.",
          "target" => "AshGraphLaw.Enforcement",
          "innererror" => %{}
        }
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(503, body)
  end

  # RG api-version gate (row 6b, coordinator-authorized landing 2026-10-15):
  # Microsoft.Resources/resourceGroups is an admitted Registry type
  # (latest 2021-04-01) — every RG verb validates api-version like any other
  # admitted type (missing -> 400 MissingApiVersionParameter; stale ->
  # 400 InvalidApiVersionParameter naming the latest).
  @rg_type "Microsoft.Resources/resourceGroups"

end
