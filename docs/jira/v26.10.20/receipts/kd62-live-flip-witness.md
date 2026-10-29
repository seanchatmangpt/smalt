# KD-62 live-flip witness — substrate recycle W17-B (2026-10-20)

- **Standing**: PASS (KD-69 + KD-114 faces) / **FAIL — KD-62 envelope face**
- **Context**: solo
- **Witnesses**: KD-62 (envelope + SAS faces), KD-69 (epoch falsifier),
  KD-114 (TLS bearer routing) on a fresh substrate boot, pid 75722.

## Substrate recycle (step 1)

- Prior substrate pid **62309** (booted 22:06:53 PDT, ports
  9443/9444/8443/5672/5673 all LISTEN under it) recorded, then
  `just substrate-down` (exit 0, all four ports freed) +
  `9>&- just substrate-up` (exit 0; lock fd NOT inherited; spawned pid
  **75722**). Readiness by bounded poll (deadline 60s, all five ports
  LISTEN — observed within seconds).
- **Env drift note**: prior boot carried
  `Application.put_env(:smalt, :sb_shared_key, "ws8sharedkey")`; the
  fresh boot printed `[substrate] WARNING: SMALT_SB_SHARED_KEY unset —
  using the pinned dev default key`. Auth mode `:enforce` set explicitly
  by the boot command on both boots (unchanged).

## Blob CORS re-seed (step 2)

`PUT http://127.0.0.1:8443/popcorn?restype=service&comp=properties`
(bearer, x-ms-version 2023-11-03, body
`<StorageServiceProperties><Cors><CorsRule><AllowedOrigins>*</AllowedOrigins><AllowedMethods>GET,PUT,POST,OPTIONS</AllowedMethods><AllowedHeaders>*</AllowedHeaders><ExposedHeaders>*</ExposedHeaders><MaxAgeInSeconds>600</MaxAgeInSeconds></CorsRule></Cors></StorageServiceProperties>`)
→ **HTTP 202**; OPTIONS preflight `/popcorn/c/probe.txt`
(Origin + Access-Control-Request-Method: PUT) → **200** (was 403 before
the seeded body landed — the first PUT went out with an empty body from a
scripting typo and correctly cleared rules; re-PUT with the real body
flipped preflight to 200, which is itself evidence the rule is live).

## KD-62 live witness (step 3) — envelope face FAIL

- **POST /popcorn-account?comp=userdelegationkey** (bearer, x-ms-version
  2023-11-03, Content-Type application/xml, body
  `<KeyInfo><Start>2026-10-20T22:00:00Z</Start><Expiry>2026-10-21T22:00:00Z</Expiry></KeyInfo>`)
  → **HTTP 404** `{"error":{"code":"RouteNotFound","message":"No route matches POST /popcorn-account"}}`.
  No envelope, so no HMAC spot-check was possible.
- SAS-only URI face (sig=AAAA%3D%3D&se=2099-01-01…, no x-ms-version) →
  **HTTP 401** `{"error":{"code":"AuthenticationFailed","message":"MissingBearerToken"}}`
  — the registered typed refusal class (never MissingXMsVersion). This
  face PASSES on the fresh boot.

**Root cause (verified, not inferred)**: the KD-62 arm and its helpers
(`udk_window/1`, `udk_account_key/1`, `udk_string_to_sign/3`,
`# KD-COVERS: KD-62`) exist in HEAD 33cd2a1
(`git show HEAD:lib/smalt/egress_router.ex | grep -c udk_account_key` → 2)
but the **working tree reverted them at 22:10:23 PDT** (mtime;
`grep -c userdelegationkey lib/smalt/egress_router.ex` → 0), between the
old boot (22:06) and the fresh boot (22:19). The fresh substrate compiled
the stripped tree. The same 22:10 sweep also removed the
`access-control-expose-headers: www-authenticate` challenge-header fix
from lib/smalt/auth/bearer.ex and the KD-66 ranged-GET content-md5 block.
The revert is coordinated with doc edits (scvd.jsonl/TESTBED/BENCH_SCVD),
so it reads as a deliberate lane transition, not corruption — I did not
touch the file (not my lane-owned surface). The pre-revert boot (62309)
predates the fix anyway, so **the KD-62 live flip has still never been
witnessed on a shared-substrate boot**; it needs a re-recycle after the
revert's owner either re-lands or the coordinator restores HEAD state.

## KD-69 live confirm (step 4) — PASS

`timeout 90 mix run --no-start /tmp/kd69_falsifier.exs` (pure TCP; the
first run without `--no-start` failed on `:eaddrinuse` self-boot vs the
live substrate — that is the harness face, not the falsifier), verbatim:

```
KD69-RESULT: %{
  face1_a_attach: {:ok, "A attached epoch=7, no detach within 500ms"},
  face2_b_evicts_a: {:ok, ...},
  face3_c_stale_refused: {:ok, ...},
KD69-VERDICT: PASS
```

(exit 0. All three faces ok on the fresh boot, pid 75722.)

## KD-114 live confirm (step 5) — PASS

Over `https://127.0.0.1:9444` (curl --cacert .smalt/tls/ca-cert.pem,
bearer from `POST http://127.0.0.1:9443/organizations/oauth2/v2.0/token`,
x-ms-version 2023-11-03):

```
PUT /popcorn/kd114w17b?restype=container → 201
PUT /popcorn/kd114w17b/w17b.txt (BlockBlob "kd114-w17b-payload") → 201
GET /popcorn/kd114w17b/w17b.txt          → 200 "kd114-w17b-payload"
```

## Falsifier status

- KD-69: PASS on fresh boot — flip evidence row (flip is coordinator-owned).
- KD-114: PASS on fresh boot — routing face holds.
- KD-62: SAS-refusal face PASS, **envelope face FAIL on this boot** —
  blocked by the 22:10 working-tree revert, not by the route logic
  (HEAD 33cd2a1 carries the arm and the plug-conn court
  test/integration/kd62_udk_witness_test.exs passed 4/4 on the edited
  tree per kd62-udk-admission-witness.md). KD-62 stays OPEN; live flip
  still pending a post-restore/re-land substrate recycle. No register
  flip performed.

## Addendum (coordinator, 2026-10-21 post-restore): shared-substrate live witness

The working-tree revert (22:10) was restored from HEAD; substrate recycled onto
the restored tree. Live wire, fresh tokens:

```
POST /popcorn?comp=userdelegationkey (bearer + x-ms-version + xml Start/Expiry)
→ 200 {"delegatedUser":"...001","expiry":"2026-10-22T00:00:00Z",
       "issuedTo":"127.0.0.1","signedObject":{"account":"popcorn","service":"b",
       "version":"2021-12-02"}, ...,"value":"LolzqHeywNhymgTakKOIlz46QbWLZV5fApWwlXD+KEk="}
SAS-only / missing-x-ms-version faces → typed 400/401 refusals (re-verified)
```

KD-62's close condition (typed UDK admission on the wire, HMAC-backed value,
SAS verification face explicitly typed) holds post-restore.
