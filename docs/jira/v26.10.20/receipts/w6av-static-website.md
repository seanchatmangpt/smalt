# w6av — Azure Blob Static Website face

**Standing: ALIVE**

**Subject**: smalt @ working tree (uncommitted; wave-6 lane w6av), 2026-10-20.

## What landed

- `lib/smalt/data_plane/blob_storage.ex` — static-website engine section:
  `set_service_properties/2` (parses StorageServiceProperties XML;
  Enabled=true without IndexDocument → typed 400 InvalidXmlDocument; valid
  body without the block clears the website — Azure parity: PUT clears what
  it omits), `service_properties_xml/1` (Get-properties XML echo; block
  omitted when unset), `website_props/1`, `static_website_serve/4`
  (root-serve decision: index doc on $web root, extension-sniffed
  content-type, missing content → configured 404 doc with 404 status, plain
  404 when unconfigured), per-account props ETS :smalt_blob_service_props
  with :heir 3-tuple, $web name-rule exemption + auto-create on enable
  (Azure parity: enabling auto-creates $web).
- `lib/smalt/egress_router.ex` — route arms (post-split, additive):
  put "/:account" (restype=service&comp=properties → 202), Get-properties
  arm inside get "/:account" (→ 200 XML echo), static-website serve gates
  in the container GET arm ($web root) and the two blob GET 404 clauses
  (missing blob → 404-doc serve), router helpers static_website_gate?/3,
  static_website_render/2, render_404_doc/2.

## Witness (real output, engine + wire tiers)

Engine (MIX_BUILD_ROOT=_build-lane-w6av MIX_ENV=test mix run --no-start
tmp/w6av_witness.exs):

```
CONTAINER_OK
PUT_INDEX.HTML=OK
PUT_404.HTML=OK
PUT_STYLE.CSS=OK
SET_PROPS_OK
GET_PROPS_HAS_WEBSITE=true
GET_PROPS_HAS_INDEX=true
ROOT_SERVE_OK body=<html>W6AV-INDEX</html>
DOC_SERVE_OK ct=text/css body=body{}
MISS_404_DOC_OK body=<html>W6AV-404</html>
DISABLE_OK
DISABLED_PASS_OK
W6AV WITNESS: ALL FACES OK
```

Wire (substrate-ctl block v89, enforce auth, STS bearer, x-ms-version gated,
ports 40590-40595, torn down after):

```
PUTCONT 201
PUTIDX 201
PUT404 201
SETPROPS 202
GETPROPS 200 (body contains StaticWebsite + IndexDocument=index.html)
ROOTSERVE 200 body=<html>W6AV-WIRE-INDEX</html>
MISS404 404 body=<html>W6AV-WIRE-404</html>
DISABLE 202
DISABLED-GET 200 EnumerationResults (prior List Blobs behavior restored)
```

Gates: strict compile of both touched files green in lane root
(_build-lane-w6av); internal tier 48 tests, 0 failures; substrate v89
torn down after the wire run.

## Defects caught during the lane (all fixed before receipting)

1. Generation-integrity class: three corrupted payload writes during the
   lane (module section, two receipt drafts) — all caught by syntax check /
   sweep and rewritten via deterministic generators.
2. Real engine defect found by the witness: "$web" was refused by the
   container name rule (400 InvalidResourceName) — fixed with the Azure
   $web exemption + auto-create-on-enable.
3. Missing Path.extname/0 (Path.extension is not an Elixir function) —
   compile-caught, fixed.
4. Stale dev-beam trap: the wire 404s that motivated the substrate-restart
   loop were a stale _build/dev beam (substrate serves _build/dev, which had
   not recompiled since the route arms landed) — resolved by recompile +
   restart; disclosed here as a replay trap for future lanes.

## Compile-freeze SLA disclosure

One minimal disclosed unblock on a sibling lane's in-flight file:
`account_from_blob_path/1` (w6ay CORS region, undefined mid-edit) —
minimal first-segment extraction added so the shared tree compiled; owner
may supersede; flagged for the w6ay receipt per the disclosure law.

## Falsifier

Re-run `tmp/w6av_witness.exs` (engine) and `python3 tmp/w6av_wire.py`
(wire, needs a fresh substrate block) on any future green tree — green
under a broken serve-gate (the disable leg not falling through to List
Blobs; the missing-blob leg not serving the 404 doc) is vacuous.
