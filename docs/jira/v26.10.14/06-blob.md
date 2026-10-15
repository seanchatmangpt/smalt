# V261014-06 — Blob Storage hardening work order

- **Release:** v26.10.14 · **Work order:** V261014-06 · **Plane:** Blob Storage (`:8443` guarded catch-all)
- **Scope owners:** `lib/smalt/data_plane/blob_service.ex`, `lib/smalt/data_plane/blob_storage.ex`, `lib/smalt/egress_router.ex` (blob route arms + `blob_error` funnel only)
- **Test surface:** `test/data_plane/blob_hardening_test.exs` (extensions)
- **Docs surface:** `docs/WIRE_PARITY.md` (Blob row, :124), `docs/compliance/C4_BLOB.md`

## 0. Decision gate (read first)

CLOSE-vs-UNSUPPORTED for `GAP(blob-error-envelope-json)` is gated on wire-court risk:

- **CLOSE** the XML envelope **iff** the new renderer emits XML **only** for routes where the real service emits XML — `comp=list` (container list and blob list) error paths — and every other consumer of `blob_error/3` (ledger, cosmos, Key Vault, attestation, sentinel — `blob_error/3` is a **shared funnel**, ~50 call sites in `lib/smalt/egress_router.ex`) keeps byte-identical JSON output. Verification = existing cross-plane wire tests pass unmodified (`test/wire/egress_wire_test.exs`, `test/data_plane/cosmos_test.exs`, `test/data_plane/key_vault_actions_test.exs`, `test/security/security_hardening_test.exs`).
- **If any shared-funnel consumer regresses** such that a scoped fix would touch non-blob planes, fall back to **typed-UNSUPPORTED** this window and record per §8.

The gate resolves **before** Task 3 starts. Tasks 1, 2, 4 and the UNSUPPORTED docs are unconditional.

## 1. CLOSE — XML escape astral-plane parity (defect 1)

**Defect.** `BlobService.xml_escape/1` (`blob_service.ex:113-129`) is a divergent copy of `BlobStorage.xml_escape/1` (`blob_storage.ex:740-753`): it lacks the supplementary-plane transform (:748-750) rewriting astral codepoints (U+10000..U+10FFFF) to numeric character references. A supplementary-plane **container name** is enumerated with raw 4-byte UTF-8 in `<Name>`, which xmerl 2.x rejects (`wfc_Legal_Character`).

**Fix (delegate, do not duplicate).** Replace `BlobService.xml_escape/1`'s body with delegation to `BlobStorage.xml_escape/1`; keep `@doc`/`@spec`. BlobService already cross-references BlobStorage in its comment — make the code match.

**Fence:** new test in `blob_hardening_test.exs`: container with an astral codepoint in the name, `GET /{account}?comp=list`, assert (a) numeric character references in the body, not raw 4-byte sequences, (b) body parses under `:xmerl_scan.string/1`. Existing `test/data_plane/blob_service_test.exs` unchanged green.

## 2. CLOSE — maxresults grammar alignment (defect 2)

**Defect.** Split grammar: container listing `BlobService.normalize_max/1` (:236-243) **silently coerces** junk (`"abc"`, `"0"`, `"-1"`, `"5x"`) to the default; blob listing `BlobStorage.check_maxresults/1` (:69-83) answers typed **400 `InvalidQueryParameter`**. Real Azure refuses junk on both routes.

**Fix.**
1. Route the container-list path through `BlobStorage.check_maxresults/1` — `{:error, 400, "InvalidQueryParameter", msg}` for junk.
2. Wire the typed error at the egress seam: the container `comp=list` route (`egress_router.ex:741` region) destructures the typed tuple the same way the blob `comp=list` route already does (:931-936 seam).
3. `normalize_max/1` retains only the positive-integer clamp for already-validated input.

**Fence:** `?comp=list&maxresults=abc|0|-1|5x` on the **container** route → 400 `InvalidQueryParameter`; `=5000` and absent still 200; blob-route strict behavior re-pinned.

## 3. CLOSE (gate per §0) — XML error envelope for comp=list routes + x-ms-error-code header

**Defects.**
- `blob_error/3` (`egress_router.ex:1872-1877`) unconditionally `send_json/3`. On a blob `comp=list` failure real Azure emits an XML `<?xml ...?><Error><Code>..</Code><Message>..</Message></Error>` envelope; smalt emits JSON.
- Zero `x-ms-error-code` hits across `lib/` and `test/` (re-derived 2026-10-15); real Azure carries the code in both envelope and header.

**Fix.**
1. Add `blob_error_xml/4` (status, code, message) producing the Azure `<Error>` shape with `Content-Type: application/xml`.
2. **Scope discipline:** do NOT change `blob_error/3`'s default output. Only the **blob `comp=list` error arms** (container list ~:741, blob list :931) switch to `blob_error_xml/4` for blob-plane typed errors.
3. Both renderers add `put_resp_header("x-ms-error-code", code)` — additive and plane-neutral; may go into `blob_error/3` itself plus `blob_error_xml/4`.
4. Extract `code` from typed tuples at the blob route arms; thread the code explicitly rather than string-munging bodies.

**Wire-court gate:** if extracting `code` at any blob arm requires reshaping a shared tuple contract used by non-blob planes, stop → typed-UNSUPPORTED per §0, record the gate outcome.

**Fence:** blob `comp=list` with `maxresults=abc` → 400, `application/xml`, body `~r/<Error>.*<Code>InvalidQueryParameter<\/Code>.*<\/Error>/s`, header `x-ms-error-code: InvalidQueryParameter`; container-list 404/400 arms likewise. **Cross-plane regression:** `test/wire/egress_wire_test.exs test/data_plane/cosmos_test.exs test/data_plane/key_vault_actions_test.exs test/data_plane/audit_planes_test.exs` all green with no JSON-shape changes on non-blob planes.

## 4. CLOSE — fast-path prefix echo cosmetic drift (defect 4)

Fast path (`blob_storage.ex:572-583` → `render_blobs/9` :651-669) always emits `<Prefix>` = full key prefix, while the composed path (:630-645) echoes the request prefix. Align the fast-path echo to the composed-path expression. Behavior-visible only in the `<Prefix>` element.

**Fence:** plain `comp=list` (no params) yields `<Prefix>` identical to a `prefix=""` request through the composed path.

## 5. UNSUPPORTED-doc — delete precedence WORM-vs-If-Match (defect 3)

`delete_blob/4` (:263-267) orders `check_worm` before `check_if_match`; a blob both WORM-locked and If-Match-mismatched answers **409 `ContainerLocked`**; real Azure evaluates preconditions first and answers **412**. **UNSUPPORTED this window** — the reorder is contract-visible (tests + `@doc` :255-260 pin 409-on-WORM) and interacts with the future lease seam; revisit with the lease work, which rewrites the same `with` chain.

**Acceptance:** divergence row in `WIRE_PARITY.md:124` + a C4_BLOB.md section (412-first vs 409-first, repro request pair).

## 6. UNSUPPORTED-doc — lease surface (GAP(blob-comp-lease-absent))

Full `comp=lease` surface (acquire/renew/change/release/break, `:smalt_blob_leases` table, enforcement seam alongside `check_worm` in the `with` chains at :131-135 and :263-267, removal of the hardcoded `<LeaseStatus>unlocked</LeaseStatus>` at `blob_service.ex:83`) is **feature-scale**. Typed-UNSUPPORTED; the hardcoded `<LeaseStatus>` stays, documented as the divergence marker.

## 7. UNSUPPORTED-doc — x-ms-date validation (GAP(blob-x-ms-date-unvalidated))

`x-ms-date` is neither required nor validated in the blob lane (only `x-ms-version` presence, `egress_router.ex:1429`). Real Azure requires it on authorized requests and bounds skew. Typed-UNSUPPORTED; bounded future fix = presence + RFC 1123 parse + skew window shared with the other `:8443` planes.

## 8. Documentation work items

1. `docs/WIRE_PARITY.md:124`: close `GAP(blob-x-ms-error-code-header-absent)` and `GAP(blob-error-envelope-json)` (if §0 gate closes); rewrite the lease and x-ms-date rows as explicit UNSUPPORTED-with-divergence; add the §5 precedence divergence and the `LeaseStatus: unlocked` marker.
2. `docs/compliance/C4_BLOB.md`: mirror sections for §5/§6/§7 plus close-out notes for §1-§4 with fence commands.

## 9. Sequencing

1 → 4 (independent, trivial) → 2 → §0-gate resolution → 3 → 8 (docs last). Test extensions land with each task, not batched.
