# Compliance corpus tier (170 wire-court tests, loader: test/compliance_test.exs).
# The family files (test/compliance/*.exs) never matched the *_test.exs glob —
# this tier is how they run. c5 (servicebus) is :amqp_wire-tagged, so the full
# 170 execute only with --include amqp_wire.
SMALT_COMPLIANCE_DIR := "test/compliance"

@test-compliance:
    mix test test/compliance_test.exs

@test-compliance-wire *args:
    mix test test/compliance_test.exs --include amqp_wire {{args}}
