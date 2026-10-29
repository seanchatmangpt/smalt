# KD-58 ARM tag operations — witness receipt (K5, v26.10.20)

**Standing:** ALIVE (fix landed + wire-witnessed)
Context: solo
Date: 2026-10-20

## Disposition: FIX

Row: tagNames CRUD -> 404; resource-scope tags/default PUT refused. Falsifier:
tag CRUD -> 200/201 or typed refusal, never 404.

## Change (lib/smalt/arm_gateway/router.ex, # KD-COVERS: KD-58)

- Tenant tagNames CRUD routes: GET /tagNames, GET/DELETE /tagNames/{name},
  PUT/GET/DELETE /tagNames/{name}/tagValues/{value} (real 2022-09-01 tags API
  envelopes). Rows share the :smalt_policy table under a "tagname:" key
  prefix — discriminated-prefix law (KD-125 precedent); tag-value rows under
  "tagname:{name}/tagValues/{value}".
- `scope_tags_incoming/1` now accepts {"properties":{"tags":{...}}} (the real
  tags/default PUT body) in addition to top-level tags.
- The list endpoint filters to type Microsoft.Resources/tags so tag-value
  rows never leak into /tagNames.

## Witness (witness beam 39780, arm_port ephemeral; live substrate untouched)

    == PUT tagValue          -> 201 {"id":"/tagNames/k5env/tagValues/prod","type":"Microsoft.Resources/tagValues",...}
    == GET /tagNames         -> 200 {"value":[{"id":"/tagNames/k5env","type":"Microsoft.Resources/tags",...}]}
    == GET tagName           -> 200 / 404 TagNotFound after value delete (last-value-delete law)
    == GET tagValue          -> 200 / 404 TagValueNotFound
    == DELETE tagValue       -> 200
    == scope tags via properties.tags -> 200 {"name":"default","properties":{"tags":{"a":"b"}}}
    == RG GET shows tags     -> {"a":"b"}

Baseline-contrast: identical /tagNames probes on the live substrate 2026-10-20
pre-fix returned 404 RouteNotFound.

## Tests

    15 tests, 0 failures (arm-facing test/integration files, _build-k5)

Verdict: PASS (tag CRUD -> 200/201, never 404).
