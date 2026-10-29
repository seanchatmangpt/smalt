# EXPL12-V: CLI auth-contract uniformity verify (KD-15 challenge handshake)

Standing: PARTIAL_ALIVE · Context: solo · 2026-10-22 · Lane EXPL12-V

Read-only verify lane over EXPL12-R's port (`docs/jira/v26.10.22/receipts/expl12r-cli-fixes.md`).
Subject: `smalt-cli/smalt_cli/wire.py`, `smalt-cli/smalt_cli/commands/{storage,cosmosdb,keyvault,servicebus,deployment,monitor,login}.py`
at HEAD ae631298. No code edited.

## Verdict

**The auth contract is NOT uniform.** 3 of 5 command groups speak the KD-15
tokenless→401→bearer challenge handshake; servicebus + deployment bypass it
(direct-bearer, challenge leg never exercised). Typed finding below. monitor
(direct-bearer GET) is the same class.

## Per-group witnesses (real wire, :enforce shared substrate pid 76687,
SMALT_ARM/SMALT_EGRESS=https://127.0.0.1:9444 TLS twin, SSL_CERT_FILE=.smalt/tls/ca-cert.pem,
enforce STS accepts any client_id/secret)

Leg trace = httpx.Client.request mock-traced during a real CliRunner invoke
(httpx.patch is instrumentation only; the wire traffic is real).

| group | trace (one bare command, cold token cache) | exit |
|---|---|---|
| storage | `PUT tokenless->401 \| POST STS->200 \| PUT bearer->201` | 0 |
| cosmosdb | `POST tokenless->401 \| POST STS->200 \| POST bearer->201` | 0 |
| keyvault | `PUT tokenless->401 \| POST STS->200 \| PUT bearer->201` | 0 |
| deployment | `POST STS->200 \| PUT bearer->201` (no tokenless leg) | 0 |
| servicebus | `POST STS->200 \| PUT bearer->202 \| PUT bearer->201` (no tokenless leg) | 0 |

Independent raw tokenless probes (curl -k, UNIQ=expl12v063512) prove the 401
challenge is live server-side on every face — the challenge the ARM groups
skip is real and answerable:

```
storage PUT container: 401 www-auth=Bearer authorization="https://127.0.0.1:9443/organizations", resource="https://127.0.0.1:9444", error="invalid_token", error_description="MissingBearerToken"
cosmos POST dbs:       401 www-auth=Bearer ... MissingBearerToken
kv PUT secret:         401 www-auth=Bearer ... MissingBearerToken
arm-twin9444 PUT rg:   401 www-auth=Bearer ... MissingBearerToken
```

(Code-level agreement: `wire.kv_request` / `wire.cosmos_request` /
`storage._blob_request` all implement tokenless-first + one bearer retry;
`wire.arm_put`/`arm_get` pre-attach `bearer_for_arm()` — wire.py:279/284;
`monitor.py` metrics uses `headers=wire.bearer_for_arm()` directly.)

## Typed finding EXPL12V-F1

**servicebus + deployment (and monitor) bypass the KD-15 challenge handshake.**
`wire.arm_put`/`wire.arm_get` send `bearer_for_arm()` pre-attached; the
tokenless→401 challenge leg never fires, so these groups cannot re-establish
auth from a cold/expired-token state by taking the challenge (they degrade to
tokenless silently when the STS mint fails — `bearer_for_arm` returns `{}`
on exception — and then the request 401s with no retry). KD-15 corpus premise
pin: the challenge IS the premise (`KNOWN_DIVERGENCES.md` KD-15; premise pins
in smalt/CLAUDE.md corpus section). The server-side challenge is live on the
ARM face (raw probe above), so the fix is mechanical: route arm_put/arm_get
through the same tokenless-first shape as kv_request/cosmos_request. Owner:
EXPL12-R lineage (wire.py arm helpers). Not fixed by this read-only lane.

Also: `monitor.py` `metrics` is direct-bearer `httpx.get` — same finding
class, same fix shape.

## EXPL12-B groups (monitor/login)

- `login`: performs the STS round-trip itself (token minting face) — no
  data-plane call, so the KD-15 handshake is N/A; contract-appropriate. Bare
  `login -o json` witnessed: `verified: true`, HS256 Bearer minted, profile
  persisted, exit 0.
- `monitor metrics`: NOT compliant — direct-bearer, no challenge leg
  (included in EXPL12V-F1). `ocel-tail`/`endpoints`: local-file/discovery
  face, no auth contract applies (endpoints is the ARM bootstrap face).

## ty suites (fresh, this session, lane SMALT_CLI_LANE=expl12v)

```
anonymous session (cosmosdb, keyvault, monitor, login, storage):
22 passed in 24.61s
enforce session (deployment, servicebus):
7 passed in 33.23s
```

29/29 green, including EXPL12-R's `test_storage_kd15_challenge_handshake_on_enforce`.

## Honest notes

- Direct `wire.kv_request` probe traced `PUT tokenless->401 | POST STS->200 |
  PUT bearer->201` — the handshake path exercised at the helper level too.
- `monitor metrics` against the shared enforce substrate returned 500 (not
  the 200 empty envelope the anonymous test asserts) for an unknown resource.
  Out of this lane's scope (not an auth-contract issue); recorded as an
  observation for the monitor owner (EXPL12-B lineage). Substrate pid 76687
  may also predate current lib code.
- Keyvault CLI verb names are flat (`secret-set`, not `secret` noun group);
  first invocations with az-style nesting were usage errors, corrected —
  CLI UX only, no defect claim.
- The shared enforce substrate serves the data-plane faces on the 9444 TLS
  twin only in practice: direct :9443 curl exited 000 (connection failure)
  for both ARM and raw probes; 9444 served all four faces including ARM.
