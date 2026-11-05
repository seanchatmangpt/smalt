# L16 — kv7 BEAM-oracle live leg

Standing: ALIVE

Repo: /Users/sac/smalt. Lane: L16, milestone v26.11.5 (mount chain
5b4f39e9 / 4dedd0bd / 4d6c20ef — the registered seed is the BEAM-oracle
live leg).

## Subject

- `test/internal/kv7_beam_oracle_court_test.exs` — the court: >=5 kv7 ops
  (put / point-get / put re-set x2 / patch / versions-list / list / delete)
  through BOTH faces on the same keys, (status, body) parity per op.
- `test/support/kv7_oracle.ex` — helper: BEAM wire client (KD-15 tokenless
  challenge leg; authed legs ride the data plane's documented KD-114
  SharedKey dev-key admission — per-account key
  `base64(sha256(account <> "smalt-dev-sb"))`, 2021-12-02 StringToSign, the
  WO-32 cordon removed the BEAM 9443 STS mint face so SharedKey is the
  lawful data-plane client credential this window) + posh translate-face
  driver (runtime-generated Go driver under `posh/kv7-oracle-l16-driver/`,
  `azure.Kv7TranslateFor` delegation bindings only, KD-03 law-free, deleted
  on exit).

## Court design

BEAM data plane (8443, real HTTP, real ETS stores) = ORACLE. The posh kv7
translate face is pinned against it on the same keys:

| op | BEAM face (live HTTP) | posh face (translate binding) | parity assert |
|---|---|---|---|
| put (create) | 201, value echoed, guid version, id grammar | azure.kv7.secrets.put on canonical row | key sets + value/id byte-equal |
| point get | 200, latest == last write | azure.kv7.secrets.get | key sets + value/id |
| put re-set x2 | 200, version accumulation, distinct mints | azure.kv7.secrets.put | key sets + value/id |
| patch | 200, value never rotates, enabled=false persists | azure.kv7.secrets.patch (tags member law) | key sets + value/id/attributes.enabled |
| versions list | 200, 3 entries, newest-first (KD-S4), value+version per KD-S3 | azure.kv7.secrets.versions per entry | per-entry key sets + scalars |
| list | 200, KD-03 drop (no value), bookkeeping never leaves | azure.kv7.secrets.list (drop-list proven with injected SHOULD-BE-DROPPED) | key sets + drop polarity |
| delete | 200, recoveryId contract, no value | azure.kv7.secrets.delete (engine-soft-delete policy) | id + no-value polarity |
| post-delete get | 404 by construction | — | — |

Readiness: bounded TCP-dial poll (SmaltTest.AssertEventually), 30s deadline,
no sleeps. Substrate down = loud typed skip (ExUnit.SkipError).

## Commands / exits

```
bash scripts/substrate.sh up            # SMALT_UP_TIMEOUT=300, lock fd closed (9>&-)
curl 8443/secrets -> 401                # data plane serving (KD-15 posture)
mix test test/internal/kv7_beam_oracle_court_test.exs   # exit 0
```

## Verification ladder

- narrow: syntax-check both files (`Code.string_to_quoted`) OK
- live court: 1 test, 0 failures, 2xx/401/404 law per op as table above
- posh driver: `go build` in posh module (go 1.26.0), law-free binding call

## Falsifiers exercised this session (real failures fixed, not hidden)

1. duplicate x-ms-date header (sent in request head + signed set) → MAC
   mismatch 401 → fixed to single header.
2. lowercase HTTP method in request line → BEAM Plug method match is
   case-sensitive → RouteNotFound 404 → fixed to uppercase.
3. StringToSign method leg not upcased with the wire method → MAC mismatch →
   fixed.
4. driver dir `posh/.kv7-oracle-l16/` — Go tooling ignores dot-dirs →
   renamed `kv7-oracle-l16-driver/`.
5. `Path.expand("../posh", __DIR__)` from test/support resolves to
   `test/posh`, not repo `posh/` → fixed to `../../posh`.
6. Port line-mode delivers `{:eol, line}` tuples, not binaries → recv fix.
7. `Port.close` on an already-dead port raises badarg in on_exit → guarded.

## Standing note

ALIVE only if the court ran green this session (see Commands/exits with the
final run appended below).

## Run receipts

- 18:04 local — 1 test, 0 failures (first full green; live 8443 data plane)
- final run (this session, post-fixes) — live 8443 data plane, substrate UP:
  `mix test test/internal/kv7_beam_oracle_court_test.exs` →
  `Result: 1 passed` (0 failures), exit 0. Re-run repeatable.
