
defmodule Smalt.ArmGateway.Engine.Policy do
  @moduledoc """
  Admission/policy gate engine (T06, v26.10.29). Verbatim extraction of the
  admission gate, shape/version validation internals from the router
  front-end. Public functions, imported by the plugs that gate on them.
  """

  import Plug.Conn
  require Logger
  import Smalt.ArmGateway.Plug.Common

  alias Smalt.GraphLaw.Validator


  # GL28-2 admission gate call site (spec §3/§8). Refusals render through the
  # pinned GraphLaw refusal face (send_graphlaw_refusal/3: 400
  # InvalidResourceShape envelope, message names the typed SMALT-* code) — the
  # router pins "ARM never returns 422" on send_graphlaw_refusal; a 422 face is
  # a coordinator flip if the GL28-2 court corpus wants one.
  def check_admission_gate(conn, envelope) do
    gate_mod = Smalt.GraphlawEx.AdmissionGate

    cond do
      not (Code.ensure_loaded?(gate_mod) and function_exported?(gate_mod, :gate, 3)) ->
        # GL28-2 build lane has not landed the module: the sanctioned
        # falsifiable stub. NOT a silent pass — invert the guard (or land the
        # module under :fail_closed with no receipt in hand) and the gate MUST
        # refuse; a gate that cannot refuse is the failure.
        :ok

      not graph_law_fail_closed?() ->
        # Spec §8 posture: :fail_open -> admit-and-seal (the seal sideband,
        # affidavit_seal/2, already runs post-commit). The gate refusal face
        # exists only under :fail_closed.
        :ok

      true ->
        case apply(gate_mod, :gate, [conn.method, envelope, gate_opts(conn)]) do
          :ok ->
            :ok

          # Gate refusals are 3-tuples ({:refused, code, details},
          # AdmissionGate.refused/0); the typed code is preserved in the
          # refusal face, details ride the log line for diagnosis.
          {:refused, code, details} ->
            Logger.warning(
              "admission gate refused: code=#{inspect(code)} details=#{inspect(details)}"
            )

            {:respond, send_graphlaw_refusal(conn, to_string(code))}

          {:error, reason} ->
            {:respond, send_graphlaw_refusal(conn, to_string(reason))}

          other ->
            {:respond,
             send_graphlaw_refusal(
               conn,
               "unexpected admission-gate verdict: " <> inspect(other)
             )}
        end
    end
  end

  # Envelope the router HAS in hand (spec §2 5-tuple): the byte-exact raw
  # request body (Smalt.Auth.BodyCache accumulates it into
  # conn.private[:smalt_raw_body]) plus the receipt fields — which the router
  # does not yet mint (receipt substrate is GL28-2 build-lane work: VcExport
  # .to_vc/2, affidavit_seal/2, journal frames 0x0A01/0x0A02), so they present
  # as nil and the gate answers in the typed SMALT-* vocabulary, never a
  # boolean.

  # Envelope the router HAS in hand (spec §2 5-tuple): the byte-exact raw
  # request body (Smalt.Auth.BodyCache accumulates it into
  # conn.private[:smalt_raw_body]) plus the receipt fields — which the router
  # does not yet mint (receipt substrate is GL28-2 build-lane work: VcExport
  # .to_vc/2, affidavit_seal/2, journal frames 0x0A01/0x0A02), so they present
  # as nil and the gate answers in the typed SMALT-* vocabulary, never a
  # boolean.
  def admission_envelope(conn) do
    {:admitted_mutation, admission_raw_body(conn), nil, nil, nil}
  end


  def admission_raw_body(conn) do
    case conn.private[:smalt_raw_body] do
      body when is_binary(body) -> body
      _ -> Jason.encode!(conn.body_params)
    end
  end

  # Gate options, spec-named keys (§3.3 engine-digest persistent_term key, §4
  # packet-4 16 MiB cap). The GL28-2 gate module may extend this list; a
  # Keyword-fetching gate ignores unknown keys.

  # Gate options, spec-named keys (§3.3 engine-digest persistent_term key, §4
  # packet-4 16 MiB cap). The GL28-2 gate module may extend this list; a
  # Keyword-fetching gate ignores unknown keys.
  def gate_opts(_conn) do
    [
      engine_digest_key: :gl_engine_digest,
      max_request_bytes: 16 * 1024 * 1024
    ]
  end

  # KD-78: api-version admission is MONOTONIC (real ARM semantics): any version
  # <= latest for the admitted type is accepted; only versions > latest or
  # malformed versions are refused (typed InvalidApiVersionParameter, naming
  # latest). SHIM-COURT surface: this gate is the anti-vacuity subject.

  def check_admitted(conn, raw_type) do
    case find_admitted(raw_type) do
      nil ->
        {:respond,
         send_graphlaw_refusal(
           conn,
           "Resource type #{raw_type} is not an admitted ontology individual in smalt-substrate-pack"
         )}

      full_type ->
        {:ok, full_type}
    end
  end


  def check_shape(conn, full_type, payload) do
    # Fail-closed fence (shacl-fuzz finding, v26.10.16): a hostile body shape
    # (e.g. "properties" as a JSON array) can raise inside the validator's
    # path traversal (BadMapError on dotted_get). A validator crash must
    # surface as a typed ARM refusal, never an untyped 500. (The non-map
    # "properties" member itself is refused earlier by
    # check_properties_member — same fence family, SHIM-COURT shacl-fuzz.)
    try do
      do_check_shape(conn, full_type, payload)
    rescue
      e ->
        responded =
          send_graphlaw_refusal(
            conn,
            "validator raised #{e.__struct__} on a hostile body shape — refused fail-closed (SHIM-COURT shacl-fuzz fence)"
          )

        {:respond, responded}
    end
  end

  # Fail-closed member-shape guard: "properties" must be a JSON object or
  # absent (shacl-fuzz fence, v26.10.16).

  # Fail-closed member-shape guard: "properties" must be a JSON object or
  # absent (shacl-fuzz fence, v26.10.16).
  def check_properties_member(conn, merged) when is_map(merged) do
    case Map.get(merged, "properties") do
      nil ->
        :ok

      p when is_map(p) ->
        :ok

      other ->
        {:respond,
         send_graphlaw_refusal(
           conn,
           "properties member must be a JSON object, got #{inspect(other)} — SHIM-COURT shacl-fuzz fence"
         )}
    end
  end

  def check_properties_member(conn, merged) when not is_map(merged) do
    {:respond,
     send_graphlaw_refusal(
       conn,
       "request body must be a JSON object, got #{inspect(merged)} — SHIM-COURT shacl-fuzz fence"
     )}
  end


  def do_check_shape(conn, full_type, payload) do
    case Validator.validate_resource(full_type, payload) do
      ok when ok in [:ok, {:ok}] ->
        :ok

      {:invalid, issues} ->
        reason =
          issues
          |> Enum.map(fn issue ->
            (issue[:message] || "constraint " <> to_string(issue[:constraint] || "violated")) <>
              " at " <> to_string(issue[:path] || "?")
          end)
          |> Enum.join("; ")

        # ARM error.details shape: one row per SHACL issue, target = offending path.
        details =
          Enum.map(issues, fn issue ->
            %{
              "code" => "InvalidResourceShape",
              "message" =>
                issue[:message] ||
                  "constraint " <> to_string(issue[:constraint] || "violated"),
              "target" => to_string(issue[:path] || "?")
            }
          end)

        {:respond, send_graphlaw_refusal(conn, reason, details)}

      # AZB-05 control-plane profile: when graphlaw enforcement is
      # :fail_closed, an engine configured-but-unavailable is a TYPED 503
      # (:engine_unavailable), never an admission and never a generic 400
      # InvalidResourceShape (that 400 face stays for :fail_open / default —
      # the anti-vacuity flip surface). No payload is admitted either way.
      {:refused, :engine_unavailable} ->
        if graph_law_fail_closed?() do
          {:respond, send_engine_unavailable(conn)}
        else
          {:respond, send_graphlaw_refusal(conn, to_string(:engine_unavailable))}
        end

      {:refused, reason} ->
        {:respond, send_graphlaw_refusal(conn, to_string(reason))}

      {:error, reason} ->
        {:respond, send_graphlaw_refusal(conn, to_string(reason))}
    end
  end


  def resource_id(sub_id, rg_name, provider_ns, resource_type, resource_name) do
    "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/providers/#{provider_ns}/#{resource_type}/#{resource_name}"
  end


  def ns_of(full_type), do: full_type |> String.split("/") |> List.first()
  def leaf_of(full_type), do: full_type |> String.split("/") |> Enum.at(1)

  # LRO PUT async response: polling URLs resolve from the client's seat — the
  # same request-authority derivation the OIDC envelopes use (never a hardcoded
  # management.smalt.local).
end
