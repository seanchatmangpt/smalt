# KD-125 close witness — policy list faces post-fix (coordinator, 2026-10-20)

**Standing:** PASS
Context: solo

Substrate restarted (pid 57559) with the nil-safe :smalt_policy list filter
(`# KD-COVERS: KD-125`, lib/smalt/policy.ex, 7 sites). Blob CORS rule re-stored
after restart (runtime-state fact: rules are ETS, 202 re-witnessed).

Policy list faces with rem:/rs: rows present (the crashing condition), real
wire:

```
$ MIX_BUILD_ROOT=_build-integ4 mix run -e 'IO.inspect(PopcornDemo.LivePolicy.run())'
{:ok, "policy=OK(5-faces-1-defs)"}
```

All five list faces (definitions, assignments, exemptions, remediations,
setDefinitions) answer 200 with the witness leg's own policyDefinition stored —
KD-125's close condition. Witness postdates the policy.ex shim.
