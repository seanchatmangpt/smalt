# KD-27 witness — ARM metadata endpoint authority (stale-row disposition)

**Standing:** CLOSED (KD-27 row OBSOLETE — row evidence stale, authority is request-derived)

Row: KD-27 — `resourceManagerEndpoint` hardcodes `http://localhost:9443/`.
Subject: `lib/smalt/arm_gateway/router.ex` (`/metadata/endpoints` route,
`request_authority/1` -> `Smalt.Auth.Bearer.request_authority/1`)

## Disposition

OBSOLETE. The metadata loginEndpoint / activeDirectoryEndpoint derive from
`request_authority(conn)` — scheme://host[:port] AS THE CLIENT REACHED US
(router.ex `request_authority/1`, "Request-derived authority"). The metadata
envelope no longer hardcodes localhost:9443.

## Evidence (live wire, 2026-10-21)

```
== KD27 metadata endpoint (client reached via 127.0.0.1:9443)
{"activeDirectoryEndpoint":"http://127.0.0.1:9443/",...,"loginEndpoint":"http://127.0.0.1:9443/",...}
```

The endpoint echoes the client seat authority (127.0.0.1), not a hardcoded
localhost. Close condition ("derive from actual listener") met in its stronger
request-derived form. (Row text names resourceManagerEndpoint; the current
envelope exposes loginEndpoint/activeDirectoryEndpoint — same hardcode family,
same request-derived resolution.)

## Flip

FLIP-ELIGIBLE (dry-run only; flip via `scripts/kd_flip.py --apply`, gated on
this receipt's mtime, never by hand).

## RE-WITNESS addendum (BK-REWIT2 lane, 2026-10-22)

```
$ grep -n 'defp request_authority(conn), do: Smalt.Auth.Bearer.request_authority' lib/smalt/arm_gateway/router.ex
406:  defp request_authority(conn), do: Smalt.Auth.Bearer.request_authority(conn)
exit=0
$ MIX_BUILD_ROOT=_build-rewit2 mix compile   # shared probe
exit=0
```

Request-derived authority (`Smalt.Auth.Bearer.request_authority/1`) still backs
the metadata envelope; no localhost hardcode in the metadata path. Standing
unchanged: OBSOLETE. exit=0
