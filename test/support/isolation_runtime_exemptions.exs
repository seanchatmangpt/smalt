# AZB-11b runtime-twin typed exemption list (isolation court, --runtime-only).
# One entry per line: `name <glob>  # reason: <text>`.
# Structural registered-name classes: lib-owned lazy singletons and
# kernel-owned VM-lifetime processes whose first use shifts
# Process.registered() for every later module in the serial suite; the twin
# attributes the shift to whichever module spans the boundary.
# A leak block is exempt only when it has NO env delta and every name delta
# matches a pattern — env leaks are never exemptable. Non-exempt leaks still
# fail the court (fail-closed). Every entry cites its witness: the AZB-11
# baseline log tmp/isolation-court-runtime.out (26/153 modules leaked).

name Smalt.Security.LedgerWriter  # reason: lib-owned lazy singleton (first ConfidentialLedger call boots it, stays for suite lifetime)
name Smalt.Affidavit.WasmEngine*  # reason: lib-owned lazy singleton family (engine + supervisor + owner, first affidavit path call boots once for suite lifetime)
name Smalt.Supervisor  # reason: shared-tree lazy boot/teardown shift — membership of the harness-owned Smalt.Supervisor tree (test_helper Lifecycle boot), attributed to whichever serial module spans the boundary
name Smalt.Store  # reason: shared-tree lazy boot/teardown shift — harness-owned Store member
name Smalt.AmqpBroker*  # reason: shared-tree lazy boot/teardown shift — harness-owned broker tree member
name Smalt.Amqp.*  # reason: shared-tree lazy boot/teardown shift — harness-owned listener/queuestore/sweeper members (QueueStore, Listener.Eh/Sb, Sweeper, CbsRouter)
name Smalt.ArmGateway.LRO.*  # reason: shared-tree lazy boot/teardown shift — harness-owned LRO notifier/sweeper members
name Smalt.Telemetry.RollingCounters  # reason: shared-tree lazy boot/teardown shift — harness-owned telemetry member
name inet_gethost_native*  # reason: kernel-owned DNS worker processes, VM-lifetime after first resolver use
name :dets  # reason: kernel dets owner process, VM-lifetime after first real DETS table
name :dets_sup  # reason: kernel dets supervisor, VM-lifetime after first real DETS table
