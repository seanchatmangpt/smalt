# v26.10.25 Lane Ledger

Oct 23–25 fan-out wave, reconciled at wrap (coordinator census 2026-10-25).
Lane names are the self-labels embedded in module docs/test headers; ownership
is single-owner-per-file; the two unclaimed faces are assigned here.

## Lanes

| Lane | Face | Files (disjoint) | Census verdict |
|---|---|---|---|
| AZURE-FIDELITY 1–8/13/14/18 | arm_gateway modules + Graph stub + signIns + latency/throttle ARM classes | `lib/smalt/arm_gateway/*` (14), `lib/smalt/arm/deployments.ex`, `lib/smalt/egress/{graph_routes,signins,latency_plug,throttle_plug}.ex`, `lib/smalt/egress_router.ex` (shared seam, see RESOLUTIONS), 16 `test/integration/*` courts | GREEN (1230/1250 → all owned faces green after wrap fixes; signIns court 3/3 post-fix) |
| CONVERGENCE V4 (kql) | KQL where-route | `lib/smalt/data_plane/kql.ex`, `test/integration/kql_where_route_test.exs`, `test/data_plane/kql_sealed_court_test.exs` | GREEN |
| CONVERGENCE V10/V12 | policy/diagnostics faces | `lib/smalt/arm_gateway/{policy_assignments,diagnostic_settings}.ex` + owned tests | GREEN |
| V20a/V20b + KD-R17-3/4/5 + KD-S3/S4 (kv lane) | secrets versions-list + tenant fence legs | `lib/smalt/egress/KvRoutes.ex`, `lib/smalt/data_plane/key_vault_actions.ex`, `test/internal/kdlith_w2_versions_list_test.exs` (single-owner), `test/internal/kds3_s4_secret_version_history_test.exs`, `test/integration/kv404_typed_error_test.exs`, tenant_fence_blob_kv_queue | GREEN (census-fence registration + exemptions per kds3_s4 twin precedent) |
| V21 + KD-R17-1/2 (cosmos lane) | pk fences on point-read/delete | `lib/smalt/data_plane/cosmos.ex`, `cosmos_pk_point_read_delete_test.exs`, `cosmos_aad_auth_header_test.exs`, `cosmos_change_feed_test.exs` | GREEN |
| D-lanes (tenant law) | tenant_law + fences | `lib/smalt/auth/tenant_law.ex`, `test/integration/tenant_*_test.exs` | GREEN |
| MOONSHOT 9 | throttle plug | `lib/smalt/egress/throttle_plug.ex` + court | GREEN (default-off) |
| latency 10 | latency plug | `lib/smalt/egress/latency_plug.ex` + court | GREEN (default-off) |
| MTTW 14 | acceptance probe | `scripts/acceptance_probe.exs` + court | GREEN |
| KD-S5/KD-W01 | sas/shared-key normalization | `lib/smalt/messaging/amqp/sas_verifier.ex`, `scripts/{dev_env,substrate}.sh` | GREEN |
| WS-AMQP | ws bridge + relay | `lib/smalt/messaging/{amqp_ws_bridge.ex, ws_amqp_relay.ex}` + court | GREEN |
| EH-REST / SB-REST | REST producer faces | `lib/smalt/egress/{EventHubsRestRoutes, service_bus_rest_routes}.ex` + courts | GREEN |
| lith 15 (popcorn) | upstream actor extraction | `lib/popcorn/`, `popcorn_actors/` (source only; `public/out/` gitignored at wrap) | GREEN |
| R8 | config alias law | `lib/smalt/config.ex`, `test/config_alias_law_test.exs | GREEN |
| R9 | jwt issuer configurability | `test/issuer_config_test.exs` | GREEN |
| P14 | TLS-everywhere | `lib/smalt/tls.ex`, `test/internal/tls_all_planes_court_test.exs` | GREEN |
| R10 | sovereign-image recipe | `justfile.d/55-sovereign-image.just`, `docker/Dockerfile`, `Justfile` | census-signal only (no Elixir court; just --summary rc=0) |
| confidential-ledger face (was UNCLAIMED → assigned coordinator) | ledger face repairs | `lib/smalt/security/{confidential_ledger,ledger_writer}.ex`, `lib/smalt/confidential_ledger/router.ex`, `az3_confidential_ledger_court_test.exs`, `ledger_append_envelope_test.exs` | GREEN |
| designs/ (was UNCLAIMED → assigned milestone-doc) | pqc design note | `designs/pqc-client-side-admission.md` | GREEN (docs-only) |
| census reconcile (coordinator, Oct 25) | fence registration + fixes | `test/internal/internal_tier_census_test.exs`, `test/internal/hang_reap.exs` (sleep removed), `test/internal/armstrong_idiom_court_test.exs` (warm-up), `test/integration/trace_session_court_test.exs` (ensure_loaded), `lib/smalt/egress_router.ex` (v1.0 reserved segment — disclosed into the shared seam), 3 graphlaw-runner courts (graphlaw-run → graphlaw-run-eh repoint), `.gitignore` | GREEN with disclosure |

## Shared seams (RESOLUTIONS.md carries the detail)

- `lib/smalt/egress_router.ex` — tenant fence reserved segments (D-lanes + coordinator v1.0 fix), fall-through chain (w6R structural split), latency/throttle plugs (two lanes), Graph/signins faces (AF lanes 13/14).
- `lib/smalt/plane/data_supervisor.ex` — LatencyPlug mount + P14 egress TLS child (two lanes, disjoint hunks).
- `config/config.exs` — latency/throttle/marketplace config blocks (three lanes, disjoint hunks).

## Known-state / advisories

- Doctor ADVISORY: dev CA not trusted in macOS keychain (pre-existing; remediation needs sudo — operator call, not lane work).
- bench receipt stale (Oct 19) — `just bench` is a Wave-4 ladder step.
- graphlaw wasi staging toolchain was partially deleted by disk cleanup (bin/, sysroot, libc++ gone; duckdb .a archives intact) — full re-staging is `--force` mode (cmake duckdb rebuild, 30-60 min); NOT re-staged in this wrap. The smalt-side fix was artifact+runner restoration: pinned `priv/graphlaw.wasm` copied into `target/wasm-abi/.../wasm/` + `graphlaw-run-eh` release binary rebuilt. Re-staging remains available: `bash ~/frozen-duckdb/scripts/build_wasi_duckdb.sh --force`.
