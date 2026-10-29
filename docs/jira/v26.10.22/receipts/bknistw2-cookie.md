# Receipt: bknistw2-cookie — NIST W2 (IA-5(1)): cookie is a Secret with a real value, gate-enforced

**Standing: ALIVE** — the backend Erlang release cookie renders as a Secret
referencing fact + a derived (non-placeholder) value in
`k8s/smalt-backend.gen.yaml`, the render is `kubectl apply --dry-run=client`
green, and a new fail-closed pack gate refuses both the ConfigMap/literal
cookie source and the placeholder value. Both refusal arms are witnessed
firing (non-vacuity), and the clean graph passes.

Context: solo. Lane BK-NISTW2, v26.10.22, repo /Users/sac/smalt.

## What landed

| File | What |
|---|---|
| `packs/smalt-k8s-pack/gates/070_cookie_secret.rq` | NEW gate, two arms: (a) any `k8s:EnvVar` named `RELEASE_COOKIE` without `envSecretName`+`envSecretKey` → `COOKIE_ENV_NOT_SECRET_REF`; (b) any `k8s:Secret` whose `secretStringDataBlock` matches `replace-me` (case-insensitive) → `COOKIE_SECRET_PLACEHOLDER_VALUE`. Any row = sync refused (FM-PACK-013). |
| `priv/smalt-k8s.ttl` | Secret `smalt:releaseCookie` placeholder replaced: value is now DERIVED, not random and not `replace-me` — `hex(sha256("smalt-release-cookie"))[0..32]` = `371ec51a45c65415ff0dafcd39e1d5ce`, same derivation shape as `scripts/dev_env.sh`'s per-host SAS key (`base64(sha256(host + "smalt-dev-sb"))`). Comment block keeps the production overwrite command. The cookie env fact (`smalt:envCookie`) was already `envSecretName`+`envSecretKey` (BK-K8SM's typed Secret reference — the ontology's equivalent of a SecretRef; no new class needed, the reference was already typed). |
| `k8s/smalt-backend.gen.yaml` | render output: `cookie: 371ec51a45c65415ff0dafcd39e1d5ce` in the `smalt-release-cookie` Secret; `RELEASE_COOKIE` env remains `secretKeyRef` → `smalt-release-cookie`/`cookie`. |
| `ggen.lock` | re-locked: `smalt-k8s-pack` blake3 `8edd6c6d…` — includes this lane's gate 070 AND lane BK-NISTW1's in-flight gate `060_network_policy.rq` (same-checkout lock absorbs concurrent pack files; disclosed). |

## Manifest half (verified done by BK-K8SM)

`k8s/smalt-backend.yaml` (and the render) already carried `RELEASE_COOKIE` as
`secretKeyRef` to Secret `smalt-release-cookie` — the manifest half of W2 was
done; this lane's work was the GATE + the value.

## Embedded output — render (ggen sync run)

```
$ ggen sync run
decisions: k8s/smalt-backend.gen.yaml: written (first run, after re-lock)
graph_hash_hex: ce570aa09b37913b0f8f782289b2ba961f0a0b25c3d81d9ceae2c7cb9c89cd76
packs: kubernetes-workload-pack 38993abe…, smalt-k8s-pack dda86b10… (pre-W1-lock)
written: [k8s/smalt-backend.gen.yaml]      exit 0
# replay: written: [] (content identical)
# final (post-W1 lock 8edd6c6d…): written: [], graph_hash_hex 1b2c9429…, exit 0
```

## Embedded output — kubectl dry-run

```
$ kubectl apply --dry-run=client -f k8s/smalt-backend.gen.yaml
secret/smalt-release-cookie configured (dry run)
configmap/smalt-backend-env configured (dry run)
service/smalt-backend configured (dry run)
service/smalt-backend-headless configured (dry run)
service/smalt-backend-nodeport configured (dry run)
statefulset.apps/smalt-backend configured (dry run)
exit 0
```

## Embedded output — gate 070 non-vacuity (rdflib 7.x over union graph:
pack ontology + priv/smalt-k8s.ttl + priv/smalt-nist-overlay.ttl)

```
MUT1 (cookie env -> literal/ConfigMap-class source:
      envSecretName/envSecretKey removed, envValue "replace-me-before-apply")
→ rows: 1
  https://seanchatman.github.io/smalt/k8s#envCookie | COOKIE_ENV_NOT_SECRET_REF   REFUSED
MUT2 (Secret block placeholder restored: cookie: replace-me-before-apply)
→ rows: 1
  https://seanchatman.github.io/smalt/k8s#releaseCookie | COOKIE_SECRET_PLACEHOLDER_VALUE   REFUSED
CLEAN (derived cookie + secretKeyRef restored, only own lines reverted)
→ rows: 0                                                          exit 0
```

Mutation discipline: only this lane's own lines were mutated and reverted
(line-level perl substitution, no whole-file restore) — lane BK-NISTW1 was
concurrently editing `priv/smalt-k8s.ttl` (NetworkPolicy facts) and the pack
(gate 060); a whole-file restore would have clobbered their in-flight work.
No stash used.

## Disclosures

- `priv/smalt-k8s.ttl` is a shared file: this commit's copy carries BK-NISTW1's
  in-flight NetworkPolicy facts alongside W2's cookie value (coordinator
  absorbs; W1's own receipt owns those rows).
- `ggen.lock` hash `8edd6c6d…` includes gate 060 (W1's) + gate 070 (mine).
- First sync attempt hit `FM-PACK-008` hash mismatch (expected after adding a
  gate); lock deleted + re-locked intentionally, twice (second re-lock needed
  when W1's gate 060 landed between my lock and my run).

## Falsifiers / boundary

- F1: flipping `RELEASE_COOKIE` to a ConfigMap source (or literal) in the
  fact graph must make `ggen sync run` exit nonzero with the gate-070 row —
  witnessed above; a graph that passes after this flip = gate vacuous.
- F2: regenerating the cookie placeholder string must be refused — witnessed.
- Boundary: no live cluster apply this session — dry-run=client only (matches
  BK-K8SM/BK-MKT1 precedent); dev cookie value is derived, deterministic, and
  dev-scope (loopback swarm); production overwrite command retained in the
  Secret comments.
