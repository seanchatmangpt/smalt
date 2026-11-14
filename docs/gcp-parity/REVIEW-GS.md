# REVIEW-GS: static skeptic review of lib/smalt/gcp and test/gcp

Standing: PARTIAL

Lane SW5. Subject: working tree of /Users/sac/smalt (uncommitted; SHA not pinned). Method: read
every file under `lib/smalt/gcp/` (15 files) and `test/gcp/` (9 files) against real signatures in
`lib/smalt/store.ex`, `store/partition.ex`, `data_plane/queue_storage.ex`, `application.ex`,
`egress_router.ex`. Nothing was compiled or run (`deps/` is absent): every row below is a static
finding, UNVERIFIED until `mix compile --warnings-as-errors` and `mix test test/gcp` run.
No `Process.sleep`, `:timer.sleep` or `receive ... after` exists in either tree (grep, 0 matches).

## Defect table

| # | file:line | sev | defect | exact fix |
|---|---|---|---|---|
| 1 | lib/smalt/gcp/pubsub.ex:588 | HIGH (compile) | `~r{...[a-z0-9\-]{3,29}.../#{coll}/...{2,254}$}`: with `{}` delimiters the sigil ends at the first unescaped `}`, i.e. the quantifier `{3,29}`. The remainder is a syntax error, so the whole module and the app fail to compile. | Change the delimiter: `~r\|^projects/[a-z][a-z0-9\-]{3,29}/#{coll}/[A-Za-z][A-Za-z0-9\-_.~+%]{2,254}$\|` (the pattern contains no `\|`). |
| 2 | test/gcp/pubsub_engine_test.exs:12 and test/gcp/pubsub_router_test.exs:11 | HIGH (test) | `start_supervised!({PubSub, name: PubSub})`: `Smalt.Gcp.PubSub` is already a named app child (`lib/smalt/application.ex:61`), so start returns `{:error, {:already_started, _}}` and `start_supervised!` raises in every test of both modules. | Delete both `start_supervised!` lines. In `setup` call `:ok = Smalt.Gcp.PubSub.reset()` and add `on_exit(fn -> Smalt.Gcp.PubSub.reset() end)`. `reset/1` also deletes the substrate queues, which the tests need (`create_queue` is matched `{:ok, 201, _}` and raises on a leftover queue). Drop the no-op `on_exit(fn -> :ok end)` at engine_test:13. |
| 3 | test/gcp/pubsub_router_test.exs:23,24,27,32,35,36 | HIGH (test) | Topic id `tr` and subscription id `sr` are 2 chars; `valid_name` requires 3..255 (`[A-Za-z]` plus `{2,254}`), so PUT answers 400 and the round-trip test fails at its first assert. | Rename `tr` to `tr1` and `sr` to `sr1` on all six lines, including the `projects/gs2-rest/topics/tr` strings at lines 23 and 24. |
| 4 | test/gcp/pubsub_router_test.exs:44-45 | HIGH (test) | `subscriptions/x:pull` with `maxMessages: 0` targets a subscription that does not exist. `handle({:pull,...})` checks existence first, so the answer is 404 NOT_FOUND, not the asserted 400 INVALID_ARGUMENT. | Before the assert create a topic and subscription (ids of 3+ chars, e.g. `top` and `sub1`), then pull `subscriptions/sub1:pull` with `maxMessages: 0`. |
| 5 | lib/smalt/gcp/logging.ex:39,69 | MED (flaky) | Row key is `pad(_ns)/insertId` and the default insertId is `"i" <> Integer.to_string(unique_integer)`. Entries written in one request can share an `os_time(:nanosecond)` value (macOS clock is us-granular), and the tiebreak is a lexicographic compare of unpadded integers (`"i99" > "i100"`). `list_entries` order, asserted in `run_logging_test.exs` ("boot ok","boom","slow") and `run_logging_router_test.exs`, can invert. | At line 69 use a padded id: `"i" <> String.pad_leading(Integer.to_string(System.unique_integer([:positive, :monotonic])), 20, "0")`. |
| 6 | lib/smalt/gcp/storage/router.ex:259 | LOW (data) | `part_body/1` (line 269) already strips one trailing CRLF; line 259 strips a second, so an object whose payload legitimately ends in `\r\n` is truncated. | Line 259: `data = part_body(p2)`. |
| 7 | lib/smalt/gcp/storage.ex:114 | LOW (500) | `delimiter=` (empty string) makes `:binary.match(rest, "")` raise `ArgumentError` and crashes the shared `Storage.Server` call path. | `case delim not in [nil, ""] && :binary.match(rest, delim) do`. |
| 8 | lib/smalt/gcp/storage/server.ex:24 | LOW (blast radius) | `fun.(st)` runs inside the single app-wide GenServer. Any raise in a caller-supplied fun (item 7, malformed input) kills the server and drops all GCS state. | Wrap `fun.(st)` in `try/rescue` returning `{:reply, {:error, %{status: 500, reason: "backendError", message: Exception.message(e)}}, st}`. |
| 9 | lib/smalt/gcp/firestore.ex:382-393 | LOW (500) | `runQuery` with a `from` entry lacking `collectionId` and `allDescendants` not true: `base <> nil` raises `ArgumentError`, answered as a 500 by Plug. | Guard before line 393: `if is_nil(coll) and not all?, do: error(400, "INVALID_ARGUMENT", "from.collectionId required"), else: ...`. |
| 10 | lib/smalt/gcp/identity.ex:16-25 | LOW (flaky) | `key/0` is check-then-put on `:persistent_term`. Two processes calling it first (async tests, `identity_plane_test` is `async: true`) each generate a different RSA key, and a token minted with the overwritten key fails `verify/1`. | Serialize with `:global.trans({{__MODULE__, :key}, self()}, fn -> ... end)` and re-check inside, or generate the key at app boot. |
| 11 | lib/smalt/gcp/firestore/router.ex:12 | LOW (unverified) | Plug param `:_db` is an underscore-prefixed var. Whether Plug 1.16 skips underscore params or emits an underscored-variable-used warning (fatal under `--warnings-as-errors`) could not be checked (deps absent). | If the compile warns: `match "/projects/:project/*rest"` and in `route/4` match `["databases", _db \| tail]`. |

## Checked and clean (static)

- Store API use: `Store.put/get/delete/list_prefix/insert_new/compare_and_swap/compare_and_swap_delete`
  arities and return shapes match `store.ex` and `store/partition.ex`; `:smalt_resources` and
  `:smalt_cosmos_docs` are in `Smalt.StoreTables`.
- QueueStorage use in `pubsub.ex`: `create_queue` `{:ok,201,_}`, `put_message`/`get_messages`/`update_message`
  `{:ok,_,_,_}`, `delete_message` `{:ok,204,_}`, `clear_messages`, `delete_queue`, `store_ready?`, and the
  `"now_ms"`, `"messagettl" => "-1"`, `"visibilitytimeout"` opts all exist; XML tags `MessageId`, `PopReceipt`,
  `MessageText` are emitted by `message_xml/2`.
- Router/engine seams: `Smalt.GCP.Storage.Router`, `Smalt.Gcp.PubSubRouter`, `Smalt.GCP.Firestore.Router`,
  `Smalt.GCP.RunLoggingRouter`, `SecretManager`/`KMS.handle/5` match the references in `egress_router.ex`
  and `application.ex` (the `Gcp` vs `GCP` spelling split is consistent across lib, app and tests).
- Walked every test assertion against its engine path (KMS, SecretManager, identity, IAM, Cloud Run,
  logging, RunLoggingRouter, Firestore CRUD/CAS/query/commit/txn, GCS JSON/XML/resumable/signed URL,
  Pub/Sub engine): no other mismatch found. `jose` is present only transitively (joken, `mix.lock:35`) and is
  already used by `auth/sts_key.ex`.

## Falsifier

`mix compile --warnings-as-errors` still fails on `pubsub.ex`, or `mix test test/gcp` shows a failure outside
rows 1-5, falsifies this review's completeness.

## smalt-15 note

Standing: UNVERIFIED

The GCP run line is pending in GCP_WIRE_PARITY.md Run log.
