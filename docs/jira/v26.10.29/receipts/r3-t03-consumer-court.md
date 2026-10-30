# Receipt: R3 T03 — courtroom-platform-az consumer court

Lane T03 · 2026-10-29 · harness: `scripts/courtroom_consumer_court.sh`, recipes
`justfile.d/56-courtroom.just` (`just courtroom-court` / `just courtroom-check`),
Justfile import appended. Consumer repo read-only (git archive only).

## Standing

**PARTIAL_ALIVE** — legs 1 and 2 ALIVE (rc 0), leg 3 BLOCKED on a typed
divergence. Full sign-in flow NOT validated; ALIVE is not claimed.

## Leg 1 — consumer materialize + check — rc 0

- SHA: `338caed8008727990c03078b348886b8a43d919a` →
  `/tmp/courtroom-void/338caed8008727990c03078b348886b8a43d919a` (git archive; consumer repo untouched).
- node 22 (nvm 22), `npm ci` rc 0 ("added 265 packages in 5s"), `npm run check` rc 0
  ("Test Files 1 passed (1)", "Tests 26 passed (26)"). Engines `>=22 <25` satisfied.
- Known consumer-repo finding confirmed: engines require node 22/23 (node 20/26 both fail npm ci engine-strict).

## Leg 2 — smalt substrate faces — rc 0

- Gate: waited for the concurrent lanes' `lib/smalt/data_plane/redis_wire.ex` +
  `lib/smalt/identity/saml_idp.ex` (landed ~20:07–20:09 local; bounded poll, no timeout).
- config/config.exs wires zero `System.get_env` (count 0), so no env-override path.
  Lawful boot used the substrate.sh-identical pattern:
  `mix run --no-start --no-halt -e 'Application.put_env(:smalt, :redis_port, 16380); Application.put_env(:smalt, :saml_idp_port, 19445); {:ok,_} = Application.ensure_all_started(:smalt)'`,
  spawned under the per-WINDOW flock with fd 9 closed. No smalt config file created/edited.
- Both faces LISTEN: redis wire :16380, saml idp :19445 (beam pid 15658).
- IdP face witnessed serving real SAML metadata on GET /metadata
  (entityID `urn:smalt:identity:saml`, RSA X509 KeyDescriptor present).
- Compile-freeze SLA disclosure (one-hop fix in another lane's in-flight file):
  `saml_idp.ex` child_spec passed Bandit opts as 4 separate args
  (`Bandit.start_link/4 undefined` boot crash). I applied the minimal fix — wrapping the
  opts in an extra list (`{Bandit, :start_link, [[plug: ..., scheme: :http, port: port, ip: ...]]}`) —
  after a bounded owner window; the owner had separately fixed an earlier `~s(...)` sigil
  syntax error (line 321) during that window. As-of 20:20 local the file also received
  further owner edits; re-verify on disk before citing the fix as still present.

## Leg 3 — consumer-on-smalt — FAILED assertion, court exit 1

- apps/api booted from scratch on :18080 with REDIS_URL=redis://127.0.0.1:16380,
  smalt IdP env (SAML_ENTRY_POINT=http://127.0.0.1:19445/sso,
  SAML_IDP_ISSUER=urn:smalt:identity:saml,
  SAML_IDP_CERT=smalt dev cert), AUTH_ALLOW_ALL_ASSIGNED_USERS=true.
- Assert `server_started ... "store":"redis"` FAILED: got NONE. API log:
  `{"event":"redis_client_error","reason":"ERR protocol error"}` repeating.

### Blocking hop (typed)

`smalt` RedisWire/AzureCache refuses `HELLO 3`
(`azure_cache.ex:193` → `-ERR NOPROTO unsupported protocol version (RESP3 refused; RESP2-only)`,
documented Azure-parity law "RESP2 only"), while the consumer's pinned
`redis@6.3.0` / `@redis/client` defaults `DEFAULT_RESP = 3`
(`node_modules/@redis/client/dist/lib/RESP/types.js:5`) and sends `HELLO 3`
as its first wire bytes (captured: `*2\r\n$5\r\nHELLO\r\n$1\r\n3\r\n...`); on the refusal it
retries forever — no RESP2 fallback path. The consumer calls `createClient({url})`
with no `RESP: 2` override, and the consumer repo is read-only for this court.
Wired commands beyond HELLO (SET NX PX / GET / DEL, SESSION) were never reached.

## Teardown

Beam 15658 TERM'd; api pid 15806 TERM'd; ports 16380/19445/18080 verified free
(lsof empty). No pattern-pkill.

## Close condition

Flip leg 3 to ALIVE by either (a) smalt adds RESP3/HELLO 3 support to the wire,
or (b) the consumer pins `RESP: 2` in `createStores` (consumer-side change,
out of this court's authority). Then rerun `just courtroom-court` — exit 0 requires
store=redis + full /api/sso/start → IdP → ACS → /api/auth/me flow.

---

## Addendum — FINISH-WIRE lane, 2026-10-29 (RESP3 hop CLOSED; SAML leg byte-bisected)

### What flipped to green

The r3 blocking hop (HELLO 3 refusal / RESP2 desync) is CLOSED. Court evidence
from the 21:49 run:

```
[T03]   api: {"time":"2026-10-30T04:51:06.469Z","level":"info","event":"server_started","port":18080,"sso":true,"store":"redis"}
[T03] leg 3 A: sso/start -> http://127.0.0.1:19445/sso?SAMLRequest=nVJNTwIxEP0rTe...
[T03] leg 3 B: IdP form action=http://127.0.0.1:18080/saml/acs SAMLResponse len=5488
```

Redis-wire fixes that landed for it (details in the r1 addendum): HELLO 3
clause-order fix (RESP3 `%5` map, proto `:3`), conn PIPELINE LAW (drain all
complete commands per recv — node-redis pipelines HELLO + 3x CLIENT in one
segment), `SET` EX/PX/NX/XX option tail (connect-redis session writes +
`setIfAbsent` `NX PX`). Two court-script defects fixed in
`scripts/courtroom_consumer_court.sh`: (a) `bash -lc "..." T03_CERT=...` placed
the cert assignment in `$0`, not env — `SAML_IDP_CERT` expanded empty;
(b) leg-3 api spawn did not close the court flock fd (`9>&-` added — the api
node was inheriting `/tmp/smalt-substrate.lock` and wedging the next window's
leg-2 for 300s, twice witnessed); (c) APP_ORIGIN/SAML_ISSUER pointed at
localhost:13000 while the api listens on $API_PORT — ACS POST target now
follows API_PORT.

### Remaining blocker: leg 3 C — IdP assertion signature (saml_idp.ex, NOT this lane's file)

```
[T03] leg 3 C: ACS POST -> 303 http://127.0.0.1:18080/?error=saml_invalid
api log: {"event":"saml_rejected","code":"saml_invalid","reason":"Invalid signature"}
```

Byte-level isolation (outside the api, `@node-saml/node-saml`
`validatePostResponseAsync` on a captured fresh response): `REJECTED: Invalid
document signature`. lxml independent check: the declared `DigestValue`
(`zyx8PQa4...`) equals sha256 of the RAW unsigned assertion string, but
exclusive-c14n of the same assertion differs (attribute order
`Version/IssueInstant` vs c14n's lexicographic order, `<X/>` vs `<X></X>`
expansion, unused `xmlns:xs` declaration dropped):

```
raw-unsigned sha256 : zyx8PQa4gt0uXoTszEMyHt+Xd/AuueLIqo/z9XnQCjY=   == declared
lxml exc-c14n sha256: tPBDjPvhvJGy72GYF2P3zf8/4HWD08AREZkbI966Xd4=   != declared
```

`saml_idp.ex` computes `digest = :crypto.hash(:sha256, unsigned)` over its
emitted string (saml_idp.ex:250) instead of over the exclusive-canonical form;
every standards-conformant verifier (xml-crypto 6.4, node-saml, lxml) recomputes
over c14n and rejects. The IdP's own court passes because it recomputes the
digest the same non-canonical way (same-calculus agreement, not conformance).
Close condition: `saml_idp.ex` must digest the exc-c14n bytes of the unsigned
assertion (and c14n the SignedInfo before signing). The consumer repo and the
court script cannot fix this — signature math is not configurable.

### Court-script falsifiers for the IdP lane

- The api is configured `wantAssertionsSigned: true`; the IdP response-level
  signature is not required (`SAML_WANT_RESPONSE_SIGNED` defaults false).
- Close = rerun `just courtroom-court` after the c14n fix; expect leg 3 C to
  303 to /dashboard and leg D (/api/auth/me 200) to complete.

## Addendum — ALIVE (coordinator, 2026-10-30 02:05)

**Standing: ALIVE** — legs 1-3 green end to end. Close conditions landed:
c14n digest law (r2/r-t04), bind_ip parse law, AudienceRestriction minted
from the AuthnRequest Issuer (coordinator patch, saml_idp.ex — node-saml
rejects without it: "SAML assertion has no AudienceRestriction"). Court run
2026-10-30 01:05Z on clean ports (orphan beams 93089/42311/59592/61279
killed by pid; ghost poller-spawned beams cleared):

- `server_started ... "store":"redis"` (api log)
- leg 3B: SAMLResponse len 8848 (audience present)
- leg 3C: `ACS POST -> 303 http://127.0.0.1:18080/dashboard`
- leg 3D: `GET /api/auth/me -> 200 {"authenticated":true,...,"tenantId":...}`
- verdict line: `PASS: full consumer sign-in flow validated through the
  consumer's own @node-saml code on smalt faces`
