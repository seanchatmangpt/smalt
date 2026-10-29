# EXPL12-F: final auth-uniformity verify — all 7 command groups KD-15-typed

Standing: ALIVE · Context: solo · 2026-10-22 · Lane EXPL12-F (read-only verify;
only this receipt written)

Subject: `smalt-cli/smalt_cli/wire.py` +
`smalt-cli/smalt_cli/commands/{storage,cosmosdb,keyvault,servicebus,deployment,monitor,login}.py`
at working tree HEAD (post EXPL12-W repair, receipt
`expl12w-arm-handshake.md`, which closed EXPL12V-F1). No code edited by this
lane.

## Verdict

**UNIFORM — ALIVE.** All 7 command groups witnessed on the live :enforce
shared substrate (9444 TLS twin, `SSL_CERT_FILE=.smalt/tls/ca-cert.pem`,
SMALT_ARM/SMALT_EGRESS=https://127.0.0.1:9444, cold token cache per group,
fresh UNIQ entities `expl12f<tail>`) speaking the KD-15
tokenless→401→mint→bearer contract, or honestly typed N/A (login = the mint
face itself; the challenge is not applicable to the face that issues the
token).

## Contract table (fresh wire witnesses, leg traces over real httpx traffic;
leg = `METHOD auth path -> status`)

| group | command witnessed | leg trace | exit |
|---|---|---|---|
| storage | `storage container-create stgexpl12f77464` | `PUT tokenless /smaltacct/stg… -> 401 \| POST STS -> 200 \| PUT bearer -> 201` | 0 |
| cosmosdb | `cosmosdb database-create cosexpl12f77464` | `POST tokenless /dbs -> 401 \| POST STS -> 200 \| POST bearer -> 201` | 0 |
| keyvault | `keyvault secret-set kvexpl12f77464 v1` | `PUT tokenless /secrets/kv… -> 401 \| POST STS -> 200 \| PUT bearer -> 201` | 0 |
| servicebus | `servicebus queue-create --name q… --namespace-name ns…` | ns PUT: `tokenless->401 \| STS 200 \| bearer 202`; queue PUT: `tokenless->401 \| bearer 201` (STS cached) | 0 |
| deployment | `deployment group-create rgexpl12f77464` | `PUT tokenless …/resourceGroups/rg… -> 401 \| POST STS -> 200 \| PUT bearer -> 201` | 0 |
| monitor | `monitor metrics rg… Microsoft.Storage storageAccounts acc…` | `GET tokenless …/microsoft.insights/metrics -> 401 \| POST STS -> 200 \| GET bearer -> 500` → typed ANDON exit 1 (pre-existing BK-MON-2 substrate defect, honestly refused, never silent) | 1 (typed ANDON) |
| login | `login -o json` | `POST /oauth2/v2.0/token -> 200` — the mint face itself; KD-15 handshake **N/A-typed** (no data-plane call; the challenge is answered WITH a token this face issues) | 0, `verified: true` |

monitor legs prove the handshake fires; the final 500 is the known substrate
defect (BK-MON-2, receipt `bkmon2-metrics-repair.md` in this directory), not
an auth-contract issue.

## Zero silent degradations (grep receipts, wire.py)

```
$ grep -n "return {}\|degrade\|tokenless fallback" smalt-cli/smalt_cli/wire.py
77:# enforce accepts the emulator-issued HS256/RS256 token). Failure degrades to
93:    (loud, full exit 1) — never a silent degrade-to-tokenless (EXPL12V-F1)."""
284:    arm_request docstring mentions the old bearer_for_arm() degrade (deleted)
```

(Adjusted for line wrap: the only hits are a STALE docstring/comment at
wire.py:77 and historical mentions in the arm_request docstring — no
executable `return {}` degrade exists anywhere. The old
`bearer_for_arm() -> return {}` silent-degrade body is GONE; `bearer_for_arm`
now andons on STS failure (wire.py:112-113). `bearer_for_arm`'s sole caller
is `storage._blob_request` (grep: 1 call site), loud via the same ANDON path.

Typed-ANDON exception handlers in wire.py, both loud:

```
112:    except Exception as exc:
113:        andon(f"ARM bearer mint failed: STS unreachable or refused ({exc})")
```

`_sts_token()` (kv/cosmos path) still returns `""` on mint failure — not a
silent degrade: with no token the bearer retry is skipped and the 401
surfaces through `wire.expect` as a typed ANDON downstream (failure stays
loud, point moves later). Noted, not a defect.

## ty suites (fresh, SMALT_CLI_LANE=expl12f, .venv-cli, tests/ dir)

```
enforce session:   35 passed, 2 skipped, 114 deselected in 67.49s
anonymous session: 37 passed, 114 deselected in 24.91s
```

Includes the EXPL12-W handshake courts (`tests/test_ty_arm_handshake.py`) plus
the pre-existing storage/cosmos/kv/servicebus/deployment/monitor/login
suites.

## Honest notes

- A probe instrumentation quirk: STS `httpx.post` legs print twice (wrapper
  records via `r.request` and appends a manual line) — one mint, two log
  lines. Wire traffic is real and single.
- wire.py:77 stale comment ("Failure degrades to tokenless") contradicts the
  code (andon) — doc drift only, out of a read-only lane's scope. Owner:
  EXPL12-R lineage or next wire.py-touching lane.
- Duplicated line in `bearer_for_arm` (`_token_cache[arm] = ...` twice,
  wire.py:114-115) — harmless idempotent duplicate, cosmetic.
- servicebus `queue-create` does two ARM PUTs (namespace + queue); the queue
  PUT re-challenges tokenless-first because `arm_request` is tokenless-first
  per call even with a cached token — contract-correct, slightly chatty. Not
  a defect.
- servicebus data face (send/receive, AMQP 5672) rides SAS
  (`scripts/dev_env.sh` per-host SAS), outside the HTTP auth-contract surface
  — N/A-typed by transport, same as EXPL12-V recorded.
- monitor metrics final 500 = BK-MON-2 (substrate-side), tracked in
  `docs/jira/v26.10.22/receipts/bkmon2-metrics-repair.md`.
- Read-only lane: only this receipt file written; probe script lived in
  /tmp (scratch, not indexed).
