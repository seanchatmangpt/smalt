# w6l — App Config /kv query faces (filters, fields, tags, continuation)
**Standing:** PARTIAL_ALIVE — raise landed + lane-file syntax verified clean;
full-tree compile gate and live-wire witness are TYPED-BLOCKED under
concurrent wave-6 lane churn (compile-freeze SLA exhausted, 20/20 attempts,
2026-10-20), deferred to the coordinator's quiesced integration window.

## What landed (all in lib/smalt/egress_router.ex, kv plane)
- GET /kv: key=/label= glob filters (exact, trailing-*, leading-* + suffix),
  fields= projection over the closed vocabulary {key,label,contentType,value,
  tags,last_modified,etag,locked}, repeated tags=k=v AND filter (raw
  query-string parse, Plug last-wins collapse bypassed), after= continuation
  with Link: rel="next" header, items sorted by {key,label}.
- kv_write: stores tags (string->string map, lenient) + locked=false.
- New helpers: kv_fields/1, kv_glob_match?/2, kv_tags_filter/1,
  kv_tags_match?/2, kv_page/2, kv_mint_page/1, kv_composite/1,
  kv_encode_after/2, kv_decode_after/1, kv_next_link/2,
  public_kv_record/2 (Map.take projection); kv_tags_from_body/1.
- Continuation tokens: base64url(JSON {key,label}) of the page's last item;
  forged/stale tokens yield an EMPTY page (never resurrect items).
- Page size 50 (real-service default); Link header carries the full
  after= URL.

## Verification (real output)
- Repo syntax (isolated, plain elixir):
    elixir -e 'Code.string_to_quoted!(File.read!("lib/smalt/egress_router.ex"))...'
    -> ROUTER-SYNTAX-OK
- Compile attempts (MIX_BUILD_ROOT=_build-lane-w6l): 20/20 FROZEN on
  foreign lanes' in-flight files (arm/dns.ex, arm_gateway/router.ex,
  cosmos.ex dup-clause warning, blob_storage.ex:1056, deployments.ex,
  kv_managed_storage.ex:348, cosmos_authz_plug.ex) — poll log:
  /Users/sac/.claude/jobs/cfab9d25/tmp/w6l_compile_poll.log
- Witness script staged at
  /Users/sac/.claude/jobs/cfab9d25/tmp/w6l_witness.sh (boot-eval private
  substrate block v61; legs: 55-kv seed, unfiltered count, continuation
  chain to exhaustion, key/label globs, fields projection, tags AND,
  forged token, teardown) — NOT RUN (no compiled tree available under
  churn).

## Falsifier (integration-time rerun)
Run w6l_witness.sh on a quiesced compiled tree: filters must return exactly
matching sets and the continuation chain must reach exhaustion with no Link
on the final page. Green-under-broken-filters would be vacuous.

## Disclosures
- Compile-freeze SLA: no unblock fixes applied to foreign files (all frozen
  files belonged to active lanes; owners landed repairs mid-poll).
- One mid-session tool-serialization corruption affected tmp/ scratch only;
  repo edits went via Edit/python splices and verified via syntax check +
  clean intermediate compiles of the kv plane.
- Snapshot-module logic untouched (additive-only constraint held).

## RE-WITNESS addendum — 2026-10-22 (lane BK-REWIT3): staged witness RUN on the integrated tree — PASS, PARTIAL_ALIVE → ALIVE

The receipt's falsifier (run `w6l_witness.sh` on a quiesced compiled tree)
was executed. Harness adaptations, all disclosed: build root
`_build-rewit3` (lane root gone); `sb_shared_key` lengthened to clear the
current >=32-byte boot gate (script predates the gate); STS bearer minted
and attached to every data-plane curl (:enforce substrate — the staged
script's tokenless curls 401). Real output:

```
PAGE1=50 link=yes ; PAGE2=5 link= ; PAGED-TOTAL=55 (expect 55)  — continuation chain to exhaustion, Link gone on last page
LEG3-PROD=28 (expect 28)   — key-glob + label-exact filter exact
LEG4-PROJ-OK               — fields=key,value projection, exact key set
LEG5-TAGS-PROD=28          — tags AND filter
LEG6-AND=1 (expect 1)      — two-pair tags AND
LEG7-FORGED=0 (expect 0)   — forged token yields empty page
W6L WITNESS COMPLETE ; exit=0
```

(Seed PUTs answered 201/200 — the 200s are idempotent upsert on this boot;
all 55 rows present.) The typed-BLOCKED witness is closed: filters exact,
continuation reaches exhaustion. SUSPECT cleared; PARTIAL_ALIVE → ALIVE.
