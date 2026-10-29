# TLS13 — AR-SEC-01 unpin trial (private boot, no lib change)

Context: solo

**Standing:** PARTIAL_ALIVE (all wire legs PASS; flip not landed — config-flag preferred, residual typed below)

Lane: TLS13 writer, 2026-10-21, repo /Users/sac/smalt, build root `_build-tls13`

## Subject

- `lib/smalt/tls.ex:161-171` — R90/D52 pin (`versions: [:"tlsv1.2"]` + 2-cipher
  pin), hardcoded in `bandit_opts/2`, no config seam. NOT edited by this lane.
- Trial surface: private Bandit HTTPS listener (port 39930) over the SAME plug
  (`Smalt.EgressRouter`), cert from `Smalt.TLS.ensure_dev_cert(39930)` (dev cert
  CA:TRUE self-anchored), opts `versions: [:"tlsv1.3", :"tlsv1.2"]` (default
  ciphers), h2 reset-rate parity with shipped (`{50_000, 10_000}`).
- Private substrate: MIX_ENV=test, anon auth, ports 39920..39925 internal
  (plaintext `:tls => false` because shipped `bandit_opts` pins 1.2-only — no
  seam), trial listener 39930. Boot: `tmp/tls13_boot.exs`. The 39900 block was
  held by another live substrate (not evicted); 39920 block pre-flighted free.
- Note: working tree carries another lane's in-flight AR-SEC-02 diff on
  `lib/smalt/tls.ex` (dual-cert plane). My trial did not call `bandit_opts/2`
  (own opts), so that in-flight edit is not exercised by this receipt.

## Wire outputs

Control (non-vacuity) — raw `:ssl.listen(39931)` with the exact shipped pin,
same host/OTP 28.3.1/OpenSSL 4.0.3:

```
== tls1_3 vs SHIPPED pin ==
tlsv1 alert protocol version:ssl/record/rec_layer_s3.c:923:SSL alert number 70
New, (NONE), Cipher is (NONE)
== tls1_2 vs SHIPPED pin ==
New, (NONE), Cipher is (NONE)   # harness limitation: control listener did a
                                # single accept; leg-3 below covers 1.2 on the trial
```

Leg 1 — real node SDK (@azure/storage-blob from verification/ts), NODE_EXTRA_CA_CERTS:

```
NEGOTIATED_PROTOCOL TLSv1.3
BLOB_PUT_GET roundtrip=OK bytes=8192
BLOB_PROPS contentLength=8192 etag="ef7754c9d43d340a1eb9146fd5b906be"
exit=0
```

Leg 2 — openssl s_client -tls1_3 vs trial listener:

```
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Protocol: TLSv1.3
Verify return code: 0 (ok)
```

Leg 3 — backward compat, openssl s_client -tls1_2 vs same trial listener:

```
New, TLSv1.2, Cipher is ECDHE-RSA-AES256-GCM-SHA256... [ECDHE-RSA-AES256-GCM-SHA384]
Protocol: TLSv1.2
Verify return code: 0 (ok)
```

Leg 4 — R90/D52 shape re-probe (Go-client X25519MLKEM768 key share), same listener:

```
-groups X25519MLKEM768            -> Protocol: TLSv1.3, Verify return code: 0 (ok)
-groups X25519MLKEM768:X25519:secp256r1 -> Protocol: TLS1.3, Verify return code: 0 (ok)
```

## Falsifier results

- The R90/D52 failure shape (client offering X25519MLKEM768 key shares) does
  NOT reproduce on OTP 28.3.1 with 1.3 enabled: the listener accepts the
  MLKEM key share (it is in OTP 28's supported_groups; AR-SEC-01 receipt's own
  measurement) or falls back via HelloRetryRequest. AR-SEC-01's residual
  concern ("OTP 28 rejects MLKEM key shares killing the handshake") is
  measured FALSE on this host toolchain when 1.3 is enabled.
- The pin's protective value is non-vacuous (control alert 70 reproduced).

## Verdict

Unpinning is SAFE on this host/OTP with a BOTH-versions config
(`[:"tlsv1.3", :"tlsv1.2"]`, default ciphers). Recommended landing shape:
config flag (`config :smalt, :tls_versions`), default the CURRENT pin — flip
is opt-in. Do not flip default without a Go-client leg (azidentity/azurerm
binary or Go test client) re-run, which this lane lacked (no Go toolchain
probed; leg 4 used openssl MLKEM-shape simulation, not a real Go client).

## Residual (typed)

1. R90/D52 Go-client claim REFUTED-as-reproduced on openssl-shape, UNTESTED
   with a real Go client — the original failure was never captured as a
   repro artifact (r90-r100-tls-pin.md and r174 are test-suite counts only;
   no Go wire capture exists in docs/). A real Go handshake (azidentity) must
   pass before default-flip.
2. Cipher surface widens from 2 pinned ECDHE-RSA-AES-GCM suites to OTP
   defaults (TLS 1.3 suites + 1.2 defaults). If the 2-cipher pin itself (not
   the version pin) was load-bearing for some client, that leg is untested.
3. h2 over TLS 1.3 rides the same max_reset_stream_rate parity (KD-157) —
   no separate court run on the 1.3 listener.
4. Trial boot pattern (plaintext internals + extra https listener) is a lane
   artifact, not a landing; landing requires the config-flag diff in
   `bandit_opts/2` — which is currently contended by the AR-SEC-02 lane.

Artifacts: `tmp/tls13_boot.exs`, `tmp/tls13_blob_probe.mjs`,
`tmp/tls13-substrate.log`, `tmp/dev-certs/dev-cert-39930.pem`. Substrate torn
down (ports 39920..39931 verified freed post-run).
