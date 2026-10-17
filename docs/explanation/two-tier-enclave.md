# two tier enclave

**Why the Native/Wire Split Exists**

Understanding-oriented. The how lives in `scripts/enclave_native.sh`,
`lib/smalt/enclave/`, `scripts/tf_trust_setup.sh`; this doc explains the
why. H1 matches filename, per docs conventions.

## The boundary that would not move

smalt's terraform story needs a real provider plugin (azurerm) to talk to
the emulator's ARM gateway. On darwin, two independent walls stand
between an external provider binary and loopback TLS:

1. **darwin Go ignores `SSL_CERT_FILE`**. Go's crypto/x509 on darwin
   does not read the OpenSSL-style environment variable; it goes to the
   System Roots and the admin trust domain via its own extractor. A Go
   binary handed `SSL_CERT_FILE=.smalt/tls/ca-cert.pem` still verifies
   against the system store, where the smalt-dev CA is not (yet)
   trusted.
2. **Hardened-runtime providers ignore DYLD interposition.** The trust
   shim (DYLD interpose, fingerprint-pinned, loopback-gated) covers
   ad-hoc / non-hardened binaries only. The azurerm provider plugin is
   hardened-runtime (`codesign` flags `0x10000`), so `DYLD_INSERT` is
   silently ignored there — silently, which is the worst failure mode:
   the shim looks installed and does nothing. (Witnessed 2026-10-16,
   shim integration lane; see WRAP_LEDGER "Zero-touch trust".)

Either wall alone would be solvable. Together they mean: on darwin, an
external azurerm provider cannot be pointed at a loopback TLS endpoint
without either (a) one-time admin keychain trust of the dev CA, or (b)
re-signing the provider — which breaks the terraform dependency-lock
checksums (witnessed, reverted).

## The zero-touch ruling

Operator ruling (2026-10-16, WRAP_LEDGER "Enclave trust hop"): the dev
workstation does not enter the enclave. Keychain trust of `smalt-dev-ca`
is a **local bootstrap prerequisite**, not an enclave capability — the
same category as having a compiler installed. `scripts/tf_trust_setup.sh`
gates it loudly (fingerprint + trust-settings parse); T3/T5 execute on
any trusted machine without blocking the substrate deliverables. The e1
lane's SKIP-LOUD semantics encode the same ruling: absent trust is a
loud per-family skip, never a fake pass.

## Why two tiers, and what each proves

The consequence of the ruling is a deliberate split:

- **Native tier (PRIMARY gate)** — in-process HCL → plan/apply engine
  (`lib/smalt/enclave/hcl.ex`, `engine.ex`, `state.ex`, `lifecycle.ex`)
  dispatching over the real ARM gateway. It boots nothing external: no
  sockets, no TLS, no terraform binary, no Go processes. Being in-BEAM,
  the darwin walls simply do not apply. What it proves: the **semantic
  correctness of the lifecycle** — parse → plan → synthesize → apply →
  destroy → residue over the real Router, with zero-drift plan and
  resource ids byte-identical to the external tfstate read from the T5
  cleanroom lane's isolated fixture (`sdk-results/native-lifecycle.md`,
  ALIVE). Timings witnessed: parse 3 / apply 52 / plan 2 / synthesize 1 /
  destroy 15 / residue 0 ms.
- **External wire tier (T4-external compat)** — real terraform + real
  azurerm over the 9444 TLS twin. What it proves: **wire compatibility**
  — that the emulator answers a real provider's real HTTP: api-version
  admission (KD-78 monotonic admission), enrichment shapes azurerm 4.54
  dereferences (FR-5), LRO polling headers, provider-metadata
  (`microsoftGraphResourceId`). It is single-flight on three global
  resources (fixture state lock, `.smalt/tls` cert regen, provider
  mirror) and opt-in.

The split is not "fast tier and slow tier" — it is a division of
epistemic labor. The native tier can be green on any machine, every
run; the wire tier certifies the one thing the native tier structurally
cannot: that a binary smalt does not control parses smalt's responses
correctly. Neither tier's green substitutes for the other's; the
demotion of the external tier to opt-in compat is a statement about
trust prerequisites, not about importance.

The tier that cannot run everywhere must never be the primary gate —
otherwise the gate inherits the keychain as a dependency and the
"zero-touch" property is lost at exactly the machines that need it most
(fresh clones, CI runners, clean-room lanes).

## See Also

- `docs/jira/v26.10.16/WRAP_LEDGER.md` — zero-touch trust, native
  pipeline, enclave trust hop sections
- `docs/jira/v26.10.16/sdk-results/native-lifecycle.md`
- `scripts/enclave_native.sh`, `scripts/tf_trust_setup.sh`
