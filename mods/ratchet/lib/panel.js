'use strict'

/**
 * Ratchet mod — status-band renderer (R3).
 *
 * Builds the one-line band drawn above the prompt:
 *   ⟐ RATCHET agents N/20 · AZB landed L/24 · open: [ids] · mode: AUTO|OBSERVE
 *
 * State sources:
 *   - mods/ratchet/state.json (optional; agents / mode / blocked) — written by
 *     other lanes; absent today, so defaults apply and AZB counts are derived.
 *   - docs/jira/v26.10.18/RECEIPTS.md — AZB landed/open derived from receipt
 *     table rows (receipts/azb-*.md links). RECEIPTS.md is generated; this file
 *     only reads it, never writes it.
 *
 * NOTE (R3 disclosure): lib/state.js is R2's module and does not exist yet;
 * this file inlines a minimal reader (readState below). When R2 lands
 * lib/state.js, swap `readState` for an import and delete the inline copy.
 */

const fs = require('fs')
const path = require('path')

const AGENT_CAP = 20
const AZB_TARGET = 24
const RECEIPTS_REL = path.join('docs', 'jira', 'v26.10.18', 'RECEIPTS.md')
const STATE_REL = path.join('mods', 'ratchet', 'state.json')

/** Minimal inline state reader (R2's lib/state.js pending — disclosed). */
function readState(repoRoot) {
  const defaults = { agents: 0, agentsMax: AGENT_CAP, mode: 'OBSERVE', blocked: [] }
  try {
    const raw = fs.readFileSync(path.join(repoRoot, STATE_REL), 'utf8')
    const parsed = JSON.parse(raw)
    return {
      agents: typeof parsed.agents === 'number' ? parsed.agents : defaults.agents,
      agentsMax: typeof parsed.agentsMax === 'number' ? parsed.agentsMax : AGENT_CAP,
      mode: parsed.mode === 'AUTO' ? 'AUTO' : 'OBSERVE',
      blocked: Array.isArray(parsed.blocked) ? parsed.blocked : [],
    }
  } catch (_err) {
    return defaults
}
}

/** Distinct AZB-nn ids with an azb receipt row in the generated RECEIPTS.md. */
function deriveAzb(repoRoot) {
  const landed = []
  try {
    const text = fs.readFileSync(path.join(repoRoot, RECEIPTS_REL), 'utf8')
    const re = /receipts\/(azb-[0-9]{2}[a-z]?)[^)]*\.md/g
    let m
    while ((m = re.exec(text)) !== null) {
      const id = m[1]
      if (!landed.includes(id)) landed.push(id)
    }
  } catch (_err) {
    /* receipts file missing: nothing landed yet */
  }
  const landedSet = new Set(landed)
  const open = []
  for (let n = 1; n <= AZB_TARGET; n++) {
    const id = 'azb-' + String(n).padStart(2, '0')
    if (!landedSet.has(id) && !landedSet.has(id + 'b')) {
      open.push('AZB-' + String(n).padStart(2, '0'))
    }
  }
  return { landed: landed.length, open }
}

/**
 * Pick the band color:
 *   green — every AZB ticket landed (open list empty)
 *   yellow — open tickets exist and none are blocked (deps satisfied)
 *   red — at least one open ticket is blocked
 */
function pickColor(open, blocked) {
  if (open.length === 0) return 'green'
  const blockedOpen = blocked.some((b) => open.some((o) => o.startsWith(b)))
  return blockedOpen ? 'red' : 'yellow'
}

/** The status line, exactly per the work order. */
function buildStatusLine(state, azb) {
  const openPart = azb.open.length > 0 ? azb.open.join(', ') : 'none'
  return (
    '⟐ RATCHET agents ' + state.agents + '/' + state.agentsMax +
    ' · AZB landed ' + azb.landed + '/' + AZB_TARGET +
    ' · open: [' + openPart + '] · mode: ' + state.mode
  )
}

module.exports = {
  AGENT_CAP,
  AZB_TARGET,
  readState,
  deriveAzb,
  pickColor,
  buildStatusLine,
}
