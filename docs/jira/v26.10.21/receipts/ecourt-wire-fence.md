# ECOURT wire fence — ECOURT-F finisher receipt

**Standing: PASS (all four legs) with loud SKIP on `apim:429-401-gateway` (route family default-off — 429/401 sub-leg not wire-witnessable on this substrate boot)**

- Court: `/Users/sac/smalt/test/courts/court_wire.erl` (pure Erlang, raw `:gen_tcp`/`:ssl`, bit syntax; zero Elixir helpers)
- Runner: `/Users/sac/smalt/scripts/courts/court_wire.sh`
- Substrate: live boot (pid 85369, ports 5672/9443/9444/8443/5673 all LISTENING) — court preflight refuses to boot/restart anything; loud SKIP exit 3 otherwise
- Toolchain: stock OTP runtime (erlc + `erl -noshell`, OTP 28 machine report, erlang 29.1.2 asdf toolchain in `.tool-versions`); `MIX_BUILD_ROOT=_build-ecourt`
- Machine (from `just bench-machine`): `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
- Context: pair

## Verdict (final run, exit 0; two consecutive green runs)

```
=== ECOURT WIRE FENCE VERDICT ===
  [PASS] amqp:sasl+cbs+queue
  [PASS] cosmos:sts+rest
  [PASS] blob:xml-face
  [PASS] apim:typed-404
  [SKIP] apim:429-401-gateway
ECOURT: PASS WITH LOUD SKIP
```

Per-leg:

| Leg | Verdict | Evidence |
|---|---|---|
| 1 AMQP 5672 (SASL ANONYMOUS + CBS put-token + queue attach/transfer/disposition) | PASS | `sasl-outcome 0x44 code 0`; both put-tokens `status-code 200`; disposition `0x15` with `accepted` (0x24) state |
| 2 Cosmos raw TLS 9444 (STS form POST + db/coll/doc create + read + 404) | PASS | STS token 1283 bytes; id/_etag binary-matched create-vs-read; missing-doc typed 404 |
| 3 Blob raw TLS 9444 (container 201, PUT/GET byte-exact, DELETE 202, 404 envelope) | PASS | `x-ms-error-code: BlobNotFound` header + `<Error><Code>BlobNotFound</Code>` XML bytes |
| 4 APIM plane (typed refusals) | PASS + SKIP | typed 404 `RouteNotFound` envelope byte-matched; 429/401 gateway sub-leg SKIP (default-off) |

## Fixes (all court-owned; zero lib/ edits)

1. **Compound `size` INCLUDES the count field** (the prior lane's finding, verified byte-proven against the substrate's own `C0 0F` mechanisms frame): both compound encoders (`desc/2`, `enc_map/1`) now emit `Sz = 4 + iolist_size(...)`.
2. **`desc_val/2` added** — `desc/2` wraps fields in a list32; passing it `enc_map`/`enc_str` output wrapped the app-properties/amqp-value VALUE in a bogus list32 (dumped bytes showed count=2 garbage). CBS message sections and the queue transfer body now emit the raw described value directly.
3. **Symbol keys, string VALUES** in application-properties: the substrate's `normalize_keys` converts symbol KEYS only; a symbol VALUE decodes as `{:symbol, _}` and fails the plain-binary `check_operation/2` compare → typed 400.
4. **SAS token parity**: string-to-sign is `"<sr>\n<se>"` (was sr-only); HMAC key is the base64 TEXT (`shared_key/0` returns the string, not decoded bytes); `sig` percent-encoded (raw base64 `+` is `URI.decode`d to a space server-side).
5. **Live-substrate key resolution in the runner**: a boot with an explicit `SMALT_SB_SHARED_KEY` override is authoritative — the runner reads the literal `Application.put_env(:smalt, :sb_shared_key, ...)` from the beam boot args (`ps eww`), falling back to the substrate.sh FQDN derivation. A per-host short-name (`inet:gethostname` = `Mac` vs `hostname` = `Mac.lan`) derivation mismatch produced honest 401s that were court-config errors, not fence violations.
6. **Disposition descriptor is 0x15, not 0x16** (0x16 = detach). The pre-fix court was mislabeling the server's `detach`-with-`amqp:unauthorized-access` as a disposition. `recv_disposition` now treats detach as a loud fence violation.
7. **Queue-scoped put-token**: entity attach authorization keys claims on `endpoint <> "/" <> entity`; a namespace-only claim is refused with `UNAUTHORIZED_ENTITY`. The court mints a second queue-scoped token before the queue attach.
8. Queue transfer sent **unsettled** (server settles with `disposition accepted`); status-200 acceptor takes uint/smalluint/ubyte forms; cosmos creates assert **201**; blob PUT/DELETE no longer assume empty bodies; unique-per-run cosmos collection name (409 on reuse); `http/5` flattens iolist bodies/needles (byte_size-on-iolist badarg).

## Typed findings (lib/ — NOT fixed here, registered for owners)

- **AMQP listener degrades under concurrent lane load**: repeated raw-socket probes saw `closed`/`timeout` before the server-mechanisms frame while other lanes were hammering the plane (popcorn traffic visible in `substrate.log`). Connection-level, intermittent (~50%), self-recovers. Worth a KD row / soak probe.
- **Entity attach refuses namespace-scoped CBS claims** (fix 7's server side): real SDKs mint per-entity tokens, so parity is likely fine — but the refusal surfaces as `detach 0x16 unauthorized-access`, which no test asserted until this court; recommend the e2e tier pin it.

## Commands

```bash
bash scripts/courts/court_wire.sh   # exit 0 (twice consecutively)
```

Runner compile warnings are residual (unused `recv_frame/1`, unused `Sock` in `recv_exact/3` base clause) — cosmetic, left as-is to keep the diff court-owned and minimal.

Receipt chain: pre-fix failure receipts from the killed prior lane are on the v26.10.21 ledger; this receipt supersedes them for the four legs above.
