# AMQP10SK — crash-only router skeptic audit

Context: solo

Date: 2026-10-21 · Lane: AMQP10SK · Repo: /Users/sac/smalt
**Standing:** **BLOCKED — UNSUPPORTED (SUBJECT_NOT_LANDED)**

## Observations (all re-verified on disk this session)

- `lib/smalt/messaging/amqp10/` does not exist. `lib/smalt/messaging/` contains `amqp/` (the landed AMQP surface: connection.ex, frame_codec.ex, primitive_codec.ex, cbs_router.ex, listener.ex, …) — no crash-only router module anywhere under it.
- `grep -ril "crash.only\|crash_only"` over `lib/`, `test/`, `docs/jira/v26.10.21/` → zero matches.
- `grep -ril "amqp10"` over the same trees → zero matches.
- `git log --all -- '*amqp10*'` → empty (no commit in any branch ever touched such a path); only `main` exists (local + origin).
- No `test/integration/amqp10_*` court file exists to re-run.

## Per-claim verdicts

| Claim | Verdict |
|---|---|
| (1) cascade <10ms on RST, root `trap_exit` + links, sibling semantics | **UNSUPPORTED** — no subject module to exercise |
| (2) OPEN frame byte-conformance vs rhea / PrimitiveCodec | **UNSUPPORTED** — no OPEN encoder to decode |
| (3) 100-credit-once link, no re-grant → transfer stop | **UNSUPPORTED** — no link credit code to observe |
| (4) partial-frame fuzz across TCP segments | **UNSUPPORTED** — no frame codec under audit |
| (5) ETS payload table unbounded growth | **UNSUPPORTED** — no table to grow |

## What was NOT done and why

No court file was authored (`test/integration/amqp10_skeptic_court.exs`) — a court against a
nonexistent subject is a fake pass by construction; writing one would launder BLOCKED into a
false ALIVE. The dispatch precondition ("launch after AMQP10 lands") is not satisfied: AMQP10
has not landed in this checkout at HEAD `800a691` on `main`.

## Receipt

Evidence commands (all exit 0, all empty / no-such-directory):

```
ls lib/smalt/messaging/amqp10/        # No such file or directory
grep -ril "crash.only\|crash_only" lib/ test/ docs/jira/v26.10.21/   # no output
grep -ril "amqp10" lib/ test/ docs/jira/v26.10.21/                   # no output
git log --all -- '*amcp10*'           # empty; branches: main only
```

Next action for the coordinator: land the AMQP10 crash-only router first, then re-dispatch this
lane; the audit plan (cascade timing, OPEN-byte conformance, credit starvation, split-frame
fuzz, ETS growth) stands as written in the dispatch and will execute against the landed subject.
