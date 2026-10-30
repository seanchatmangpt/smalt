# r-undock-restore

**Lane**: L02 — T-R1 undock restore (egress_router.ex)
**Standing**: ALIVE for the six gate families + expl9r1 + both KV falsifier
courts; PARTIAL for the two pre-existing blob_xml_error legs (pre-existing
baseline failures, see Verification)
**Date**: 2026-10-29 (session 22:05–23:40 PDT)
**Build root**: `MIX_BUILD_ROOT=_build-l02`, Elixir 1.20.4-otp-29 via asdf
shims (per `/tmp/smalt-validate/baseline.sh`; ambient homebrew Elixir 1.19.5
fails the mix.exs `~> 1.20` gate)
**Base**: HEAD `35bd36d0` (unchanged — no git state commands beyond read-only
log/show/rev-parse)

## Undock attribution

- **Pre-undock source**: `95d4243d` (v26.10.28 squash-forward; its
  egress_router.ex, 4,865 lines, carries the full pre-undock surface).
- **DROP**: `3feb1cb9` — the 2,458-file undock merge took origin/main's
  egress_router.ex wholesale. Marker counts (`git show <sha>:lib/smalt/egress_router.ex | grep -c`):
  `use Plug.ErrorHandler` 1→0, `w6r_fallthrough` 2→0, `ServiceBusRestRoutes`
  1→0, `def build_event` 1→0 (demoted to defp), `safe_dispatch` retained but
  demoted def→defp.
- **Partial restore**: `f63c981f` ("undock drop-restores": cors knob,
  account_key/loopback_origin?, ~40 defp→def) — did NOT restore the fence,
  w6r wiring, SB-REST plug, or build_event/safe_dispatch visibility.
- **Lane start state**: the prior L02 attempt's partial re-land was in the
  working tree (194 insertions, 3 deletions). Each hunk was verified verbatim
  against 95d4243d before building on it (w6r_fallthrough and safe_dispatch
  bodies byte-identical; handle_errors/build_event comment-only deltas).

## Restored surface

**(a) Prior attempt's re-land (verified this session, kept):**
`use Plug.ErrorHandler` + `handle_errors/2` + F-EGS1 fallback + `error_xml/2`;
`plug(Smalt.Egress.ServiceBusRestRoutes)` before the queue plane;
`plug(:apim_gateway_plane)` + `plug(:w6r_fallthrough)` + `safe_subrouter_call`
+ the 12-delegator fallthrough list; `def safe_dispatch/2`; `Peers.build_event/2`
public + per-event `make_ref` correlationId.

**(b) This session (L02):**
- **File Share plane** (whole plane was dropped): `plug(:file_share_plane)`
  after the queue plane; `file_share_plane/2` + `file_plane_route/4` (7
  clauses) + `@file_reserved_first` fence (`dbs keys secrets certificates
  tables colls users permissions`) + `file_reserved_first?/1` + `join_segs/1`
  + `run_file_arm/2` + `file_dispatch/3` (14 arms, incl. the KD-175 guarded
  put_range 413) + `send_file_xml/bytes/headers_only` + `send_file_error/4` +
  `file_range_too_large_msg/1`. Callees all survived in
  `lib/smalt/data_plane/file_share.ex` — zero callee changes.
  `git diff --stat` on my file: 647 lines, 622(+) / 25(−) at receipt time.
- **w6av `put "/:account"`** service-properties arm (guarded read_body 413 +
  BlobCors 202 path), verbatim from 95d4243d:1387.
- **raw_blob_put? KD-122 / KD-123 / D9** parser-exemption clauses, verbatim.
- **B-XML opt-in law** (the coordinator/L11 KV-JSON regression's root cause):
  the undock dropped the `:smalt_blob_face` stamp in `blob_route/2`, the
  consult branch in `blob_error/3`, and `put_error_code_header/2` (deleted by
  f63c981f as "unused" — unused precisely because the consult was gone).
  Restored: stamp + consult + put_error_code_header; the wf8 python-parity XML
  body (InternalError default, message-default, xml_escape_error) is preserved
  INSIDE the stamped branch. Non-stamped call sites (KV / KvRoutes /
  ARM / cosmos / queue-plane / ledger) answer JSON again.
- `config/test.exs`: `saml_idp_port` + `oidc_port` ephemeral-probe entries
  (`test_port.("SAML_IDP", 9445)` / `test_port.("OIDC", 9446)`) — both IdP
  faces bound FIXED fallback ports in test (9445/9446), colliding
  `:eaddrinuse` across concurrent test VMs and failing whole-tree boots
  fleet-wide (witnessed: `failed to start child: {Smalt.Identity.SamlIdp, 9445}`).

## Adaptations (disclosed)

1. **apim plug position**: L04's landing (`plug(:apim_gateway_plane)` before
   w6r/match + private fn delegating `Smalt.Apim.gateway/2`) preserved intact
   per coordinator note — verified post-edit at :715/:735-736 (pre-edit-check
   :473/:493 before the file-plane insert shifted lines). History's position
   was pre-EventGridWebhookPlug (95d4243d:486); L04's position stands.
2. **blob_error XML branch** keeps the wf8 python-parity body (court-pinned,
   post-undock) inside the stamped branch; the else-branch is pre-undock
   verbatim (send_json + put_error_code_header).
3. **Visibility**: kept current `defp blob_route` (pre-undock `def`) — the
   stamp is additive inside it; `blob_route_guarded` is only reached via
   blob_route so one stamp covers both.
4. **Peers.build_event**: `@doc false` + `@spec` added (warning hygiene).
5. **handle_errors comment** shortened vs pre-undock (semantics identical);
   `queue_storage_plane` kept `defp` (pre-undock `def`).
6. **Not restored (out of WO-1's named families; owned elsewhere):**
   table_service_plane, the pre-undock KD-139/140 ensure_put_blob_type block
   (the undock lineage evolved its own KD-139/140 blob guards), ThrottlePlug,
   PushRouterPlug, tenant_namespace, CosmosAuthzPlug — throttle is triage D4,
   tenant fence is WO-2/D2, cosmos/eventgrid lanes active.

## Verification (real output, this session)

Toolchain: `export PATH="$HOME/.asdf/shims:$PATH"` (Elixir 1.20.4-otp-29).

```
$ MIX_BUILD_ROOT=_build-l02 mix compile
COMPILE_EXIT=0        (final state; "Generated smalt app")

$ MIX_BUILD_ROOT=_build-l02 mix test <file>   (each file, this session)
expl9r1_egress_guard_court_test      EXIT=0 | Result: 5 passed
bk101_g3_seam_probe_test             EXIT=0 | Result: 2 passed
armstrong_idiom_court_test           EXIT=0 | Result: 8 passed
ath1_batch_frame_receiver_court_test EXIT=0 | Result: 13 passed
marketplace_saas_test                EXIT=0 | Result: 12 passed
kv_crypto_face_test                  EXIT=0 | Result: 4 passed
servicebus_rest_dataplane_test       EXIT=0 | Result: 12 passed
```

Gate = bk101 + armstrong + marketplace_saas + ath1_batch + kv_crypto_face +
servicebus_rest_dataplane: ALL GREEN, zero test-file edits (git status shows
no test/ modifications from this lane).

### B-XML falsifier (coordinator item 1) — real flips witnessed in-session

```
BEFORE the B-XML restore (same session, same tree otherwise):
  kds3_s4_secret_version_history_test EXIT=2 | Result: 1/3 passed
  kv_ec_create_test                   EXIT=2 | Result: 4/5 passed
AFTER:
  kds3_s4_secret_version_history_test EXIT=0 | Result: 3 passed
  kv_ec_create_test                   EXIT=0 | Result: 5 passed
  blob_xml_error_test                 EXIT=2 | Result: 7/9 passed
```

The two "scope regression — non-blob faces stay JSON" legs of
blob_xml_error (which pin the consult law directly) were BASELINE FAILURES
(/tmp/smalt-validate/integration.log items 78+81; offline 22–25) and now PASS.
The two remaining failures ("InvalidRange 416 is XML", "ContainerAlreadyExists
409 is XML") are PRE-EXISTING baseline failures (both appear in
/tmp/smalt-validate/integration.log items 79+80 and offline 22/25 — i.e.
failing on the undock tree BEFORE this lane touched anything). Baseline court
failures 4 → 2 after the restore; zero regressions in the court.

## Incidents / disclosures

1. **Compile-freeze unblocks (other lanes' files)**:
   - `purview_atlas.ex` + `purview_atlas/glossary.ex` (T10 split, stable-broken
     >10 min): widened `new_guid/0` + `delete_term_edges/2` defp→def and added
     an import in glossary.ex. T10 superseded with qualified `Purview.*` calls;
     I removed my now-redundant import. The parent widenings stand (load-bearing
     for the qualified calls).
   - `config/test.exs` (fleet-wide boot freeze): added the two IdP port entries
     in the house `test_port.()` idiom (mcp_port comment cited verbatim).
   - NOT unblocked (owners self-fixed within minutes): key_vault/keys.ex
     (`opts \ []` → `opts \\ []`, fixed by its lane in ~2 min), oidc_authorize.ex
     (fixed by its lane at 23:01), arm_gateway/router.ex (fixed by its lane),
     blob_storage.ex (`opts \ []` class, fixed by its lane at 23:22).
2. **Self-introduced defects, caught and fixed in-session** (disclosed per
   receipt-cited counts law): a truncated file_dispatch insert (placeholder
   reference — caught at compile, repaired same session), a corrupted kafka
   line in config/test.exs ("9ishing092" — fixed within seconds, verified on
   disk), a leading-space header-name typo in the restored blob_error JSON
   branch (fixed immediately). L11 witnessed the ~8.5-min broken intermediate
   during the file-share landing (coordinator relay) — the final suite above
   is the receipt of truth, not the intermediate states.
3. **Coordinator items**: L04 apim wiring preserved (verified post-edit). KV
   XML-vs-JSON regression root-caused: KvRoutes' blob_error calls are faithful
   to history — what landed wrong was `blob_error` losing its opt-in consult;
   fixed in MY file (KvRoutes untouched). Prior-attempt pkill damage
   assessment: none in this lane — I pattern-killed nothing (SAFETY OVERRIDE
   held); the only foreign process observed (beam PID 26939 on 9445) was left
   untouched; all my background runs completed normally.
4. **Self-edits on shared seams**: none. Zero test-file edits. Zero commits
   (coordinator owns git transitions).

## Falsifier status

- Gate falsifier (six families green, zero test edits): RAN — 6/6 EXIT=0.
- B-XML falsifier (KV JSON restored AND blob XML kept): RAN — kds3_s4 1/3→3/3
  and kv_ec_create 4/5→5/5 flips witnessed; blob_xml_error stamped-XML legs
  green (7/9 with the 2 residual legs receipted as pre-existing).
- Non-vacuity: both flips are real state changes on the wire envelope, not
  test-side accommodation — the lib-side restore flipped them.

## Follow-ups (not this lane's files)

- table_service_plane + ThrottlePlug + PushRouterPlug + tenant_namespace +
  CosmosAuthzPlug — undock-lineage gaps owned by WO-2 (tenant fence, D2),
  D4 (throttle), and the cosmos/eventgrid lanes.
- The 2 residual blob_xml_error legs (InvalidRange 416 envelope,
  ContainerAlreadyExists 409 detection) — pre-existing engine defects, not
  envelope-law defects; need their own falsifiers (blob lane / WO list).
- KD-139/140 ensure_put_blob_type (pre-undock block) vs the undock lineage's
  own guards — diff review recommended before any re-land.
