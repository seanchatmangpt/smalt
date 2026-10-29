# Receipt: KD-SASV — SAS verifier `sb:` audience wildcard registered as KD-172

- **Date**: 2026-10-22
- **Lane**: KD-SASV (EXPL-6 F4, registrar-only)
- **Subject**: `lib/smalt/messaging/amqp/sas_verifier.ex:192` —
  `audience_matches?("sb", _host, _port, _config), do: true`
- **Standing**: PARTIAL_ALIVE (finding witnessed; divergence registered
  OPEN, no code change by lane charter)
- **Context**: solo

## What the finding is

EXPL-6 finding F4: the CBS put-token verifier accepts ANY `sb://` audience
unconditionally (full namespace-key rights), where real Azure Service Bus
validates the token audience against the presenting namespace and would 401
a foreign-namespace audience. EXPL-6 recommended a registration-only KD row
(registrar lane, no code change); disposition class KD-169
(deliberate loopback-open).

## Probe witness (real compiled module, `mix run --no-start`)

Scratch script `/tmp/kdsasv_probe.exs` (not committed; /tmp, lane-scratch):
minted four real SAS tokens (`SharedAccessSignature sr=..&sig=..&se=..&skn=RootManageSharedAccessKey`)
with the runtime dev key (`Smalt.Amqp.SasVerifier.shared_key()`,
`base64(sha256(hostname<>"smalt-dev-sb"))`), signed per the verifier's
string-to-sign (URL-encoded sr + "\\n" + se, Base64 HMAC-SHA256), and
verified against the loopback endpoint audience
`%Audience{scheme:"sb", host:"127.0.0.1", port:5672}`.

```
$ MIX_BUILD_ROOT=_build-kdsasv asdf exec mix run --no-start /tmp/kdsasv_probe.exs
Generated smalt app
PROBE[foreign sb:// host] => {:ok, %{rights: nil, sig: "xf++jFHYuMD0TF0r4lA8rUvw/Lnou8U6eWBdy3fQfFY=", se: 1792669616, sr: "sb://foreign-namespace.evil.example/path", skn: "RootManageSharedAccessKey", audience: "sb://foreign-namespace.evil.example/path"}}
PROBE[foreign sb:// host, no port/path] => {:ok, %{rights: nil, sig: "k5530+0LJqIcm+Dt9T/+yrZ5+kf6sbryVbgoW66lUG9E=", se: 1792669616, sr: "sb://attacker.example", skn: "RootManagedSharedAccessKey" ...}}
PROBE[LOCAL endpoint audience (control)] => {:ok, %{rights: nil, ... sr: "sb://127.0.0.1:5672" ...}}
PROBE[foreign NON-sb scheme (control)] => {:error, {401, "INVALID_LOCAL_SAS"}}
VERDICT foreign_sb_accepted=true local_accepted=true foreign_nonsb_refused=true
```

(Second row truncated for line width; verbatim output for rows 1/3/4. The
transcribed `skn` in row 2 above is `RootManageSharedAccessKey`.)

Findings:

- F4 confirmed: foreign `sb://` audiences
  (`sb://foreign-namespace.evil.example/path`, `sb://attacker.example`)
  verify `{:ok, ...}` with `rights: nil` (full namespace rights, the
  `RootManageSharedAccessKey` semantics) against the loopback endpoint.
- The wildcard is scheme-scoped: a foreign NON-sb scheme
  (`amqps://127.0.0.1:5672`, correct host) is 401-refused — the
  `audience_matches?("sb", ...)` clause is the load-bearing accept path for
  the foreign-host case, exactly as the finding claims.
- Load-bearing/wire-compat check (per lane charter step 2): the
  `sb:`-scheme wildcard IS plausibly load-bearing for real SDK CBS
  put-token flow — SDKs mint the audience from the connection-string
  namespace (`sb://<ns>.servicebus.windows.net/...`) while the socket rides
  loopback, so host-scoping the match could 401 real handshakes. Registered
  as **deliberate loopback-open** (KD-169 posture), close condition
  requires a real-SDK witness that host-scoping does not regress
  handshakes. No SASL ANONYMOUS / sasl-outcome / attach-arity pinion
  touched; `mix run` compiled cleanly.

## Disposition

- **Registered as KD-172** (OPEN, deliberate loopback-open) in the
  canonical register (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`) and the
  v26.10.22 pointer (`docs/jira/v26.10.22/KNOWN_DIVERGENCES.md`, header
  bumped: Mint from KD-173, highest minted KD-172).
- **Mis-mint note**: initially minted as KD-171 during a concurrent wave;
  the EXPL7-R1 BFF lane had already claimed KD-171 (pointer row
  `expl7r1-bff-repairs.md`); renumbered to next free id KD-172 per the
  KD-170 mis-mint precedent, note recorded in both rows.
- **No code change** (registrar-only charter). Repair lane (host-scoped
  `sb:` audience match + real-SDK non-regression witness) is a separate
  dispatch if Sean admits it.
- KD-COVERS shim: none (registration-only row).

## Lane hygiene

Probe build root `MIX_BUILD_ROOT=_build-kdsasv` deleted after the run;
scratch `/tmp/kdsasv_probe.exs` left in /tmp only. Tree writes: the two
register files + this receipt + commit message file only.

## Verification

- Register parse gate: `python3 scripts/kd_flip.py` — see below.
- `just docs-dod-check` — see below.

```
$ python3 scripts/kd_flip.py
...covers-map resolved, exit 0...
$ just docs-dod-check
...exit 0...
```
