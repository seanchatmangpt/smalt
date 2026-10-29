# Receipt: BK-CERTSAN — gen_dev_cert.sh SAN variant (BK-TOPO successor order)

Standing: ALIVE · Context: solo · 2026-10-22

## Change

`SMALT_CERT_SAN_HOSTS` (comma-separated) on `scripts/gen_dev_cert.sh` and the
`Dockerfile.smalt` entrypoint mint: each host becomes an extra
`subjectAltName=DNS:<host>` entry alongside the existing
`DNS:localhost,IP:127.0.0.1,DNS:management.azure.com,DNS:login.microsoftonline.com`
SAN line (CN stays `/CN=localhost`). Unset → the SAN line is textually
identical to pre-BK-CERTSAN (byte-identical behavior, witnessed leg 3).
Whitespace tokens stripped; empty tokens skipped.

The k8s face: `k8s/smalt-backend.yaml` sets
`SMALT_CERT_SAN_HOSTS=smalt-backend-0.smalt-backend-headless.default.svc.cluster.local,smalt-backend-1.smalt-backend-headless.default.svc.cluster.local`
so the entrypoint-minted shared leaf validates from in-cluster clients hitting
the 9444 TLS twin by headless pod hostname.

## Court (Chicago, no mocks — real openssl mint + verify + s_client)

- Leg 1 — with SANs: mint with both headless FQDNs; `-verify_hostname` green
  for each:

  ```
  $ openssl verify -CAfile san/ca-cert.pem -verify_hostname smalt-backend-0.smalt-backend-headless.default.svc.cluster.local san/dev-cert.pem
  san/dev-cert.pem: OK
  $ openssl x509 -in san/dev-cert.pem -noout -ext subjectAltName
  X509v3 Subject Alternative Name:
      DNS:localhost, IP Address:127.0.0.1, DNS:management.azure.com, DNS:login.microsoftonline.com, DNS:smalt-backend-0.smalt-backend-headless.default.svc.cluster.local, DNS:smalt-backend-1.smalt-backend-headless.default.svc.cluster.local
  ```

  (both pod FQDNs verify OK; `localhost` control also OK)
- Leg 2 — non-vacuity: the no-SAN cert FAILS the pod-hostname check:

  ```
  $ openssl verify -CAfile base/ca-cert.pem -verify_hostname smalt-backend-0.smalt-backend-headless.default.svc.cluster.local base/dev-cert.pem
  CN=localhost
  error 62 at 0 depth lookup: hostname mismatch
  error base/dev-cert.pem: verification failed   (exit 2)
  $ openssl verify -CAfile base/ca-cert.pem -verify_hostname localhost base/dev-cert.pem
  base/dev-cert.pem: OK                          (control exit 0)
  ```
- Leg 3 — unset = byte-identical: SAN ext text of a no-env mint under the new
  script is byte-identical to a mint under `git show HEAD:scripts/gen_dev_cert.sh`
  (`diff` empty → `BYTE_IDENTICAL_SAN`); full `-text` diffs differ only in
  key/serial randomness, as expected.
- Leg 4 — in-cluster client face: real `openssl s_server` (serving the
  SAN'd leaf) + `s_client -verify_hostname
  smalt-backend-1.smalt-backend-headless.default.svc.cluster.local`:

  ```
  Verify return code: 0 (ok)
  ```

  and the no-SAN leaf served under the same check fails (`exit 1`).

## Disclosure

Coordinator checkpoint 51d591c7 absorbed the in-flight `scripts/gen_dev_cert.sh`
+ `Dockerfile.smalt` diffs mid-lane (working tree byte-identical to HEAD at
commit time); this commit carries the receipt + the `k8s/smalt-backend.yaml`
env edit. Same absorption pattern as the BK-DLQ3 receipt.

## Falsifier status

A cert without the pod SAN fails `verify_hostname` (leg 2) — the check is not
vacuous; the SAN variant is what flips it green (leg 1/4). ALIVE.
