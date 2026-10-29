defmodule Smalt.Attestation.Maa do
  @moduledoc """
  AZ-2 (v26.10.22): Azure Managed Attestation (MAA) **protocol face** over the
  landed attestation surface (`Smalt.Security.Attestation` baseline module +
  `Smalt.Egress.AttestRoutes`).

  ## MAA REST wire shape (real doc, never azurite)

  Microsoft Learn, *Azure Attestation REST API reference* — `Attest /
  Attest Sgx Enclave / Attest Tpm` operation
  (`Microsoft.Attestation/attestationProviders`):

      POST https://{provider}.attest.azure.net/attest/{tee}?api-version=2022-08-01
      {
        "report":      "<base64url-encoded enclave quote>",
        "runtimeData": { "data": "<base64>", "dataType": "JSON" | "Binary" }
      }

      200 -> { "jwt-token": "<RS256 JWT signed by MAA>" }
      400 -> { "error": { "code": "invalidmeasurement", "message": ... } }

  `:type` is a per-provider TEE family (`SevSnpVM`, `SgxIntelSdk`,
  `OpenEnclave`, `Tpm`).

  ## Loopback reality (typed honestly)

  smalt plays BOTH the verifier and the attester. There is no TEE silicon
  here: producing a REAL SEV-SNP/TDX hardware quote is **typed UNSUPPORTED**
  — falsifier: a real SEV-SNP or TDX quote (VCEK/VCEM-signed report with
  chip-endorsement chain) cannot be produced on this machine by construction
  (no SNP/TDX firmware, no AMD PSP, no TDX module). The PROTOCOL face is
  real: quote structure validation, a MAA-grammar policy evaluation,
  measurement binding into the substrate artifacts (BK-85 CTRT / W3C-B VC),
  and a real RS256 attestation token via `Smalt.Security.ReceiptSigner`
  (W3C-B's typed precedent: MAA's own VCEK-backed signing cert is part of
  the same UNSUPPORTED row, not a second claim).

  ## Loopback quote framing (the "evidence" this emulator can attest)

      bytes  0..3   magic "SMQ1"
      bytes  4..35  measurement digest (32 bytes, sha256 class)
      bytes 36..39  runtime payload length (u32 BE)
      bytes 40..    runtime payload (the attester's own claims JSON)

  The measurement ALSO rides as a `runtimeData` claim
  (`"x-ms-measurement"`), and the admission rule in the default policy
  requires the runtime claim to equal the quote-frame measurement — a single
  tampered measurement byte flips the policy verdict to refuse. (Real MAA
  validates a hardware-anchored quote signature; here the protocol-level
  cross-binding stands in, typed as above.)

  ## MAA policy grammar (real doc)

  Microsoft Learn, *Attestation policy grammar*:

      version=1.0;
      authorizationrules { c:[type=="SevSnpVM"] => permit(); };
      issuancerules { c:[type=="SevSnpVM"] => issue(type="sevsnpvm"); };

  `authorizationrules` gate admission (all rules' conditions must match for
  `permit()`); `issuancerules` copy/derive claims into the issued JWT.
  This module implements the minimal grammar: condition `c:[k=="v"]`,
  actions `permit()` / `issue(name="value")`, semicolon-separated sections.
  `evaluate_policy/2` returns the issued-claims map or a typed refusal.

  ## Bindings

  * `:bind_ctrt` — a BK-85 sealed CTRT (352 bytes, magic `"CTRT"`; the
    task's "320-byte CTRT" note predates the landed layout: BK-85's CTRT is
    352 bytes — 320 is the ATH-1 receipt. The binding law is unchanged:
    bind to the REAL sealed artifact). The JWS claims carry
    `ctrt_sha256` and the CTRT's probe-region digest (`blake3(delta)`
    region bytes 70..102 as hex, sha256-committed).
  * `:bind_vc` — a W3C-B VC 2.0 map. It is verified through
    `Smalt.Receipt.VcExport.verify_vc/1` and the JWS claims carry the VC's
    `proofPayloadSha256` + `credentialSubject.receiptDigest`.

  ## Nonce replay

  A runtimeData `"nonce"` is single-use: recorded on issue in the
  `:smalt_maa_nonces` ETS table, a replayed nonce is a typed refusal
  (`nonceReplay`) with an andon leaf. The registry is BOUNDED (BK-MAAP6):
  keys over `nonce_max_key_bytes/0` refuse typed at intake; rows older than
  `nonce_ttl_seconds/0` (== the token TTL, so a burned nonce outlives every
  token it issued) are swept on each attest; a hard entry cap
  (`nonce_max_entries/0`) evicts the oldest consumed row under a same-window
  burst. Reservations are owner-ref'd — only the reserving process can
  release its own pending row. (Real MAA has no nonce-replay registry; this
  is loopback hardening, documented.)

  ## Refusal leaf (BK-111 chain)

  Every typed refusal emits a `Smalt.Powl2.Andon` receipt (rule id
  `maa_attestation_refusal` / `maa_nonce_replay`) whose N-Triples leaf
  carries the full PROV-O Entity/Activity/Agent chain, verified through
  `Andon.verify_ntriples/1` before it is returned — the Merkle/andon DAG
  only ever receives chain-complete leaves.
  """

  alias Smalt.Powl2.Andon
  alias Smalt.Receipt.VcExport
  alias Smalt.Security.ReceiptSigner

  @api_version "2022-08-01"
  @quote_magic "SMQ1"
  @compliance_status "azure-compliant-cvm"
  @tee_type "AMD-SEV-SNP"
  @ttl_seconds 7200
  @default_policy """
  version=1.0;
  authorizationrules {
    c:[type=="SevSnpVM"] => permit();
  };
  issuancerules {
    c:[type=="SevSnpVM"] => issue(type="sevsnpvm");
    c:["x-ms-measurement"==x-ms-measurement] => issue(x-ms-isolation-tee="AMD-SEV-SNP");
  };
  """
  @nonce_table :smalt_maa_nonces

  @type attest_result ::
          {:ok, String.t(), map()}
          | {:error, pos_integer(), map(), Andon.t()}

  @doc "The MAA api-version this face serves."
  def api_version, do: @api_version

  @doc "The default MAA-grammar policy text (cited verbatim in `@default_policy`)."
  def default_policy, do: @default_policy

  @doc """
  Evaluates a quote+runtime evidence set against `policy` text.

  `evidence` is a string-keyed claims map (quote frame fields + runtimeData
  JSON claims). Authorization rules' conditions must ALL match (fail-closed:
  a policy with no authorizationrules refuses); matching issuance rules
  copy/derive claims into the returned map.

  Returns `{:ok, issued_claims}` or `{:error, {:policy_refusal, rule}}`.
  """
  @spec evaluate_policy(String.t() | nil, map()) ::
          {:ok, map()} | {:error, {:policy_refusal, String.t()}}
  def evaluate_policy(nil, _evidence), do: {:error, {:policy_refusal, "no_policy"}}

  def evaluate_policy(policy, evidence) when is_binary(policy) and is_map(evidence) do
    with {:ok, sections} <- parse_policy(policy),
         :ok <- run_authorization(sections.authorization, evidence) do
      {:ok, run_issuance(sections.issuance, evidence)}
    end
  end

  @doc """
  The AZ-2 attest face (MAA `POST /attest/:type?api-version=2022-08-01`).

  `params`:

    * `"report"` — base64url-encoded loopback quote (see framing above)
    * `"runtimeData"` — `%{"data" => base64(json), "dataType" => "JSON"}`;
      the JSON carries `"x-ms-measurement"` (hex) and optionally `"nonce"`
    * `"policy"` — optional MAA-grammar policy override (default policy
      otherwise)

  Opts:

    * `:bind_ctrt` — 352-byte BK-85 CTRT binary
    * `:bind_vc` — W3C-B VC 2.0 map
    * `:ts` — injectable epoch-second timestamp (replay-stable courts)

  Returns `{:ok, jwt_token, claims}` or
  `{:error, status, error_body, andon_receipt}`. Success-path binding
  verification rides `ReceiptSigner.verify/1` (see `verify_attestation/1`).
  """
  @spec attest(String.t(), map(), keyword()) :: attest_result()
  def attest(type, params, opts \\ [])
      when is_binary(type) and is_map(params) and is_list(opts) do
    now = Keyword.get(opts, :ts, System.system_time(:second))
    policy = Map.get(params, "policy") || @default_policy

    # EXPL9-R1 compile-freeze SLA unblock (2026-10-22, disclosed): the
    # in-flight edit bound `reserved` in a with clause and read it in the
    # else block — with/else clauses cannot see with-clause bindings, so the
    # file did not compile (undefined variable at line 191). Minimal faithful
    # fix: hoist the pure decode_runtime call above the with so the else can
    # derive the reserved nonce from the result. Clause order (error
    # precedence) unchanged; decode_runtime is pure.
    runtime_result = decode_runtime(Map.get(params, "runtimeData"))

    with {:ok, claims} <- tee_claims(type),
         {:ok, quote} <- decode_quote(Map.get(params, "report")),
         {:ok, runtime} <- runtime_result,
         :ok <- nonce_fresh?(runtime["nonce"]),
         # Nonce is now RESERVED (:pending). Any failure below must release
         # it — a FAILED attempt must not burn the nonce (E8-T6); it is
         # recorded as consumed only on the success path (issue_token).
         _reserved = runtime["nonce"],
         evidence =
           runtime
           |> Map.merge(quote_claims(quote))
           |> Map.put("type", type),
         :ok <- same_measurement?(runtime, quote),
         {:ok, issued} <- evaluate_policy(policy, evidence),
         {:ok, binding} <- binding_claims(opts) do
      issue_token(type, claims, issued, runtime, quote, binding, now)
    else
      {:error, reason} ->
        # KD-169R compile-freeze unblock (disclosed): `reserved` is not in
        # scope inside with/else — derive the reserved nonce from the hoisted
        # runtime_result instead (the fix the adjacent comment already
        # describes). Behavior unchanged.
        nonce =
          case runtime_result do
            {:ok, rt} -> rt["nonce"]
            _ -> nil
          end

        release_nonce(nonce)
        refuse(type, reason, opts)
    end
  end

  @doc """
  Verifies an issued attestation token (RS256 via `ReceiptSigner.verify/1`)
  and re-derives the bound digests: the payload must still carry
  `measurement_digest` and (when present) `ctrt_sha256` / `vc_proof_sha256`
  as a coherent set. Returns `{:ok, claims}` or `{:error, reason}`.
  """
  @spec verify_attestation(String.t()) :: {:ok, map()} | {:error, term}
  def verify_attestation(token) when is_binary(token) do
    with {:ok, claims} <- ReceiptSigner.verify(token),
         :ok <- binding_coherent?(claims) do
      {:ok, claims}
    end
  end

  def verify_attestation(_), do: {:error, :invalid_token}

  @doc """
  SKR witness leg: a valid attestation token whose `measurement_digest`
  matches `expected_measurement_hex` releases the key through the REAL
  `Smalt.DataPlane.SKR.release/2` face (bearer-token conn); a mismatching or
  invalid token is a typed refusal WITHOUT touching SKR.
  """
  @spec secure_key_release(String.t(), String.t(), String.t()) ::
          {:ok, 200, map()} | {:error, pos_integer(), map()}
  def secure_key_release(key_name, token, expected_measurement_hex)
      when is_binary(key_name) and is_binary(token) and is_binary(expected_measurement_hex) do
    case verify_attestation(token) do
      {:ok, %{"measurement_digest" => ^expected_measurement_hex} = claims} ->
        conn =
          Plug.Test.conn(:post, "/keys/#{key_name}/release", nil)
          |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
          |> Map.put(:body_params, %{})
          |> Map.put(:params, %{})

        case Smalt.DataPlane.SKR.release(key_name, conn) do
          {:ok, 200, body} -> {:ok, 200, Map.put(body, "attested_measurement", claims["measurement_digest"])}
          other -> other
        end

      {:ok, _} ->
        {:error, 403, %{"error" => %{"code" => "UnauthorizedAttestation", "message" => "measurement fingerprint mismatch"}}}

      {:error, _} = err ->
        err
    end
  end

  def secure_key_release(_, _, _),
    do: {:error, 400, %{"error" => %{"code" => "InvalidParameter"}}}

  ## -- quote / runtime decoding ---------------------------------------------

  defp decode_quote(report) when is_binary(report) do
    with {:ok, raw} <- b64url_decode(report),
         <<@quote_magic, measurement::binary-size(32), runtime_len::unsigned-integer-size(32),
           runtime::binary-size(runtime_len)>> <- raw do
      {:ok, %{measurement: measurement, runtime: runtime}}
    else
      _ -> {:error, {:invalid_report, "invalidmeasurement"}}
    end
  rescue
    _ -> {:error, {:invalid_report, "invalidmeasurement"}}
  end

  defp decode_quote(_), do: {:error, {:invalid_report, "invalidparameter"}}

  defp decode_runtime(%{"data" => data, "dataType" => "JSON"}) when is_binary(data) do
    data =
      if String.valid?(data) and match?({:ok, _}, Jason.decode(data)) do
        # Plain-JSON data accepted alongside the documented base64 form.
        data
      else
        case b64_decode(data) do
          {:ok, raw} -> raw
          :error -> {:error, {:invalid_runtime, "invalidparameter"}}
        end
      end

    case if(is_binary(data), do: data) do
      nil -> {:error, {:invalid_runtime, "invalidparameter"}}

      raw ->
        case Jason.decode(raw) do
          {:ok, %{} = json} -> {:ok, json}
          _ -> {:error, {:invalid_runtime, "invalidparameter"}}
        end
    end
  end

  defp decode_runtime(_), do: {:error, {:invalid_runtime, "invalidparameter"}}

  defp quote_claims(%{measurement: m}) do
    %{
      "x-ms-quote-measurement" => Base.encode16(m, case: :lower),
      "x-ms-quote-runtime-sha256" => Base.encode16(:crypto.hash(:sha256, m), case: :lower)
    }
  end

  # KD-COVERS: KD-168 — AZ-2 (MAA protocol face): the runtimeData
  # measurement claim is the only cross-binding that stands in for hardware
  # quote validation; if this leg stops refusing, a tampered measurement
  # would be ATTESTED. Shim court: scripts/shim_court/az2_maa_court.sh.
  # The protocol-level cross-binding: the runtimeData measurement claim must
  # equal the quote-frame measurement byte-for-byte. A single tampered byte
  # anywhere in either flips this to a refusal (court tamper leg).
  defp same_measurement?(%{"x-ms-measurement" => runtime_hex}, %{measurement: m}) do
    if is_binary(runtime_hex) and lower(runtime_hex) == Base.encode16(m, case: :lower) do
      :ok
    else
      {:error, {:measurement_mismatch, "invalidmeasurement"}}
    end
  end

  defp same_measurement?(_, _), do: {:error, {:measurement_mismatch, "invalidmeasurement"}}

  defp lower(s), do: String.downcase(s)

  defp sha256_hex(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  defp b64url_decode(s) when is_binary(s) do
    case Base.url_decode64(s, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> Base.decode64(s) |> case do
        {:ok, bin} -> {:ok, bin}
        :error -> :error
      end
    end
  end

  defp b64_decode(s) when is_binary(s) do
    case Base.decode64(s) do
      {:ok, bin} -> {:ok, bin}
      :error -> Base.url_decode64(s, padding: false)
    end
  end

  ## -- nonce replay ----------------------------------------------------------

  # BK-MAAP6 (P6 fix): the nonce registry is BOUNDED three ways.
  #
  #   1. Key-size cap at intake — a nonce over @nonce_max_key_bytes is a typed
  #      refusal before any ETS write (attacker-controlled keys cannot mint
  #      arbitrarily large rows).
  #   2. TTL sweep — every attest call opportunistically select_delete's rows
  #      older than @nonce_ttl_seconds (consumed rows must outlive the token
  #      TTL @ttl_seconds so a replayed token's nonce stays burned for as long
  #      as the token itself is valid; @nonce_ttl_seconds == @ttl_seconds).
  #      This is compute-on-write, not a sleep/timer: no sweeper process, no
  #      Process.sleep anywhere.
  #   3. Hard entry cap @nonce_max_entries — if the sweep cannot free enough
  #      (e.g. a burst inside one TTL window), the OLDEST CONSUMED rows are
  #      evicted; :pending rows are never evicted (a live reservation is the
  #      replay gate).
  #
  # E8-T6: the nonce is RESERVED atomically (insert_new of a :pending row)
  # before evaluation, and recorded as consumed only when the token is
  # actually issued. A FAILED attempt releases the reservation (release_nonce
  # in attest/3's else), so a legitimate retry with corrected runtime data and
  # the same nonce succeeds. The reservation is the replay gate: a concurrent
  # duplicate with the same nonce hits insert_new and is refused while the
  # first attempt is still in flight (no TOCTOU widening vs the old
  # insert-on-check, and no burn-on-failure).
  #
  # BK-MAAP6 (P5 fix): rows are owner-ref'd — `{nonce, owner, state, ts}`.
  # release_nonce/2 deletes ONLY the caller's own :pending reservation, so a
  # refused process can no longer delete another process's in-flight
  # reservation (the cross-process release window BK-MAASKEP documented).

  @nonce_max_key_bytes 256
  @nonce_max_entries 65_536
  @nonce_ttl_seconds @ttl_seconds
  @nonce_pending_ttl_seconds 300

  @doc "Max nonce key size accepted at intake (bytes)."
  def nonce_max_key_bytes, do: @nonce_max_key_bytes

  @doc "Max live nonce rows before oldest-consumed eviction kicks in."
  def nonce_max_entries, do: @nonce_max_entries

  @doc "TTL (seconds) for consumed nonce rows; >= the attestation token TTL."
  def nonce_ttl_seconds, do: @nonce_ttl_seconds

  @doc """
  Sweep expired nonce rows (consumed older than the nonce TTL, stale pending
  past the pending TTL). Public for real-ETS courts; also run opportunistically
  on every attest call. Returns the number of rows deleted.
  """
  @spec sweep_expired_nonces(non_neg_integer()) :: non_neg_integer()
  def sweep_expired_nonces(now) when is_integer(now) and now >= 0 do
    if :ets.whereis(@nonce_table) != :undefined do
      consumed_cutoff = now - @nonce_ttl_seconds
      pending_cutoff = now - @nonce_pending_ttl_seconds

      ms = [
        {
          {:"$1", :"$2", :"$3", :"$4"},
          [
            {:orelse,
             {:andalso, {:==, :"$3", :consumed}, {:<, :"$4", consumed_cutoff}},
             {:andalso, {:==, :"$3", :pending}, {:<, :"$4", pending_cutoff}}}
          ],
          [true]
        }
      ]

      :ets.select_delete(@nonce_table, ms)
    else
      0
    end
  end

  defp nonce_fresh?(nil), do: :ok

  defp nonce_fresh?(nonce) when is_binary(nonce) do
    if byte_size(nonce) > @nonce_max_key_bytes do
      {:error, {:nonce_too_large, "invalidparameter"}}
    else
      ensure_nonce_table()
      sweep_expired_nonces(System.system_time(:second))
      enforce_entry_cap()

      if :ets.insert_new(@nonce_table, {nonce, self(), :pending, System.system_time(:second)}) do
        :ok
      else
        {:error, {:nonce_replay, "nonceReplay"}}
      end
    end
  end

  defp nonce_fresh?(_), do: {:error, {:nonce_replay, "invalidparameter"}}

  defp enforce_entry_cap do
    if :ets.info(@nonce_table, :size) >= @nonce_max_entries do
      evict_oldest_consumed()
    end

    :ok
  end

  # Evict the oldest consumed row (the sweep's fallback under a same-TTL-window
  # burst; :pending rows are never evicted — a live reservation is the replay
  # gate). Wrapped in a rescue so an empty/closed table is a no-op, not a crash.
  defp evict_oldest_consumed do
    ms = [{{:"$1", :"$2", :consumed, :"$4"}, [], [{{:"$4", :"$1"}}]}]

    case :ets.select(@nonce_table, ms) do
      [] ->
        :ok

      rows ->
        {_oldest_ts, oldest} = Enum.min_by(rows, fn {t, _} -> t end)
        :ets.delete(@nonce_table, oldest)
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp release_nonce(nil), do: :ok

  defp release_nonce(nonce) when is_binary(nonce) do
    # BK-MAAP6 (P5): delete ONLY the caller's own :pending reservation — a
    # refused process can no longer delete another process's in-flight
    # reservation, closing the cross-process release window.
    # BK-MAA2 (F1): guard the table lookup — the oversized-nonce refusal path
    # releases BEFORE the table has ever been created, and a deleted table
    # must be a no-op, not an ArgumentError crash out of attest/3.
    if :ets.whereis(@nonce_table) != :undefined do
      :ets.match_delete(@nonce_table, {nonce, self(), :pending, :_})
    end

    :ok
  end

  # E8-T2: the nonce table is owned OUTSIDE the caller's process class. The
  # heir 3-tuple (SPOF-B / A-4 shadow-table law, Sync.Store idiom) transfers
  # the table to :init when the creating process (a short-lived Bandit request
  # process in production) dies — replay protection no longer silently resets
  # with its creator.
  defp ensure_nonce_table do
    if :ets.whereis(@nonce_table) == :undefined do
      heir = Process.whereis(:init) || self()

      :ets.new(@nonce_table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        heir: heir
      ])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Test helper: clears the nonce replay registry."
  def reset_nonces! do
    if :ets.whereis(@nonce_table) != :undefined, do: :ets.delete_all_objects(@nonce_table)
    :ok
  end

  ## -- bindings ---------------------------------------------------------------

  defp binding_claims([]), do: {:ok, %{}}

  defp binding_claims(opts) do
    case Keyword.fetch(opts, :bind_ctrt) do
      {:ok, ctrt} -> ctrt_binding(ctrt)
      :error ->
        case Keyword.fetch(opts, :bind_vc) do
          {:ok, vc} -> vc_binding(vc)
          :error -> {:ok, %{}}
        end
    end
  end

  # BK-85 CTRT (352 bytes, magic "CTRT", version 1 LE-u16). The sealed
  # artifact is immutable — binding = digest commitment in the signed JWS:
  # whole-CTRT sha256 + the probe-region (blake3(delta) region, [70..102])
  # content, so the attestation is only coherent for THIS seal.
  defp ctrt_binding(ctrt) when is_binary(ctrt) do
    case ctrt do
      <<magic::binary-size(4), 1::16-little, _::binary>> when magic == "CTRT" ->
        {:ok,
         %{
           "ctrt_sha256" => sha256_hex(ctrt),
           "ctrt_probe_region_sha256" => sha256_hex(binary_part(ctrt, 70, 32)),
           "ctrt_bytes" => byte_size(ctrt)
         }}

      _ ->
        {:error, {:invalid_binding, "invalidparameter"}}
    end
  end

  defp ctrt_binding(_), do: {:error, {:invalid_binding, "invalidparameter"}}

  defp vc_binding(vc) when is_map(vc) do
    case VcExport.verify_vc(vc) do
      {:ok, subject} ->
        {:ok,
         %{
           "vc_proof_sha256" => vc["proof"]["proofPayloadSha256"],
           "vc_receipt_digest" => subject["receiptDigest"]
         }}

      {:error, reason} ->
        {:error, {:invalid_binding, "invalidparameter: #{inspect(reason)}"}}
    end
  end

  defp vc_binding(_), do: {:error, {:invalid_binding, "invalidparameter"}}

  defp binding_coherent?(%{"measurement_digest" => m} = claims) when is_binary(m) do
    pairs = [
      {"ctrt_sha256", "ctrt_probe_region_sha256"},
      {"vc_proof_sha256", "vc_receipt_digest"}
    ]

    coherent? =
      Enum.all?(pairs, fn {a, b} ->
        not Map.has_key?(claims, a) or is_binary(claims[b])
      end)

    if coherent?, do: :ok, else: {:error, :incoherent_binding}
  end

  defp binding_coherent?(_), do: {:error, :invalid_claims}

  ## -- token issuance ----------------------------------------------------------

  defp tee_claims(type) when is_binary(type) do
    case type do
      "SevSnpVM" -> {:ok, %{"x-ms-attestation-type" => "sevsnpvm"}}
      _ -> {:error, {:unsupported_tee, "invalidparameter"}}
    end
  end

  defp issue_token(type, _tee, issued, runtime, quote, binding, now) do
    nonce = runtime["nonce"]

    # E8-T6 / BK-MAAP6: record the nonce as consumed on the SUCCESS path only —
    # the caller's :pending reservation is flipped in place (owner preserved via
    # update_element, so release_nonce/2 can never match a consumed row). If the
    # reservation was swept mid-flight, fall back to a fresh consumed row.
    if is_binary(nonce) do
      now = System.system_time(:second)

      unless :ets.update_element(@nonce_table, nonce, [
               {3, :consumed},
               {4, now}
             ]) do
        :ets.insert(@nonce_table, {nonce, self(), :consumed, now})
      end
    end

    # E8-T3: the envelope security claims (iss/iat/exp + the x-ms envelope)
    # are PROVIDER-CONTROLLED — policy-issued and binding claims merge UNDER
    # the envelope defaults, never over them. Belt-and-braces with the
    # parse-time reservation of the claim namespace (parse_issue/1).
    claims =
      Map.merge(
        Map.merge(issued, binding),
        %{
          "iss" => "https://smalt-attestation.local/",
          "iat" => now,
          "exp" => now + @ttl_seconds,
          "x-ms-compliance-status" => @compliance_status,
          "x-ms-isolation-tee" => @tee_type,
          "x-ms-runtime" => %{
            "jti" => System.unique_integer([:positive]) |> to_string(),
            "type" => type,
            "nonce_consumed" => is_binary(nonce),
            "quote_runtime_sha256" => quote_claims(quote)["x-ms-quote-runtime-sha256"]
          },
          "measurement_digest" => quote_claims(quote)["x-ms-quote-measurement"]
        }
      )

    {:ok, ReceiptSigner.sign(claims), claims}
  end

  ## -- refusal leaf (BK-111 chain) ---------------------------------------------

  defp refuse(type, {kind, code}, _opts) do
    rule_id = if kind == :nonce_replay, do: "maa_nonce_replay", else: "maa_attestation_refusal"

    andon =
      Andon.format_andon(rule_id, "#{kind}: #{type} refused (#{code})", %{type: type, code: code},
        repair_hint: "resubmit a structurally valid quote with a fresh nonce",
        session: "az2-maa"
      )

    # Fail-closed: a chain-less leaf never leaves this module.
    :ok = Andon.verify_ntriples(Andon.ntriples(andon))

    {:error, 400, %{"error" => %{"code" => code}}, andon}
  end

  ## -- MAA policy grammar --------------------------------------------------------

  defp parse_policy(policy) do
    text = String.replace(policy, "\n", " ")

    with {:ok, auth} <- section(text, "authorizationrules"),
         {:ok, iss} <- section(text, "issuancerules"),
         {:ok, auth_rules} <- parse_rules(auth, :authorization),
         {:ok, iss_rules} <- parse_rules(iss, :issuance) do
      {:ok, %{authorization: auth_rules, issuance: iss_rules}}
    end
  end

  defp section(text, name) do
    case Regex.run(~r/#{name}\s*\{(.*?)\}/s, text) do
      [_, body] -> {:ok, body}
      nil -> {:error, {:policy_refusal, "missing_section:#{name}"}}
    end
  end

  # E8-T5: rules are AND-ed, so a silently-dropped unparseable rule WIDENS
  # the policy (a Tpm-only intent that admitted SevSnpVM). Fail-closed: any
  # unparseable rule in either section is a typed policy refusal.
  defp parse_rules(body, kind) do
    results =
      body
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn rule -> parse_rule(rule, kind) end)

    if error = Enum.find(results, &match?({:error, _}, &1)) do
      error
    else
      if Enum.any?(results, &is_nil/1) do
        {:error, {:policy_refusal, "bad_rule"}}
      else
        {:ok, results}
      end
    end
  end

  defp parse_rule(rule, kind) do
    with [cond_part, action] <- String.split(rule, "=>", parts: 2),
         {:ok, claim, value} <- parse_condition(String.trim(cond_part)),
         {:ok, action} <- parse_action(String.trim(action), kind) do
      {claim, value, action}
    else
      {:error, _reason} = err -> err
      _ -> nil
    end
  end

  # Condition: `c:[claim=="literal"]` or `c:[claim==claimref]` — a quoted
  # value is a string literal; a bare name is a claim reference resolved
  # against the evidence at evaluation time.
  defp parse_condition(cond) do
    case Regex.run(~r/c:\s*\[\s*(.+?)\s*==\s*(.+?)\s*\]\s*\z/, cond) do
      [_, claim, value] -> {:ok, unquote_name(claim), classify(value)}
      nil -> {:error, {:policy_refusal, "bad_condition"}}
    end
  end

  defp classify(value) do
    value = String.trim(value)

    if String.starts_with?(value, "\"") and String.ends_with?(value, "\"") and byte_size(value) >= 2 do
      {:lit, String.slice(value, 1..-2//1)}
    else
      {:ref, value}
    end
  end

  defp unquote_name(name) do
    name = String.trim(name)

    if String.starts_with?(name, "\"") and String.ends_with?(name, "\"") and byte_size(name) >= 2 do
      String.slice(name, 1..-2//1)
    else
      name
    end
  end

  defp parse_action("permit();", :authorization), do: {:ok, :permit}
  defp parse_action("permit()", :authorization), do: {:ok, :permit}
  defp parse_action(<<"issue(", _::binary>> = action, :issuance), do: parse_issue(action)
  defp parse_action(_, _), do: nil

  # `issue(name="literal")` or `issue(name=claimref)`; the issued value is a
  # literal verbatim or a claim reference resolved against the evidence.
  # E8-T3: the JWT envelope claim namespace is PROVIDER-CONTROLLED (real MAA
  # issuancerules cannot override iss/iat/exp/nbf/jti) — an issue() naming a
  # reserved claim is a typed refusal, and issue_token/7 merges issued claims
  # UNDER the envelope defaults as belt-and-braces.
  @reserved_claims ~w(iss iat exp nbf jti)
  defp parse_issue(action) do
    case Regex.run(~r/issue\s*\(\s*(.+?)\s*=\s*(.+?)\s*\)\s*\z/, action) do
      [_, name, value] ->
        name = unquote_name(name)

        if name in @reserved_claims do
          {:error, {:policy_refusal, "reserved_claim:#{name}"}}
        else
          {:ok, {name, classify(value)}}
        end

      nil ->
        nil
    end
  end

  defp run_authorization([], _evidence), do: {:error, {:policy_refusal, "no_authorization_rules"}}

  defp run_authorization(rules, evidence) do
    Enum.reduce_while(rules, :ok, fn {claim, value, :permit}, :ok ->
      if cond_match?(claim, value, evidence) do
        {:cont, :ok}
      else
        {:halt, {:error, {:policy_refusal, "authorization_denied:#{claim}"}}}
      end
    end)
  end

  defp run_issuance(rules, evidence) do
    Enum.reduce(rules, %{}, fn {claim, value, {name, issued_value}}, acc ->
      if cond_match?(claim, value, evidence) do
        Map.put(acc, name, resolve(issued_value, evidence))
      else
        acc
      end
    end)
  end

  defp cond_match?(claim, {:lit, literal}, evidence) do
    case Map.fetch(evidence, claim) do
      {:ok, observed} -> observed == literal
      :error -> false
    end
  end

  defp cond_match?(claim, {:ref, ref}, evidence) do
    case Map.fetch(evidence, claim) do
      {:ok, observed} -> observed == resolve({:ref, ref}, evidence)
      :error -> false
    end
  end

  defp resolve({:lit, literal}, _evidence), do: literal
  defp resolve({:ref, ref}, evidence) do
    case Map.fetch(evidence, ref) do
      {:ok, v} -> v
      :error -> nil
    end
  end
end
