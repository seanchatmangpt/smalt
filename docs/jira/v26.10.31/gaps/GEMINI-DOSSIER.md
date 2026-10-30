# GEMINI-DOSSIER — Consolidated Gemini-delta dispositions (gaps 71–76 + wasm supersession)

Consolidation lane 5/15. Consolidates posh/v26.10.30/gaps/71–76 (Gemini-delta wave)
plus the M6 wasm KILL supersession (posh/v26.10.31/gaps/06-wasm-disposition.md) into
one dossier. As-of: 2026-10-30 (per-source timestamps noted inline; subject trees were
volatile at read time — re-stat before consuming).

---

## 1. Inventory summary

Source: `gaps/71-gemini-inventory.md` (as-of 2026-10-30 14:15–14:20 PDT; ALIVE, read-only lane).

- **70 git status rows** under `posh/` (17 modified tracked files + ~53 untracked paths,
  many whole untracked dirs). Writes were IN FLIGHT during inventory: `internal/court/`,
  `internal/membrane/`, `internal/storage/`, `internal/api/api.go` mtimes advanced
  13:2x → 14:09–14:11 between reads (71:7–10).
- **Trees built** (71:24–43): `internal/tui/` (bubbletea/lipgloss dashboard),
  `internal/wasm/` (wazero engine), `internal/dev/` (fsnotify watcher + supervisor),
  `internal/poshvet/` (7 files, go/analysis multichecker; POSHVET-002 fenced-dialer vet),
  `internal/egress/` (fail-closed Control fence), `internal/metrics/`, `internal/mutation/`,
  `internal/chaos/`, `internal/replay/`, `internal/mock/`, `internal/pgo/` + `cmd/pgo-merge`
  + `default.pgo`, `internal/doctor/*` expansion, plus 14:0x platform chain
  (`court`, `membrane`, `storage`, `api` — PARTIAL/in-flight, not yet UDS-surfaced, 71:51).
- **go.mod / go.sum**: `go 1.23 → 1.26.0`; adds bubbletea, lipgloss, fsnotify, wazero,
  testify, golang.org/x/tools (71:15).
- **cmd/posh/main.go**: +481 lines — DEV-only pprof on private mux (POSH_DEBUG=1),
  opt-in loopback metrics (POSH_METRICS_ADDR), andon transition hook, plus Gemini-side
  `dev`/`tui` subcommands (71:17; 75:12–21).
- Composition verdicts (71:44–53): tui / wasm / dev / main.go wiring / Dockerfile COMPOSES;
  new court/membrane/storage/api chain PARTIAL.
- Bypass check clean: only `http.ListenAndServe` in main.go debug muxes (DEV-only,
  loopback, private); kube_healer is the sole TCP path and routes through `egress.Control`;
  everything else is UDS (71:54–60).

## 2. SPAF verdicts

Source: `gaps/72-gemini-spf-audit.md` (PARTIAL_ALIVE, static read @ posh 845c1318,
2026-10-30, no tests executed).

| SPAF clause | Verdict | Evidence |
|---|---|---|
| Zero domain state (charter Rule 1/2) | **MET** | tui holds only view state + capped log ring (dashboard.go:17–28, 47); dev retains only rebuildable build/socket state, no DB (72:8–24) |
| Egress / dispatch bypass | **MET (fenced)** | no unfenced dial in the audited delta; only localhost UDS (supervisor.go:67,79); zero `http.Get/Post/Client{}` hits; egress fence mechanically enforced by poshvet POSHVET-002 (72:57–66; 71:59) |
| internal/wasm vs BEAM Affidavit.WasmEngine | **VIOLATION (competing runtime)** | no sha256 pin, no import allowlist, no af_abi handshake vs fail-closed BEAM admission (engine.go:123–132 vs wasm_engine.ex:65–71; 72:29–53). Mitigated by being unwired dead code. **Superseded → KILL** per M6 (see §5) |

## 3. Toolchain resolution (go 1.26 STANDS)

Sources: `gaps/73-gemini-toolchain.md` (ALIVE) and `gaps/76` §4/§5 (row 4 blocking row).

- Dep-floor refutation of "lower the directive": wazero v1.12.0 requires go 1.25.0,
  golang.org/x/tools v0.52.0 declares 1.26.0, bubbletea v1.3.10 requires 1.24.0
  (73:26–31; 76:85–89). No post-1.23 stdlib/language features in-tree (grep clean;
  76:94–99) — the floor is dependency-driven, not language-driven.
- CI auto-follows: `.github/workflows/posh-go.yml` uses `go-version-file:` (posh/go.mod
  @45) for all three go steps — no pinned go-version, CI will not break (73:14; 76:99).
- Dockerfile pairings fixed: `posh/Dockerfile:12` already `golang:1.26-alpine` + 
  `GOTOOLCHAIN=local` (verified: `docker build -t posh:sidecar` exit 0, image
  sha256:7bfd650a64fd, 18.5MB; 73:13). The remaining stale pin `docker/Dockerfile.posh:2`
  (`golang:1.23-alpine`) is the single required edit (76:71, 76:93–97) — latent, not
  breaking (zero CI/Makefile/Justfile consumers, 76:100). Close condition: builder
  bumped to 1.26-alpine + grep gate failing any `golang:` pin below the go.mod
  directive (76:105–108).
- Host: go1.23.4 + `GOTOOLCHAIN=auto` builds green (auto-downloads 1.26.0;
  `go build/vet/test ./...` exit 0, 73:17).

## 4. Test vacuity

Source: `gaps/74-gemini-test-vacuity.md` (PARTIAL_ALIVE @ posh f0e0a125, 2026-10-30;
executed `go test -count=1 ./internal/tui/... ./internal/dev/... ./internal/wasm/...`
exit 0, go1.26.0).

- **Chicago-predominant; no London violation** (74:10–26): tui uses a hand-written
  one-method interface implementation (Chicago-exception, test-local); dev tests are
  fully Chicago (real unix socket bind + collision refusal, real fsnotify over
  `t.TempDir()`, bounded 500ms-deadline poll); wasm tests are exemplary — real wazero,
  hand-crafted real WASM binaries, real memory-limit rejection, no doubles.
- **Untested surfaces** (74:33–43): `DirectMetricsSource` live-registry path,
  `RenderAndonBadge`, `DashboardModel.Init`/`onReload`, **the dev supervisor lifecycle
  (`Build`/`SpawnWorker`/`Reload`/`Run`) — the largest untested Gemini surface, an
  exported wave-landed capability with zero falsifier**, `Watcher.Errors()`,
  `hostLog`, wasm host-fn error paths.
- Court contradictions: none found (74:45–50).

## 5. Keep / kill / reconcile table

Sources: `gaps/76` §1–§3; wasm superseded by `v26.10.31/gaps/06-wasm-disposition.md`
(operator-ratified `00-unification-dialect-decision.md` law 4: "any posh component
owning state or admission stops being a shim").

| Component | G76 verdict | Final disposition | Reason / supersession |
|---|---|---|---|
| internal/tui/ | KEEP with RECONCILE seam (76:14–29) | **KEEP-reconcile** via M7 seams (`v26.10.31/gaps/07-tui-watcher-seams.md`) | composes via `TelemetrySource`; data path must reconcile to one status surface (posh_status.sh / dx_report.py — wire or retire). M7 owns the seams |
| internal/wasm/ | KEEP "it IS the court host" (76:31–42) | **KILL — superseded** (v31/gaps/06:5–27, 60–68) | GM6's KEEP predates the v26.10.31 operator decision; admission authority lives in BEAM, not posh (06:9–15); one artifact one engine, anti O(N²) drift (06:16–22); dead code today, ERRC delete outranks generate (06:23–27). Inheritance: `internal/receipt/` BLAKE3 kernel KEEP untouched (06:31–35); host-fn out-pointer ABI carried into Phase-4 Rust kernel (06:36–42); three test fixtures port forward (06:44–55). Close: deletion PR green, zero internal/wasm or wazero refs, affidavit seals via BEAM only (06:73–76) |
| internal/dev/ | RECONCILE scoped, not killed (76:44–58) | **RECONCILE** | generic rebuild-restart loop, not stateless-violating; charter-serving only if wired to `internal/bootstrap.Run` regen (flips to KEEP) or retired via zero-witnessed-firing pruner (C23 pattern). Coordinator lands only together with the regen wiring |
| go.mod 1.26 + deps | keep 1.26, fix Dockerfile pin (76:60–91) | **RESOLVED** | see §3 |

### Shared-seam collision map

Source: `gaps/75-gemini-overlap-map.md` (ALIVE @ f0e0a125; per-hunk attribution
inside shared files UNVERIFIED, 75:82–84).

| Seam | Owner | Risk | Note |
|---|---|---|---|
| `posh/cmd/posh/main.go` (import block + subcommand switch) | SHARED-SEAM (wave + Gemini, one uncommitted diff, 248→703 lines) | **HIGH** | hottest file in the tree; blame all-or-nothing at integration (75:12–21, 75:33–39) |
| `posh/go.mod` / `go.sum` | SHARED-SEAM | **HIGH** | single interleaved alphabetical require block (wave: testify, x/tools; Gemini: bubbletea, lipgloss, fsnotify, wazero) + go 1.26 bump attributable to neither side alone (75:40–43) |
| `internal/adapter/generated_*.go` via watcher | trigger conflict, not write conflict | **MEDIUM** | `posh dev` watcher watches L42 regen surfaces (`.go .yaml .toml`, ignore prefixes exclude bin/run/var/tmp only); regen-check while `posh dev` is live fires a reload storm. Fix: IgnorePrefix `internal/adapter` or gate on non-generated `.go` (75:23–32, 75:45–48) |
| `internal/server/server.go` | WAVE-owned | LOW-MED | runDev duplicates the socket default (`run/posh.sock`) from config — drift risk, not collision (75:49–52) |
| `internal/andon/`, `internal/metrics/`, `internal/config/` | WAVE-owned, Gemini read-only | LOW | `andon.OnTransition` is a package-global set from main.go — last-writer-wins if runTUI ever sets it (75:53–56) |
| `posh.yaml`, `config/egress_allowlist.generated.yaml` | WAVE-owned (L42), regen-check fail-closed | LOW | Gemini not a writer (75:57–58) |

## Receipt

- Subject: `/Users/sac/smalt/docs/jira/v26.10.31/gaps/GEMINI-DOSSIER.md`, consolidated
  from `/Users/sac/smalt/docs/jira/posh/v26.10.30/gaps/{71,72,73,74,75,76}-*.md` and
  `/Users/sac/smalt/docs/jira/posh/v26.10.31/gaps/06-wasm-disposition.md` (all read in
  full this session, 2026-10-30).
- Subject tree of record: `/Users/sac/smalt/posh` @ 845c1318 (gap 72) / f0e0a125
  (gaps 74–76) — uncommitted Gemini-delta state, volatile; re-stat before consuming.
- Status: PARTIAL — dispositions consolidated; queued edits ride their owning lanes
  (`docker/Dockerfile.posh:2` pin, wasm deletion PR per v31/gaps/06 plan, tui seam
  wiring per M7).
