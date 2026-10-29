# Tier-2 Scout: Event Grid Routing, DTDL, KQL over Sealed Segments

Standing: PARTIAL_ALIVE (scout only — design grounded, zero implementation, nothing committed).
Context: solo. Date: 2026-10-22.

All paths verified on disk at HEAD 7b64d3c (working tree). Modules read:
`lib/smalt/event_grid_webhook.ex` (in full),
`lib/smalt/data_plane/kql.ex` (in full),
`lib/smalt/webpubsub/events.ex`,
`lib/smalt/powl2/law_compiler.ex` (modoc + constraint types),
`lib/smalt/messaging/event_grid.ex` (doc-surface grep: publish/subscribe, CloudEvent + EventGrid schemas, retry policy, DLQ),
`lib/smalt/security/ledger_writer.ex` (append path: serialized Merkle-chain GenServer),
`mix.exs` deps block.

---

## 1. Event Grid push-style routing (A-5)

### Landed (verified)

- `Smalt.EventGridWebhook` + `EventGridWebhookPlug`
  (`lib/smalt/event_grid_webhook.ex`) — full RECEIVER face: both validation
  handshakes (CORS-style `WebHook-Request-Origin` and inline
  `Microsoft.EventGrid.SubscriptionValidationEvent`), CloudEvents 1.0
  mandatory-attribute validation, per-subscriber delivery records (ring cap
  1000), `aeg-*` delivery metadata, mountable plug (not mounted), zero-auth
  path class.
- `Smalt.Messaging.EventGrid` (`lib/smalt/messaging/event_grid.ex`) —
  PUBLISH face: `publish/2` with seen-id dedup, `subscribe/4` with retry
  policy (max_delivery_attempts 1..30, event_time_to_live), DLQ + telemetry,
  both `:cloud_event_schema` and `:event_grid_schema` envelopes.
- `Smalt.WebPubSub.Events` (`lib/smalt/webpubsub/events.ex`) — binary-mode
  `ce-*` CloudEvents emission, loopback fail-closed host check (KD-166
  adjacent).
- Air-gap law: push-to-remote is banned; delivery is in-process/loopback
  only. This divergence is already registered in the webhook modoc.

### Delta for full push-style routing (subscriptions as SHACL node shapes in WAL frames)

Today a subscription is a `{name → pid}` registry entry (webhook) or
`subscribe/4` opts (messaging). The delta is making the subscription FILTER
a first-class, durable, receipted object:

1. **Filter predicate layer** (cost S): wire `LawCompiler.compile_shape/2`
   (`lib/smalt/powl2/law_compiler.ex`) into the subscription record. Each
   subscription declares a SHACL node shape over the CloudEvent envelope
   (`sh:path type` + `sh:in (...)` on event types, `sh:maxInclusive` on
   delivery-count, `sh:not [ ... ]` for negation). `compile_all/1` gives a
   guard table; the delivery core checks `guard_fun.(event)` before
   delivery. Azure filter kinds map: `Is In` → `sh:in`; `Is Not In` →
   `sh:not` + `sh:in`; `Number In`/range → maxInclusive-style numeric
   class. Missing piece: string filters (`String Begins With` / `Ends
   With` / `Contains`) need a new **pattern/startsWith constraint class**
   in LawCompiler (cost M).
2. **Durability via ledger frames** (the "WAL"): the substrate's WAL analog
   is the Confidential Ledger Merkle chain
   (`Smalt.Security.LedgerWriter.append/3` — single-writer GenServer, dedup,
   prev-hash chaining). Each subscription mutation (create/update/delete of
   a SHACL-backed subscription) appends `{op, subscription,
   shape_ttl_sha256}`; replay = fold the chain. Reuses ledger_writer
   serialization discipline + sha256 receipts. Cost M.
3. Remaining honest divergence: remote webhook push stays banned (air-gap).

Landing cost overall: **M** (filter predicates S + pattern class M + ledger
durability M).

Modules reused: LawCompiler (powl2), LedgerWriter (security),
EventGridWebhook delivery core, Messaging.EventGrid publish face/DLQ,
WebPubSub.Events ce-* header discipline, GraphLaw.Validator.ShapeFile
(canonical Turtle tokenizer).

Falsifier: (a) a subscription whose shape refuses event E
(guard_fun → `{:violation, _, _}`) still receives E — routing not enforced
at the delivery core; (b) a subscription create/update/delete lands in the
ring buffer but produces no ledger append — no WAL frame; (c) after
replaying the chain, the reconstructed subscription set differs from the
pre-restart set. A court that passes with unrouted delivery or frame-less
mutations is VACUOUS.

---

## 2. DTDL (A-6) — DTDL→RDF/SHACL

### Critical grounding finding: there is no RDF library in the tree

`mix.exs` deps: bandit, plug, cors_plug, jason, joken, ash (+ash_graphlaw
path), ash_r2rml (path), ash_ex4pm, ex4pm, ggen_igniter (path),
stream_data, sobelow, recon, wasmex. **No RDF.ex, no SPARQL.ex, no JSON-LD
parser, no full Turtle parser.** The "landed RDF stack" is two hand-rolled
Turtle tokenizers in the same token discipline:

- `Smalt.GraphLaw.Validator.ShapeFile.parse!/2` — canonical shape-Turtle
  tokenizer (quote-aware comments, prefixed names, IRIs, literals), keyword
  set pinned to `sh:path/minCount/maxCount/datatype/message`, raises by
  design on anything else.
- `Smalt.POWL2.LawCompiler`'s own tokenizer — five constraint classes
  (maxInclusive, minCount, notEquals, sh:not, sh:in).

Both are statement-oriented keyword parsers, not graph stores: no triple
store, no SPARQL, no JSON-LD. DTDL v3 documents are JSON-LD
(`@context dtmi:dtdl:context;3`), so **JSON-LD parsing is the first-class
gap**; Turtle support exists only as keyword-limited statement parsing.

### Probe result and disclosed flaw

I attempted to inline a 3-node DTDL probe model (Thermostat Interface with a
Telemetry node `schema: double` and a Relationship node) and produced
malformed JSON twice mid-draft. Disclosed; the probe model is trivial to
author correctly at implementation time, and the scout verdict below does
not rest on the inline sample. Verdict: the landed stack **cannot parse
DTDL today** — a DTDL JSON-LD document fed to either tokenizer fails with a
typed refusal (not JSON grammar). The path is: Jason decode (already a dep)
→ mechanical DTDL-term → SHACL-term projection → emit shape Turtle →
LawCompiler.compile_all/1 → guards; twin instances (JSON patch documents)
validate against the compiled guards.

### DTDL → RDF/SHACL mapping (spec-grounded)

| DTDL | RDF/SHACL | Notes |
|---|---|---|
| `@id dtmi:ns:Model;1` | `<dtmi:ns:Model;1>` IRI | dtmi IRIs contain `;` — must be `<...>`-quoted in Turtle, never a prefixed local name |
| `@type Interface` | `a dtdl:Interface` + NodeShape target | |
| `contents` Telemetry/Property/Command nodes | `sh:property` blocks | one property shape per content node |
| `schema: double` (telemetry/property) | `sh:datatype xsd:double` | **new constraint class needed** — sh:datatype is not among LawCompiler's five |
| Relationship `target: dtmi:...;1` | `sh:class` / `sh:node` on the edge's object | relationship = typed edge to an Interface-typed node |
| Relationship `minMultiplicity`/`maxMultiplicity` | `sh:minCount`/`sh:maxCount` | direct |
| `extends` (interface inheritance) | `sh:node` chaining | shape chaining = inheritance |

Twin lifecycle (create/update/delete of twins + relationships) rides the
existing item-CRUD discipline (`data_plane/cosmos.ex` family) with a
QueueStore-pattern GenServer store like EventGridWebhook's — no new infra
class.

Landing cost: **M** overall — (1) sh:datatype constraint class (S),
(2) JSON-LD→Turtle projection, mechanical Jason decode + term mapping,
dtmi IRIs `<...>`-quoted (S/M), (3) twin store face (M, reuses QueueStore
pattern + cosmos item-CRUD discipline).

Modules reused: LawCompiler (+sh:datatype), GraphLaw.Validator.ShapeFile
(tokenizer, keyword-set extension), data_plane cosmos item-CRUD discipline,
receipt/vc_export standing.

Falsifier: a 3-node DTDL model (Interface + Telemetry `schema: double` +
Relationship) projected to SHACL Turtle must compile via
LawCompiler.compile_all/1 into guards, and a twin payload violating the
telemetry datatype must yield `{:violation, _, _}` while a conforming
payload yields `:ok`. A court that admits a datatype-violating twin, or a
projection that cannot express the mapping table row-for-row, fails.

---

## 3. KQL over sealed segments (A-7)

### Landed (verified from lib/smalt/data_plane/kql.ex, read in full)

Operators present: `where` with `==, =~, !=, contains, startswith,
endswith, has, >, <, >=, <=, between (a..b)`; `take N` (cap 1000);
`sort by` / `order by C [asc|desc] [nulls first|last]`; `project`
(aliases + arithmetic scalar exprs); `extend`; `summarize
count/sum/avg/min/max [by K1, K2]`. Scalar functions: `ago(dur)`, `now()`,
`datetime("iso")`, `+ - * /`. Typed SYN0002–SYN0005 positional parse
errors; fail-closed on unknown operators/functions/aggregates; pure
`run/2` over row maps; time anchored once per run.

### Missing operators, ranked by value for sealed-segment analytics

| rank | operator | value | cost | note |
|---|---|---|---|---|
| 1 | `bin()` scalar fn | highest | S/M | time binning (`bin(TimeGenerated, 1h)`) for `summarize by` — sealed-segment analytics is time-first; today `bin` is SYN0004 unknown-function. Reuses the existing duration grammar + per-run time anchor |
| 2 | `countif` / `sumif` conditional aggregates | high | S/M | Sentinel detections are countif-shaped; directly reuses the where-clause predicate evaluator `eval/3` per group |
| 3 | `in` / `in~` list membership | high | S | parser map entry + eval clause |
| 4 | `dcount` aggregate | medium-high | M | distinct-set per group (MapSet per group) |
| 5 | `mv-expand` | medium | M | first 1:N stage — the pipeline reduce currently assumes 1:1 row flow, so this is a stage-contract change |
| 6 | `join` / `lookup` | lower | M/L | sealed segments are self-contained; cross-segment joins are rarer |
| 7 | `render`, `.show` management commands | skip | — | no UI, no cluster |

Modules reused: `kql.ex` itself (lexer/parser/eval all internal), Sentinel
plane column typing, test-budget/stress tiers for the new parser surface.

Falsifier: `where TimeGenerated > ago(1h) | summarize count_ by
bin(TimeGenerated, 1h)` on a sealed segment must return one row per hour
bucket (not SYN0004), and each new operator added to the accepted set must
have a negative fixture — an unknown-operator query still fails typed
(fail-closed ratchet holds). A gate that accepts `bin(` without
registering it is VACUOUS.

---

## Cross-cutting: shared seam

A-5 and A-6 share one seam: **LawCompiler constraint-class extension**
(A-5 needs a pattern/startsWith class; A-6 needs sh:datatype). One landing
closes both. KQL additions are independent (kql.ex parser/eval additions;
existing budget/stress tiers apply).

## Standing

- A-5 Event Grid routing: PARTIAL_ALIVE → ALIVE requires string-filter
  constraint class + ledger-frame durability + routing enforced at the
  delivery core.
- A-6 DTDL: UNKNOWN until the JSON-LD→Turtle projection + sh:datatype
  class land (mapping table is spec-grounded but unprobed; no RDF/JSON-LD
  library exists in the tree — disclosed above).
- A-7 KQL: engine ALIVE for the landed operator set (Sentinel/ResourceGraph
  faces landed and gated); `bin()`/`countif`/`in`/`dcount`/`mv-expand`
  gaps named and ranked above.
