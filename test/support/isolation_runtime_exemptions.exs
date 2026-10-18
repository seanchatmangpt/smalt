# AZB-11b runtime-twin typed exemption list (isolation court, --runtime-only).
# One entry per line: `module <Name>  # reason: <text>`.
# Structural lazy-singleton / shared-tree / kernel-owned registered names that
# lib ownership keeps running for the rest of the serial suite — a boot within
# one module's window shifts Process.registered() for every later module, and
# the twin attributes the shift to whichever module spans the boundary.
# Every entry cites its witness: tmp/isolation-court-runtime.out (AZB-11
# baseline, 26/153 leaked). Non-exempt leaks still fail the court (fail-closed).

module Smalt.Security.Lens5CrashClassTest  # reason: LedgerWriter is a lib-owned lazy singleton (first ConfidentialLedger call boots it, stays for suite lifetime); not test-owned state
module Smalt.Amqp.BrokerFacadeTest  # reason: inet_gethost_native(+sup) are kernel-owned DNS worker processes, VM-lifetime after first resolver use; not test-owned state
module Smalt.StoreDetsGrowthTest  # reason: :dets/:dets_sup are kernel dets owner processes, VM-lifetime after first real DETS table; not test-owned state
module Smalt.Affidavit.WasmEngineTest  # reason: names_lost of the lib-owned WasmEngine lazy singleton (shared tree shift at module boundary), restored by later boots; harness-lifecycle pair class
module Smalt.EventGridTopicsArmTest  # reason: names_new of the lib-owned WasmEngine lazy singleton (first affidavit path call boots it, stays); harness-lifecycle pair class
module Smalt.Affidavit.WasmEngineFailClosedTest  # reason: names_new of the lib-owned WasmEngine lazy singleton (first affidavit path call boots it, stays); harness-lifecycle pair class
module AffidavitIngestionFunctorTest  # reason: names_new of the lib-owned WasmEngine lazy singleton (first affidavit path call boots once for suite lifetime); harness-lifecycle pair class
