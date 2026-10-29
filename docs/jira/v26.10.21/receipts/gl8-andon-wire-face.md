# GL-8 — ANDON Wire Face (`Smalt.Powl2.AndonWire`)

**Standing:** PARTIAL_ALIVE
Context: full
Date: 2026-10-21
Lane: GL-8, build root `_build-gl8`, repo `/Users/sac/smalt`

## Module

`/Users/sac/smalt/lib/smalt/powl2/andon_wire.ex` — `Smalt.Powl2.AndonWire`

Serializes a typed ANDON refusal into shapes non-BEAM agents consume. Both
faces derive from one `normalize/2` step, so the HTTP and AMQP faces cannot
disagree about the facts of a refusal:

- **HTTP JSON envelope** — `http_envelope/2` → `%{status: 422,
  content_type: "application/json; charset=utf-8", body}` where body is
  `{"error": {...}}`, `code: "GraphlawRefusal"`.
  **Status pinion (documented)**: 422 Unprocessable Content — well-formed
  syntax, law-rejected content; distinguishable from 400 (syntax), 403
  (principal), 409 (peer state); the request becomes processable once the
  named rule is satisfied, which is the repair-hint contract. The
  `{"error": {...}}` shape follows the smalt ARM-gateway error convention.
- **AMQP application-properties shape** — `amqp_properties/2` →
  `%{body, content_type, content_encoding, application_properties,
  message_annotations, andon_ts_long}`; `andon.code = "GraphlawRefusal"`
  plus flat `andon.*` string keys; `ts` additionally rides `andon_ts_long`
  as a binary AMQP long (typed, not inspect-string). Body byte-identical to
  the HTTP body.

`normalize/2` accepts the three real producers' shapes: the GL-3
`Smalt.Powl2.Andon` receipt, the GL-1 executor andon tuple
`{:powl2_andon, id, rule_id, diagnostic}` (digest over the tuple — commits
to refusal identity), and the GL-1 DETS receipt `%{shape_id, rule_id,
diagnostic, at_ms}`. Unknown shapes fail closed `{:error, :unwirable_shape}`.

A second GL-8-dispatched lane converged onto this module mid-session
(disclosed collision, same-checkout fan-out rule: single writer per file —
this lane owns the file at receipt time); the union embeds the GL-3
`json_ld` string inside the error object (`error.json_ld`) so the
JSON-LD/`x-ms-error-code: BusinessLawViolation` design also has a home.

## Courts

`/Users/sac/smalt/test/internal/powl2_andon_wire_court.exs` — Chicago court
(6 tests): envelope facts from a real GL-3 receipt, AMQP typed long
round-trip + byte-identical body, tuple/DETS normalization with
identity-committed digests (distinct violations never share digests),
fail-closed on unknown shapes, and the wire witness.

Wire witness: a real Bandit HTTP server (kernel-assigned port via
`ThousandIsland.listener_info/1`) serving a guarded mini-route that runs a
real GL-1-guarded transition (law guard: `risk_officer_signature`).
Violating proposal (unsigned) → real HTTP 422 with the ANDON envelope on
the wire and the guarded op provably never ran (store unchanged); conforming
proposal → 200 `{"status":"completed"}` and the op ran.

```
$ MIX_BUILD_ROOT=_build-gl8 mix test test/internal/powl2_andon_wire_court.exs \
    test/internal/powl2_andon_court.exs
Result: 14 passed
```

### Wire output (real, captured via `mix run --no-start`)

```
HTTP 422 application/json; charset=utf-8
{"error":{"agent_message":"[ANDON risk_officer_signature] missing Risk Officer signature for Order #8921 — repair: obtain the Risk Officer signature on the plan, then resubmit","code":"GraphlawRefusal","context_digest":"65b96dac1a11e7d3dd7177dc82565f4001a5083d2526419385f58b66412dfeca","diagnostic":"missing Risk Officer signature for Order #8921","json_ld":"{\"@context\":[\"https://www.w3.org/ns/prov.jsonld\",...],...}","repair_hint":"obtain the Risk Officer signature on the plan, then resubmit","rule_id":"risk_officer_signature","session":"gl8@node","ts":1760000000000000000}}

AMQP app-props: %{"andon.agent_message" => "[ANDON risk_officer_signature] ...", "andon.code" => "GraphlawRefusal",
  "andon.context_digest" => "65b96dac...", "andon.diagnostic" => "missing Risk Officer signature for Order #8921",
  "andon.repair_hint" => "obtain the Risk Officer signature on the plan, then resubmit",
  "andon.rule_id" => "risk_officer_signature", "andon.session" => "gl8@node"}
AMQP ts decoded: 1760000000000000000
```

## Honest failure notes (pre-existing / other-lane, disclosed)

- `test/integration/graphlaw_skeptic_court.exs` (GL lane-owned, untracked,
  was itself mid-rewrite during this session — `guarded_node/2` compile
  error at receipt time): 3 of its C4 legs pin the rival envelope design
  (`http_envelope/1` byte-for-byte json_ld body + `x-ms-error-code` header;
  `http_envelope/4` convenience returning json-ld body; FINDING leg
  expecting untyped FunctionClauseError). These contradict the fullstack
  court's GL-8 legs, which pin THIS module's envelope. Coordinator
  adjudication item; not adjudicated by this lane.
- `graphlaw_fullstack_court.exs` GL-8 legs could not be exercised to green:
  the court fails EARLIER at a SHACL rule_id prefix assert
  (`"HighValueOrderShape/maxInclusive/totalAmount"` vs
  `"ex:HighValueOrderShape/..."`, line 83) — GL-4/5 SHACL surface, not this
  module. The court's AndonWire assertions (lines 135-150) match this
  module's shape exactly (verified by reading).
- Two shared-compile freezes from other lanes' in-flight edits
  (`cosmos_query_metrics.ex` bare `is_integer/3`, `wasm/worker.ex`
  `catch_exit/1`) were polled out (never edited by this lane).

## Falsifier status

- Wire witness is the falsifier: violating → 422 + untouched store;
  conforming → 200 + mutation. Both witnessed on real HTTP.
- Distinct-refusal digest separation is court-pinned.

## Replay

```
cd /Users/sac/smalt
export PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$HOME/.asdf/installs/erlang/29.1.2/bin:$PATH"
MIX_BUILD_ROOT=_build-gl8 mix test test/internal/powl2_andon_wire_court.exs
MIX_BUILD_ROOT=_build-gl8 mix run --no-start -e 'r = Smalt.Powl2.Andon.format_andon("risk_officer_signature", "missing Risk Officer signature for Order #8921", %{order: "8921"}, ts: 1_760_000_000_000_000_000, session: "gl8@node"); IO.puts(Smalt.Powl2.AndonWire.http_envelope(r).body)'
```
