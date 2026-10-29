defmodule Smalt.Powl2.AndonWire do
  @moduledoc """
  Wire face for `Smalt.Powl2.Andon` receipts (GL-8): serializes a typed ANDON
  refusal into shapes non-BEAM agents consume.

  Two serializations, both derived from the same normalized receipt so the
  HTTP and AMQP faces can never disagree about the facts of a refusal:

  ## HTTP JSON envelope

  `http_envelope/2` returns `%{status: 422, content_type, body}` where `body`
  is:

      {"error": {"code": "GraphlawRefusal", "rule_id": "...",
                 "diagnostic": "...", "agent_message": "...",
                 "repair_hint": "...", "context_digest": "...",
                 "session": "...", "ts": 1700000000000000000}}

  Status pinion: **422 Unprocessable Content** — the request syntax is
  well-formed but the law rejected the *content* of the proposed transition.
  Distinguishable from 400 (malformed syntax), 403 (forbidden by principal),
  and 409 (conflict with peer state): the identical request becomes
  processable later by satisfying the named rule, which is exactly the
  repair-hint contract. The `{"error": {...}}` shape follows the smalt
  ARM-gateway error convention, so a plain HTTP client reads the refusal code
  without any smalt SDK.

  ## AMQP application-properties shape

  `amqp_properties/2` returns `%{body, content_type, content_encoding,
  application_properties, message_annotations, andon_ts_long}` keyed to what
  an AMQP 1.0 sender passes when publishing a refusal notification. The
  refusal code rides `application_properties["andon.code"] =
  "GraphlawRefusal"` plus flat string keys; `ts` additionally rides
  `andon_ts_long` as a binary-encoded 64-bit signed integer (AMQP long), so a
  non-BEAM consumer gets typed fields, not inspect strings. Body is
  byte-identical to the HTTP envelope body.

  ## Normalization

  `normalize/2` accepts any of the three real producers' shapes:

    * a `Smalt.Powl2.Andon` receipt (GL-3): `%{rule_id, diagnostic,
      agent_message, repair_hint, context_digest, ts, session}` — facts
      already present, passed through
    * the executor's andon tuple (GL-1): `{:powl2_andon, id, rule_id,
      diagnostic}` — the context digest is computed over the tuple itself,
      committing to the refusal identity (instance id, rule, diagnostic)
    * the executor's DETS andon receipt (GL-1): `%{shape_id, rule_id,
      diagnostic, at_ms, at_rel_ms}` — digest over `{shape, rule, diag,
      at_ms}`; `ts` from `at_ms`; `session` defaults to the current node

  Unknown shape → `{:error, :unwirable_shape}` (fail-closed: a wire face that
  silently widens its domain would emit an envelope a consumer trusts for a
  receipt it does not understand).
  """

  alias Smalt.Powl2.Andon

  @andon_code "GraphlawRefusal"
  @http_status 422
  @content_type "application/json"

  @typedoc "Canonical wire receipt (post-normalization)."
  @type wire_receipt :: %{
          required(:code) => String.t(),
          required(:rule_id) => String.t(),
          required(:diagnostic) => String.t(),
          required(:agent_message) => String.t(),
          required(:repair_hint) => String.t(),
          required(:context_digest) => String.t(),
          required(:session) => String.t(),
          required(:ts) => integer(),
          optional(:shape_id) => String.t(),
          optional(:instance_id) => String.t()
        }

  @doc """
  Normalizes any supported producer shape into the canonical wire receipt.
  Fails closed on unknown shapes (`{:error, :unwirable_shape}`).
  """
  @spec normalize(term(), keyword()) :: {:ok, wire_receipt()} | {:error, :unwirable_shape}
  def normalize(receipt, opts \\ [])

  # GL-3 `Smalt.Powl2.Andon` receipt: facts already present.
  def normalize(%{rule_id: r, diagnostic: d, context_digest: dg} = receipt, opts)
      when is_map_key(receipt, :agent_message) and is_map_key(receipt, :repair_hint) do
    {:ok,
     %{
       code: @andon_code,
       rule_id: to_string(r),
       diagnostic: to_string(d),
       agent_message: to_string(Map.fetch!(receipt, :agent_message)),
       repair_hint: to_string(Map.fetch!(receipt, :repair_hint)),
       context_digest: dg,
       session: to_string(Map.get(receipt, :session, default_session(opts))),
       ts: Map.get(receipt, :ts, System.system_time(:nanosecond))
     }}
  end

  # GL-1 executor DETS andon receipt: carries shape_id + at_ms.
  def normalize(%{shape_id: shape, rule_id: r, diagnostic: d, at_ms: at_ms}, opts)
      when is_integer(at_ms) do
    rule = to_string(r)
    diag = to_string(d)
    hint = generic_hint(rule)

    {:ok,
     %{
       code: @andon_code,
       rule_id: rule,
       diagnostic: diag,
       agent_message: Andon.agent_message(rule, diag, hint),
       repair_hint: hint,
       context_digest: sha256_hex({shape, r, d, at_ms}),
       session: default_session(opts),
       ts: at_ms,
       shape_id: to_string(shape)
     }}
  end

  # GL-1 executor andon tuple {:powl2_andon, id, rule_id, diagnostic}.
  def normalize({:powl2_andon, id, r, d}, opts) do
    rule = to_string(r)
    diag = to_string(d)
    hint = generic_hint(rule)

    {:ok,
     %{
       code: @andon_code,
       rule_id: rule,
       diagnostic: diag,
       agent_message: Andon.agent_message(rule, diag, hint),
       repair_hint: hint,
       context_digest: sha256_hex({:powl2_andon, id, r, d}),
       session: default_session(opts),
       ts: System.system_time(:nanosecond),
       instance_id: to_string(id)
     }}
  end

  def normalize(_other, _opts), do: {:error, :unwirable_shape}

  @doc """
  HTTP JSON envelope: `%{status: 422, headers, content_type, body}` (GL-CONF
  refinement, GRAPHLAW-SPEC §GL-8: the `x-ms-error-code: BusinessLawViolation`
  header face) plus the GL-3 JSON-LD refusal receipt riding the error map as
  a decode-able `json_ld` string. Fails closed on non-ANDON shapes with
  `{:error, :unwirable_shape}`.
  """
  @spec http_envelope(term(), keyword()) :: map() | {:error, :unwirable_shape}
  def http_envelope(receipt, opts \\ []) do
    case normalize(receipt, opts) do
      {:ok, wr} ->
        %{
          status: @http_status,
          headers: [{"x-ms-error-code", "BusinessLawViolation"}],
          content_type: @content_type <> "; charset=utf-8",
          body: Jason.encode!(%{"error" => error_map(wr)})
        }

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  AMQP application-properties shape: `%{body, content_type, content_encoding,
  application_properties, message_annotations, andon_ts_long}`. Body is
  byte-identical to the HTTP envelope body; `ts` is a binary AMQP long.
  """
  @spec amqp_properties(term(), keyword()) :: map() | {:error, :unwirable_shape}
  def amqp_properties(receipt, opts \\ []) do
    case normalize(receipt, opts) do
      {:ok, wr} ->
        props =
          %{
            "andon.code" => wr.code,
            "andon.rule_id" => wr.rule_id,
            "andon.diagnostic" => wr.diagnostic,
            "andon.agent_message" => wr.agent_message,
            "andon.repair_hint" => wr.repair_hint,
            "andon.context_digest" => wr.context_digest,
            "andon.session" => wr.session
          }
          |> maybe_put("andon.shape_id", Map.get(wr, :shape_id))
          |> maybe_put("andon.instance_id", Map.get(wr, :instance_id))

        %{
          body: Jason.encode!(%{"error" => error_map(wr)}),
          content_type: @content_type,
          content_encoding: "utf-8",
          application_properties: props,
          message_annotations: %{"x-opt-andon" => true},
          andon_ts_long: <<wr.ts::signed-size(64)>>
        }

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---- internals ----

  defp error_map(wr) do
    # GAP-6a: the wire face carries the same neutral agent id the receipt
    # would default to (session-derived, domain-blind); a wire receipt that
    # already carries :agent keeps its own.
    agent = Map.get(wr, :agent) || "urn:smalt:agent:#{wr.session}"

    json_ld =
      Andon.json_ld(%{
        rule_id: wr.rule_id,
        diagnostic: wr.diagnostic,
        session: wr.session,
        ts: wr.ts,
        context_digest: wr.context_digest,
        agent: agent
      })

    %{
      "code" => wr.code,
      "rule_id" => wr.rule_id,
      "diagnostic" => wr.diagnostic,
      "agent_message" => wr.agent_message,
      "repair_hint" => wr.repair_hint,
      "context_digest" => wr.context_digest,
      "session" => wr.session,
      "ts" => wr.ts
    }
    |> maybe_put("shape_id", Map.get(wr, :shape_id))
    |> maybe_put("instance_id", Map.get(wr, :instance_id))
    |> Map.put("json_ld", json_ld)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp generic_hint(rule), do: "correct the " <> rule <> " violation in the plan, then resubmit"

  defp sha256_hex(term),
    do: Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(term)), case: :lower)

  defp default_session(opts), do: to_string(Keyword.get(opts, :session, node()))
end
