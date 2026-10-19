'use strict'

/**
 * Ratchet mod — panel registration hook (R3).
 *
 * Registers the status band above the prompt via the `ui.render` hook surface,
 * component `AbovePrompt`. This file is NEW and self-contained: it does NOT
 * touch hooks/register.js or hooks.json (R1's lease). It exports
 * `registerPanel(on)`; the parent integrates it.
 *
 * hooks.json integration (R1/parent to land — one line):
 *   add to the "hooks" array inside the existing Register block:
 *     { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/panel.js\"" }
 *
 * When run directly as that hook command, it self-registers.
 */

const path = require('path')
const { readState, deriveAzb, pickColor, buildStatusLine } = require('../lib/panel.js')

/** Build the colored band element from the ui.render kit (Box + Text). */
function bandFor(kit, e) {
  const repoRoot = path.resolve(__dirname, '..', '..', '..')
  const state = readState(repoRoot)
  const azb = deriveAzb(repoRoot)
  const color = pickColor(azb.open, state.blocked)
  const line = buildStatusLine(state, azb)
  const width = (e.props && e.props.bodyColumns) || (e.viewport && e.viewport.columns) || 80
  const clipped = line.length > width ? line.slice(0, Math.max(8, width - 1)) : line

  if (kit && typeof kit.Box === 'function' && typeof kit.Text === 'function') {
    return kit.Box({ paddingRight: 2 }, [
      kit.Text({ color: color, wrap: 'truncate-end' }, [clipped]),
    ])
  }
  // Kit unavailable: degrade to a plain string so the band still shows.
  return clipped
}

/** Register the AbovePrompt renderer. `on` is the mod's hook registrar. */
function registerPanel(on) {
  on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => {
    if (e.surface && e.surface !== 'terminal') return next(e)
    let kit = null
    try {
      kit = $.ui.resolve(e)
    } catch (_err) {
      kit = null
    }
    const el = bandFor(kit, e)
    return el !== null ? el : next(e)
  })
}

if (require.main === module) {
  // Direct hook invocation: register against the host-provided registrar API.
  if (typeof globalThis.__ratchetOn === 'function') {
    registerPanel(globalThis.__ratchetOn)
  }
}

module.exports = { registerPanel, bandFor }
