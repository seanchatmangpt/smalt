# BK-STANDALONE — console standalone output (WI-3, BK-TOPO cell 2b)

**Standing:** ALIVE
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main, shared tree — coordinator owns git)
Lane: BK-STANDALONE
Owns: `workspace/next.config.mjs`, `Dockerfile.console`, this receipt.

## Change

`workspace/next.config.mjs` gains `output: "standalone"` (WI-3 of
`docs/jira/v26.10.22/TOPOLOGY-MATRIX.md`, cell 2b work item). Static export
is falsified (BK-P20: `force-dynamic` BFF route handlers + the `headers()`
COOP/COEP server face are structurally incompatible with `output: "export"`);
standalone is the middle path — the traced build still emits a real Node
server (`.next/standalone/.../server.js`) with the BFF faces intact, plus a
traced `node_modules` subset instead of the full tree.

Unconditional config: `output` is a **build-output mode only** — `next dev`
is byte-identical (verified below by the e2e-court live-harness legs, which
run `next dev` against this exact config).

## Build (host, workspace/)

```
$ cd workspace && npm run build
✓ Compiled successfully in 1932ms-class ...
ƒ (Dynamic)  server-rendered on demand   <- BFF faces intact
$ ls .next/standalone/workspace/server.js  (repo-root lockfile -> Next nests under workspace/)
103M .next/standalone
```

## Boot smoke (host standalone server, private port 47311)

```
$ cp -r .next/static .next/standalone/workspace/.next/static
$ cp -r public .next/standalone/workspace/public
$ PORT=47311 HOSTNAME=127.0.0.1 node .next/standalone/workspace/server.js
✓ Ready in 0ms  / ✓ Running next.config took 2.0ms
$ curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:47311/          -> 200
$ curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:47311/console   -> 200
$ curl -sI http://127.0.0.1:47311/console | grep -i cross-origin
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
$ curl -s -X POST .../api/sync/state -d '{}'
{"error":"sync_state_invalid_batch","detail":"expected a JSON array batch"}   (typed 400 — BFF route alive, validating)
```

## Dockerfile.console runtime stage

Runtime now copies the traced standalone bundle + static assets instead of
full `node_modules` + full `.next`; entrypoint is `node server.js`
(`PORT`/`HOSTNAME` env):

```
COPY --from=build --chown=1000:1000 /app/.next/standalone ./
COPY --from=build --chown=1000:1000 /app/.next/static ./.next/static
COPY --from=build --chown=1000:1000 /app/public ./public
CMD ["node", "server.js"]
```

Path note (typed): in-container the tracing root is `/app` (single package,
lockfile at `/app`), so standalone output is `/app/.next/standalone`
directly; on the laptop the repo-root detection makes Next nest the output
under `workspace/`. First build attempt COPYed the nested path and failed
(`"/app/.next/standalone/workspace": not found`); fixed to the flat path.

## Image sizes (before/after)

| image | size |
|---|---|
| `smalt-console:bkimg` (BEFORE — full node_modules + .next, `next start`) | 1.21GB |
| `smalt-console:standalone` (AFTER — traced standalone, `node server.js`) | **437MB** (−64%) |

## Container smoke (smalt-console:standalone, port 47377)

```
$ docker run -d --rm -p 127.0.0.1:47377:3000 smalt-console:standalone
$ curl root          -> 200
$ curl /console      -> 200 (COOP/COEP headers intact)
$ curl /terminal     -> 200
$ POST /api/sync/state {} -> {"error":"sync_state_invalid_batch", ...} (typed 400)
Status: Up (health: starting) at probe time — stopped right after the curls
```

## Courts

- `workspace/scripts/e2e-court.mjs` (`NODE_PATH=... node scripts/e2e-court.mjs`):
  **PASS=73 FAIL=0 SKIP=2** — both skips are the court's pre-existing loud
  classes (DOM/Web Serial not executable in node; popcorn live leg needs a
  :3100 server).
- `workspace npx tsc --noEmit`: exit 0.
- `workspace node scripts/hooks-court.mjs`: exit 0.
- `smalt-cli pytest tests/test_ty_monitor.py` (asdf shims first): **8 passed**
  against the live anonymous substrate (real wire).

## Disclosures

- Killed two orphaned `next dev`/`next-server` processes (PIDs 52372, 72743;
  15 min and 1 h old, both bound to :3000 in the shared workspace dir) that
  blocked the e2e-court harness's own dev-server spawn. Not in-flight courts
  — parents were bare `next dev` launches, not court shells.
- `just` is currently parse-broken by another lane's in-flight
  `justfile.d/53-trivy.just:24` (extra leading whitespace) — recipes invoked
  directly instead; not my file, untouched.
- The justfile-documented `just ws-court` was run as its raw command
  (`NODE_PATH=... node scripts/e2e-court.mjs`) for the reason above; exit 0.
- Coordinator checkpoint 51d591c7 absorbed the in-flight
  `workspace/next.config.mjs` diff mid-lane (precedent: BK-DLQ3). This
  lane's commit d5096a7e therefore carries Dockerfile.console + this
  receipt only; the config diff itself landed in that checkpoint (verified
  present in HEAD via `git show HEAD:workspace/next.config.mjs`).
