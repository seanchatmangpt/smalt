# KD-69 fresh live witness — idle-eviction delivered (coordinator, 2026-10-21)

**Standing:** PASS
Context: solo

Live falsifier rerun against the CURRENT substrate beam (boot postdates the
KD-69 recv-pump fix in lib/smalt/messaging/amqp/connection.ex, `KD-COVERS:
KD-69`), using W13-A2's falsifier probes (/tmp/kd69_falsifier.exs, with the
probe's own 3-tuple destructure corrected to the 2-tuple the post-fix wire
delivers — W14-A disclosed this probe bug):

```
face1_a_attach:      {:ok, "A attached epoch=7, no detach within 500ms"}
face2_b_evicts_a:    {:ok, ...}
face3_c_stale_refused: {:ok, ...}
KD69-VERDICT: PASS
```

Face 2 is the row's exact divergence: the idle incumbent receiver receives the
typed `com.microsoft:epoch-lock-lost` + `EPOCH_EVICTION` detach WITHOUT sending
first. All three faces hold on the live wire.
