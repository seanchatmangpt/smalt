# v26.10.25 Shared-Seam Resolutions

Shared seams crossed by multiple lanes; the coordinator reconciled at wrap.

## `lib/smalt/egress_router.ex`

- **Fall-through chain**: the w6R structural split (fall-through subrouters,
  then `plug :match`/`:dispatch`, blob splat LAST) is the composition law.
  New faces mount in the w6r_fallthrough list or as pipeline plugs — never by
  editing the blob splat.
- **Tenant fence reserved segments** (D-lanes + coordinator, 2026-10-25): the
  new `/v1.0/*` Graph face was missing from `@reserved_first_segments` and
  `blob_plane_path?/1`; a foreign-tid bearer namespaced the account segment
  `"v1.0"` in place → GraphRoutes fallthrough → blob 400 MissingXMsVersion
  (witnessed: signins court 0/3 census + live substrate curl). Fix: `v1.0`
  added to both lists (fence stays intact for real blob paths).
- **Latency/throttle plugs** (latency lane 10 / MOONSHOT lane 9): pipeline
  plugs declared ahead of the fall-through chain; both default-off; the data
  supervisor mounts `LatencyPlug` as the Bandit plug with `router:`
  delegation. Byte-identical boots when gates are off (courts pin this).
- **Graph/signIns faces** (AF lanes 13/14): mounted LAST in the fall-through
  chain; GraphRoutes falls through un-halted un-sent; signIns ring records
  at the STS mint site in `lib/smalt/arm_gateway/router.ex` (AF lead's file).

## `lib/smalt/plane/data_supervisor.ex`

- LatencyPlug Bandit mount (latency lane) and P14 `egress_tls_child/0`
  (P14 lane) — disjoint hunks, one owner per hunk, landed together.

## `config/config.exs`

- `:latency`, `:throttle`/`:throttle_clock`, `:marketplace_saas` config
  blocks (latency / MOONSHOT 9 / AF lane 8) — disjoint hunks; all gates
  default-off except the marketplace flip (documented in-file as
  default-ON 2026-10-25 with the byte-identical-fallthrough Gate 5 proof).

## Cross-lane disclosures

- Coordinator census-reconcile edits (Oct 25) rode lanes' files under the
  compile-freeze SLA with disclosure: census-fence registration
  (`internal_tier_census_test.exs`, `hang_reap.exs` sleep→observation-paced
  triple confirm), armstrong warm-up fence, trace-court `ensure_loaded` arms,
  the v1.0 reserved-segment fix above, and the graphlaw-runner repoint
  (graphlaw-run → graphlaw-run-eh after graphlaw's wasmi retirement) in
  `ath3_law_court_test.exs` + `w3cc_acp_court.exs` +
  `wasm_real_runner_court_test.exs`.
