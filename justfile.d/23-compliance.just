# 23-compliance — RETIRED (v26.10.19 staleness-repair lane)
#
# Subject deleted: the compliance corpus tier (test/compliance_test.exs,
# test/compliance/*.exs, 170 wire-court tests) was removed at 64f6099. No
# successor exists yet — the verification/ suites (V261019-08/09) do not
# carry a compliance corpus. Both recipes are LOUD no-ops: exit 1, message
# naming the deleted subject; never a silent pass. Re-author or repoint only
# with a receipt for a fresh compliance corpus.

@test-compliance:
    #!/usr/bin/env bash
    echo "[RETIRED] test-compliance: test/compliance_test.exs deleted at 64f6099; no successor landed (V261019-08/09 do not carry a compliance corpus). Exit 1."
    exit 1

@test-compliance-wire *args:
    #!/usr/bin/env bash
    echo "[RETIRED] test-compliance-wire: test/compliance_test.exs deleted at 64f6099; no successor landed. Exit 1."
    exit 1
