# vacuous-courts-and-real-clients

Why a court that recomputes with the same calculus as the thing it judges
proves nothing, and why protocol surfaces are only honestly gated by real
consumers.

## The T02 court that passed vacuously

T02's SAML IdP (r2) landed green: 6/6 courts, exit 0, including a signature
court that recomputed SHA-256 over the emitted assertion and verified the
signature with the embedded cert. Real listener, real HTTP, real crypto.

Then T03 pointed a real consumer at it (r3). The court's own green held;
the consumer rejected every response:

```text
raw-unsigned sha256 : zyx8PQa4gt0uXoTszEMyHt+Xd/AuueLIqo/z9XnQCjY=   == declared
lxml exc-c14n sha256: tPBDjPvhvJGy72GYF2P3zf8/4HWD08AREZkbI966Xd4=   != declared
```

The IdP digested its own emitted string (saml_idp.ex:250 per r3's
addendum); every conformant verifier (xml-crypto 6.4, node-saml, lxml)
digests the exclusive-canonical form. The in-repo court passed because it
recomputed the digest the same non-canonical way — same-calculus
agreement, not conformance. r3's wording is the law: "The IdP's own court
passes because it recomputes the digest the same non-canonical way
(same-calculus agreement, not conformance)."

## The class, named

A gate is vacuous when judge and judged share the defect. The verifier was
derived from the implementation's model instead of the spec's, so the
court measured self-consistency and reported conformance. 6/6 green
carried zero bits about SAML correctness; the first real client
(node-saml) withdrew that confidence in one run.

## The byte-frozen replay fence is the same class

The replay-identity fence (test/smalt_gen_ash_replay_identity_test.exs)
pins that regeneration is a disk no-op — but per r11's recon it covers the
ash_gen pipeline only, NOT the substrate pack, and the pack fence is
designed to be re-pinned by landing regenerated outputs. A fence whose
expected value updates to whatever the pipeline last produced cannot
detect a pipeline that drifts; it detects only mutation of the artifact
behind the pipeline's back. Self-referential green again.

## Law: real consumers are the only honest gates for protocol surfaces

r3 closed the RESP3 hop and isolated the signature hop only by running the
real stack: node-redis (`redis@6.3.0` sending `HELLO 3` as first wire
bytes), `@node-saml/node-saml`'s `validatePostResponseAsync` on a captured
response, lxml's independent c14n recomputation. None of those can share
the implementation's defect, which is exactly the property that makes the
verdict carry bits.

Practical form for any new protocol face:

1. In-repo court for mechanics (r2's tamper non-vacuity court — mutating
   NameID flips the result to `{:error, :digest_mismatch}` — is a good
   non-vacuity shape for the mechanism itself).
2. A real consumer court for conformance (r3's `just courtroom-court`:
   real npm client, real validator, exit code as verdict).
3. Independence check on any verifier: name what would make it fail that
   the implementation could also get wrong. If nothing, it is same-calculus.

## Related

- [generated-files-are-projections](generated-files-are-projections.md)
- [multi-agent-compile-freeze-economics](multi-agent-compile-freeze-economics.md)
- r2: receipts/r2-t02-saml-idp.md; r3: receipts/r3-t03-consumer-court.md
