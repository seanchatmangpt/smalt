# W7-A — staged_roundtrip put-block-list 400 fix (live wire)

**Standing: ALIVE** — 2 consecutive green suite runs against the live
substrate (shared 8443/9443, enforce mode), wire-proven before and after.

## Witnessed failure

`mix test test/live_blob_blocks_test.exs` — `staged_roundtrip/1` died at
`put-block-list` with HTTP 400 `InvalidXmlDocument: The block list body
contains no block references.`

## Diagnosis (wire-first, curl against the live substrate)

Grammar check against the emulator parser
(`lib/smalt/data_plane/blob_storage.ex` `parse_block_list_xml/1`): it scans
`<(Latest|Committed|Uncommitted)>...</...>` — the canonical Azure envelope
`<?xml ...?><BlockList><Latest>b64</Latest>...</BlockList>` with base64 ids
is correct and parses in-process (fresh `_build-w7a` compile, private-port
beam: stage 201 ×2 → parse → `commit 201`).

```
refs: [latest: "aWQtMA==", latest: "aWQtMQ=="]
commit 201
```

The real killer is content-type. `PopcornDemo.Transport.Httpc` defaults the
request content-type to `application/x-www-form-urlencoded`, and the
router's route-conditional `Plug.Parsers` (raw-PUT exemption requires
`comp in [nil, ""]`) lets the `:urlencoded` parser CONSUME the body of any
`comp=block` / `comp=blocklist` PUT with that content-type — the block arms
then read `""`. Curl proof on the live wire:

```
block0 201 / block1 201
blocklist 400 InvalidXmlDocument "no block references"   (urlencoded CT)
blocklist 400 InvalidBlockList "block not found: ..."    (application/xml CT
                                                          — parser sees refs)
```

In-process the identical stage/parse/commit sequence commits 201 — the wire
difference is the parser-consumed body, not the store.

## Diff (this session)

1. `popcorn_demo/lib/popcorn_demo/live_blob.ex` (staged_roundtrip region
   only; run/0 untouched):
   - The `content-type: application/xml` header on all three body-carrying
     staged steps (block PUTs + blocklist PUT) — NOTE: this edit landed
     mid-session matching my diagnosis while I was re-deriving it (sibling
     lane or coordinator; file mtime jumped 18:44→18:50). I verified it
     against the wire proof rather than re-applying.
   - W7-A: `cleanup_staged/2` delete-blob arm switched from
     `step_req(..., 202)` to raw `request/1` — step_req reshaped the
     by-design 409 ContainerLocked into a step error before the
     `{:ok, %{status: 409}}` retained-clause could match, so a healthy
     WORM-retained walk FAILED (`witnessed: FAIL(delete-blob:...http-409...)`
     at 19:10-class runs). Now classified `{:lock, :blob_retained}` →
     "-worm-retained".
   - @doc updated: suffix contract (`-cleaned` / `-worm-retained`) and the
     explicit-content-type law.
2. `popcorn_demo/test/live_blob_blocks_test.exs`: the suffix `case rest`
   matched the bare suffix string against the WHOLE message tail (account/
   container/blob prefix + trailing paren) — unmatchable, so the test
   flunked on a green walk. Replaced with a regex extraction of
   `:(\d+)-(cleaned|worm-retained)-staged-roundtrip\)$` plus wire-state
   assertion (cleaned ⇒ GET 404, worm-retained ⇒ GET 200).

## Verification (green ×2, consecutive)

```
attempt 1: Result: 2 passed
attempt 2: Result: 2 passed
TWO CONSECUTIVE GREENS
```

(`mix test test/live_blob_blocks_test.exs`, MIX_BUILD_ROOT=_build-w7a,
Elixir 1.20.3-otp-28 via asdf shims, live substrate 8443/9443 enforce
mode; run/0 test included and green in both runs.)

## Environmental note (honest numbers)

The shared substrate bounced repeatedly during this session (other lanes
booting/cycling; substrate.sh reported multiple lock orphans). One earlier
run FAILED with `put-block-list:http-400 InvalidBlockList (block not
found)` — stage 201 on one node, commit against a freshly restarted node
whose block ETS was empty. That failure class is substrate churn, not the
walk; the retry-in-up-window loop produced the two clean greens.

## KD-candidate (not registered)

Real Azure ignores request content-type on Put Block / Put Block List and
parses the XML body regardless; smalt's route-conditional Plug.Parsers
exemption does not cover `comp=block`/`comp=blocklist` PUTs, so any client
sending a form-urlencoded content-type (curl's `--data-binary` default,
Transport.Httpc's default) silently loses the body and gets 400
InvalidXmlDocument "no block references". Same parser-consumed-body class
as KD-108/KD-122/KD-123, third+ instance. Close condition: extend the
raw-PUT exemption to `comp in ["block", "blocklist"]` (then the client
content-type becomes optional). Left OPEN for the registrar.

## Files

- /Users/sac/smalt/popcorn_demo/lib/popcorn_demo/live_blob.ex
- /Users/sac/smalt/popcorn_demo/test/live_blob_blocks_test.exs
- /Users/sac/smalt/docs/jira/v26.10.20/receipts/w7a-staged-roundtrip-wire-fix.md
