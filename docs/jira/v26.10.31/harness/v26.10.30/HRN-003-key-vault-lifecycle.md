# HRN-003: Key Vault Lifecycle

## Context

Vault secret lifecycle is environment-dependent: the same operation may surface as success
or as a typed echo of prior state depending on substrate semantics. Tests must pin
disjunctive laws, not single-outcome guesses.

## Acceptance

- **TC-VAULT-001** Secret set + read round-trip.
  - Given a live substrate, When a secret is set then read back over real HTTP,
    Then the read value equals the set value.
- **TC-VAULT-002** Secret update.
  - Given an existing secret, When it is set again with a new value,
    Then read returns the new value; version increments (or, if the substrate returns the
    prior version id, the version id is asserted unchanged — one typed outcome, asserted).
- **Versioning**: each set yields an observable version identifier; two sets ⇒ two distinct
  observable versions (or one if the substrate coalesces — the disjunction is pinned in the
  assertion, never left to sleep-and-hope timing).
- **TC-VAULT-003** Deletion — disjunctive echo law.
  - Given an existing secret, When delete is issued,
    Then the law `deleted-or-echo` holds: a subsequent read either (a) 404s (deleted) or
    (b) returns the prior value with the deleted flag surfaced (echo). Both branches are
    typed and asserted; neither is treated as failure; no sleep waits for "eventual"
    deletion.

## Falsifier

A test asserting a single deletion outcome where the substrate legitimately exhibits the
other; or a sleep-based eventual-consistency wait.

## Constraints

Chicago; mocks banned; loud SKIP exit 3. Tests at
`apps/api/src/vault.harness.test.ts`.
