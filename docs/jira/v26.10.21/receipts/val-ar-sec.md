# VAL: AR-SEC-01..03 validator receipt

**Standing:** **PARTIAL / PARTIAL / UNSUPPORTED (N/A per airgap)**

Context: solo. Machine: Apple M3 Max, 16 cores, OTP 28.3, Elixir 1.19.5,
Darwin 26.2. Substrate UP (pid 8877), `bash scripts/substrate.sh status` exit 0
on 9443/9444/5672/5673.

## Verdict table

| Cell | Spec (ARD-PRD 2.4) | Verdict | Measured evidence |
|---|---|---|---|
| AR-SEC-01 | PQ hybrid `x25519mlkem768` default on TLS listener plane | **PARTIAL** — supported-not-negotiated on host toolchain | OTP 28 ssl `supported_groups` on a live `ssl:listen` **does contain** `x25519mlkem768` (plus mlkem512/768/1024, secp*mlkem* hybrids) but it is not first-preferred, and the smalt listener pins `versions: [:"tlsv1.2"]` + 2-cipher pin (`lib/smalt/tls.ex:164-171`) — so TLS 1.3 (and any PQ group) is structurally out of the negotiation. Measured: `openssl s_client -connect localhost:9444 -tls1_3` (both OpenSSL 4.0.3 and 3.6.4) → `tlsv1 alert protocol version` (alert 70), `New, (NONE), Cipher is (NONE)`; default handshake → **TLSv1.2 / ECDHE-RSA-AES256-GCM-SHA384**. ALIVE requires OTP 29 listeners; note the 2-cipher pin is itself the R90/D52 Go-client workaround for the very rejection OTP 28 does to X25519MLKEM768 key shares, so "just flip versions" is not a one-line move. |
| AR-SEC-02 | `{certs_keys, ...}` dual RSA+ECDSA on one socket | **PARTIAL** — option exists on host ssl, single-cert configured | Direct `ssl:listen` probe on host OTP 28 accepts and echoes back `certs_keys => [#{certfile => ..., keyfile => ...}]` in the listener config (probe module compiled+run in-session); option supported. Actual listener (`lib/smalt/tls.ex:175-176`) binds exactly one `certfile`/`keyfile` pair, and the only cert on disk is RSA-only (`.smalt/tls/dev-cert.pem`: `Public Key Algorithm: rsaEncryption`, `sha256WithRSAEncryption`). No ECDSA pair exists to dual-bind. ALIVE requires generating an ECDSA leaf + wiring both into `certs_keys`. |
| AR-SEC-03 | CRL `allowed_hosts` SSRF restriction | **UNSUPPORTED / N/A** — no outbound CRL path exists | `grep -rn -i "crl" lib/smalt --include="*.ex"`: zero CRL-fetching code; the listener config probe above shows `crl_check => false` in the ssl config. The substrate is airgapped by construction — standing witness `tmp/bench/scvd-airgap.jsonl` (lane `scvd-airgap` rows, errors 0, all surfaces loopback-bound). The attack surface named by the spec (outbound CRL HTTP fetch) does not exist to restrict; `allowed_hosts` has nothing to attach to. Falsifier: any single non-loopback outbound connection from the substrate would flip this; none exists. |

## Method

- Live listener probes with `openssl s_client` (system 4.0.3 and
  /opt/homebrew 3.6.4) against the running :9444 twin, per-group
  (`X25519MLKEM768`, `x25519`, `P-256`) and default, stdout/stderr separated.
- Host ssl capability probe: `ssl:listen/2` on OTP 28 + inspection of the
  returned `config` map (`supported_groups`, `certs_keys`, `crl_check`,
  `ciphers`), compiled probe module in-session.
- Static: `lib/smalt/tls.ex` (tls_pin block), cert on disk inspected with
  `openssl x509 -text`.

## ALIVE conditions

1. AR-SEC-01: listeners on OTP 29 ssl, `versions` pin lifted to `[:tlsv1.3,
   :"tlsv1.2"]`, and a client handshake negotiating `x25519mlkem768` witnessed
   via socket property inspection.
2. AR-SEC-02: ECDSA P-256 leaf minted (`.smalt/tls/`), both pairs wired through
   `certs_keys` in `lib/smalt/tls.ex`, and an ECDSA cipher observed in a real
   handshake.
3. AR-SEC-03: stays N/A while the airgap holds; revisit only if an outbound
   egress path lands — then `allowed_hosts` becomes mandatory, not optional.
