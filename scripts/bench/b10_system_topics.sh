#!/usr/bin/env bash
# scripts/bench/b10_system_topics.sh — lane b10 witness: systemTopics ARM family
# (PUT 201 -> GET 200 -> LIST -> DELETE -> 404) plus the eventSubscriptions
# child face (in-proc admitted / WebHook destination typed-refused per KD-101).
#
# Auth: :enforce (default config.exs mode — NOT the MIX_ENV=test anonymous
# bench boot); bearer minted from the emulator STS /{tid}/oauth2/v2.0/token.
#
# Port law: lane b10 -> 39100..39105 (39000 + 10*10).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" /../../ 2>/dev/null; pwd)"
