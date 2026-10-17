# R178b — gen_error_codes helper-window widening (11→14) + drift witness

Standing: PARTIAL_ALIVE

## Scope

`scripts/gen_error_codes.py` helper-send extraction window widened (11→14
recognized helper send-sites), so code literals paired with their send
sites beyond the old window no longer emit `?` egress rows or a silent
`| egress | ? |` projection. The extractor's fail-loud contract is
in-source at `scripts/gen_error_codes.py:319` and `:394` ("update the
extraction patterns or the source; do NOT ship a ...").

## Re-run output (docs lane, 2026-10-16, `_build-lane207`)

```
$ MIX_BUILD_ROOT=_build-lane207 mix test test/error_codes_doc_test.exs
Finished in 0.1 seconds (0.00s async, 0.00s sync)
7 tests, 1 failure
```

```
$ MIX_BUILD_ROOT=_build-lane207 mix test test/error_codes_doc_test.exs (failure detail)
1) test docs/ERROR_CODES.md is the byte-identical projection of the sources
   docs/ERROR_CODES.md is stale relative to the sources.
   Regenerate: python3 scripts/gen_error_codes.py
   --- docs/ERROR_CODES.md (on disk)
   +++ regenerated
   (egress rows: line cites moved, e.g.
    InvalidApiVersion egress_router.ex:1776 -> regenerated cite,
    new InvalidRequestBody :1322 / InvalidXmlOrJson :1027 / MissingXMsVersion :1953 rows)
```

## Interpretation

The 1 failure is DRIFT, not extractor breakage: concurrent lanes moved
line cites in `lib/smalt/egress_router.ex` after the last doc regen. The
byte-identity fence fired exactly as designed (fail-loud, exact regen
command in the message). `docs/ERROR_CODES.md` is a generated artifact —
regenerated at fin sweep per the wrap sequence, never hand-patched, so
this receipt does not patch the doc.

Standing PARTIAL_ALIVE until the fin-sweep regen turns the drift fence
green.
