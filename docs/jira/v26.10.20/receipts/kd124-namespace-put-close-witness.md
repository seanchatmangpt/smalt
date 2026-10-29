# KD-124 close witness — first namespace PUT with sku (coordinator, 2026-10-21)

**Standing:** PASS
Context: solo

Shim: `# KD-COVERS: KD-124` fail-safe wrap on the AZB-10 post-store emission
(lib/smalt/arm_gateway/router.ex; plug-conn witness test/integration/namespace_put_test.exs
5/5 x2 incl. the crash face — Peers genuinely deleted via :code.delete, PUT still 202/200 —
by lane W6-G). Live wire, substrate pid 82830+:

put-rg=201
first-ns-put=202     (first-ever PUT with sku, no 500; LRO poll 200 per W6-G corroboration)

KD-124's close condition witnessed on the real wire postdating the shim.
