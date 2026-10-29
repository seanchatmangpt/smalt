defmodule Smalt.Powl2.Andon do
  @moduledoc """
  ANDON diagnostic receipt for a refused POWL2 rule evaluation.

  When a rule fires a refusal (e.g. "Missing Risk Officer signature for Order
  #8921"), `format_andon/4` mints a typed receipt map:

    * `rule_id` — the violated rule
    * `diagnostic` — caller-supplied message naming the exact violation
    * `agent_message` — one-line agent-consumable string carrying the rule id
      and a repair hint (an agent can read the receipt without the surrounding
      plan context and know what to fix)
    * `context_digest` — `sha256(term_to_binary(context_snapshot))`, hex — the
      same hash law as `Smalt.PPlan.ReceiptEngine.record_step/2`'s `delta_hash`
      (`ts` excluded from nothing here: the snapshot IS the bound context, so
      the digest commits to it byte-for-byte at the term level)
    * `ts` — nanosecond timestamp (injectable for replay stability)
    * `session` — session id (defaults to the current node, injectable)

  ## PROV-O N-Triples

  `ntriples/1` serializes the receipt as a `prov:Entity` that is
  `prov:wasInvalidatedBy` the refused activity (the rule evaluation that
  produced the refusal invalidates any downstream claim on the plan), with the
  context digest as an `xsd:hexBinary` `prov:value` — the same vocabulary and
  IRI conventions as `Smalt.PPlan.ReceiptEngine`'s seal serialization.

  ## PROV-O Agent chain (GAP-6a)

  Every refusal leaf names a responsible agent: a neutral, domain-blind
  `urn:smalt:agent:<session>` IRI (override with the `:agent` opt), typed
  `prov:Agent`, with `prov:wasAssociatedWith` (Activity→Agent) and
  `prov:wasAttributedTo` (Entity→Agent) edges. `verify_ntriples/1` fails
  closed on any leaf missing any chain term.
  """

  @typedoc "ANDON receipt (typed)."
  @type t :: %{
          required(:rule_id) => String.t(),
          required(:diagnostic) => String.t(),
          required(:agent_message) => String.t(),
          required(:repair_hint) => String.t(),
          required(:context_digest) => String.t(),
          required(:ts) => integer(),
          required(:session) => String.t(),
          required(:agent) => String.t(),
          required(:json_ld) => String.t()
        }

  @prov "http://www.w3.org/ns/prov#"
  @rdf_type "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
  @xsd_hex "http://www.w3.org/2001/XMLSchema#hexBinary"
  @xsd_string "http://www.w3.org/2001/XMLSchema#string"

  @doc """
  Formats an ANDON diagnostic receipt. `context_snapshot` is any term (usually
  the plan/order map at refusal time); it is bound by digest, not stored.

  Opts:

    * `:ts` — nanosecond timestamp (default `System.system_time/1`); inject a
      fixed value for replay-stable receipts
    * `:session` — session id (default current node inspect)
    * `:agent` — responsible-agent IRI (default `urn:smalt:agent:<session>`;
      a neutral, domain-blind operator/agent id from the refusal context)
    * `:repair_hint` — override the default hint derived from `rule_id`
  """
  @spec format_andon(String.t(), String.t(), term(), keyword()) :: t()
  def format_andon(rule_id, diagnostic, context_snapshot, opts \\ [])
      when is_binary(rule_id) and is_binary(diagnostic) and is_list(opts) do
    context_digest = hex(:crypto.hash(:sha256, :erlang.term_to_binary(context_snapshot)))
    ts = Keyword.get(opts, :ts, System.system_time(:nanosecond))
    session = Keyword.get(opts, :session, to_string(node()))
    agent = Keyword.get(opts, :agent, "urn:smalt:agent:#{session}")
    repair_hint = Keyword.get(opts, :repair_hint, default_repair_hint(rule_id))

    receipt = %{
      rule_id: rule_id,
      diagnostic: diagnostic,
      repair_hint: repair_hint,
      agent_message: agent_message(rule_id, diagnostic, repair_hint),
      context_digest: context_digest,
      ts: ts,
      session: session,
      agent: agent
    }

    Map.put(receipt, :json_ld, json_ld(receipt, Keyword.get(opts, :repair_action)))
  end

  @doc """
  Public repair-hint derivation by rule id (the GL-8 wire face needs the hint
  without the full receipt; same law as the receipt's default hint).
  """
  @spec repair_hint(String.t()) :: String.t()
  def repair_hint(rule_id), do: default_repair_hint(rule_id)

  @doc """
  Agent-consumable one-line diagnostic: carries the rule id and the repair
  hint so an agent reading only this string knows which rule to satisfy and
  how.
  """
  @spec agent_message(String.t(), String.t(), String.t()) :: String.t()
  def agent_message(rule_id, diagnostic, repair_hint) do
    "[ANDON #{rule_id}] #{diagnostic} — repair: #{repair_hint}"
  end

  @doc """
  GL-3 JSON-LD serialization (GRAPHLAW-SPEC §GL-3): the refusal as an
  `andon:RefusalReceipt` JSON-LD node, `@context` binding the `andon:` prefix
  over the PROV-O context, all spec-required fields present
  (@type/failedConstraint/repair action are the GL-3 falsifier's musts).

  `repair_action_override` (nil = default) pins `andon:suggestedRepairAction`.
  """
  @spec json_ld(t() | map(), String.t() | nil) :: String.t()
  def json_ld(receipt, repair_action_override \\ nil) when is_map(receipt) do
    ld = %{
      "@context" => [
        "https://www.w3.org/ns/prov.jsonld",
        %{"andon" => "https://smalt.io/ontology/andon#"}
      ],
      "@type" => "andon:RefusalReceipt",
      "andon:refusalId" => "urn:smalt:andon:#{receipt.session}:#{receipt.rule_id}:#{receipt.context_digest}",
      "andon:violatingActivity" => "urn:smalt:act:#{receipt.session}:#{receipt.rule_id}",
      "andon:failedConstraint" => receipt.rule_id,
      "andon:shapeClass" => shape_class(receipt.rule_id),
      "andon:detail" => receipt.diagnostic,
      "andon:suggestedRepairAction" => repair_action_override || "urn:smalt:action:repair_#{slug(receipt.rule_id)}",
      "prov:atTime" => iso8601(receipt.ts),
      "prov:wasInvalidatedBy" => "urn:smalt:actor:#{receipt.session}",
      "prov:wasAssociatedWith" => receipt.agent,
      "prov:wasAttributedTo" => receipt.agent,
      "andon:agent" => %{"@id" => receipt.agent, "@type" => "prov:Agent"}
    }

    Jason.encode!(ld)
  end

  @doc """
  PROV-O N-Triples serialization: the receipt is a `prov:Entity` invalidated by
  the refused activity. Digest binds the context (`prov:value` hexBinary);
  diagnostic + agent message ride as string literals so the triple block is
  self-contained. The full Activity/Entity/Agent chain is always present:
  the responsible agent is typed `prov:Agent` with `prov:wasAssociatedWith`
  (Activity→Agent) and `prov:wasAttributedTo` (Entity→Agent) edges.
  """
  @spec ntriples(t()) :: String.t()
  def ntriples(%{rule_id: rule_id, context_digest: digest, agent: agent} = receipt) do
    entity = "<urn:smalt:andon:#{receipt.session}:#{rule_id}:#{digest}>"
    activity = "<urn:smalt:act:#{receipt.session}:#{rule_id}>"
    agent_iri = "<#{agent}>"

    lines = [
      iri_line(entity, "<" <> @rdf_type <> ">", "<" <> @prov <> "Entity>"),
      iri_line(activity, "<" <> @rdf_type <> ">", "<" <> @prov <> "Activity>"),
      iri_line(agent_iri, "<" <> @rdf_type <> ">", "<" <> @prov <> "Agent>"),
      iri_line(entity, "<" <> @prov <> "wasInvalidatedBy>", activity),
      iri_line(activity, "<" <> @prov <> "wasAssociatedWith>", agent_iri),
      iri_line(entity, "<" <> @prov <> "wasAttributedTo>", agent_iri),
      lit_line(entity, "<" <> @prov <> "value>", ~s("#{digest}"^^<#{@xsd_hex}>)),
      lit_line(entity, "<" <> @prov <> "endedAtTime>",
        ~s("#{iso8601(receipt.ts)}"^^<http://www.w3.org/2001/XMLSchema#dateTime>)),
      lit_line(entity, "<" <> @prov <> "value>", ~s("#{escape(receipt.diagnostic)}"^^<#{@xsd_string}>)),
      lit_line(entity, "<" <> @prov <> "value>", ~s("#{escape(receipt.agent_message)}"^^<#{@xsd_string}>))
    ]

    Enum.join(lines, "\n")
  end

  @doc """
  Fail-closed chain verifier over an emitted N-Triples leaf: `:ok` only when
  the block carries the full Entity/Activity/Agent chain (all three type
  triples plus `wasInvalidatedBy`, `wasAssociatedWith`, `wasAttributedTo`).
  Any missing term returns `{:error, missing_terms}` — a leaf that dropped
  the Agent chain is refused downstream, never silently admitted.
  """
  @spec verify_ntriples(String.t()) :: :ok | {:error, [String.t()]}
  def verify_ntriples(nt) when is_binary(nt) do
    required = [
      ~s(<http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/ns/prov#Entity> .),
      ~s(<http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/ns/prov#Activity> .),
      ~s(<http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/ns/prov#Agent> .),
      "<" <> @prov <> "wasInvalidatedBy>",
      "<" <> @prov <> "wasAssociatedWith>",
      "<" <> @prov <> "wasAttributedTo>"
    ]

    missing = Enum.reject(required, &String.contains?(nt, &1))
    if missing == [], do: :ok, else: {:error, missing}
  end

  # ---- internals ----

  # Known-rule repair hints; unknown rules get the generic re-admission hint.
  defp default_repair_hint("risk_officer_signature"),
    do: "obtain the Risk Officer signature on the plan, then resubmit"

  defp default_repair_hint("order_capacity"),
    do: "reduce the order size or split it across ticks, then resubmit"

  defp default_repair_hint(rule_id),
    do: "correct the #{rule_id} violation in the plan, then resubmit"

  defp iso8601(ns) when is_integer(ns) do
    ns
    |> DateTime.from_unix(:nanosecond)
    |> case do
      {:ok, dt} -> dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      # Out-of-range injectable ts: keep the raw integer rather than crash.
      {:error, _} -> Integer.to_string(ns)
    end
  end

  defp escape(binary), do: String.replace(binary, "\"", "\\\"")

  defp iri_line(subj, pred, obj_iri), do: subj <> " " <> pred <> " " <> obj_iri <> " ."

  defp lit_line(subj, pred, literal), do: subj <> " " <> pred <> " " <> literal <> " ."

  # shapeClass derived from LawCompiler rule ids ("Shape/class/path");
  # unknown shapes degrade to the generic class, never crash.
  defp shape_class(rule_id) do
    case String.split(rule_id, "/") do
      [_shape, class, _path] -> class
      _ -> "RuleViolation"
    
    end
  end

  defp slug(bin), do: String.replace(bin, "/", "_")

  defp hex(bin), do: Base.encode16(bin, case: :lower)
end
