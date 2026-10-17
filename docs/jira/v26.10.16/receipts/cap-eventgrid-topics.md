# Receipt: cap-eventgrid-topics — ARM Event Grid topics + systemTopics, inputSchema-gated EG1 admission

- **Lane**: EventGrid-topics (cap lane)
- **Standing**: PARTIAL_ALIVE
- **Subject**: `lib/smalt` egress data plane — `Microsoft.EventGrid/topics` and
  `Microsoft.EventGrid/systemTopics` ARM CRUD; per-topic `inputSchema` gate on
  EG1 (native Event Grid schema) ingest.
- **Date**: 2026-10-16

## Scope landed

1. **ARM CRUD, topics + systemTopics**: PUT/GET/LIST lifecycle for
   `Microsoft.EventGrid/topics` and `.../systemTopics` under
   `/subscriptions/:sub/resourceGroups/:rg/providers/Microsoft.EventGrid/...`,
   stored in the dedicated `:smalt_eg_topics` table
   (`{name, location, endpoint (loopback ingest URL), inputSchema}` —
   `CloudEvents` default | `EventGrid`).
2. **inputSchema-gated EG1 admission**: a topic explicitly declared
   `inputSchema: "EventGrid"` at PUT admits the native EG1 event envelope
   (`eg1_publish/2`) with the real-Event-Grid wire form — **200 + empty body**.
   Un-declared / `CloudEvents`-schema topics keep the existing typed refusal
   `400 InvalidCloudEvent` for the same EG1 envelope.
3. **Typed refusals**: invalid `properties.inputSchema` value (e.g. `"Fancy"`)
   → `400 InvalidResourceShape` (typed); EG1 envelope on an un-declared topic
   → `400 InvalidCloudEvent` (typed). Merged GET readback
   (`.../providers/Microsoft.EventGrid/topics/:name?api-version=...` /
   getById binding) returns the stored record including the declared
   `inputSchema`.
4. **8 wire fences**: `test/eventgrid_topics_arm_test.exs` (9 test blocks on
   disk; 8 wire fences across topics CRUD, systemTopics mirror lifecycle,
   inputSchema validation, EG1 admit/refuse flip on the declared bit, merged
   readback).

## GAP status: narrowed, NOT closed

`GAP(eventgrid-eg1-schema-absent)` in `docs/WIRE_PARITY.md` **stays OPEN** —
the token remains on disk for (a) un-declared topics and (b)
system-topics-as-source event ingest (system-topic ARM CRUD landed;
system-topic-sourced event ingest did not).

**Annotation verified on disk** at `docs/WIRE_PARITY.md:123` (Event Grid
ingest row) — the "narrowed 2026-10-16 (EventGrid-topics lane)" text is
present verbatim, including the OPEN-token clause. No edit was required.

## Census tuple context note

`{400, "InvalidResourceShape"}` is a registered corpus row in
`test/arm_error_corpus_test.exs`. Context for the census reader: the corpus
rows at lines 106/123/152/169/186 exercise the **ARM shape-validation
refusal** (`target AshGraphLaw.Enforcement`) — shape-invalid PUT, multi-issue
`error.details` rows, details-absent refusals. The EventGrid-topics lane
reuses the same error code for the `inputSchema` grammar fence
(`test/eventgrid_topics_arm_test.exs:155`, `"invalid inputSchema value is a
typed 400 InvalidResourceShape"`); it is the same registered code, not a new
corpus row. Census prose counts may lag the table — the table is ground truth.

## Evidence (real command output, DoD lane — no build/test runs)

```
$ grep -n 'corpus: "InvalidResourceShape' /Users/sac/smalt/test/arm_error_corpus_test.exs && echo '---' && grep -c '  test "' /Users/sac/smalt/test/eventgrid_topics_arm_test.exs && echo '---' && grep -n 'GAP(eventgrid-eg1-schema-absent)' /Users/sac/smalt/docs/WIRE_PARITY.md
106:    @tag corpus: "InvalidResourceShape-shape-invalid"
123:    @tag corpus: "InvalidResourceShape-details-multi-issue"
152:    @tag corpus: "InvalidResourceShape-details-absent-refused"
169:    @tag corpus: "InvalidResourceShape-details-absent-valid"
186:    @tag corpus: "InvalidResourceShape-unadmitted"
---
9
---
123:| Event Grid ingest | ... GAP(eventgrid-eg1-schema-absent) — **narrowed 2026-10-16 (EventGrid-topics lane)**: native Event Grid schema (EG1) ingest is now admitted **for ARM topics explicitly declared `inputSchema: "EventGrid"`** ... the GAP token stays OPEN for undeclared topics and system-topics-as-source events (system-topic ARM CRUD landed, system-topic-sourced event ingest not) | ALIVE (partially narrowed) | ...
```

Test file census (`grep -c '  test "' test/eventgrid_topics_arm_test.exs` → 9
blocks; wire fence inventory at lines 93/99/109/130/155/176/261/316/345):
topics PUT/GET merged readback carrying declared `inputSchema`, systemTopics
mirror lifecycle, typed `InvalidResourceShape` on bad schema, EG1 admit
(200 + empty) vs `InvalidCloudEvent` refusal flip keyed on the declared bit.

## Deferred (next window)

Webhook delivery (Event Grid subscriptions / delivery to webhook endpoints)
is out of scope for this window — standing stays PARTIAL_ALIVE.

## Replay

```
grep -n 'GAP(eventgrid-eg1-schema-absent)' docs/WIRE_PARITY.md   # annotation on disk, token OPEN
grep -c '  test "' test/eventgrid_topics_arm_test.exs            # 9 test blocks
```
