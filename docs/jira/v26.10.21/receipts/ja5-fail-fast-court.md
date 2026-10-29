# JA-5 — Fail-Fast Boundary Court (OTP-29 lane)

**Standing: PASS (ALIVE) — 4/4 gates, 24 top-level assertions, 3 consecutive green runs**

- Court file: `test/integration/ja5_fail_fast_court.exs`
- Lane build root: `MIX_BUILD_ROOT=_build-ja5`
- Toolchain: Erlang/OTP 29.1.2 + Elixir 1.20.4-otp-29 (asdf; PATH-pinned, matches `.tool-versions`)
- Repo head at run: `08acebf552b1aebd3f388d88048515439e982cd8`
- Context: solo

## Command

```bash
export ERL_ROOT=~/.asdf/installs/erlang/29.1.2 ELX=~/.asdf/installs/elixir/1.20.4-otp-29
PATH="$ERL_ROOT/bin:$ELX/bin:$PATH" MIX_BUILD_ROOT=_build-ja5 \
  mix test test/integration/ja5_fail_fast_court.exs
```

## Output (run 3 of 3, all identical verdicts)

```
Finished in 16.4 seconds (0.00s async, 16.4s sync)
Result: 4 passed
```

(runs 1 and 2: `Result: 4 passed`; earlier red-to-green iterations disclosed below)

## Gates (all on real wire faces: Bandit + Smalt.EgressRouter + raw :httpc HTTP, no mocks)

1. **Malformed JSON → typed 400, data plane untouched.** Truncated JSON
   (`{"id":"ja5-victim","v":`), scalar JSON (`5`), and invalid doc-id grammar
   (`{"id":"a/b"}`) each answer typed 400 on
   `POST /dbs/:db/colls/:coll/docs`; truncated CloudEvent JSON answers a typed
   400/415 envelope on `/topics/:topic/events`. Deep assert:
   `:smalt_cosmos_docs` has no row for the victim key and the container's row
   count is unchanged — the malformed body never reached the store.
2. **Oversized payload → typed 413 + CAS 412.** A 9 MB Put Blob against the
   8,000,000-byte transport cap answers **413 RequestBodyTooLarge**; the blob
   is then GET-verified ABSENT from the store (deep assert). Wrong `If-Match`
   answers **412 PreconditionFailed** and the blob body is verified untouched
   (`v1` round-trips).
3. **Atom-smuggling battery (the ARMSTRONG class).** After a per-CLASS warm-up
   (5x each: blob catch-all GET, cosmos GET docs, events POST, XML blocklist
   PUT), a battery of atom-shaped payloads across paths, query params, JSON
   keys/values (incl. invalid UTF-8 and struct-smuggling shapes), and XML
   bodies mints **0 new atoms**
   (`:erlang.system_info(:atom_count)` fence, per-request bisect, offenders
   list empty).
4. **Handler crash → worker disposable, system not.** A real plug raising in a
   real Bandit handler drops the request with 500 + `connection: close` (or
   connection-level failure); the Bandit supervisor survives; the very next
   request answers a typed 404 with a typed error envelope; a subsequent
   malformed-JSON request still answers typed 400 and the store stays clean.

## Honest findings during development (red-to-green, no numbers invented)

- **First-touch atom minting measured and dispositioned.** The first versions
  of gate 3 measured 4, 203, and 3 new atoms. Per-class bisect attributed:
  `cosmos-path/get` +187 (first-touch cosmos GET-docs lazy init), `xml/blocklist`
  +3-6 (first-touch PUT-blocklist 404 path), `json-body/events` +10
  (first-touch events surface init). All three DECAY to zero after per-class
  warm-up — one-time lazy initialization, NOT per-request minting. The court
  warms each probe class 5x before the fence baseline so the fence measures
  per-request minting only. No per-request atom minting was found anywhere on
  the probed surfaces.
- **Blob-plane errors are XML, not JSON.** The blob catch-all answers typed
  errors as `<?xml?><Error><Code>...</Code></Error>` (RequestBodyTooLarge,
  BlobNotFound), so the court's error-code parser reads both JSON
  `error.code` and XML `<Code>` envelopes.
- **413 over a hard-closed transport**: when the server refuses an oversized
  body without draining it, the client can receive an empty body with the 413
  status; the gate therefore asserts status 413 + store-absence (deep) and
  accepts the typed XML code when the transport delivers it.

## No-sleep discipline

Zero `Process.sleep` — all gates are synchronous request/response.

## Falsifier

Any of: a malformed body creating an ETS row; an oversized body stored after a
413; a nonzero atom-count delta after class warm-up; the Bandit supervisor
dying with its handler; a 2xx answer to a crashing request.
