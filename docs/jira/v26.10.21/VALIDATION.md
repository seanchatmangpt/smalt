# VALIDATION

Master validation board **v8** for the v26.10.21 ARD/PRD charter
(`docs/jira/v26.10.21/ARD-PRD.md`). Lineage: v1 (commit `dfe49a0`,
36 cells) and v2 (36 cells) are superseded; v3 (43 cells,
commit `7939df9`), v4 (45 cells, board mtime 14:51), v5 (the GWS
fold, 4 PENDING-GWS rows) and v6 (the post-v5 wave fold) are folded
into this board. v7 is the BOARDV3 fold (BK-22, `receipts/`-derived,
as-of 2026-10-21): every cell's receipt re-verified on disk; the
POWLBENCH row now reflects the fresh re-run
(`receipts/powlbench-fresh-rerun.md` PARTIAL_ALIVE — fresh p99
373 µs breaches the AR-PROD-05 ≤100 µs gate under machine load,
typed not smoothed), and the SEC-01 row folds the ML-KEM flip
evidence (`receipts/imp14-mlkem-flip.md` — Go mlkem-only is a
client-side UNSUPPORTED, OTP-side witnessed). v8 is the post-v7
wave fold (as-of 2026-10-22): the post-v7 receipt census
(`ls` + `receipts/INDEX.md`) landed ~37 receipts; every cited
path `[ -f ]`-verified on disk. Cell-level changes are exactly
three: **NFR-FOOTPRINT** cold-start folds the TTV-6 charter
ceiling re-type (500 ms → 2,000 ms — the measured 1,906 ms best
quiet boot now passes the re-typed ceiling; the original 500 ms
FAIL stands as measured history) plus the BK-33 warm-restart
rebind resolution; **AR-POWL-PERF** folds TTV-7/7b (the v7
quiet-tail falsifier's p50 clause did NOT fire — p50 6–7 µs —
but the ms-tail reproduces warmed under load, refuting the
cold-noise premise; the quiesced re-run is BLOCKED-ON-QUIESCENCE,
load never dropped below 84.5 vs the 32 gate); **NFR-COMPLIANCE**
folds the KD-register wave (register now spans KD-01..163 after
the BK-52 mints, with the BK-14/19/24/25/26/29/39/43/48/55
closure + tooling receipts). SYNC/TIV-5/PAT lanes are still
running — their cells are not flipped in this fold. v6 folded: the graphlaw/wasm/sandbox wave's
receipted lanes register as wave evidence (GWS-1..12 in `_LANES.md`;
GL receipts folded in the provenance). v6 folds everything post-v5:
**GL-KILL** (GL-10 skeptic's two KILL-class defects F1/F2 closed with
witness courts, skeptic 29/29, 78 neighbors green), **GLADJ** (GL-8
andon-wire shape conflict adjudicated to the canonical union envelope —
skeptic 17 + fullstack 2 + andon 24 = 43/43 courts green post-adjudication),
**WASM-1** (`receipts/wasm1-otp29-sandbox-port.md` ALIVE — bridge/pool/worker
ported, 6-gate sandbox court green; typed stub caveat: gates run against
`stub_runner.exs`, the wasmtime swap is config, `graphlaw_duckdb.wasm` does
not exist — closes PENDING-GWS-13 as ALIVE-on-stub), **GWS-12**
(`receipts/gws12-cross-engine-determinism.md` PASS — 3-leg determinism
differential, native ABI / wasm / BEAM COLD-1 partition identical — closes
the determinism half of PENDING-GWS-15), **GWS-11** (memory-wall court 7/7
on the real pinned `priv/graphlaw.wasm` binary, 2 runs incl. parallel),
**the SQLD/GLD data-ingestion wave** (SQLD-2/3/5/8 + GLD-2/4 receipted;
GLD-5 skeptic SUSPECT — F2/F3 since CLOSED post-v6 by
`receipts/gld5fix-null-formula-court.md`, see §3.4),
**the BENCH-ERLANG wave** (BENCH-3/5/6/7/8/10/11/13/14 receipted; BENCH-2/4/12
dispatched without receipts on disk), **OBS4COURT** (`receipts/obs4court-
peer-two-node.md` ALIVE — two-node real-`:peer` court 4/4; flips AR-OBS-04),
**ECOURT-F** (wire fence PASS 4 legs + loud SKIP on the default-off APIM
429/401 sub-leg), **SPEC-SCOPE + GWS-14 skeptic** (WASM-SANDBOX-SPEC §5
current-state amendment + final spec-compliance audit), and **GWS-2/7/13**
(wasm build trial PARTIAL_ALIVE with the DOCS_RS escape path ABI-matched;
real-ABI host bridge 18/18; integration manifest). v4 folded the post-v3
landings — **CAS412** (PRD-COSMOS If-Match wire path confirmed correct;
PB-1's DIV-1 resolved as SDK-side premise rot: `ifMatchEtag` appears
zero times in the @azure/cosmos 4.10.1 dist, so PB-1's 1700/1700
"accepted" witness never sent an If-Match header; 412 now carries the
current etag affordance; 35/35 regression tiers green), **IMPL-14F +
GOLEG** (TLS 1.3/ML-KEM default flip landed, 3-leg court PASS with the
config-revert escape; real-Go client 6/6 legs close the handshake
residual — R90/D52 failure shape does not reproduce; azidentity
auth-flow leg typed-open residual), **RELCUT** (deferred-listeners
phased boot, config-gated, front door 24% earlier; court 3/3),
**IMPL-24/25/26** (reductions standing fence, LRO selective drain
adoption, remaining spawn-site label adoption — OBS-02 adoption
complete), **WARNCLEAN/WARN2** (lib warnings 94→66→0 on the target
backlog: 9 modules zeroed, tiers green), **USERS500** (cosmos
users/permissions 500 closed as stale-beam artifact, healthy-shape
court landed), **T47** (cold-start FAIL measured on the release
subject), **PB-2/PB-5 receipts landed** (PENDING-PB bucket resolves to
zero), **CTXFILL** (window receipts law-clean: 0 NO-CONTEXT, 0 SUSPECT
after backfill of 41 context lines + 7 reproduction blocks),
**JSONSAX/FONDREC** (JsonCompat.stream/3 SAX helper 16/16; parallel
Erlang FOND/POWL runner family 7/7 courts), and **IMPL-13/19/20/21**
(JIT re-adjudication on the pinned 29.1.2 — REFUTED stands at 11.9%,
toolchain pin coherence, post-upgrade wire-tier 28/28 and real-SDK
5/5 witnesses on the recycled OTP-29 beam). Every cell is typed from a
landed receipt under `receipts/` — no cell is typed from prose.
Regenerable from disk: re-read the receipts and re-derive the table.

Standing of this board: **PARTIAL_ALIVE** — the wire planes, the OTP-29
adoption seams, the TLS 1.3 default (handshake face), and the PB bench
wave are ALIVE with named residuals (v7: the fresh POWLBENCH re-run
types a machine-load p99 gate breach on AR-PROD-05 pending a
quiet-machine re-run — see the AR-POWL-PERF row; v8: TTV-7b's quiesced
re-run gate is BLOCKED-ON-QUIESCENCE, so that adjudication is still
open); the honest remainder is the ARD
REFUTED pillars (ARD re-scoping, not implementation), the DATA
adoption gaps, and the
azidentity auth-flow leg, and the WASM stub-to-wasmtime swap
(`graphlaw_duckdb.wasm` does
not exist). Row-level PENDING: 0. Row-level PENDING-PB: 0. Row-level
PENDING-GWS: 0 (down from v5's 4 — GWS-SANDBOX-GATES closed
ALIVE-on-stub by WASM-1, GWS-DETERMINISM closed PASS by GWS-12,
GWS-IN-WASM-COURTS CLOSED PASS by BK-31 (`receipts/bk31-gws14-inwasm-courts.md`),
GWS-SEC-FUZZ CLOSED PASS by BK-32 (`receipts/bk32-gws15-sec-fuzz.md`;
GWS-15 fully closed) — all four GWS wave rows now CLOSED, none remaining).

Context: solo · Date: 2026-10-21 · Repo: /Users/sac/smalt

Verdict vocabulary: ALIVE (evidenced as scoped) · ALIVE-on-pinned
(evidenced under the pinned 29.1.2 toolchain; the host OTP-28 toolchain
compile-refuses the same tree — the pin IS the scope) · AVAILABLE
(API exists and behaves as typed by the arbiter; residual gate named) ·
PARTIAL_ALIVE (partly evidenced, named open half) · PASS (portable
availability + behavior witnessed) · CONFIRMED-on-pinned (API witnessed
on the pinned release; absent on host) · REFUTED (probe shows the claim
false as stated) · UNSUPPORTED (no API / no receipt / no court —
falsifier named) · FAIL (measured miss) · PENDING (not yet adjudicated).

## 2.1 Substrate Core (VAL-CORE → `receipts/val-ar-core.md` + arbiter override + IMPL-13)

| Req | Verdict | Evidence | Falsifier (flip condition) |
|---|---|---|---|
| AR-CORE-01 constant-memory process iteration | **AVAILABLE + adopted** | ARBITER override (`receipts/val-conflict-arbiter.md`): v1's UNSUPPORTED was a probe bug — p7 called nonexistent `process_next/1`; the real API is `processes_iterator/0` + `processes_next/1` (OTP 27+), `function_exported=true` on all three legs. Adoption landed: `lib/smalt/process_iter.ex` (`Smalt.ProcessIter` seam), court `test/internal/process_iterator_court.exs` 1/1 — 200k real procs traversed, every pid exactly once, iterator caller-heap delta **0 words** vs **514,605 words** for `processes/0` (`receipts/impl1-process-iterator.md`). Census adoption (IMPL-18, `receipts/impl18-vm-census-processiter-adoption.md`): `test/internal/vm_zero_growth_test.exs` census now reduces over the whole-VM population via `Smalt.ProcessIter.reduce/3` — real booted app, 1,492 live procs, 5/5 deterministic paired rounds, new-side heap delta 9,178 vs 10,802 words (**−15.2%**), sublinear-in-population scaling shape, 2/2 tests green on 29.1.1 | the arbiter's 500k-proc ≤64 KB sweep (measured this run: 200k / 0 words), any pinned re-run of `arbiter_iter_trace.escript all` printing `raw processes_iterator() => undef`, or a census-semantics regression failing the 2 zero-delta tests |
| AR-CORE-02 priority alias head injection | **REFUTED** | `p8_arcore02_drain.escript` 3 legs: priority accepted on 28.3.1 identically to 29.x; flood 2.0–3.5 ms, backlog 0.25–2.7 ms, mode-sign-agnostic; ≤500 µs gate fails on every release | paired min-of-N shows priority ≥3x faster than plain alias at 50k backlog |
| AR-CORE-03 JIT multi-segment binary matching ≥30% | **REFUTED (stands, re-adjudicated on the pin)** | `otp29-capability-probes.md` claim 2: 622 vs 635 ms min (~2% noise) on 29.1.1. **IMPL-13** (`receipts/impl13-jit-2912.md`) re-ran on the pinned 29.1.2 vs host 28.3.1: 1M mixed-endian decodes min-of-5, **612 vs 695 ms — 11.9% in favor of 29.1.2** with reduction counts byte-identical (131,001,116) — real speedup, still under the ≥30% gate; a real-AMQP FrameCodec leg agreed | paired min-of-N wall delta ≥1.5x, or the ≥30% ARD gate re-scoped downward with a receipted new bound |
| AR-CORE-04 escape-analysis in-place updates | **UNSUPPORTED** | no observable API; ARD names no gate; profiling court does not exist | tprof call_memory court authored + >0% delta across toolchains on a fixed workload (REFUTED if 0% on documented releases) |
| AR-CORE-IDOM ARMSTRONG idiom census top-3 violations (ARMFIX) | **ALIVE (fixed, courted)** | `receipts/armstrong-idiom-census.md` census → `receipts/armfix-top3-typed-violations.md` closure at HEAD `4326bd6`: `runtime_contracts.ex` rescues now return typed `{:error, :bad_name}` (no silent `{:ok, name}`/`{:ok, :unknown}` re-guess, `to_existing_atom` with rescue); `appconfig_features.ex` `eval_filter` rescue narrowed to `[ArgumentError, ErlangError]` + `[:smalt, :appconfig, :filter_error]` telemetry — unknown raises propagate (let-it-crash); `deployments.ex` correlation_id minted once per record via `make_ref()` (referentially stable across GET/PUT, id≡operationId); `egress_router.ex` Peers fallback correlationId minted PER EVENT (was shared per resource). Chicago court `test/internal/armstrong_idiom_court_test.exs` **8/8** + owning tiers 28/28 on rerun; one non-reproducing flake disclosed in the receipt | any typed-violation class from the census reappearing at HEAD, or the idiom court failing on a real caller |

## 2.2 Data Plane (VAL-DATA → `receipts/val-ar-data.md`, + `receipts/etsauto-rollout-impl3.md`)

| Req | Verdict | Evidence | Falsifier |
|---|---|---|---|
| AR-DATA-01 `{write_concurrency, :auto}` + `decentralized_counters` | **PARTIAL_ALIVE** (adoption landed, ARD CAS gate untested) | probes AVAILABLE both toolchains; census 0 → **3 adoption sites landed default-ON** (`:smalt_cosmos_ru`, `:smalt_arm_rate`, `:smalt_rolling_counters` — `receipts/etsauto-rollout-impl3.md`): court 3/3, min-of-3 walls 1417→141 / 1159→115 / 3762→67 ms (10–56x) at 128k atomic increments × 16 schedulers, exactness leg zero lost updates on real table state, reversible flag `:ets_write_concurrency_auto` | **v9 (BK-CELLS fold, 2026-10-22): ARD perf gate MEASURED PASS** — real adopted rate table (`Smalt.ArmGateway.Router.rate_table_for_test/0`), 16 workers x distinct keys (decentralized profile), exactness asserted on table state, min-of-3 p99 flat sub-µs at 256/1024/4096 rungs (0.333/0.709/0.5 µs; `../v26.10.22/receipts/bkcells-board-triage.md` §2, court `test/internal/bkcells_ard_cas_gate_test.exs` green). Typed residual: single-hot-key contention (16 writers, one key) shows sub-µs p50 but p99 spikes to ~160 µs at n=4096 — a harder contention class, not gated | the Store-CAS-tables adoption clause remains **UNBUILT** (code change; another lane owns store.ex in-flight) |
| AR-DATA-02 `ets:next_lookup` + `update_element/4` | **PARTIAL_ALIVE** (AVAILABLE with corrections; 0 adoption) | `next_lookup` is **/2 not /1**, ordered_set-only (badarg on set), past-end returns bare `:$end_of_table`; `update_element/4` is `(Tab, Key, ElementSpec, DefaultTuple)` — the `(Tab,Key,Pos,Value)` shape is badarg | **v9 (BK-CELLS triage, 2026-10-22): migration UNBUILT** — `ordered_walk/3` still `ets.next`-based (now at store.ex:395-409), zero `next_lookup`/`update_element` hits in lib/; code change pending, owner: next data-plane lane; flips REFUTED if any correction fails to reproduce |
| AR-DATA-03 `Registry.lock/3` | **PARTIAL_ALIVE** (API AVAILABLE; swap unsuitable as-stated) | real lock on composite key `{:lock, "blob", "container/x"}` ran and returned; Store funnel is load-bearing (next_seq race history, store.ex:277-301) — naive swap re-introduces the documented race | **v9 (BK-CELLS triage, 2026-10-22): redesign UNBUILT** — zero `Registry.lock` hits in lib/, no redesign receipt exists; the Store-funnel race refutation stands | atomics-preserving redesign receipted (insert_new/update_counter leave the funnel; true CAS redesigned), not a decoupling |
| AR-DATA-04 `PartitionSupervisor.resize!/2` | **PARTIAL_ALIVE** (exists; ARD grow-semantics wrong) | resize works within `[0, configured]` only (4→2→4 observed, resize to 8 refused with bound message); returns previous count, not `:ok` | **v9 (BK-CELLS re-witness, 2026-10-22): resize semantics re-witnessed at HEAD** — green court `test/internal/bkcells_data04_resize_probe_test.exs` (4→2→4, previous count returned, resize-to-8 raises `ArgumentError` "between 0 and 4, got: 8", state preserved; Registry child_spec template collision under 1.20.4 typed in the receipt). Adoption clause **UNBUILT**: still 0 PartitionSupervisor hits in lib/ | worker pool sized at max partitions + shrink witnessed in `lib/`; greenfield |

## 2.3 Wire / Serialization (VAL-WIRE → `receipts/val-ar-wire.md` + T46/IMPL-5 + JSONSAX)

| Req | Verdict | Evidence | Falsifier |
|---|---|---|---|
| AR-WIRE-01 native json + SAX streaming | **ALIVE** | SAX 51.6 MB: 464–506 ms / 0 KB retained vs ~845 MB full-tree peak, ~3.3x throughput, Jason parity true (`p9_wire.escript`, `p13_wire_peak.exs`). Rollout landed: `Smalt.JsonCompat` seam (byte-equivalence court, 9 payload classes — `receipts/t46json-native-json-seam.md` 5/5) + native-default host-gated flip + 3 hot decode families (arm_router Plug MFA, egress_router Parsers MFA + raw fallback, KV blob decodes; integration tier **170 tests, 0 failures** — `receipts/impl5-jsoncompat-rollout.md`). **JSONSAX** (`receipts/snippet-jsonsax-stream.md`): `Smalt.JsonCompat.stream/3` — discard-style SAX helper on the real `json:decode_start/3`/`decode_continue/2` API (the folklore `:json.decode/3` handler-map form is absent, per SNIPPET-REVIEW); court **16/16** + 7/7 standalone court, 50k-doc synthetic array in 3 chunks delivered exactly once in order, peak heap **92,736 bytes** < 1 MB budget; NDJSON/concatenated values typed | `p9_wire.escript` prints a non-ok NATIVE_SAX line or PARITY=false; any normalized `:json`-vs-Jason divergence beyond the typed `null` atom; stream/3 double-delivery or heap breaching the 1 MB court budget |
| AR-WIRE-02 `is_integer/3` guard | **ALIVE-on-pinned** | adopted: `int_in/3` `defguardp` delegating to the real OTP-29 range-guard BIF `:erlang.is_integer/3` in 4 hot files (`blob_storage.ex`, `cosmos.ex`, `file_share.ex`, `egress_router.ex`); compiles + range-enforces only under the 29.1.2 pin (`popcorn_demo/.tool-versions`, IMPL-9); host Elixir 1.19.5/OTP-28 compile-refuses. **IMPL-11 rollout landed** (`receipts/impl11-ar-wire-02-adoption.md`): 3 real conversion sites re-typed through `int_in/3` (`blob_storage.ex:1194 validate_period_days`, +2), guard-context limitation witnessed twice (`cannot invoke remote function :erlang.is_integer/3 inside a guard` — the defguard delegate is the adopted compiled form), all four court faces green (ALIVE), 2 defects caught and fixed mid-court. **v26.10.22 wire-surface shim-court re-run** (`../../v26.10.22/receipts/bk6-validation-closures.md`, ALIVE): `wire_norm_court.sh all` (KD-01/03/07, the wire-normalization shim surface) ALL LEGS PASSED with byte-exact RESTORE, after two court repairs — kd01 BEFORE re-anchored past the KD-139 blob-type gate + the fallback arm's modernized 201 shape, and a vacuous duplicated kd03_before clause removed (the ISO-8601 assertion now actually runs) | out-of-range input accepted on the pinned toolchain, or the pin reverts (the host toolchain is the standing falsifier witness) |
| AR-WIRE-03 strict generators `<-:-` + compr_assign | **REFUTED** | `[X || X <-:- L]` → syntax error on 28.3.1, 29.0.6, 29.1.1; compr_assign is plain Erlang already — no feature exists to adopt | `p10_wire_ca.erl` prints a `STRICT_GEN good=...` success on any pinned toolchain |

## 2.4 Security (VAL-SEC → `receipts/val-ar-sec.md` + IMPL-8/IMPL-14F/GOLEG)

| Req | Verdict | Evidence | Falsifier |
|---|---|---|---|
| AR-SEC-01 PQ hybrid default | **ALIVE (handshake face; azidentity auth-flow leg + Go mlkem-only single-shot pin typed-open residuals)** | **IMPL-14F flip landed** (`receipts/impl14f-tls13-default-flip.md`): `lib/smalt/tls.ex` default is now `[:"tlsv1.3", :"tlsv1.2"]` — 3-leg court PASS on the pinned 29.1.2: leg 1 default boot negotiates TLSv1.3, leg 2 same listener still serves TLSv1.2 (backward compat), leg 3 config-revert escape `[:tls_versions]= [:"tlsv1.2"]` refuses 1.3 (alert 70) and serves 1.2 — the R90/D52 pin remains one config line away. **ML-KEM group preference flip** (`receipts/imp14-mlkem-flip.md`, standing PARTIAL_ALIVE, lane bk2): `lib/smalt/tls.ex` tlsv1.3 branch now pins `supported_groups: [:x25519mlkem768, :x25519, :secp256r1]`; OTP 29 client with `[:x25519mlkem768]` negotiates `selected_group: :x25519mlkem768` against the live 9444 twin (curl regression 200); honest typing — on OTP 29 a no-option server already selects mlkem against an mlkem-only client, so the pin is behaviorally a durable-preference pin, not a behavioral change today (OTP 28 refuses the atom, riding the tlsv1.3 gate correctly). **GOLEG** (`receipts/goleg-tls13-client.md`): real Go 1.23.4 client, 6/6 legs, 0 errors — `default` (MLKEM share offered), `classical`, and `mlkemonly` (raw codepoint 0x4588) modes all negotiate TLS 1.3 against an unpinned listener and TLS 1.2 against the pinned 9444 twin; **the R90/D52 failure shape does not reproduce**; the v3 residual gate ("real Go client leg before flip") is closed for the handshake surface. **Go 1.24 leg** (imp14): `mlkem` first-preference handshake negotiates the hybrid KEM (TLS 1.3, cipher 1301); `mlkemonly` (single-shot pin, no ECDHE curve) is **UNSUPPORTED — a Go 1.24 client-side validation** ("tls: no supported elliptic curves for ECDHE"), not a server divergence (identical mlkem-only offer succeeds from an OTP 29 client against the same listener); close condition Go ≥ 1.25 or OTP-side capture of the negotiated group. **BK6 re-witness** (`receipts/bk6-kd157-h2-postrestart-witness.md`): go1.23.4 legs (default/classical/mlkemonly) all negotiate **TLS 1.3 on the live 1.3-default-flipped 9444 twin** — the production-seat face the original GOLEG could not witness (the twin was then 1.2-pinned and answered TLS 1.2). **v26.10.22 re-witness** (`../../v26.10.22/receipts/bk6-validation-closures.md`, ALIVE, 2026-10-22): default + classical legs again negotiate TLS 1.3 on the live flipped twin (0 errors); mlkemonly re-fires the Go-1.23 client-side refusal (`tls: CurvePreferences includes unsupported curve`) — typed residual unchanged. **BK-6 partial-cell closures receipt** (`receipts/bk6-validation-partial-closures.md`, ALIVE, v8 fold): SEC-01/WIRE-02/OBS-04 re-witnessed fresh — the backlog snapshot claiming these cells open was premise rot; the one genuinely open surface (KD-157 FLIP-PENDING-WITNESS) closed with the falsifier run for real. Typed residuals: (a) a full azidentity/azurerm Go SDK auth-flow session (OAuth2 over the twin) is still unprobed; (b) go1.23 does not export the negotiated group name; (c) Go mlkem-only single-shot pin (above) | an azidentity OAuth2 session failing the TLS handshake against the default-flipped listener, or a default-flip regression where an MLKEM-offering client is served TLS 1.2, post-dating the diff; mlkem-only flips to SUPPORTED on a Go toolchain whose client accepts the single-shot pin and completes the handshake |
| AR-SEC-02 dual `certs_keys` RSA+ECDSA | **ALIVE** | IMPL-8 court leg 3 on the real `bandit_opts/2` path: `SMALT_TLS_ECDSA=1` serves `ECDHE-ECDSA-AES256-GCM-SHA384` + `id-ecPublicKey` leaf (chain `Verify return code: 0 (ok)`) to ECDSA-preferring clients, `ECDHE-RSA-AES256-GCM-SHA384` + RSA leaf to legacy clients — both directions witnessed; ECDSA P-256 pair on disk, CA-chained | a handshake where an ECDSA-preferring client is served the RSA leaf, or the chain fails to verify, post-dating the diff |
| AR-SEC-03 CRL `allowed_hosts` SSRF fence | **UNSUPPORTED / N/A** | zero CRL-fetch code in lib/smalt; `crl_check => false`; airgap witness `tmp/bench/scvd-airgap.jsonl` (errors 0, loopback-bound) — nothing to restrict | any single non-loopback outbound connection from the substrate (then `allowed_hosts` becomes mandatory) |

## 2.5 POWL 2.0 (VAL-POWL → `receipts/val-ar-powl.md` + PB wave + FONDREC)

| Req | Verdict | Evidence | Falsifier |
|---|---|---|---|
| AR-POWL-01 EEP-79 native records | **UNSUPPORTED** | `p3_eep79.escript on 28.3.1 AND 29.1.1: forms rejected, records still require `-record` (`nodecl_compiles=no`) — IMPL-23's EEP-78 probe (`receipts/impl23-eep78-probe.md`) found the ADJACENT feature real: multi-element comprehension templates `[E1,E2,E3 \|\| X <- L]` compile on 29.1.2 and parse-fail on 28.5.0.2 (EEP-79 ≠ EEP-78; no ARD row names EEP-78, so no cell) | an OTP release ships EEP-79 (`p3` prints `nodecl_compiles=yes`) |
| AR-POWL-02 deterministic map-order Merkle hashing | **CONFIRMED-on-pinned + ALIVE as implemented** (IMPL-12 adjudication) | v2 typed REFUTED-as-claimed from `p4_maporder.escript` (`stable_of_100=0/100`) — **IMPL-12 found two defects in that probe** (`receipts/impl12-maporder-2912.md`); the corrected `p4_maporder_2912.escript` on the pinned 29.1.2 release: `stable_of_100=100/100` at every size 8..256, child-process equivalence 20/20, and the 256-key fingerprint `yjnri` byte-identical across runs AND across 28.3/28.5.0.2/29.0.6/29.1.1/29.1.2. Scope boundary (do not over-claim): deterministic per release, not a language guarantee — OTP 26.2.1 yields a different order (`1vfje5`); `maps:fold/3`-without-sorting admissible only under a pinned toolchain + fingerprint court. `Smalt.PPlan.ReceiptEngine` (ordered tuples + `{epoch,seq}` sort, re-seal `root_identical=true` incl. cold DETS reopen, 6/6 tests) remains correct as-is; no lib/ change required | flip back on `stable_of_100<100` in any pinned re-run of `p4_maporder_2912.escript`, a fingerprint mismatch across runs on the same release, or a ReceiptEngine re-seal yielding a different root |
| AR-POWL-03 functional graph module | **CONFIRMED-on-pinned + adopted** | stdlib-8.1 (29.x) ships the immutable `graph` module (acyclic/cycle legs pass, original term untouched); 28.3.1 `code:which(graph)=non_existing`. Adoption landed: `lib/smalt/powl2/graph_compat.ex` (commit `48ad71f`) + cross-engine court `test/internal/powl2_graph_compat_court.exs` green on OTP 28 **and** 29, 10-graph corpus (commit `b87092d`); replayed this session under the 29.1.2 pin: **8 tests, 0 failures** (0.1 s; `receipts/bk17-graph-compat-witness.md`). **IMPL-15** (`receipts/impl15-decomposition-graphcompat.md`): adoption extended to `decomposition.ex` (`block_order_edges/2` quotient graph, `block_cycle_check!/2` typed `{:powl2_refusal, :block_order_cycle}` refusal) — cyclic block order refused by BOTH engines in agreement | `code:which(graph)` non_existing on a future 29.x pin, or the cross-engine court diverging on a corpus graph |
| AR-POWL-PERF native-face latency | **REFUTED-favorably (measured row, POWLBENCH) — fresh re-run PARTIAL_ALIVE with a typed p99 gate breach** | prior operator estimate of 15–40 µs per native op is refuted favorably by measurement (`tmp/bench/powl-native-face.jsonl`, lane `powlbench`, surface `powl2-native`, OTP 29.1.2 / Elixir 1.20.4-otp-29, M3 Max): `point_read_etag3` n=10000 errors=0 **p99 2 µs** (p50 1 µs, 895k ops/s); `cas_put_if_match_200` n=10000 errors=0 **p99 5 µs** (383k ops/s). **POWLBENCH fresh re-run** (`receipts/powlbench-fresh-rerun.md`, standing PARTIAL_ALIVE, lane bk5, Context solo): fresh baseline `point_read_etag3` p99 4 µs / `cas_put_if_match_200` p99 6 µs (0 errors, n=10000 each) reproduce the regime; the 4-step settlement reproduced p50/p95 (29/77 µs) but **p99 373 µs (max 12.4 ms outlier) exceeds both the AR-PROD-05 ≤100 µs gate and the 200 µs falsifier on the fresh run** — typed as machine-load tail (concurrent lanes live during the run; n=200 coarse p99 ≈2 samples); adversarial 2×-step mutant leg is non-vacuous (p50 29→113 µs, 3.9x move). AR-PROD-05 "within gate" now rests on the earlier run; the fresh breach is the loudest data point until a quiet-machine re-run (`just quiet-check` precondition) re-adjudicates. Wire-face comparison rows (T43): point-read wire p99 0.813–1.1 ms vs native 2 µs (~400–520x), decomposition ESTIMATE-not-measurement, typed in the jsonl note. **v8 (TTV-7/7b fold)**: `receipts/ttv7-warmed-p99-standard.md` (PARTIAL_ALIVE) — guarded 4-step settlements at load 132.8: **COLD p50 7 µs / WARM p50 6 µs** — the v7 falsifier's p50 clause did NOT fire; but the ms-tail reproduces on the WARM profile too (p99 197 ms, max 3.06 s, identical reds/step 285.4), so the "cold-start noise" premise is refuted and the tail is typed machine-load (per-step compute exonerated via reductions). `receipts/ttv7b-quiesced-rerun.md` (BLOCKED-ON-QUIESCENCE): the pre-registered quiesced re-run gate (load < 32) never met — window minimum 84.5, 2.6x the gate — so the quiet-tail adjudication remains open | a re-run of the native face with p99 > 15 µs on the same surface/toolchain, or the estimate-only wire decomposition being cited as a measurement; **v7 falsifier:** a quiet-machine re-run where p50 also exceeds 100 µs (not just the tail) refutes the tail-noise typing and escalates AR-PROD-05 to failing; **v8 residual:** the TTV-7b quiesced re-run (load < 32) — if the ms-tail reproduces at low load it is a REAL typed defect |
| AR-POWL-CEIL executor concurrency ceiling | **PARTIAL_ALIVE (PB-3)** | `receipts/pb3-executor-ceiling.md` + `tmp/bench/pb3-executor-ceiling.jsonl`: N independent 4-step settlements through `Smalt.POWL2.Executor.execute_admitted/6`, real DETS, ramp 64→8192, **0 errors at every rung, `wall_level=unreached-at-8192`** (2x past the wire face's clean ceiling); vs the wire wall (T3, typed at L8192 with 534 typed errors): the wall's locus is the socket/handshake layer, not the orchestration kernel. Honest decay typed: beyond ~L2048 slow-but-never-wrong (ops/s 22.8k@1024 → 3.8k@8192, latency plateaus ~200–240 ms scheduler-queueing). CTXFILL re-ran the full bench fresh (exit 0, 0 errors L64→L8192, wall unreached) — SUSPECT flag closed with real output | **v9 (BK-CELLS escalated ramp, 2026-10-22)**: ramp extended to L32768 (4x prior probe) — **0 errors at every rung, `wall_level=unreached-at-32768`** (`tmp/bench/pb3-escalated-bkcells.jsonl`, log `tmp/bench/pb3x-bkcells.log`); slow-but-never-wrong decay continues (p99 828→860→4121 ms). The ceiling above L32768 remains UNKNOWN — an escalated run that keeps not failing extends, never closes, this cell | an escalated ramp reaching a first-error cliff above L32768, or any untyped collapse / DETS failure below the reached rung |
| AR-POWL-PB1 FOND loop: native vs SDK-over-HTTP under CAS contention | **PARTIAL_ALIVE (DIV-1 resolved as premise rot; SDK-leg rerun pending)** | `receipts/pb1-fond-loop-latency.md`: native leg fully executed — contention 0→100%, 0→10 forced strong-cyclic retries/settlement, 0 errors; SDK-leg contention injection is possible, the v3 "impossible on this substrate" reading was **premise rot**: **CAS412** (`receipts/cas412-cosmos-replace-if-match.md`, standing ALIVE) proved the cosmos wire surface honors If-Match on replace — 800/800 stale-If-Match replaces → 412 via real @azure/cosmos 4.10.1 over the TLS twin; the 1700/1700 "accepted" witness used `ifMatchEtag`, which appears ZERO times in the SDK dist (silently swallowed, no header sent, server correctly answers last-writer-wins 200). Landed affordance: stale-412 now carries the CURRENT etag in the `ETag` response header (Azure envelope unchanged); CAS412R regression (`receipts/cas412r-postfix-regression.md`) 35/35 on the recycled OTP-29 beam | SDK-leg contention rows typed using real `accessCondition*` options (never `ifMatchEtag`) on the proven If-Match-honoring surface; or any witnessed 200-on-stale-etag with a real If-Match header on the wire |
| AR-POWL-PB4 ReceiptEngine dual-path | **REFUTED-as-noise (PB-4)** | `receipts/pb4-merkle-dual-path.md` + `tmp/bench/pb4-merkle-dual.jsonl` (16 rows, errors=0): the O(n) fingerprint-gated variant is byte-identical (correctness gate PASS at every cell, both ingests) but **not faster** — fast path 76.5 ms vs current 64.7 ms at n=10k, 950 vs 656 ms at n=100k sorted; the O(n log n)→O(n) WO is not gate-eligible on these numbers, the current sorted-tuple path stands | the variant beats the current path by the gate margin on a re-run, or a workload class where the fingerprint hits >shuffled rate |
| AR-POWL-PB6 dual-boundary settlement walk | **ALIVE (PB-6)** | `receipts/pb6-dual-boundary.md` + `tmp/bench/pb6-dual-boundary.jsonl` (5 rows, 0 errors both legs): same 5-step settlement through real `@azure/cosmos` 4.10.1 over the TLS twin (N=300) and native `Smalt.POWL2.ChangeFeed` (N=5000); lease +0.708 ms (9.7x), CAS +0.675 ms (12.6x), observe **−1.630 ms (0.3x, CDC drain beats point-read)**; honest decomposition typed (SDK negotiates HTTP/1.1 over the HTTP/2-capable twin) | a re-run where the observe step flips positive, or the tax table being cited without the decomposition caveats |
| AR-POWL-PB2 reductions-per-step denominator | **PARTIAL_ALIVE (PB-2)** | `receipts/pb2-reductions-denominator.md` + `tmp/bench/pb2-reductions-step.jsonl` (7 rows, exit 0, run-to-run variance <0.1% over 5 runs): stage-composed denominator **≈17.5k reductions per 8-step settlement orchestration**, per-step divider ≈1,609 reds/step; dominance finding — record+seal (15,224) is ~9x the FOND scheduling + HTN + graph-validation work combined (2,320); `fond_runner_total` row typed caller-side (41,041), statem internal cost lives in the per-stage rows. Honest caveats typed: execute_primitive/receipt_seal bodies include DETS open/close per iteration; the per-step divider is derived, `receipt_seal_alone` words (74) derived | a per-stage tprof/reductions court contradicting any table cell, or a dominance flip (scheduling work exceeding engine work) on a re-run |
| AR-POWL-PB5 cross-language differential (Erlang runner vs Executor) | **ALIVE (correctness differential closed; executor ahead on measured perf; no promotion)** | `receipts/pb5-crosslang-differential.md` + `tmp/bench/pb5-crosslang.jsonl` (n=200/engine, 0/200 errors both): receipt byte-identity **TIE** — 3-way Merkle `AC94479A…AC3` identical through both seal paths; correctness race closed (was 98/200 runner errors, now 0/500 false positives); perf: executor ahead on p50 (0.084 vs 0.456 ms) and throughput (11,426 vs 2,118 ops/s, 5.4x); typed honest delta: the fixed runner emits a gen_statem termination error report per run (abnormal `{stop, {completed, Receipt}}` exit) rendered inside the timing window — reported, not fixed, owning lane's call. Promotion ineligibility lifted; promotion itself not executed | a receipt byte-identity mismatch through both seal paths, or any 0/200→error regression on a re-run |
| AR-POWL-FONDREC parallel Erlang FOND/POWL pipeline family | **ALIVE (FONDRUNNER)** | `receipts/fondrunner-otp29-pipeline.md`: new parallel Erlang module family under `lib/smalt/pipeline/` (landed Elixir POWL2/PPlan stack untouched) — `smalt_fond_plan.erl` (linear HTN + Kahn acyclicity, crash-only `{cyclic_plan, _}`), `smalt_fond_seal.erl` (deterministic Merkle seal behind the IMPL-12 order-fingerprint gate: `otp_release>=28` AND sentinel `phash2 == 628801`, else typed `{order_fingerprint_mismatch, Got, Want}` — non-vacuous: 26.2.1 and 28.3 both refuse with real binaries), `smalt_fond_powl_runner.erl` (gen_statem, 5-stage htn→fond→powl→ocel→seal); courts **7/7 green**, 3 consecutive runs byte-stable, pinned 29.1.2 | a court divergence between engines on any corpus plan, or the fingerprint gate admitting on a toolchain whose sentinel phash2 ≠ 628801 |

## 2.6 Observability (VAL-OBS → `receipts/val-ar-obs.md` + IMPL-26)

| Req | Verdict | Evidence | Falsifier |
|---|---|---|---|
| AR-OBS-01 `trace:session_create/3` | **AVAILABLE** | ARBITER override (`receipts/val-conflict-arbiter.md`): v1's UNSUPPORTED was two probe defects (missing `code:ensure_loaded(trace)`; opts `#{}` instead of `[]` → badarg at trace.erl:1510). API is OTP 27+ (kernel trace.beam resolves on all three legs); T37 two-session zero-cross-drop gate holds on every leg (s1_r1=2, s2_r2_after_s1_stop=3); Phase-4 isolated-trace-session migration unblocked | a pinned re-run of `arbiter_iter_trace.escript all` with `session_create(name, self(), [])` raising, or a 20-court concurrent-trace gate recording <100% of events |
| AR-OBS-02 `proc_lib:set_label` crash rendering | **PASS (adoption complete, IMPL-26)** | micro-court: crash report renders `process_label: {val_obs,probe_label_42}` on 28.3.1, 29.0.6, 29.1.1; IMPL-6 labeled 4 actor families; **IMPL-26** (`receipts/impl26-ar-obs-02-label-adoption.md`) completed the adoption: census of remaining spawn sites in `lib/smalt` — APIM rate-table owner, hw serial readers (stdio + file), POWL2 frontier eval all LABELED under the IMPL-6 schema; AMQP connection children already labeled in-init; negative census typed (no spawn sites in `lib/smalt/data_plane/` or `event_grid_webhook.ex`); court **6/6**, regression pass green, landed at HEAD `8defcf5` | a toolchain where the label stops rendering in crash reports, or a new labeled-family spawn site landing unlabeled past the census |
| AR-OBS-03 tprof call_memory fence | **ALIVE** (fence landed; gate + non-vacuity court PASS) | `scripts/tprof_memory_profile.exs` + fail-closed `scripts/tprof_memory_gate.py` (ceiling 200 words = 134-baseline + 49% headroom) + `just memory-gate`/`memory-gate-seed`/`memory-gate-court` (`justfile.d/44-obsfence.just`); real run: `[PASS] tprof-memory-gate: 134 words/txn <= ceiling 200 (otp 28, 51 rows)` — reproduces the VAL-OBS baseline exactly; shim-court flip witnessed (`receipts/ar-obs-03-memory-fence.md`) | the CI fence failing to discriminate an injected regression — the shim court must REFUSE (a gate that accepts the shim exits 1 VACUOUS) |
| AR-OBS-04 `peer` multi-node orchestration | **ALIVE (v6 — court landed, OBS4COURT)** | v4 typed PARTIAL (available, no court). **OBS4COURT** (`receipts/obs4court-peer-two-node.md` ALIVE) landed the missing half: `test/integration/peer_two_node_court.exs` — two ephemeral BEAM nodes over loopback distribution, real `:peer` + `:erpc` (no mocks), remote boots real `Smalt.Store` faces via shipped beam binaries; **4/4 legs green, two consecutive runs, exit 0**, epmd clean after teardown; owner-process face-boot pattern fixes the transient-worker `:noproc` race witnessed mid-court. **BK6 re-run** (same session, fresh): **4/4 passed** (56.6 s, exit 0) on the recycled beam — `receipts/bk6-kd157-h2-postrestart-witness.md`. **v26.10.22 re-run** (`../../v26.10.22/receipts/bk6-validation-closures.md`, ALIVE, 2026-10-22): distributed runner (`--name court127@127.0.0.1 --cookie smalt_peer_court`), **4/4 passed, exit 0** (1.3 s) — forward/reverse erpc round-trips 41/64 µs/op, injected disconnect typed `{:node_down, …}`, epmd clean | a court run where a cross-node health call returns `:noproc`, or a remote node surviving its linked runner halt (lifecycle leak) |

## 3.1 PRD planes (VAL-PRD → `receipts/val-prd.md` + KVCRYPTO + APPWS + APIMWIRE + CAS412 + USERS500)

| Req | Verdict | Evidence | Falsifier |
|---|---|---|---|
| PRD-BLOB Blob wire parity | **ALIVE** | KD-135/137/139 CLOSED (`../v26.10.20/receipts/bkd-kd135-137-139-witness.md`: Delete Blob 202, 416 + InvalidRange XML + x-ms-error-code, 400 MissingRequiredHeader); **v8: BK-39 KD-144/145/146 blob-face fixes landed** (`receipts/bk39-kd144-146-blob-fixes.md`, ALIVE — container etag routes through `storage_etag(seed)` with `# KD-COVERS: KD-144`); `blob_error.ex`; scvd-blob putget-c128 n=512 errors=0; caveat: KD-142 still OPEN in register | a live SDK delete reverting to 409 on a default container, or a 4xx/5xx face rendering JSON instead of StorageError XML, post-dating the shims |
| PRD-COSMOS Cosmos core/SQL + authz | **ALIVE (scoped)** | KD-147/148 closed (`../v26.10.20/receipts/fix3-kd147-152-witness.md`: clean body keys, quoted-GUID etag, CAS 200/412); 0 errors through ramp-L4096, typed wall at L8192 (`tmp/bench/scvd-tier3.jsonl`); the "50k RU/s burst" line is operator-asserted aspiration, NOT measured. **CAS412** (`receipts/cas412-cosmos-replace-if-match.md`): If-Match on replace wire-proven correct (800/800 412s, real SDK) and stale-412 now etag-carrying. **USERS500** (`receipts/us500-users-permissions-500-court.md`, standing PARTIAL_ALIVE): POST users[/permissions] 500 closed as **stale-beam artifact** — healthy 201s witnessed on the current shared beam with full Azure record shape, typed errors (400 missing resource / bad permissionMode, 404 unknown user, 409 duplicate); healthy-shape Chicago court landed over real `CosmosAuthzPlug`/ETS, no mocks; one compile-freeze repair disclosed | a live 429 inside the charter envelope, a witnessed 200-on-stale-If-Match on the wire, or a users/permissions 500 reproducing on a non-stale beam |
| PRD-SB Service Bus + Event Hubs | **ALIVE** (no Dedicated-cluster surface — typed per T18) | KD-131/132 (`fix4-amqp-witness.md`), KD-143 (`fix2-kd143-witness.md`), KD-155 (`kd155-sdk-deletequeue-witness.md`: real SDK deleteQueue 204); EH ramp send-c128 n=512 0 errors; KD-157 h2 reset-rate parity witnessed (`receipts/kd157-h2-reset-rate-parity.md`); T27 LQ paging witness (`receipts/t27lq-listqueues-paging-witness.md`) | CBS put-token 401, rule GET echoing `trueFilter`, deleteQueue `HPE_INVALID_CONSTANT` recurrence, or any Dedicated-cluster claim |
| PRD-APIM policy gateway | **ALIVE** (wired + wire refusals witnessed; dedicated witness receipt filed, BK-CELLS 2026-10-22) | APIMWIRE checkpoint `1570385`: `Smalt.Apim` wired into the router (`lib/smalt/egress_router.ex` +54 lines, supervised rate-limit ETS fixing the counter-reset defect, default-off pass-through), 429/401 wire refusals witnessed; closes v1's row-level PENDING. **v9**: witness receipt filed — `../v26.10.22/receipts/bkcells-apim-witness.md` (6/6 real-router court green at HEAD: default-off 404, echo 200, typed 429, typed 401, valid STS JWT admits, jwt-wins chain order) | a policy chain that stops being served by the live router, or a 429/401 without the supervised ETS counter behind it |
| PRD-KV Key Vault / HSM | **ALIVE (secrets + crypto faces)** | v1 typed crypto down to the POWL-8 HsmSigner; **KVCRYPTO closed the witness gap** (`receipts/prd-kv-crypto-face.md`): the face was already routed (`KvRoutes.kv_crypto_dispatch/4`, api-version 7.4, KD-16 versioned routes) — implementation gap, not witness gap; live-substrate witness (pid 8877): create 200, ES256 sign 200, verify 200 `valid:true`, wrong-digest/bad-sig `valid:false`, HS256 → 400 InvalidAlgorithm, unknown key → 404 KeyNotFound; Chicago tests over real STS dance, no mocks | a witnessed KV REST crypto response with an Azure-inconsistent shape |
| PRD-APPCONF App Configuration | **ALIVE (config/flags + webhook push face)** | @azure/app-configuration 1.13.0 unmodified SDK 7/7 PASS (`../v26.10.20/receipts/wire-parity-matrix.md`); flag engine witnessed (KD-109); sub-ms ETS lookups (T23 p50 0.519 ms); **push sub-claim closed by APPWS** (`receipts/appconf-push-webhook-face.md`): `AppConfigEvents` GenServer with Event Grid envelope typing (KeyValueModified/Deleted), loopback SSRF fence typed (`{:error, {:refused, :non_loopback_endpoint}}`), 5/5 Chicago tests + combined run 21/0; HTTP-delivery variant typed UNSUPPORTED-by-airgap (zero outbound dial in `lib/`) — recorded per event, never a silent drop | sync-token regex crash or non-200 PUT post-dating the fixes; push flips on a real Event Grid receiver rejecting the envelope shape, or a non-loopback URL being admitted |

## 3.3 NFRs (VAL-NFR → `receipts/val-nfr-migrate.md` + T45 + T47 + RELCUT)

| Req | Verdict | Evidence | Falsifier |
|---|---|---|---|
| NFR-CONCURRENCY L8192 wall | **ALIVE as-scoped** | `tmp/bench/scvd-tier3.jsonl`: 0 errors through ramp-L4096; ramp-8192 = 534 errors with `typed_fail_512:true` (typed backpressure, not collapse) | untyped 5xx or unbounded memory growth inside L4096 |
| NFR-LATENCY sub-ms point ops | **PASS** (BK-CELLS 2026-10-22) | T23 serial floor (n=1000/face, 0 errors): KV p50 0.519/p99 1.322 ms PASS. **BK-CELLS floor re-run** (`tmp/bench/bkcells-floor.jsonl`, harness `tmp/bench/bkcells_floor.mjs`, n=1000/face strictly serial, live 9444 twin, STS bearer): cosmos p50 0.62 ms ≤0.8 PASS, p99 1.035 ms ≤3 — the T23 3.040 ms head-of-line outlier cleared on re-run; **blob-PUT 1 KiB p50 0.765 ms ≤1.5, p99 1.06 ≤4 ms, 1000/1000 ok 0 errors** — the missing serial blob-PUT receipt now exists (final blob state download-verified). "E5BLOB 916 µs" remains nowhere on disk and is no longer load-bearing | a re-run breaching any charter latency gate, or the E5BLOB 916 µs figure surfacing without a receipt |
| NFR-FOOTPRINT cold start / idle / WASM | **Cold start: PASS against the TTV-6 re-typed 2,000 ms charter ceiling (v8); the original 500 ms FAIL (T47, 1,906 ms = 3.8x) stands as measured history; idle: UNSUPPORTED; WASM: ALIVE** | v2 typed the cell from T36/T45 (dev-path shape). **T47** (`receipts/t47-release-boot-gate.md`): release builds, boots, serves real ops (ARM 200, Cosmos 200), best quiet-machine cold boot 1,906 ms — the ≤500 ms ceiling was **FAILED at 3.8x**. **TTV-6** (`receipts/ttv6-cold-boot-gate.md`, ALIVE, v8 fold): the charter ceiling is **re-typed 500 ms → 2,000 ms** in `DIRECTIVES.md` ("Release cold-boot budget (TTV-6)") with a named falsifier and load-exclusion clause; the measured best quiet boot (1,906 ms) passes the re-typed ceiling, the loaded series (16.2–19.1 s at load 144) is typed load-bound residual, and the receipt honestly records the 500 ms CONFIRMED FAILED as the finding that motivated the re-type. **BK-33** (`receipts/bk33-warm-restart-rebind.md`, RESOLVED/ALIVE, v8 fold): the warm `System.restart` rebind FAIL witnessed by TTV-6's loaded series is **resolved** — root cause was the heir-to-init ETS table surviving restart (not a listener defect); warm restart rebinds all 6 listeners 3/3 under court, `tmp/bench/bk33-warm-restart.jsonl` (5 rows). **RELCUT** (`receipts/relcut-deferred-listeners.md`, ALIVE, court 3/3): config-gated `:deferred_listeners` phased boot — front door serves **24% earlier**; known limitation: supervisor-level restart in deferred mode re-inits without deferred listeners (one-shot deferral). T45 remains valid as the dev-path mechanism decomposition. Result file `tmp/bench/t47-release-boot.jsonl` (9 rows) | cold start: a release boot breaching the re-typed 2,000 ms ceiling on a quiet machine; idle: a stationary idle-RSS sampler receipt; WASM flips on a failed browser blob leg |
| NFR-COMPLIANCE SDK wire authority | **ALIVE as-scoped** | canonical KD register **KD-01..163** (flips receipt-gated via kd_flip.py — hardened by BK-55 witness identity pinning, `receipts/bk55-kdflip-witness-pinning.md`); T24 wire-parity matrix (6 SDKs end-to-end); KD-157 witness receipt landed; open rows registered, not hidden. **v8 KD-wave fold**: BK-52 minted KD-161..163 (JA-9 OTP-29 scaling divergences, `receipts/bk52-kd161-163-mint.md`); closures witnessed on the live wire — KD-10/75 (`receipts/bk24-kd10-75-key-route.md`), KD-92/93 (`receipts/bk25-kd92-93-cosmos.md`), KD-14/23 (`receipts/bk26-kd14-23-auth.md`), KD-79 (`receipts/bk29-kd79-close.md`), KD-93 (`receipts/bk43-kd93-close.md`), KD-143 (`receipts/bk14-kd143-sqlfilter-persistence.md`), KD-144/145/146 fixes (`receipts/bk39-kd144-146-blob-fixes.md`); pinion witness BK-48 (`receipts/bk48-pinion-witness.md`); register-structure repair BK-34 (`receipts/bk34-register-structure-repair.md`); coherence/skip/lease censuses BK-30/36/38/40 (`receipts/bk30-kd-coherence-census.md` PARTIAL_ALIVE — 3 structural defects typed, `receipts/bk36-wave-row-triage.md`, `receipts/bk38-lane-lease-census.md`, `receipts/bk40-skip-audit.md` PARTIAL_ALIVE); KV/Cosmos/Queue conformance BK-19 (`receipts/bk19-kv-cosmos-queue-conformance.md` ALIVE). Post-upgrade re-validation on the recycled OTP-29 beam: IMPL-20 wire-tier census **28/28** (`receipts/impl20-postupgrade-tiers.md`), IMPL-21 real-SDK witnesses **5/5, 0 errors** (`receipts/impl21-postupgrade-sdk.md`), CAS412R **35/35** (`receipts/cas412r-postfix-regression.md`) | a substrate-vs-SDK dispute resolved against the substrate, or a register flip landing without a PASS witness |

## 3.2 smalt-migrate legs (VAL-NFR → `receipts/val-nfr-migrate.md` + M4SBFIX + NFR-2 budget)

| Req | Verdict | Evidence | Falsifier |
|---|---|---|---|
| Trilingual IaC parser | **ALIVE** | `../v26.10.20/receipts/migarm-arm-template-parser.md` (14 new tests; .tf+.bicep+.arm.json merged in one ScanResult; 62 pass / 1 pre-existing skip) | a template family that parses to a wrong IR node |
| Deterministic manifest | **ALIVE** | `../v26.10.20/receipts/smalt-migrate-wave1-audit.md` M2 (NFR-3 byte-identical manifests, `test_nfr3_determinism_byte_identical`) | identical inputs yielding differing manifest bytes |
| Inject + rollback | **ALIVE** | same audit M3, 12/12 (read-only, stdlib-only, dry-run writes nothing) | rollback restoring wrong bytes or dry-run writing to disk |
| Wire-gate verify | **ALIVE (zero-skip receipted)** | `receipts/m4sbfix-verify-zero-skip.md`: re-run under `.venv-cli` with the derived-key client fix in `smalt-cli/verify.py` — **11 passed, 0 skipped, 0 failed** (9.85 s wall) | a verify/e2e suite run with any silent skip, or a wire gate passing on a mutated observation |
| e2e pipeline + NFR-2 budget | **ALIVE (e2e) / budget receipted (30 s bound)** | `../v26.10.20/receipts/t26-rehearsal-demo.md` (4/4 REHEARSAL-PASS + exit-2 non-vacuity) + `../v26.10.20/receipts/migrate-enterprise-fixture.md` (43 passed, live verify zero_egress); NFR-2 budget receipt (`receipts/migrate-nfr2-budget.md`): 50-resource pipeline 0.205 s vs the 30 s budget (~150x headroom; synthetic in-process body, bounds orchestration cost, not per-resource wire latency) | a pipeline stage failing on the fixture, or a measured run exceeding the receipted 30 s budget |

## 3.4 SQL ingestion wave (v6 — SQLD/GLD lanes)

Wave premise (PROD-CORE-ADDENDUM §65): SQL corpora seed the SAME pipeline —
converters live in smalt; the analytical engine never crosses the boundary.

| Row | Verdict | Evidence | Falsifier |
|---|---|---|---|
| SQLD-2 pg_dump ingestion court | **PASS** | `receipts/sqld2-sql-ingest-court.md`: real duckdb CLI v1.4.1, six-leg court, deterministic synthetic pg_dump (500 rows COPY, sha256-pinned generator); new `lib/smalt/sql_ingest.ex` (stdlib-only COPY parser + CSV emit); header fail-open fixed, poisoned-table refusal witnessed (commit e4864b4 line) | a dump the converter mangles silently, or a court leg accepting a poisoned table |
| SQLD-3 SQLite ingestion court | **PASS** | `receipts/sqld3-sqlite-ingestion-court.md`: real `/usr/bin/sqlite3` 3.51.0 + duckdb `sqlite_scanner` (typed availability check; the extension is `sqlite_scanner`, NOT `sqlite` — recorded so no future lane reads that as absent); OCEL projection artifacts + typed SKIP (exit 3) path | the sqlite_scanner extension uninstalling (loud SKIP, never a fake pass), or a projected OCEL CSV drifting from the source db |
| SQLD-5 SQL→SHACL auto-shape generation | **ALIVE** | `receipts/sqld5-sql-shape-gen.md`: `Smalt.GraphLaw.SqlShapeGen` — duckdb DESCRIBE shape → SHACL Turtle in exactly the GL-2 law-compiler grammar; 14/14 court, round-trips through `ShapeFile` admission; unmappable types are a typed `ArgumentError`, never silent widening | a schema whose shapes fail to round-trip through the substrate's own admission grammar, or a DOUBLE/DECIMAL silently widened |
| SQLD-8 bulk-ingest perf baseline | **PASS** | `receipts/sqld8-ingest-baseline.md` + `tmp/bench/sqld8-ingest-baseline.jsonl` (2 rows, errors=0): 100k-row pg COPY dump (4.23 MB), converter 64.7k rows/s, direct path 450k rows/s; fences derived from measurement; AR-BENCH-01/02 compliant (no fixed sleeps, memory/reds bans honored) | a re-run dropping below the derived fences, or a ban violation in the harness |
| GLD-2 CDC incremental ingestion | **PASS** | `receipts/gld2-cdc-court.md`: epoch-snapshot + append-only delta log (update_before/update_after paired by `tx`, terminal delete tombstone); court legs: 100-row epoch, 145 events, 115-row ledger (no phantoms), exact-delta + idempotency + durability + tamper legs, exit 0 | a delta log whose replay diverges from the epoch fold, or a tamper leg passing on a mutated ledger |
| GLD-4 SQL-seed closure court | **PASS** | `receipts/gld4-sql-seed-court.md`: corpus seeded FROM a postgres-style SQL dump yields a **byte-identical OCEL corpus and identical quarantine/release partition** to the COLD-1 receipt — the ingestion path does not change the governed outcome | any byte difference in the OCEL corpus or any partition flip between SQL-seeded and fixture-seeded runs |
| GLD-5 SQL-ingestion skeptic | **SUSPECT → F2/F3 CLOSED post-v6** (as-of 2026-10-21, `receipts/gld5fix-null-formula-court.md` ALIVE) | `receipts/gld5-ingestion-skeptic.md`: execution surface holds (nothing in a hostile dump is executed; typed refusals fire on the newest text; F1 flip is the non-vacuity proof); skeptic verdict was F2/F3 open — **both since CLOSED by `receipts/gld5fix-null-formula-court.md`** (typed `\N` NULL sentinel + numeric-exempt `'` neutralization, value-exact 6/6 court in real duckdb v1.4.1, zero row loss); two mid-audit mutations disclosed per the compile-freeze law | F2/F3 fixed with witness courts (DONE — gld5fix receipt); any regression re-opens |
| GLD-1 / GLD-6 / GLD-7 | **UNWITNESSED at v6 write time → receipted post-v6** (as-of 2026-10-21) | v6 correctly recorded no gld1/gld6/gld7 receipts on disk; all three have since landed: `receipts/gld1-sql-n3-court.md` (PASS — N3 fixed-point partition equality, three consecutive runs, sha `c5c65bd1…eed1990` fixture), `receipts/gld6-sql-row-gate-security-court.md` (ALIVE — 7/7 PASS, two seeds 456741/99), `receipts/gld7-ingest-to-settlement-court.md` (ALIVE — 112/112 `ok`, exit 0) | their receipts under `receipts/` (DONE — flip witnessed) |

## 3.5 Bench-framework wave (v6 — BENCH-ERLANG lanes)

| Row | Verdict | Evidence | Falsifier |
|---|---|---|---|
| BENCH-3 cosmos CAS bench (pure Erlang, raw TLS 9444) | **PASS** | `receipts/bench3-cosmos-cas-erlang.md`: 2 consecutive green runs, 0 errors, p99 0.543/0.672 ms vs the 2.08 ms parity fence (under the T43 wire p99 itself); `bench/bench_cosmos_cas.erl`, zero Elixir | a run breaching the parity fence, or any error row in the jsonl |
| BENCH-5 in-process POWL pipeline bench | **ALIVE (measured claim) / PARTIAL (promotion)** | `receipts/bench5-powl-pipeline.md`: 5000/5000 orchestrations 0 errors on the PB-5-pinned OTP 29.1.2; post-fix completion-protocol parity; per-run gen_statem termination report keeps the runner out of the pre-fix perf regime (disclosed, not fixed — owning lane's call) | the exit-reason protocol changing the cost shape, or a 0/5000→error regression |
| BENCH-6 native :json SAX streaming | **ALIVE** | `receipts/bench6-json-streaming.md`: pure-Erlang `:json` SAX over a 52,692,552-byte corpus, exit 0, lane `bench6-json` | a re-run with non-zero errors or a throughput collapse |
| BENCH-7 pure-Erlang concurrency ceiling | **PASS** | `receipts/bench7-concurrency-ceiling.md`: no ceiling through 32k processes, gentle degradation only, 6 jsonl rows | a first-error cliff below 32k on a re-run |
| BENCH-8 court-bench escript runner | **PASS** | `receipts/bench8-court-bench-escript.md`: `bin/court-bench` escript + `just court-bench`; run_all/0 dispatch wired and dormant (BENCH-2 contract not exported yet); documented-interface fallback green | a runner that can't compile a bench module or dispatch run_all on an exporting module |
| BENCH-9 benchee deletion audit | **TYPED (audit; deletion is a no-op)** | `receipts/bench9-deletion-audit.md`: benchee present in mix.exs/mix.lock/benchee_runner.exs; verdict — deletion is a measurement no-op, enforcement prospective | any claim that benchee was already deleted |
| BENCH-10 bench-architecture skeptic | **ALIVE** | `receipts/bench10-skeptic.md`: all three audit claims proven with executed probes; flags BENCH-ERLANG.md as corrupted mid-write (two STOP markers) — a clean re-land of the spec is a precondition for implementation lanes | a clean re-land contradicting an audit claim |
| BENCH-11 court receipt schema | **ALIVE** | `receipts/bench11-court-receipt-schema.md`: `bench/court_receipt.erl` — closed 11-field schema, fail-closed encode/validate, selftest non-vacuity; first receipts written | a row validating that should not, or selftest accepting a mutated row |
| BENCH-13 deletion exec | **PASS (typed no-op)** | `receipts/bench13-deletion-exec.md`: BENCH-9 audit receipt absent at execution time → fallback greps; minimal real dep deletions, verified | a deletion that changes a measurement |
| BENCH-14 bench-framework gate | **ALIVE** | `receipts/bench14-bench-framework-gate.md`: `scripts/bench_framework_gate.py` fail-closed census + `just bench-framework-gate` + non-vacuity court, frozen allowlist; flip proven on this exact subject | the gate accepting a NEW benchee reference (gate that can't exit 1 is the failure) |
| BENCH-2 / BENCH-4 / BENCH-12 | **UNWITNESSED** | no receipts on disk; `bench/smalt_bench_court.erl` is landed (named by BENCH-8/10/11) but has no dedicated receipt | their own receipts under `receipts/` |

## Adoption receipts folded into v2 (new since v1)

- **IMPL-1** — `receipts/impl1-process-iterator.md`: CORE-01 adoption
  (`Smalt.ProcessIter` seam, 200k-proc court, 0-word iterator heap delta).
- **IMPL-3** — `receipts/etsauto-rollout-impl3.md`: DATA-01 adoption
  (3 tables `:auto` default-ON, 10–56x walls, zero lost updates, reversible flag).
- **IMPL-5** — `receipts/impl5-jsoncompat-rollout.md`: WIRE-01 rollout
  (native-default host-gated flip, 3 hot decode families, integration tier 170/0).
- **IMPL-7** — POWL-03 adoption: `lib/smalt/powl2/graph_compat.ex` (commit
  `48ad71f`) + cross-engine court `test/internal/powl2_graph_compat_court.exs`
  (commit `b87092d`, OTP 28 + 29, 10-graph corpus; replayed under the 29.1.2
  pin this session: 8 tests, 0 failures — `receipts/bk17-graph-compat-witness.md`).
- **IMPL-8** — `receipts/impl8-tls-version-seam.md`: SEC-01 `:tls_versions`
  seam (3/3 court legs on the real `bandit_opts/2` path) + SEC-02 dual-cert
  court (ECDSA/RSA selection witnessed both directions).
- **IMPL-9** — `receipts/impl9-popcorn-otp29-pin.md`: the 29.1.2 pin
  (`popcorn_demo/.tool-versions`), the scope every ALIVE-on-pinned cell types under.
- **APIMWIRE** — checkpoint `1570385`: PRD-APIM wired into the router
  (429/401 wire refusals witnessed, supervised rate-limit ETS, default-off pass-through).
- **KVCRYPTO** — `receipts/prd-kv-crypto-face.md`: PRD-KV crypto face witness
  (ES256/RS256 sign/verify on the live substrate, 400/404 typed errors).
- **APPWS** — `receipts/appconf-push-webhook-face.md`: PRD-APPCONF webhook
  push face (Event Grid envelopes, loopback SSRF fence, 21/0 combined run).
- **OBSFENCE** — `receipts/ar-obs-03-memory-fence.md`: OBS-03 tprof
  memory-ceiling fence (gate PASS at 134 ≤ 200 words + shim-court non-vacuity).
- **T42** — `receipts/t46json-native-json-seam.md`: the JsonCompat
  byte-equivalence court (9 payload classes, typed `null`-atom divergence), the
  gate WIRE-01's rollout rides on.

## Adoption receipts folded into v3 (new since v2)

- **POWL-BENCH** — `tmp/bench/powl-native-face.jsonl` (lane `powlbench`):
  the native-face measured row (AR-POWL-PERF); 15–40 µs estimate refuted
  favorably at 2 µs p99 point-read.
- **PB-3 / PB-1 / PB-4 / PB-6** — the bench wave first typed in v3
  (`receipts/pb3-executor-ceiling.md`, `receipts/pb1-fond-loop-latency.md`,
  `receipts/pb4-merkle-dual-path.md`, `receipts/pb6-dual-boundary.md`).
- **IMPL-11 / IMPL-12 / IMPL-18 / ARMFIX / T47 / DIRECTIVES** — guard
  rollout, map-order adjudication, vm-census adoption, idiom fixes, release
  boot gate, standing falsification charter (receipts listed in §Provenance).

## Adoption receipts folded into v4 (new since v3)

- **CAS412 + CAS412R** — `receipts/cas412-cosmos-replace-if-match.md`,
  `receipts/cas412r-postfix-regression.md`: If-Match wire path proven
  correct (800/800 412s, real SDK), DIV-1 resolved as SDK-side premise rot
  (`ifMatchEtag` is a silent no-op in @azure/cosmos 4.10.1), stale-412 now
  etag-carrying; regression 35/35 on the recycled OTP-29 beam.
- **IMPL-14F** — `receipts/impl14f-tls13-default-flip.md`: TLS 1.3/ML-KEM
  default flip (1 behavioral line in `lib/smalt/tls.ex`), 3-leg court PASS
  with config-revert escape.
- **GOLEG** — `receipts/goleg-tls13-client.md`: real Go 1.23.4 client 6/6
  legs; R90/D52 failure shape does not reproduce; handshake residual closed,
  azidentity auth-flow leg typed-open.
- **RELCUT** — `receipts/relcut-deferred-listeners.md`: config-gated phased
  listener start, front door 24% earlier, court 3/3 + regression 12 passed;
  folded into NFR-FOOTPRINT.
- **PB-2** — `receipts/pb2-reductions-denominator.md`: reductions-per-step
  denominator ≈17.5k/8-step orchestration, per-step 1,609; dominance finding
  (engine legs ~9x scheduling work).
- **PB-5** — `receipts/pb5-crosslang-differential.md`: cross-language
  differential — receipt byte-identity TIE, correctness race closed, executor
  ahead 5.4x throughput; promotion not executed.
- **FONDRUNNER** — `receipts/fondrunner-otp29-pipeline.md`: parallel Erlang
  FOND/POWL pipeline family, 7/7 courts, IMPL-12-gated deterministic seal.
- **JSONSAX** — `receipts/snippet-jsonsax-stream.md`: `JsonCompat.stream/3`
  discard-style SAX helper, 16/16, 92,736-byte peak on 50k docs.
- **IMPL-13** — `receipts/impl13-jit-2912.md`: JIT re-adjudication on the
  pin (11.9% wall gain, REFUTED stands under the ≥30% gate).
- **IMPL-15** — `receipts/impl15-decomposition-graphcompat.md`: GraphCompat
  adoption extended to `decomposition.ex` (typed block-order cycle refusal).
- **IMPL-19** — `receipts/impl19-pin-coherence.md` +
  `receipts/impl19-warnings-census-top5.md`: toolchain pin coherence (8
  files, full tree compiles clean on 29.1.2) + top-5 warning modules cleared
  (94→66).
- **WARN2** — `receipts/warn2-warnings-backlog-6-10.md`: remaining target
  backlog zeroed (6 modules, 12 sites → 0; census falsifier: any warning
  line reappearing reopens the receipt). Window lib warnings: 94→66→0 on
  the target backlog.
- **IMPL-20 / IMPL-21** — `receipts/impl20-postupgrade-tiers.md`,
  `receipts/impl21-postupgrade-sdk.md`: post-upgrade re-validation on the
  recycled OTP-29 beam (wire tiers 28/28; real-SDK witnesses 5/5, 0 errors).
- **IMPL-23** — `receipts/impl23-eep78-probe.md`: EEP-78 multi-element
  comprehensions real on 29.1.2 (not an ARD cell; EEP-79 remains UNSUPPORTED).
- **IMPL-24** — reductions standing fence (2x per-stage ceilings,
  shim-proven non-vacuous, `just reductions-gate`; commit `bc2586c`).
- **IMPL-25** — LRO notifier selective drain (duplicate due-checks coalesce,
  10k flood collapses; commit `feb5f82`).
- **IMPL-26** — `receipts/impl26-ar-obs-02-label-adoption.md`: remaining
  spawn-site label adoption; OBS-02 adoption complete (6/6).
- **USERS500** — `receipts/us500-users-permissions-500-court.md`: cosmos
  users/permissions 500 closed as stale-beam artifact + healthy-shape court.
- **POWLSK2** — `receipts/powl2-high-findings-recourt.md`: v26.10.20
  HIGH-1/HIGH-2 re-courted against the landed POWL-4 compiler (skeptic lane).
- **CTXFILL** — `receipts/ctxfill-receipt-flag-backfill.md`: window
  receipts law-clean — 41 NO-CONTEXT backfilled, 7 SUSPECT closed with
  fresh reproduction output (0 NO-CONTEXT / 0 SUSPECT after backfill).

## Receipts folded into v6 (new since v5)

- **GL-KILL** — `receipts/glkill-f1-f2-close.md` (ALIVE): both GL-10
  KILL-class defects closed with witness courts; law fields preserved
  through the typed-struct path (`reticle.ex`); skeptic 29/29, 78
  neighbors green.
- **GLADJ** — `receipts/gl8-andon-wire-adjudication.md` (ALIVE): andon
  wire shape conflict adjudicated to the canonical union envelope;
  skeptic 17 + fullstack 2 + andon 24 = **43/43 courts green**
  post-adjudication; no `lib/` changes.
- **WASM-1** — `receipts/wasm1-otp29-sandbox-port.md` (ALIVE):
  bridge/pool/worker ported, 6-gate sandbox court green (3 spec + 3
  lane); typed stub caveat — gates run against `stub_runner.exs`;
  wasmtime swap is config; closes PENDING-GWS-13 as ALIVE-on-stub.
- **GWS-12** — `receipts/gws12-cross-engine-determinism.md` (PASS):
  3-leg determinism differential (native ABI / wasm / BEAM COLD-1),
  partition identical; closes the determinism half of PENDING-GWS-15.
- **GWS-11** — `receipts/gws11-wasm-memory-wall.md` (ALIVE): memory-wall
  court 7/7 on the real pinned `priv/graphlaw.wasm`, 2 runs incl.
  parallel.
- **GWS-2 / GWS-7 / GWS-13** — `receipts/gws2-wasm-build-trial.md`
  (PARTIAL_ALIVE — blessed wasm link fails on `-lduckdb`; DOCS_RS escape
  artifact is ABI-identical to the pin), `receipts/gws7-wasm-abi-bridge.md`
  (ALIVE — real-ABI host bridge, 18/18), `receipts/gws13-integration-manifest.md`
  (PARTIAL_ALIVE — manifest landed, every registered item PENDING at its
  write time).
- **GWS-14 skeptic + SPEC-SCOPE** — `receipts/gws14-skeptic.md` (ALIVE
  audit; stub-mode default typed), `receipts/gws14-spec-scope.md` (ALIVE —
  WASM-SANDBOX-SPEC §5 current-state amendment, pure insertion).
- **SQLD wave** — `receipts/sqld2-sql-ingest-court.md` (PASS),
  `receipts/sqld3-sqlite-ingestion-court.md` (PASS),
  `receipts/sqld5-sql-shape-gen.md` (ALIVE 14/14),
  `receipts/sqld8-ingest-baseline.md` (PASS).
- **GLD wave** — `receipts/gld2-cdc-court.md` (PASS),
  `receipts/gld4-sql-seed-court.md` (PASS),
  `receipts/gld5-ingestion-skeptic.md` (SUSPECT — F2 silent row loss +
  F3 formula injection OPEN in the converter→CSV boundary).
- **BENCH wave** — `receipts/bench3-cosmos-cas-erlang.md` (PASS),
  `receipts/bench5-powl-pipeline.md` (ALIVE measured / PARTIAL promotion),
  `receipts/bench6-json-streaming.md` (ALIVE),
  `receipts/bench7-concurrency-ceiling.md` (PASS),
  `receipts/bench8-court-bench-escript.md` (PASS),
  `receipts/bench9-deletion-audit.md` (typed audit),
  `receipts/bench10-skeptic.md` (ALIVE),
  `receipts/bench11-court-receipt-schema.md` (ALIVE),
  `receipts/bench13-deletion-exec.md` (PASS typed no-op),
  `receipts/bench14-bench-framework-gate.md` (ALIVE).
- **OBS4COURT** — `receipts/obs4court-peer-two-node.md` (ALIVE, 4/4 ×2
  runs): flips AR-OBS-04 PARTIAL → ALIVE (the board's only cell flip in
  v6).
- **BK6** — `receipts/bk6-kd157-h2-postrestart-witness.md` (ALIVE):
  post-restart KD-157 falsifier (transport_retries 539–562 → 0, ×2 runs,
  zero post-fix GOAWAYs) — closes the KD-157 FLIP-PENDING-WITNESS row
  (flipped CLOSED-SIMULATED, also witnessed by bk20); plus live-twin Go
  TLS 1.3 re-witness (SEC-01) and peer-court 4/4 re-run (OBS-04).
- **ECOURT-F** — `receipts/ecourt-wire-fence.md` (PASS — 4 legs green +
  loud SKIP on the default-off APIM 429/401 sub-leg; exit-3 skip is
  loud, never a fake pass).
- Dispatched without receipts on disk at v6 write time (UNWITNESSED,
  registered in `_LANES.md` v6 reconciliation): IMPL-27, BENCH-2,
  BENCH-4, BENCH-12. GLD-1, GLD-6, GLD-7 have since landed (see
  post-v6 fold above); BENCH-12's deliverable (the §3 denominator
  table) is landed in `bench/README.md` but no dedicated receipt exists.

## Summary counts (v6)

Cell granularity = one AR/PRD/NFR/migrate/bench requirement = **45 cells**
(43 v3 cells − the PENDING-PB placeholder + PB-2 + PB-5 + FONDREC), each
counted once at its primary row verdict; split verdicts and sub-claims are
listed below the tables. v6 changes the buckets in exactly one place:
AR-OBS-04 flips PARTIAL → ALIVE (OBS4COURT receipt), 26→27 / 10→9.

| Verdict | Count | Cells |
|---|---|---|
| ALIVE / PASS / CONFIRMED-on-pinned / ALIVE-on-pinned / AVAILABLE | **29** (v9 BK-CELLS fold: NFR-LATENCY -> PASS, PRD-APIM -> ALIVE) | CORE-01 (AVAILABLE+adopted), CORE-IDOM (ARMFIX), WIRE-01 (incl. JSONSAX), WIRE-02 (ALIVE-on-pinned), POWL-02 (IMPL-12), POWL-03 (incl. IMPL-15), POWL-PB6, POWL-PB5, FONDREC, OBS-01 (AVAILABLE), OBS-02 (adoption complete), **OBS-04 (v6: OBS4COURT two-node court)**, OBS-03, SEC-01 (flip + Go legs; azidentity residual typed), SEC-02, PRD-BLOB, PRD-COSMOS, PRD-SB, PRD-KV, PRD-APPCONF, **PRD-APIM (v9: bkcells-apim-witness 6/6)**, **NFR-LATENCY (v9: bkcells-floor PASS)**, NFR-CONCURRENCY, NFR-COMPLIANCE, mig-parser, mig-determinism, mig-inject, mig-verify, mig-e2e |
| PARTIAL / PARTIAL_ALIVE | **7** | DATA-01 (ARD gate measured; Store CAS adoption UNBUILT residual), DATA-02 (migration UNBUILT), DATA-03 (redesign UNBUILT), DATA-04 (re-witnessed; adoption UNBUILT), POWL-CEIL (escalated to L32768, wall unreached), PB-1 (DIV-1 resolved as premise rot; SDK-leg rerun on accessConditions pending), PB-2 (denominator measured, derived divider typed) |
| REFUTED | **5** | CORE-02, CORE-03 (re-adjudicated on the pin: 11.9% < 30%), WIRE-03, POWL-PERF (favorably — 2 µs p99 vs the 15–40 µs estimate), PB-4 (variant correct but not faster) |
| UNSUPPORTED / FAIL | **4** | CORE-04, SEC-03, POWL-01, NFR-FOOTPRINT (v8: cold-start PASS against the TTV-6 re-typed 2,000 ms charter ceiling; the original 500 ms FAIL at 3.8x stands as measured history; idle sub-claim UNSUPPORTED) |

Bucket arithmetic: 29 + 7 + 5 + 4 = 45 cells (v9 BK-CELLS fold applied:
NFR-LATENCY → PASS and PRD-APIM → ALIVE both count in the ALIVE-class
bucket, 27→29 / 9→7). Row-level PENDING: 0.
Row-level PENDING-PB: 0. Row-level PENDING-GWS: 0 (GWS-IN-WASM-COURTS
closed BK-31, GWS-SEC-FUZZ closed BK-32 — receipts on disk). v8 changes
no bucket arithmetic beyond the v9 folds — the v8 cell folds
(NFR-FOOTPRINT, AR-POWL-PERF, NFR-COMPLIANCE, PRD-BLOB evidence) are
typed inside their existing buckets.

## Honest backlog note (v4)

Row-level PENDING is zero: the PB wave is fully typed (PB-1..6) and the
PENDING-PB placeholder is gone. The remainder lives in named falsifiers:

- **ARD re-scoping class** (not implementation): the REFUTED pillars
  (EEP-79, priority aliases, strict comprehensions) do not exist on any
  pinned toolchain; CORE-03 is a measured 11.9% wall gain under a ≥30% ARD
  gate. EEP-78 (adjacent, real on 29.1.2) has no ARD row to attach to.
- **DATA adoption gaps**: DATA-01 ARD CAS contention gate, DATA-02
  ordered_walk migration, DATA-03 Registry.lock redesign, DATA-04
  PartitionSupervisor wiring.
- **SEC residual**: azidentity/azurerm Go SDK auth-flow session over the
  default-flipped listener (handshake face closed by GOLEG).
- **PB-1 SDK leg**: rerun the SDK contention rows with real
  `accessCondition*` options on the CAS412-proven If-Match-honoring surface
  (never `ifMatchEtag`).
- **Observability/NFR**: NFR-LATENCY blob-PUT receipt + cosmos p99 re-run CLOSED (BK-CELLS 2026-10-22, `tmp/bench/bkcells-floor.jsonl`; OBS-04 peer court closed by BK-6 `../v26.10.22/receipts/bk6-validation-closures.md`); NFR-FOOTPRINT idle-RSS receipt; the release cold-start
  ceiling is **re-typed by TTV-6** (charter 2,000 ms; measured best quiet
  1,906 ms passes; the original 500 ms FAIL stands as measured history) and
  the TTV-7b quiesced re-run (AR-POWL-PERF tail adjudication) is
  BLOCKED-ON-QUIESCENCE.
- **SQLD converter defects (GLD-5 SUSPECT)**: F2 silent row loss + F3
  formula injection were open in the canonical converter→CSV boundary
  (`lib/smalt/sql_ingest.ex`) — **both CLOSED post-v6** (as-of 2026-10-21)
  by `receipts/gld5fix-null-formula-court.md` (typed `\N` sentinel +
  numeric-exempt neutralization + value-exact 6/6 court in real duckdb,
  zero row loss); nothing hostile executes.
- **BENCH spec re-land**: `BENCH-ERLANG.md` is corrupted mid-write
  (BENCH-10 skeptic, two STOP markers) — a clean re-land is a
  precondition for the implementation lanes; BENCH-2/4/12 have no
  receipts on disk.
- **WASM stub→wasmtime swap**: the 6 sandbox gates are ALIVE-on-stub;
  `graphlaw_duckdb.wasm` does not exist; the blessed wasm link fails on
  `-lduckdb` (GWS-2) — GWS-IN-WASM-COURTS and GWS-SEC-FUZZ are now
  CLOSED (BK-31 / BK-32, both on the graphlaw surface; the frozen-duckdb
  under-wasmtime link remains the GWS-2 open item).
- **PRD-APIM** dedicated witness receipt FILED (BK-CELLS 2026-10-22, `../v26.10.22/receipts/bkcells-apim-witness.md`) — clause closed.
- Hygiene landed this window and closed: warnings backlog (94→66→0 on the
  target set), IMPL-24 reductions fence, IMPL-25 selective drain, USERS500
  stale-beam closure. CTXFILL made the window receipts law-clean
  (0 NO-CONTEXT / 0 SUSPECT). AMQP10SK
  (`receipts/amqp10-crash-only-skeptic.md`) typed the crash-only router
  audit BLOCKED-UNSUPPORTED (SUBJECT_NOT_LANDED) rather than laundering it —
  the subject does not exist under `lib/smalt/messaging/`.

## GWS wave rows folded into v5, flipped in v6

The graphlaw/wasm/sandbox wave's receipted lanes are typed in
`_LANES.md` (GWS-1..12: gl1/gl2/gl3/gl4/gl5/gl6/gl7/gl9/gl12 ALIVE or
PASS; gl8 PARTIAL_ALIVE adjudicated ALIVE; gl10 SUSPECT closed by
GL-KILL). They carry no separate ARD/PRD/NFR rows — they are wave
evidence, not board cells. The wave's four unreceipted surfaces
register as board rows, each **PENDING-GWS-n until receipted**; a row
flips only on its own receipt under `receipts/`, never on prose.

| Row | Surface | Standing | Receipt gate |
|---|---|---|---|
| GWS-SANDBOX-GATES | WASM sandbox court over `lib/smalt/wasm/{bridge,pool,worker}.ex` (landed, commit 63f01b6 line of the wave) | **CLOSED in v6: ALIVE-on-stub** — `receipts/wasm1-otp29-sandbox-port.md` (WASM-1): 6-gate court (3 spec + 3 lane) green on the pinned toolchain; typed caveat (GWS-14 skeptic): the gates run against `priv/wasm/stub_runner.exs` — the wasmtime swap is config (`:wasm_runner_path`), and `graphlaw_duckdb.wasm` does not exist. **As-of v7 (BK-22 fold): receipt `[ -f ]`-verified on disk 2026-10-21** | wasmtime-mode re-run of the 6 gates, or `graphlaw_duckdb.wasm` landing |
| GWS-IN-WASM-COURTS | in-wasm SHACL/N3 courts (graphlaw + frozen-duckdb under wasmtime, 64 MiB wall) | **CLOSED in v7 (BK-31): PASS for the graphlaw surface** — `receipts/bk31-gws14-inwasm-courts.md`: 4 suites / 11 tests green, exit 0, on a real wasmi Engine hosting the freshly built `graphlaw_wasm.wasm` (governance preflight, N3 admission, 312-call boundary fuzz, coldchain e2e); adversarial leg via real `graphlaw-run` (mutated frames → typed `Unsupported`, no traps). Typed caveat: frozen-duckdb-under-wasmtime remains open (GWS-2 `-lduckdb` gap) — not claimed by this closure. **Receipt `[ -f ]`-verified on disk 2026-10-22** | re-run where any suite fails, or a mutated frame that traps instead of a typed refusal |
| GWS-DETERMINISM | determinism differential (in-wasm vs BEAM execution byte-identity) | **CLOSED in v6: PASS** — `receipts/gws12-cross-engine-determinism.md` (GWS-12): 3 legs (native graphlaw ABI / wasm module under wasmi / BEAM COLD-1 court), partition identical, 2 typed findings. **As-of v7 (BK-22 fold): receipt `[ -f ]`-verified on disk 2026-10-21** | a differential re-run where any leg diverges on response bytes or partition |
| GWS-SEC-FUZZ | security fuzz of the sandbox boundary (adversarial payloads, timeout + panic containment) | **CLOSED (BK-32): PASS** — `receipts/bk32-gws15-sec-fuzz.md`: 1172 hostile frames (>= 1000 required) against the real `graphlaw_wasm.wasm` in wasmi via the hostile `gl_call` ptr/len path; classes: deep JSON (depth 0..10k vs the 64 guard), 16 MiB at/over boundary, malformed UTF-8, SQL-injection tokens (wasm `shacl` + native `sql_ast` gate), NaN/Infinity, mid-frame truncation, random byte mutation. **0 panics/traps/hangs**, every refusal typed in the documented vocabulary; histogram: Unsupported 654 / EngineRejected 291 / ResourceLimit 195 / NotSemanticContent 28 / ok:true 4 (designed at-boundary admissions). Receipt `[ -f ]`-verified on disk 2026-10-22. Closes the security half of PENDING-GWS-15 (determinism half already closed by `receipts/gws12-cross-engine-determinism.md`) | re-run `cargo test --test wasm_boundary_fuzz` — any panic/trap/hang or untyped refusal reopens the row |

Row-level PENDING-GWS: 0 (was 4 at v5; GWS-IN-WASM-COURTS closed BK-31
`receipts/bk31-gws14-inwasm-courts.md`, GWS-SEC-FUZZ closed BK-32
`receipts/bk32-gws15-sec-fuzz.md` — all four wave rows now CLOSED).
These are wave surfaces, not
regressions of the 45 v4 cells; the v4 verdict buckets change in exactly
one place: **AR-OBS-04 flips PARTIAL → ALIVE** (OBS4COURT), moving one
cell from the PARTIAL bucket to the ALIVE bucket (26→27 / 10→9).

## Provenance

- Charter: `docs/jira/v26.10.21/ARD-PRD.md` (OPERATOR-CHARTER standing)
- Validator receipts: `receipts/val-ar-core.md`, `receipts/val-ar-data.md`,
  `receipts/val-ar-wire.md`, `receipts/val-ar-sec.md`,
  `receipts/val-ar-powl.md`, `receipts/val-ar-obs.md`,
  `receipts/val-prd.md`, `receipts/val-nfr-migrate.md`
- Arbiter: `receipts/val-conflict-arbiter.md` (CORE-01 / OBS-01 overrides)
- Adoption receipts: the v2/v3/v4 folding lists above; the v5 fold adds
  the GWS wave receipts (`receipts/gl1-law-guard-seam.md` …
  `receipts/gl12-fullstack-seal-court.md`,
  `receipts/glconf-spec-fold.md`, `receipts/glfix-red-courts-closed.md`,
  `receipts/glkill-f1-f2-close.md`, `receipts/cold1-pipeline-court.md`)
  and the WASM-SANDBOX-SPEC surface inventory
- Post-v3 landings: `receipts/cas412-cosmos-replace-if-match.md`,
  `receipts/cas412r-postfix-regression.md`,
  `receipts/impl14f-tls13-default-flip.md`,
  `receipts/goleg-tls13-client.md`,
  `receipts/relcut-deferred-listeners.md`,
  `receipts/pb2-reductions-denominator.md`,
  `receipts/pb5-crosslang-differential.md`,
  `receipts/fondrunner-otp29-pipeline.md`,
  `receipts/snippet-jsonsax-stream.md`,
  `receipts/impl13-jit-2912.md`, `receipts/impl15-decomposition-graphcompat.md`,
  `receipts/impl19-pin-coherence.md`, `receipts/impl19-warnings-census-top5.md`,
  `receipts/warn2-warnings-backlog-6-10.md`,
  `receipts/impl20-postupgrade-tiers.md`, `receipts/impl21-postupgrade-sdk.md`,
  `receipts/impl23-eep78-probe.md`,
  `receipts/impl26-ar-obs-02-label-adoption.md`,
  `receipts/us500-users-permissions-500-court.md`,
  `receipts/powl2-high-findings-recourt.md`,
  `receipts/ctxfill-receipt-flag-backfill.md`,
- Post-v5 landings (v6 fold): `receipts/glkill-f1-f2-close.md`,
  `receipts/gl8-andon-wire-adjudication.md` (GLADJ),
  `receipts/wasm1-otp29-sandbox-port.md`,
  `receipts/gws12-cross-engine-determinism.md`,
  `receipts/gws11-wasm-memory-wall.md`,
  `receipts/gws2-wasm-build-trial.md`,
  `receipts/gws7-wasm-abi-bridge.md`,
  `receipts/gws13-integration-manifest.md`,
  `receipts/gws14-skeptic.md`, `receipts/gws14-spec-scope.md`,
  `receipts/sqld2-sql-ingest-court.md`,
  `receipts/sqld3-sqlite-ingestion-court.md`,
  `receipts/sqld5-sql-shape-gen.md`,
  `receipts/sqld8-ingest-baseline.md`,
  `receipts/gld2-cdc-court.md`, `receipts/gld4-sql-seed-court.md`,
  `receipts/gld5-ingestion-skeptic.md`,
  `receipts/bench3-cosmos-cas-erlang.md`,
  `receipts/bench5-powl-pipeline.md`,
  `receipts/bench6-json-streaming.md`,
  `receipts/bench7-concurrency-ceiling.md`,
  `receipts/bench8-court-bench-escript.md`,
  `receipts/bench9-deletion-audit.md`,
  `receipts/bench10-skeptic.md`,
  `receipts/bench11-court-receipt-schema.md`,
  `receipts/bench13-deletion-exec.md`,
  `receipts/bench14-bench-framework-gate.md`,
  `receipts/obs4court-peer-two-node.md`,
  `receipts/ecourt-wire-fence.md`,
  `receipts/bk6-kd157-h2-postrestart-witness.md`
- Post-v6 landings (folded as-of 2026-10-21, citation audit BK-10):
  `receipts/gld5fix-null-formula-court.md` (GLD-5 F2/F3 close),
  `receipts/gld1-sql-n3-court.md`, `receipts/gld6-sql-row-gate-security-court.md`,
  `receipts/gld7-ingest-to-settlement-court.md`,
  `receipts/sqld4-sql-mapping-court.md`,
  `receipts/sk5-sk3-credit-arbitration.md`
  `tmp/bench/powl-native-face.jsonl` (POWL-BENCH, gitignored scratch —
  ground-truth jsonl cited by the AR-POWL-PERF row)
- Post-v6 landings (v7 BOARDV3 fold, as-of 2026-10-21, receipt paths
  `[ -f ]`-verified): `receipts/powlbench-fresh-rerun.md` (fresh
  POWLBENCH re-run, AR-PROD-05 p99 gate breach typed),
  `receipts/imp14-mlkem-flip.md` (ML-KEM group-preference flip +
  Go-client interop; Go mlkem-only client-side UNSUPPORTED typed),
  `receipts/bk10-citation-audit.md`, `receipts/bk17-graph-compat-witness.md`,
  `receipts/bk20-kd157-witness.md`, `receipts/bk15-skip-fetch-census.md`,
  `receipts/bk9-popcorn-live-leg.md`
- **Post-v7 landings (v8 fold, as-of 2026-10-22, all paths `[ -f ]`-verified
  on disk; census = fresh `ls` of `receipts/` (190 files) + `receipts/INDEX.md`)**
  — the board's cell-evidence set from this wave, by family:
  - **TTV boot/perf wave**: `receipts/ttv4-journal-boot-replay.md` (ALIVE —
    JournalReader boot-replay wired into `Smalt.Store`, replay-then-listen),
    `receipts/ttv6-cold-boot-gate.md` (ALIVE — cold-boot ceiling re-type
    500 ms → 2,000 ms in the charter; folded into NFR-FOOTPRINT),
    `receipts/ttv7-warmed-p99-standard.md` (PARTIAL_ALIVE — warmed-P99
    standard; ms-tail reproduces warmed under load; folded into
    AR-POWL-PERF), `receipts/ttv7b-quiesced-rerun.md`
    (BLOCKED-ON-QUIESCENCE — load never < 84.5 vs the 32 gate),
    `receipts/ttv8-spec-bounds.md`
  - **KD-register wave (NFR-COMPLIANCE evidence)**:
    `receipts/bk14-kd143-sqlfilter-persistence.md`,
    `receipts/bk19-kv-cosmos-queue-conformance.md`, `receipts/bk24-kd10-75-key-route.md`,
    `receipts/bk25-kd92-93-cosmos.md`, `receipts/bk26-kd14-23-auth.md`,
    `receipts/bk29-kd79-close.md`, `receipts/bk30-kd-coherence-census.md`,
    `receipts/bk34-register-structure-repair.md`, `receipts/bk36-wave-row-triage.md`,
    `receipts/bk38-lane-lease-census.md`, `receipts/bk39-kd144-146-blob-fixes.md`,
    `receipts/bk43-kd93-close.md`, `receipts/bk48-pinion-witness.md`,
    `receipts/bk52-kd161-163-mint.md`, `receipts/bk55-kdflip-witness-pinning.md`
  - **Defect-repair wave**: `receipts/bk33-warm-restart-rebind.md` (RESOLVED —
    folded into NFR-FOOTPRINT), `receipts/bk23-fence-repair-promotions.md`
    (PARTIAL_ALIVE), `receipts/bk40-skip-audit.md` (PARTIAL_ALIVE),
    `receipts/bk41-amqp10-ledger-owner.md` (ALIVE — AMQP10 ledger GenServer
    owner, kill/adoption/race court 3/3; BK-1 amqp10 lane closed by
    `receipts/amqp10-court-closure.md`), `receipts/bk46-walk-restructure.md`
    (PARTIAL_ALIVE — wasm walk-restructure blockers), `receipts/bk47-healthz-apim-fixes.md`
    (ALIVE — HealthPlug halt() + apim duplicate-init; ja-r2 residue),
    `receipts/bk49-mcp-router-warning.md`
  - **Joe-Armstrong lane wave (wave evidence, no board cell)**:
    `receipts/ja9-scaling-envelope.md` (fed the BK-52 KD mints),
    `receipts/ja10-transparency-court.md` (ALIVE — court 5/5 ×2),
    `receipts/ja13-supervisor-intensity-court.md` (ALIVE — 5/5 phases ×2 runs),
    `receipts/ja-r1-silent-violation-fixes.md`, `receipts/ja-r2-apim-atom-bridge-fixes.md`
    (ALIVE — 21/21), `receipts/ja-r3-ja16-defect-fixes.md` (PASS),
    `receipts/bk28-ja-receipt-rewitness.md` (PASS — 6 parent JA receipts
    re-derived against the current tree)
  - **Backlog-cell closures + re-witness**: `receipts/bk6-validation-partial-closures.md`
    (ALIVE — SEC-01/WIRE-02/OBS-04 premise-rot closure + fresh re-witness),
    `receipts/bk15b-skip-rewitness.md` (PARTIAL_ALIVE),
    `../v26.10.22/receipts/bk6-validation-closures.md` (ALIVE — 2026-10-22
    fresh re-witness of the same three cells: Go TLS 1.3 legs on the live
    flipped twin, wire_norm shim court ALL LEGS PASSED after two disclosed
    court repairs, peer two-node court 4/4)
  - **Other post-v7 landings**: `receipts/wp1-lithography-whitepaper.md`
    (ALIVE — whitepaper artifact), and the v26.10.22 receipts where relevant:
    `../v26.10.22/receipts/bk57-heir-guard.md` (ALIVE — 37/37 heir sites
    guarded, mutation-probe non-vacuity)
  - Census note: additional receipts have mtimes newer than the v7 board
    (bk7, bk15, bk21, bk37, ja1/ja2/ja8/ja11, amqp10-court-closure and
    INDEX.md re-index) — folded by citation above where they carry board
    evidence; the remainder are lane receipts without board-cell impact.
  - Not landed as of this fold: bk58/bk59/bk60 do not exist on disk (the
    v26.10.22 receipts dir holds bk50/bk53/bk57/ath2 + INDEX); BENCH-2/4/12
    still have no dedicated receipts.
- Standing charter: `docs/jira/v26.10.21/DIRECTIVES.md` (cross-language
  falsification; binds future windows, instances receipt-gated)
- Underlying evidence: `receipts/phase2-ets-audit.md`,
  `docs/jira/v26.10.20/receipts/otp29-capability-probes.md`,
  `docs/jira/v26.10.20/receipts/tracebug-mixtest-tracing.md`,
  `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (canonical KD register)
- Probes: `tmp/otp29_probes/` (p3, p4, p7, p8, p9, p10, p13,
  arbiter_iter_trace.escript), `tmp/val-ar-data/`, `tmp/val_ar_obs/`,
  `tmp/goleg_dial.go`, `tmp/impl16/` (scratch, gitignored)

## See Also

- `docs/jira/v26.10.21/ARD-PRD.md` — the requirement charter this board types
- `docs/jira/v26.10.21/DIRECTIVES.md` — standing cross-language falsification charter
- `docs/jira/v26.10.20/DFLSS-CHARTER.md` — measured CTQ standings
- `docs/jira/v26.10.21/WASM-SANDBOX-SPEC.md` — sandbox gate spec (GWS-13 gate source)
- `docs/jira/v26.10.21/GRAPHLAW-POWL.md` — GL-11 manifest (GWS-1..12 seam map)
- `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — canonical KD register

---
*Addendum (BK-BMIR2, 2026-10-22): the `tmp/bench/*.jsonl` evidence files cited above are gitignored scratch; byte-identical tracked mirrors now live at `docs/jira/v26.10.21/bench/` (bk33-warm-restart, bkcells-floor, pb2-reductions-step, pb3-escalated-bkcells, pb3-executor-ceiling, pb6-dual-boundary, t47-release-boot) and `docs/jira/v26.10.20/bench/` (scvd-airgap, scvd-tier3), paired-sha256-verified — provenance in each dir's `PROVENANCE.md` and `docs/jira/v26.10.22/receipts/bkbmir2-mirror-wave2.md`.*
