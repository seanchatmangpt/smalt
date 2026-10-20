# kd108-blob-lease-acl-tbd.md — KD-108 witness (witness lane, 2026-10-19)

- **KD row**: KD-108 (blob container lease/ACL absent)
- **Standing**: PASS-EVIDENCED (wire-tier witness executed 2026-10-19, transcript below; register row flip is registrar's call via kd_flip.py)
- **Context**: solo (witness lane, block b5, auth=enforce)

## What would witness / Falsifier

acquire/renew/release container lease over the raw wire + container ACL
(setAccessPolicy/getAccessPolicy) roundtrip with signed identifiers; 6-id ACL PUT
refused 400.

## Execution-2026-10-20 (executed 2026-10-19 20:0x local, block b5)

Substrate: `scripts/substrate-ctl up --block b5 --auth enforce` → exit 0, ports
amqp=39050 eh=39051 arm=39052 egress=39053 tls=39054 mcp=39055,
`substrate-ctl verify --block b5` → exit 0. Bearer minted from the emulator STS:

```
$ curl -s -X POST "http://localhost:39052/contoso/oauth2/v2.0/token" \
    -d 'grant_type=client_credentials&client_id=x&client_secret=y&scope=https://storage.azure.com/.default'
{"access_token":"eyJ... (1275 chars)","...":...}   # HTTP 200, token 1275 chars
```

Blob target: plaintext egress port 39053, blob catch-all `/{account}/{container}`.

### Lease legs (container kd108cont2)

```
=== create container ===
PUT /kd108acct/kd108cont2?restype=container
HTTP 201

=== acquire lease ===
PUT ?comp=lease, x-ms-lease-action: acquire, x-ms-lease-duration: 60,
x-ms-proposed-lease-id: aaaaaaaabbbbbbbbccccccccdddddddd
HTTP 201
x-ms-lease-id: c0f66817-fff1-4127-84ae-3edf2e371fb6

=== second acquire (expect 409 LeaseAlreadyPresent) ===
HTTP 409
{"error":{"code":"LeaseAlreadyPresent","message":"There is already a lease present on the container."}}

=== renew (x-ms-lease-action: renew, x-ms-lease-id: c0f66817-…) ===
HTTP 200

=== break (x-ms-lease-action: break) ===
HTTP 202
x-ms-lease-time: 0

=== release ===
HTTP 200

=== re-acquire after release (duration -1, infinite) ===
HTTP 201
=== release (infinite lease) ===
HTTP 200
```

### ACL legs

```
=== ACL PUT (setAccessPolicy shape, 2 signed identifiers, perms rwdl + r) ===
HTTP 204
=== ACL GET roundtrip ===
HTTP 200
<?xml version="1.0" encoding="utf-8"?><SignedIdentifiers><SignedIdentifier><Id>mtA1d9j3Yk9</Id><AccessPolicy><Start>2026-10-19T00:00:00Z</Start><Expiry>2027-10-19T00:00:00Z</Expiry><Permission>rwdl</Permission></AccessPolicy></SignedIdentifier><SignedIdentifier><Id>sId-000000002</Id><AccessPolicy><Permission>r</Permission></AccessPolicy></SignedIdentifier></SignedIdentifiers>

=== ACL PUT 6 signed identifiers (expect 400) ===
HTTP 400
{"error":{"code":"InvalidArgument","message":"Too many signed identifiers (max 5 per container)."}}
```

The GET read-back byte-matches the PUT (both identifiers, start/expiry/permission).

### Honest divergences witnessed (not close blockers, for the register)

1. **`x-ms-proposed-lease-id` is not honored** — acquire 201 minted a fresh UUID
   (`c0f66817-…`) despite a proposed id being sent. First probe run failed
   renew/break/release with `LeaseIdMismatchWithLeaseOperation` 409 because the
   caller kept using its proposed id. Real Azure returns the proposed id verbatim.
   Probe: `/tmp/kd108_transcript.txt`, `/tmp/kd108_hdr.txt`.
2. **ACL permission-letter set is narrower than real Azure container ACLs** —
   `racwdl` refused `InvalidXmlDocument` 400 ("allowed: r, p, w, d, l"); real
   Azure container permissions are r/a/c/w/d/l. Transcripts embedded above.
3. **Container DELETE while lease released returned 409 ContainerLocked**
   (WORM policy refusal) — not exercised further; separate surface.

## Close condition status

Close condition (BlobLeaseClient acquire/renew/release + ACL roundtrip passes)
is MET at the wire tier: all legs 2xx/typed-4xx as specified, ACL read-back
matches. Registrar may flip KD-108 via `scripts/kd_flip.py --apply` gated on
this receipt (mtime > shim mtime).

Context: solo (witness lane, block b5, auth=enforce)
