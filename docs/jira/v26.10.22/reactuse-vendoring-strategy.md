# React-Use Vendoring Strategy

Milestone: v26.10.22 — design doc, no code changes, no commit.
Scope: how (and whether) streamich/react-use hooks enter the Sovereign
Console (`/Users/sac/smalt/workspace`) under the air-gap constraints.

## 0. Grounding (real repo reads, 2026-10-21)

- `workspace/package.json` — dependencies are Next 16 / React 19.3 plus the
  eight `@azure/*` SDKs. **No react-use, no hook utility packages.** The
  dependency surface is intentionally narrow; `node_modules` is a vendored
  offline store, not a runtime fetch target.
- `workspace/next.config.mjs` — no `output: "export"` today; config is
  headers-only (COOP/COEP, no egress images/fonts/scripts). `output` mode
  implications below are for the *future* static-export path.
- `workspace/lib/engine/` — the landed engine hooks are hand-written
  pattern ports, not library imports: `useJournal.ts` ("Pattern 16 —
  Reactive Hearth", built on `useSyncExternalStore` with an SSR-safe
  `getServerSnapshot`), `useAndon.tsx` ("Pattern 14 — Ambient Cord",
  context-based), plus `useSovereignTerminal.ts`. Each cites its own
  pattern number — this is the "vendored patterns, not packages" precedent.
- `workspace/lib/engine/law-worker-bridge.ts:20-26` and `guard.ts:80` —
  BK-54 Class A law in situ: worker spawn is *injected* by the page
  because `import.meta.url` "resolves in page/bundler territory"; lib/
  engine is compiled commonjs by the node courts where `import.meta` is
  illegal. No repo-root constants; everything URL-derived.
- `workspace/README.md:40-95` — networking air-gap invariant is
  lint-enforced (`smaltFetch`/`assertLocalUrl` only); the offline store
  classifies packages `vendored` vs `missing` and an offline gap "must not
  hit the network to install".
- `ws-build` network: `next build` itself makes no network calls (no
  font/image optimization, `images.unoptimized: true`), but `npm install`
  for a new dep would need the offline store refreshed — i.e. a build-time
  npm dep is *not* free; it costs an offline-store refresh per version
  bump.

## 1. License facts

`streamich/react-use` is licensed **Unlicense** (public-domain dedication,
verified against upstream `package.json` `license` field). Consequences:

- Copying hook source into the tree is permitted without attribution
  *legally*, but smalt convention is disclosure regardless (receipt- and
  GAP-token culture: an unreceipted lift is indistinguishable from
  hand-written code that later diverges silently).
- Unlicense means the strictest option (per-file license headers +
  `THIRD_PARTY` row) is cheap insurance, not a legal necessity.

## 2. Decision matrix

| Criterion | A: full npm dep at build time | B: cherry-picked vendored files (`workspace/lib/engine/vendor/react-use/`, license headers) | C: pattern-port into our own hooks |
|---|---|---|---|
| Zero-egress / no runtime fetch | OK (dep resolved from offline store) but every bump needs an offline-store refresh | OK — file copy, versioned by receipt | OK — nothing to refresh |
| Matches existing precedent | No — breaks the "patterns not packages" pattern the engine hooks set | Partial — introduces first `vendor/` dir | **Yes** — useJournal/useAndon already did this |
| Upstream bugfix flow | Best (npm update) | Manual re-copy per hook | Ours to own |
| BK-54 Class A (import.meta.url-derived, no absolute paths) | Risky: react-use internals (e.g. `useRaf`, `useWorker`) reference `window`/bundler assumptions not our law; we cannot audit the whole package | Auditable per-file; we rewrite path/worker constants to the law at vendoring time | Fully ours — law-compliant by construction |
| Tree-shake under static `output` | Fine for ESM (react-use ships per-hook modules; Next/Turbopack tree-shakes), but pulls transitive deps (`use-sync-external-store` shim vs React 19 built-in) | Only what is copied ships | Only what we write ships |
| Node-court compilation | Some hooks import `document`/`navigator` at module scope — server-side court builds can break | Only copied files ever compiled | Already proven (current hooks compile) |
| Air-gap lint (`raw fetch` ban, egress router) | Neutral | Neutral | Neutral |
| Dependency-audit surface (`publish-dry` tarball greps, offline-store census) | New package to classify `vendored`; README offline table row owed | One `THIRD_PARTY.md` row + headers | Zero new surface |
| Cost for >~10 hooks | Lowest marginal | Rises linearly, but each hook is ~50-200 LOC | Rises linearly; risk of subtle divergence from upstream semantics |

## 3. License / attribution mechanics (if B ever used)

1. Each copied file keeps an unbroken header block: upstream repo, commit
   SHA, Unlicense notice, `VENDORED:` marker, and the smalt receipt path
   that admitted it.
2. `docs/THIRD_PARTY.md` gains one row (react-use, Unlicense, vendored
   subset, upstream SHA). It is a generated artifact — the row must come
   from the `Canonical.write` rider path, not hand-editing.
3. A file whose header lacks `VENDORED:` + SHA fails review; the
   `naming-sweep`/docs-dod gate is the natural enforcement point if the
   vendor dir ever materializes.

## 4. Tree-shake / `output` mode implications

- Current config has no `output` override. If the console moves to
  `output: "export"` (static hosting in the air gap), every byte ships to
  clients: option A still tree-shakes fine (react-use is ESM, per-hook
  entry points), but its transitive deps and the
  `use-sync-external-store` compatibility path widen the client bundle
  versus options B/C, where only authored/copied hook code exists.
- Option B's vendor dir would sit inside `lib/engine`, compiled by both
  the Next build (client) and the node courts (commonjs). Hooks using
  `import.meta.url` are illegal in the node-court path (witnessed:
  `law-worker-bridge.ts` deliberately keeps `import.meta` out of lib/).
  Any vendored hook touching workers/URLs must follow the bridge's
  injected-spawn pattern instead.
- SSR: react-use hooks without `getServerSnapshot` equivalents break
  `useSyncExternalStore` SSR contracts our `useJournal.ts` already honors.
  Pattern ports (C) preserve those contracts by construction.

## 5. Recommendation

**Option C — pattern-port.** The engine already demonstrates the pattern
(Reactive Hearth, Ambient Cord are self-authored, law-compliant,
SSR-safe); react-use's marginal hooks (event/observer/animation utilities)
are small enough to port individually when a concrete need arrives, under
the existing "patterns not packages" doctrine. Do not adopt option A
(offline-store churn + audit surface + Class A incompatibility risk for
zero capability we cannot hand-write). Option B is the fallback of
record only when a hook is too subtle to port safely (e.g. `useAudio`
class of media hooks) — then vendor exactly that file with §3 mechanics.

**Falsifier (would reverse C → A or B):** a needed hook whose ported
version cannot pass the existing courts — i.e. a pattern-port that
repeatedly diverges from upstream behavior under `just ws-court` /
workspace e2e, or a whole-hook-family adoption need (>10 hooks in one
milestone) where per-hook ports cost more than the offline-store refresh
of option A. Absent one of those observations, C stands.

## See Also

- `workspace/README.md` — air-gap invariant, offline store census
- `workspace/lib/engine/law-worker-bridge.ts` — BK-54 Class A in situ
- `docs/jira/v26.10.22/receipts/bk54-private-trip-remediation.md`
- `docs/THIRD_PARTY.md` (generated; canonical-write rider)
