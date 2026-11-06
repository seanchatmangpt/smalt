# p3-l4-c4-reanchor

Standing: ALIVE

Lane: P3-L4 (C4_BLOB re-anchor wave, v26.11.7). Repos: `/Users/sac/smalt`,
`/Users/sac/arcus`. Date: 2026-11-05. No git transitions (per dispatch).

## Subject

C4_BLOB.md gains its arcus anchor appendix; every anchor carries real line
numbers read from disk in both repos on 2026-11-05. Doc edited:
`docs/compliance/C4_BLOB.md` (append-only section "Arcus re-anchor appendix
(P3-L4, 2026-11-05)"); body untouched (plan law: smalt anchors stay
byte-identical, arcus halves appended).

## Anchor inventory (15 rows, all file:line verified on disk)

1. bearer.ex:174-191 + :198-209 (SharedKey admit / shared_key_header?) <-> sharedkey.go:42-52, :60-78, :82-91
2. blob/core.ex:1859-1878 + egress_router.ex:2722-2740 (request-id v4 mint) <-> blob_headers.go:37-53 (BlobRequestID; v4 bits :44-45)
3. blob_service.ex:188-193 (x-ms-version emission) <-> blob_headers.go:18-21, :55-63
4. conditional_headers.ex:13-34 (evaluate/2) <-> conditional_headers.go:35-77 (EvaluateConditional)
5. conditional_headers.ex:50-62 (etag_matches?/strip_quotes) <-> conditional_headers.go:79-101 (etagListMatches)
6. blob/core.ex:1124 + :1212-1229 + leases.ex:605-638 (range law) <-> blob_blocks.go:221-257 (ParsePageRange/CheckPageAlignment)
7. blob/core.ex:405-430 (block grammar) <-> blob_blocks.go:41-70 (ValidateBlockID/BlockKey)
8. egress_router.ex:2829-2896 (blob_error/3 family) <-> errors_armwire.go:70-90 (BlobRender/SendBlobError)
9. blob/core.ex:1583-1610 (xml_escape) <-> errors_blob.go:9-48 (XMLEscape)
10. blob/core.ex:282-313 (KD-141 metadata validation) <-> blob_headers.go:74-104
11. blob_storage.ex:19-30 + worm.ex:297-345 (WORM request headers) <-> blob_headers.go:133-154 (ParseWORMPolicyHeaders)
12. blob_service.ex:82-110 + :160-193 (container XML + ETag) <-> etags.go:22-34 + storage_host.go:24
13. storage_catch_all batch grammar <-> blob_batch.go:40-190
14. blob/core.ex:866-1010 (snapshot/DeleteSnapshots) <-> blob_batch.go:191-260
15. egress_router.ex:2798-2814 (FEGS1 crash-fence fallback) <-> UNSUPPORTED(counterpart-absent) — wire-layer crash fence stayed smalt-side; arcus dialect is pure functions

## Byte-pin receipts (all read from disk 2026-11-05)

**x-ms-range precedence.** smalt `lib/smalt/data_plane/blob/core.ex:1124`:

    range = header_value(headers, "x-ms-range") || header_value(headers, "range") || ""

smalt `blob/leases.ex:608`: `Regex.run(~r/^bytes=(\d*)-(\d*)$/, String.trim(header))`.
arcus `blob_blocks.go:228-246` pins the same parse law + exact 400 code strings
(`MissingRequiredHeader` / "x-ms-range is required for Put Page." and
`InvalidHeaderValue` / "The x-ms-range value is invalid."). Divergence
disclosed in the appendix: the x-ms-range-over-Range *preference* is resolved
engine-side (core.ex:1124); arcus `ParsePageRange` receives the resolved
string, so the preference law is UNSUPPORTED(counterpart-absent) at the
dialect layer — loudly missing, never silently skipped.

**request-id v4 regex.** smalt mint: `blob/core.ex:1865-1878` and
`egress_router.ex:2727-2740` (identical bit ops: `c4 = band(c, 0x0FFF) + 0x4000`,
`d = bor(band(d, 0x3FFF), 0x8000)`; format `~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b`).
smalt fence: `test/internal/kd_conf_court_test.exs:13`
`~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/` (full v4
pin; the C4_BLOB.md header's `c4_blob.exs:85/:220` cite is stale on disk —
`test/compliance/c4_blob.exs` no longer exists in the test tree, disclosed below).
arcus mint: `blob_headers.go:39-53`, v4 bits `:44-45`; arcus fence:
`blob_headers_test.go:15` `dashed36` regex + `:26` explicit "is not version 4" check.

**verbatim body.** smalt `egress_router.ex:2858-2866` iolist envelope:
`<?xml version="1.0" encoding="utf-8"?><Error><Code>…</Code><Message>…</Message></Error>`.
arcus `errors_armwire.go:75-78` `BlobRender` concatenates the byte-identical
string (XMLEscape both slots). Also pinned: smalt FEGS1 fallback body
`egress_router.ex:2803` (`...InternalServerError...Internal server error....`)
— no arcus counterpart (see row 15).

## Gate receipt

`cd /Users/sac/arcus && go test ./internal/dialect/azure/` → **FAIL (2
failures, both PRE-EXISTING, 0 session-introduced)** — this lane edited two
markdown files only; failing tests touch `fileshare_test.go`
(TestFileShareListDir, listing order) and `routing_court_test.go`
(TestRoutingCourtAcrV2Route, ACR v2 base-ping grammar), neither in the C4
anchor set nor edited by any lane file I own.

Targeted gate over the anchored laws:

    go test ./internal/dialect/azure/ -run 'TestBlobHeadersBlobRequestID|BlobError|ParsePageRange|Conditional'
    → ok  github.com/seanchatmangpt/arcus/internal/dialect/azure  0.285s

PASS: TestBlobHeadersBlobRequestIDIsDashed36RFC4122v4, TestConditionalDateHeaders
(10 subtests), TestConditionalNoLastModified, TestConditionalEmptyETag, and the
SendBlobError error-envelope courts.

## Premise-rot disclosures

1. The C4_BLOB.md body anchors `blob_storage.ex:232-255 / 263-267 / 302-346 /
   410-428 / 479 / 999` pre-date the T09 blob split: `blob_storage.ex` is now a
   161-line defdelegate facade; the cited law moved to `blob/core.ex`,
   `blob/leases.ex`, `blob/worm.ex`. Per the plan's "smalt anchor stays
   byte-identical" law the body was NOT rewritten; the appendix anchors the
   on-disk counterparts and the divergence is disclosed both in the doc and here.
2. `test/compliance/c4_blob.exs` (cited at C4_BLOB.md header pins :85/:220 and
   in the Fence tests section) no longer exists in the smalt test tree; the
   live v4 request-id fence is `test/internal/kd_conf_court_test.exs:13`.
3. `egress_router.ex` grew from the doc-era ~1100 lines to 2914; the blob_error
   region cited at "egress_router.ex:1605" (CLOSED lens-5 note) is now
   `egress_router.ex:2829-2896`.

## Falsifier

Any arcus line number in the appendix not matching disk at receipt-read time
invalidates the row; re-derive with the same grep/awk commands. Any smalt-side
body edit to C4_BLOB.md would violate the append-only law (none made).
