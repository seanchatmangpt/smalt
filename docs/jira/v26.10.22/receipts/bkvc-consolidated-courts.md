# BK-VCOURTS — consolidated validation-board courts (v26.10.22)

**Standing: ALIVE** — named consolidated court `just bkvc-court` green ×2
(`Result: 7 passed`, exit 0); owned-tier adjacency 33/33 exit 0; three
VALIDATION.md §3 PENDING rows closed/re-typed. Context: solo

## What landed

- `justfile.d/51-bkvc.just` — `just bkvc-court`: one exit-1-on-any-fail run of
  `test/integration/ttv4_journal_boot_replay_court.exs` +
  `test/internal/bkvc_consolidated_court_test.exs`, `MIX_BUILD_ROOT=_build-bkvc`.
  Import line added to the root justfile per the same-checkout fan-out law.
- `test/internal/bkvc_consolidated_court_test.exs` — 3-leg consolidated court:
  - **COURT-ATOM-CLAMP leg (JA-R3 D1 law)**: warmup parse, then real
    `:erlang.system_info(:atom_count)` zero-delta across two parses of 20k
    distinct junk tokens; keyword parse returns `{:ok, _ast}` (the clamp did
    not break parsing); both junk verdicts typed.
  - **COURT-CERT-OBS accept face**: real minted CA (real RSA-2048
    self-signed X.509 from the real `Smalt.DataPlane.Certificates` data
    plane), PEM written to a real CA file, configured `require: true`,
    real `X-ARR-ClientCert` header → `{:ok, conn}`, thumbprint = SHA-1 of
    the header DER, CN asserted. No mocks, no sleeps.
  - **COURT-CERT-OBS missing-file face**: `:ca_certfile` pointing at a
    missing path → `Logger.error` "stat failed" diagnostic captured (the
    D2 law) AND typed `{:refuse, 403, "AuthenticationFailed",
    "ClientCertUntrustedRoot"}` twice (fail-closed state, not call count).

## Real defect found and fixed by the court

`lib/smalt/data_plane/certificates.ex` `mint_certificate/4` encoded
`{:"RSAPublicKey", e, n}` — **modulus and exponent swapped** (X.509
`RSAPublicKey ::= SEQUENCE { modulus, publicExponent }`). Every minted cert
carried a swapped key: OTP `:public_key.pkix_path_validation(der, [der], [])`
refused `{:error, {:bad_cert, :invalid_signature}}` — this is exactly the
chain-validation the x-arr plug performs. `openssl verify -CAfile cert cert`
prints OK because openssl does not check the self-signature of a trust
anchor — **the openssl face was vacuous for self-anchors**. Fix: `{n, e}`
with a comment naming the witness.

Second minimal repair (D2 module, disclosed): `x_arr_cert.ex` `subject_cn/1`
only matched binary CNs; OTP ASN.1 decodes `printableString` to a charlist,
so minted-cert subjects decoded to `nil` (identity.subject became `""` after
`to_string`). Added a charlist clause normalizing with `List.to_string/1`.

## Commands (real output)

```bash
export PATH="$HOME/.asdf/shims:$PATH"
just bkvc-court                      # runs both court files, exit 1 on any leg fail
```

Run 1 (seed 648985):

```
Running ExUnit with seed: 648985, max_cases: 32
Finished in 2.2 seconds (0.00s async, 2.2s sync)
Result: 7 passed
```

Run 2 (seed 933303):

```
Running ExUnit with seed: 933303, max_cases: 32
Finished in 2.1 seconds (0.00s async, 2.1s sync)
Result: 7 passed
```

Final receipt-capture run + owned-tier adjacency (exit 0):

```
Running ExUnit with seed: 962516, max_cases: 32
Finished in 2.2 seconds (0.00s async, 2.2s sync)
Result: 7 passed        # 4 TTV-4 boot-replay legs + 3 bkvc legs
Result: 33 passed       # cosmos_sql_raise + eh_throttle_wiring + kd104 witness + certificates_pending
```

Debug probe receipts (fixed immediately after each red run):
- missing-CA leg before any caching existed — red → green during authoring;
- `{e, n}` swap: `BKVC-DEBUG-pathval: {:error, {:bad_cert, :invalid_signature}}`
  on the pre-fix mint, `openssl verify -CAfile /tmp/bkvc4.pem /tmp/bkvc4.pem`
  → `/tmp/bkvc4.pem: OK` (vacuous face) — the contrast is the finding;
- charlist CN: `identity.subject == ""` (nil after to_string) → green after
  the charlist clause.

## Unbuild typing (COURT-SYNC-FASTFWD / COURT-SYNC-ANDON)

Capability grep, 2026-10-22, over `lib/ workspace/lib/ smalt-cli/`:

```
$ grep -rin "fast.forward\|fast_forward\|fastForward" lib workspace/lib smalt-cli | wc -l
0
$ grep -rin "join gate\|join_gate" lib workspace/lib smalt-cli | wc -l
0
```

FR-SNC-005 (fast-forward Merkle sync) and FR-SNC-006 (join gate ω) have zero
implementation: the courts are UNBUILT because the capabilities are UNBUILT —
no consolidation possible, no capability minted by this lane. Andon exists as
a courted pattern (`workspace/lib/engine/useAndon.tsx`; browser pattern-court
P2 legs in `workspace/scripts/pattern-court.mjs` — pull-cord / ack /
ALLOC_CAP_EXCEEDED) but the SYNC-specific legs do not exist. Owner: SYNC
follow-up WO per PRD §5. Falsifier: any real batch/frame path exercising a
fast-forward Merkle rebind, or a join-gate ω refusal raising andon.

## Court evidence (closed rows)

- **COURT-BOOT-REBIND** → ALIVE: leg 1 of `just bkvc-court` is the TTV-4
  court (4 legs: OFF-default byte-identical, real kill→supervisor
  restart→sealed-journal rebind with tombstone non-resurrection, corrupt
  segment boot-refusal, truncated tail boot-refusal), `Result: 7 passed`
  ×2 above includes it. Warm-restart rebind witnessed live.
- **COURT-ATOM-CLAMP** → PASS residue closed: named court exists and runs.
- **COURT-CERT-OBS** → ALIVE with the two real-defect repairs disclosed.
- VALIDATION.md §4 PENDING ledger: 2 → 0 row-level PENDING.

## Falsifiers

- `just bkvc-court` exiting 1 (any leg), or the atom-clamp leg observing
  nonzero atom delta over repeated parses.
- A cert accepted with a missing/unreadable `:ca_certfile`, or the stat
  diagnostic absent from the log on the missing-file face.
- Re-minting any certificate and getting `{:bad_cert, :invalid_signature}`
  from `pkix_path_validation` again.
- A fast-forward/join-gate implementation appearing without its court legs.

## See Also

- `docs/jira/v26.10.22/VALIDATION.md` (§3 rows this lane closed)
- `../v26.10.21/receipts/ja-r3-ja16-defect-fixes.md` (D1/D2 laws)
- `../v26.10.21/receipts/ttv4-journal-boot-replay.md` (TTV-4 court)
- `receipts/bksec-nfr-closures.md` (BK-SECPEND composition evidence)
