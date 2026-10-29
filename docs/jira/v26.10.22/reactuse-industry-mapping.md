# react-use Hook Mapping — 6-Industry Console Pages (v26.10.22)

Maps `react-use` hooks onto the six industry examples' client surfaces
defined in `docs/jira/v26.10.22/azure-industry-matrix.md` (the emulator faces)
and `nextjs-sweep.md` (the seed apps), riding the landed workspace engine
(`workspace/lib/engine/`: journal-sync WAL, snapback, tab-lease, useJournal,
useAndon, useSovereignTerminal, law-worker-bridge).

**Tags**

- **react-use-native** — vendor hook used as-is (`react-use` npm package).
- **engine-native** — already landed in `workspace/lib/engine/`; do not
  re-implement with a vendor hook.
- **pattern-port** — vendor hook composed with an engine/emulator seam; the
  composition is per-industry, the hook itself is vendored.

**WAL/sync lifecycle events** (the engine surface hooks map onto): `appendLocal`,
`flushSync` (ack cursor advance), `SYNC_REFUSED_BY_SERVER` → snapback,
`PEER_TAB_ACTIVE`, lease transitions `locked | fallback | unknown`,
`needsRehydrate`/`rehydratePlan`, terminal states `READY_STANDALONE →
COMMITTED_LOCAL → SYNCED_AND_SEALED` (derived in useSovereignTerminal).

Rule applied throughout: the **only** networking seam is `smaltFetch`
(`workspace/lib/smalt.ts:22`); every react-use hook that touches the wire is
pattern-ported through it. Hooks that fake latency or time as a coordination
device are out of scope (no-sleep doctrine).

## Per-industry mapping

### 1. Legal / e-discovery (seed: affidavit/web; faces: Blob WORM, Cosmos CAS, SB, AppConfig, Confidential Ledger)

| Concern | Hook | Tag | Notes |
|---|---|---|---|
| Offline auto-flush gating | `useNetwork` | pattern-port | `online===false` suspends the WAL drain (`unacked()` accumulates); on re-online trigger `flushSync`. Custody chain must never half-flush: flush is all-or-nothing per batch (engine byte-exact contract). |
| Custodian location attestation | `useGeolocation` | pattern-port | One-shot fix stamped into the ledger append payload (`/app/transactions`, `AttestRoutes.ex:38-58`). Opt-in per matter; refused → typed `PEER_TAB_ACTIVE`-class refusal, not silent. |
| Draft review-note persistence | `useLocalStorage` / `useSessionStorage` | react-use-native | Draft annotations survive reload; final notes live in Cosmos (ETag-CAS), never in LS. |
| Review-set list ops | `useList` / `useMap` | react-use-native | In-memory review queue state; durable form goes through `appendLocal`. |
| Idle → session lock (ethical wall) | `useIdle` | pattern-port | Idle threshold locks the review session and force-drains the journal before lock (no un-acked custody frames left in a locked tab). |
| Chain-of-custody banner | `useAndon` | engine-native | Raised/refused standing for WORM 409 `ContainerLocked` refusals. |
| Media queries for review grids | `useMediaQuery` | react-use-native | Doc-review vs film-strip layouts. |
| Clipboard citation copy | `useCopyToClipboard` | react-use-native | Copy tx_id/ledger refs. |
| Speech | `useSpeechRecognition` | — | skip (domain-creep; transcript integrity is evidence-adjacent). |

WAL lifecycle: `useNetwork` gates `flushSync`; `useIdle` forces drain-before-lock;
snapback on server refusal replays nothing silently — review-session state
rebuilds from `rehydratePlan`.

### 2. Financial services (seed: warehouse-sim + smalt/workspace; faces: Cosmos CAS, KV sign/release, EH, AppConfig flags, Ledger)

| Concern | Hook | Tag | Notes |
|---|---|---|---|
| Offline order-entry queuing | `useNetwork` | pattern-port | Same WAL gate as legal; orders append locally, flush on reconnect; CAS refusal (`SYNC_REFUSED_BY_SERVER`) → snapback + re-quote. |
| Draft order persistence | `useLocalStorage` | react-use-native | Ticket drafts; never balances. |
| Order/position book views | `useList` / `useMap` | react-use-native | Volatile view over acked frames; truth = Cosmos CAS docs. |
| Risk-limit flag flip UX | `useSessionStorage` + engine | pattern-port | Flag evaluate context (`appconfig_features.ex:100`) staged locally until sync. |
| Idle → trade-desk lockout | `useIdle` | pattern-port | Force-drain then lock; compliance-grade. |
| Market-data throttled display | `useThrottle` / `useRaf` | react-use-native | EH replay leg via relay; render-side throttle only — ingest stays server-side. |
| Stale-quote indicator | `usePrevious` + `useUpdateEffect` | react-use-native | Compare successive acked snapshots. |
| Terminal status derivation | `useSovereignTerminal` | engine-native | READY_STANDALONE/COMMITTED_LOCAL/SYNCED_AND_SEALED already derived. |
| Deep-link to blotter | `useSearchParam` / `useHash` | react-use-native | Shareable blotter state. |
| Key-release ceremony banner | `useAndon` | engine-native | SKR refusal standing. |

### 3. Pharma 21 CFR Part 11 (authored fresh; faces: Blob WORM batch records, Cosmos LIMS, AppConfig part-11 flags, KV PS256 e-sig, Ledger audit trail)

| Concern | Hook | Tag | Notes |
|---|---|---|---|
| Offline batch-record capture (cleanroom terminals) | `useNetwork` | pattern-port | Entries append to WAL offline; flush gated; 11.10(e) audit frames never dropped, only deferred. |
| Second-person verification drafts | `useLocalStorage` | react-use-native | Draft only; the verified record is ETag-CAS'd in Cosmos. |
| e-Signature idle timeout (Part 11 §11.10(d)) | `useIdle` | pattern-port | Walk-away invalidates the open signing ceremony: drain journal, invalidate credential cache, andon-raise. The strictest of the six industries. |
| Attestation banner | `useAndon` | engine-native | Disposition refusal standing. |
| Batch list / disposition state | `useList` / `useMap` | react-use-native | View-only; audit trail = Ledger. |
| Form-factor: tablet on floor | `useMediaQuery`, `useOrientation` | react-use-native | Gloved/touch layouts on batch-record terminals. |
| Audit-trail link copy | `useCopyToClipboard` | react-use-native | tx_id references into batch PDFs. |
| Permission state for camera (label scan) | `usePermission` | react-use-native | Optional label-photo evidence via blob face. |
| Speech | `useSpeechRecognition` | — | skip: 21 CFR data is typed or scanned, never dictated (attribution). |

### 4. Aerospace/defense air-gap (seed: wd-fa-web; faces: zero-egress workspace, Attestation, KV PS256 custody, EH capture, Blob WORM)

| Concern | Hook | Tag | Notes |
|---|---|---|---|
| Operator walk-away auto-seal | `useIdle` | pattern-port | THE defense hook: idle → seal current journal segment (`COMMITTED_LOCAL`), release master lease, screen-lock. Sealed segments are never edited, only appended-after. |
| Network-state discipline | `useNetwork` | pattern-port | Inverted use: console is loopback-only by construction; `useNetwork` "offline" is the *expected* state — surfaced as ambient air-gap status, not as a degradation banner. |
| Multi-tab custody lease | (tab-lease) | engine-native | `withWalLease` master lease + `PEER_TAB_ACTIVE` already landed; no vendor hook (react-use has none covering Web Locks). |
| FMEA triage lists | `useList` / `useMap` / `useSet` | react-use-native | Workbench case views. |
| Classification-banner media layout | `useMediaQuery` | react-use-native | Field-device (ruggedized tablet) vs desk layouts. |
| Geofence attestation | `useGeolocation` | pattern-port | SCIF/facility geofence check feeding `/attest/:type` (`AttestRoutes.ex:17`) — refused geolocation = refused custody signing. |
| Fullscreen kiosk | `useFullscreen` | react-use-native | Console lock-down mode. |
| Prevent accidental exit mid-ceremony | `useBeforeUnload`? (not in react-use — use engine) | pattern-port | beforeunload guard wired to `unacked()>0` (vendor `react-use` lacks it; small page-level compose). |
| Speech/voice | `useSpeechRecognition` | — | skip (air-gap + classification). |

### 5. Manufacturing / DfLSS Andon (seed: wasm4pm OCEL; faces: EH telemetry, Andon/OCEL Powl2, Cosmos genealogy, AppConfig SPC params)

| Concern | Hook | Tag | Notes |
|---|---|---|---|
| Station-terminal offline buffering | `useNetwork` | pattern-port | Line telemetry legs degrade to WAL appends; drain on reconnect (EH ingest stays server-side; this is console-side station evidence). |
| Andon state + cord | `useAndon` | engine-native | Already the landed Pattern 14 ambient-cord provider; wire to `powl2/andon_wire.ex`. |
| Andon event log views | `useList` / `useMap` | react-use-native | OCEL event/object projections in the console. |
| Station-tablet layouts | `useMediaQuery`, `useOrientation` | react-use-native | Wall-mounted andon board vs handheld. |
| Operator idle → station handoff | `useIdle` | pattern-port | Idle station releases its WAL lease so the next operator's tab can acquire (pairs with SPOF-4.2 rehydrate-on-acquire). |
| SPC parameter drafts | `useLocalStorage` | react-use-native | Draft recipe tweaks; admitted params are AppConfig ETag-CAS. |
| Live gauge refresh | `useInterval` / `useRaf` | react-use-native | Poll andon wire face (bounded, observable — not sleep-based). |
| Shift-report clipboard | `useCopyToClipboard` | react-use-native | OCEL export snippets. |

### 6. Semantic CAD/BIM temporal KG (authored fresh; faces: Purview Atlas, bitemporal Cosmos, Blob model WORM, KV signing, AppConfig snapshots)

| Concern | Hook | Tag | Notes |
|---|---|---|---|
| Model-revision draft persistence | `useLocalStorage` | react-use-native | Authoring-session drafts; revisions are WORM blobs + bitemporal Cosmos docs. |
| Entity/relationship graph views | `useMap` / `useSet` | react-use-native | Atlas entity/relationship selection state (typedef/store faces, `purview_atlas.ex`). |
| Large-model offline checkout | `useNetwork` + WAL | pattern-port | Same journal contract: annotation frames append locally, flush when the loopback plane is reachable. |
| Viewer canvas sizing | `useMeasure`, `useWindowSize`, `useScrollbarWidth` | react-use-native | 3D/BIM viewport layout. |
| Idle → revision auto-save+seal | `useIdle` | pattern-port | Seal open revision frame, release lease — CAD sessions are long; walk-away must not lose valid-time open state. |
| Design-authority signing banner | `useAndon` | engine-native | Signing refusal standing. |
| Valid-time range slider state | `useDebounce` | react-use-native | Debounced bitemporal queries to Cosmos (query-cost gate, not coordination). |
| Deep-link to model state | `useSearchParam` / `useHash` | react-use-native | Shareable (entity, valid-time) views. |

## Cross-cutting: hooks that map directly onto WAL/sync lifecycle events

| Engine event | Hook(s) | Pattern |
|---|---|---|
| `appendLocal` (frame appended, un-acked) | `useList`/`useMap` | Volatile view mirrors `unacked()` for pending-queue UI |
| `flushSync` success (cursor advance) | `usePrevious` + `useUpdateEffect` | Stale-data indicators on acked-snapshot change |
| `SYNC_REFUSED_BY_SERVER` → snapback | `useAndon` (engine-native) | Raise refusal standing; terminal re-derives to `READY_STANDALONE` |
| `PEER_TAB_ACTIVE` | `useAndon` (engine-native) | Disclose fallback-tab degraded mode (SPOF-4.1 disclosure law) |
| lease `locked→fallback→unknown` | `useMediaQuery` (orthogonal) + snapshot `leaseMode` | leaseMode already carried in the journal snapshot — render-only |
| `needsRehydrate` / `rehydratePlan` | `useIdle` (trigger) | Idle-before-acquire reduces dead-master replay windows |
| terminal `COMMITTED_LOCAL → SYNCED_AND_SEALED` | `useSovereignTerminal` (engine-native) | Already the derived state machine; hooks only render it |

## Top 8 hooks by cross-industry value

1. **`useIdle`** (pattern-port) — walks away: session lock (legal), trade-desk
   lockout (financial), e-sig invalidation (pharma), auto-seal (defense),
   station handoff (mfg), revision seal (CAD). Six-for-six, each drain-before-lock.
2. **`useNetwork`** (pattern-port) — the WAL flush gate in all six; defense uses
   it inverted as air-gap status display.
3. **`useLocalStorage`** (+ `useSessionStorage`) (react-use-native) — draft
   persistence everywhere; drafts are always engine-external (durable truth
   stays CAS'd server-side).
4. **`useList` / `useMap` / `useSet`** (react-use-native) — volatile projections
   over WAL/acked frames in every industry console (review sets, blotters,
   triage lists, OCEL views, Atlas graph views).
5. **`useMediaQuery`** (+ `useOrientation`) (react-use-native) — field-device
   layouts: review grids, floor tablets, ruggedized defense tablets, CAD
   viewports.
6. **`useAndon`** (engine-native) — refusal/custody banner already landed; one
   provider reused per industry with industry rules.
7. **`useGeolocation`** (pattern-port) — custodian attestation (legal) and
   facility geofence (defense); niche but high-consequence, pairs with
   `/attest/:type` and Ledger appends.
8. **`useCopyToClipboard`** (react-use-native) — tx_id/ledger/citation copy
   across legal, financial, pharma, mfg — small, universal operator affordance.

Explicitly skipped: `useSpeechRecognition`/`useSpeechSynthesis` (domain-creep;
attribution/at-air-gap problems in four of six industries), `useBattery`,
`useMotion`, `useDrop`/`useDrag` (no engine seam yet), anything time-as-proxy.

## DoD

- Every mapping cites either a landed engine module (`workspace/lib/engine/*`)
  or an emulator face cited in `azure-industry-matrix.md`; no new GAP tokens
  minted; no code touched; not committed.
