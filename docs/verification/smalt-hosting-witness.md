# smalt-hosting-witness

Standing: BLOCKED

Date: 2026-11-14 (UTC). Ticket: docs/jira/v26.11.14/smalt-04.md.

## Observed

```text
$ dig +short smalt.fnox.io
136.81.33.94
$ dig +short NS fnox.io
ns-cloud-e1.googledomains.com. (e1..e4)
$ curl -sS -m 10 -o /dev/null -w "%{http_code}\n" https://smalt.fnox.io/health
curl: (35) LibreSSL SSL_connect: SSL_ERROR_SYSCALL in connection to smalt.fnox.io:443
000   (exit 35)
$ dig +short nonexistent-smalt-zz.fnox.io
(empty)
```

## Standing

BLOCKED: DNS A record answers, but /health returns no HTTP 200 (TLS connect fails; exit 35).
Registration status (ACTIVE vs REGISTRATION_PENDING) not observed this session: gcloud not run
by this lane. Probe target: `lib/smalt/health_plug.ex`.

## Witness probe (PASS only when both hold; otherwise exit non-zero, no PASS written)

```sh
H=${1:-smalt.fnox.io}
ip=$(dig +short "$H" A | head -1); [ -n "$ip" ] || { echo "BLOCKED: no A record for $H"; exit 1; }
curl -fsS -m 10 "https://$H/health" >/dev/null || { echo "BLOCKED: /health not 200"; exit 1; }
echo "PASS $H $ip $(date -u +%F)"
```

Falsifier: `H=nonexistent-smalt-zz.fnox.io` yields empty dig, prints BLOCKED, exit 1, no PASS.

## See Also

`/Users/sac/fnox/docs/setup/fnox-io-domain.md`, `docs/DEV_ENV.md`
