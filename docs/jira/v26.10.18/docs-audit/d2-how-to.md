# D2 — docs/how-to audit (2026-10-18)
Wrong (1): dev-loop.md:186 "full suite ~8s" contradicts own receipts (40-58s).
Stale (2): :196 "latest counted 8/1529"; :174-184 recipe table missing justfile.d 23-30 generation.
Missing everywhere (9 families): burn suite (docker/burn/* + just burn*), test-stress/:stress tier, budget gate, sleep gate, leak-court, quiesce/quiet-check, rewitness/kd-stale, wt-scratch/corpus-soak, SMALT_PLANES.
Clean: debug-agent, develop-native, wire-parity, pqc-seals, how-to-clean (except burn-clean gap).
