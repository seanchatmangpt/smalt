// ratchet mod — auto-execute: submit a dispatch prompt as if the user typed it.
//
// Submit surface (mods docs, "Start a turn from a background job",
// /docs/en/plugins/mods/api): `$.prompt.submit({ text, asUser: true })` sends
// text as the user's own words, without the mod-attribution sentence.
// It waits for session idle, then starts a new turn, and resolves when that
// turn starts. Per the docs, never `await` it from a handler that runs while
// Claude is working (e.g. prompt.submit / tool.call hooks) — call
// injectDispatch from a background context (timer callback, /command handler)
// and let the promise run; it is awaited here so the caller can observe the
// typed refusal or the resolution.
//
// This module holds no state beyond the file below; the hooks module
// (hooks/register.js) binds the mods API once via initInject($) at register
// time, then any hook or timer may call injectDispatch(promptText).

const ROOT = '/Users/sac/smalt';
const STATE_PATH = ROOT + '/mods/ratchet/state/inject-state.json';
const TICKETS_DOC = 'docs/jira/v26.10.18/azsim-burn/TICKETS.md';
const RECEIPTS_DIR = 'docs/jira/v26.10.18/receipts';
const WINDOW_MS = 5 * 60 * 1000; // max one injection per 5 minutes
const MAX_SLUG = 40;

// Bound the mods API handle. Called once from register(on) with the `$`
// the hooks receive. Idempotent.
export function initInject(modsApi) {
  $api = modsApi;
}

let $api = null;

function defaultState() {
  return { lastInjectAt: 0, dispatchLock: false, lastTicket: null };
}

async function readState() {
  try {
    const raw = await $api.fs.read(STATE_PATH);
    const s = JSON.parse(raw);
    return {
      lastInjectAt: typeof s.lastInjectAt === 'number' ? s.lastInjectAt : 0,
      // Fail-closed: anything but literal false counts as locked.
      dispatchLock: s.dispatchLock !== false,
      lastTicket: typeof s.lastTicket === 'string' ? s.lastTicket : null,
    };
  } catch {
    // No state file (or unreadable) = fresh state, except lock: a missing
    // state cannot be holding a lock, so unlocked is correct here.
    return { lastInjectAt: 0, dispatchLock: false, lastTicket: null };
  }
}

async function writeState(state) {
  const body = JSON.stringify(state, null, 2) + '\n';
  try {
    await $api.fs.write(STATE_PATH, body);
  } catch (err) {
    // $.fs has no mkdir; the state directory is created on first write.
    if ($api.process) {
      await $api.process.run(['mkdir', '-p', ROOT + '/mods/ratchet/state']);
      await $api.fs.write(STATE_PATH, body);
    } else {
      throw err;
    }
  }
}

// Extract the ticket id from free text. Only AZB-nn in this window's
// register; anything else is refused rather than loosely matched.
export function parseTicketId(text) {
  const m = /\bAZB-(\d{1,3})\b/i.exec(String(text));
  return m ? 'AZB-' + m[1] : null;
}

// Derive a bounded filesystem-safe slug from the remainder of the prompt.
export function slugFor(text) {
  const rest = String(text).replace(/\bAZB-\d{1,3}\b/i, ' ').toLowerCase();
  const slug = rest.replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, MAX_SLUG)
    .replace(/-+$/g, '');
  return slug || 'dispatch';
}

// The one and only injected prompt shape. `ticket` is AZB-nn (validated),
// `slug` is sanitized [a-z0-9-] — nothing from promptText reaches the
// submitted text outside these two slots.
function boundedPrompt(ticket, slug) {
  return 'AZB ratchet: dispatch an agent for ' + ticket + ' per ' + TICKETS_DOC
    + ' — receipt to ' + RECEIPTS_DIR + '/azb-' + ticket.slice(4) + '-' + slug + '.md';
}

export function boundedPromptFor(promptText) {
  const ticket = parseTicketId(promptText);
  if (!ticket) return null;
  return boundedPrompt(ticket, slugFor(promptText));
}

// Submit promptText's ticket as a bounded, named dispatch prompt into the
// active session as if the user typed it.
//
// Guard order: API bound -> dispatch lock -> rate window -> ticket parse.
// Returns { ok: true, text, ticket } on submission, or
// { ok: false, refused, detail } — a typed refusal, never a throw for
// guard conditions (throws only for API/IO faults, which the caller sees).
export async function injectDispatch(promptText) {
  if (!$api) {
    return { ok: false, refused: 'API_NOT_BOUND', detail: 'call initInject($) from register() first' };
  }

  // Guard 2: never inject while a ticket's receipt is being written.
  const state = await readState();
  if (state.dispatchLock) {
    return { ok: false, refused: 'DISPATCH_LOCKED', detail: 'a receipt write is in flight (dispatchLock in ' + STATE_PATH + ')' };
  }

  // Guard 1: max one injection per 5 minutes.
  const now = Date.now();
  const elapsed = now - state.lastInjectAt;
  if (state.lastInjectAt > 0 && elapsed < WINDOW_MS) {
    return { ok: false, refused: 'RATE_LIMITED', detail: 'next injection in ' + (WINDOW_MS - elapsed) + 'ms' };
  }

  // Guard 3: the injected prompt is always bounded and named.
  const text = boundedPromptFor(promptText);
  if (!text) {
    return { ok: false, refused: 'UNBOUNDABLE_PROMPT', detail: 'no AZB-nn ticket id in promptText' };
  }

  // Reserve the window before submitting so a crash between submit and
  // bookkeeping cannot open a tight loop of injections.
  await writeState({ lastInjectAt: now, dispatchLock: false, lastTicket: parseTicketId(promptText) });

  try {
    // asUser: true — the docs' "as if you had typed it" surface.
    await $api.prompt.submit({ text, asUser: true });
  } catch (err) {
    // Submit failed: release the reserved window so a transient fault
    // doesn't burn a 5-minute slot.
    await writeState({ lastInjectAt: state.lastInjectAt, dispatchLock: false, lastTicket: state.lastTicket });
    throw err;
  }

  return { ok: true, text, ticket: parseTicketId(promptText) };
}
