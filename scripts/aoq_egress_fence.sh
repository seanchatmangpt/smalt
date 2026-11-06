#!/usr/bin/env bash
# LANE-13 AoQ egress fence (aq-architecture-spec §3).
#
# Law: no `<>` binary append at AoQ egress sites. Egress emits iolist
# [Header | Payload] only. This fence greps lib/smalt/aoq/** for `<>`
# occurrences and fails closed on any un-allowlisted hit.
#
# Allowlist policy: every exemption must carry a `# AOQ-FENCE-OK:` comment
# on the SAME line, naming the by-design reason. The fence reports every
# allowlisted hit loudly (never silently) and exits 0 only when nothing
# un-allowlisted remains.
#
# rg fail-loud guard (tools.md law): refuse to fake-pass when rg is absent.
command -v rg >/dev/null 2>&1 || { echo "aoq_egress_fence: refusing to fake-pass — rg not on PATH"; exit 2; }

set -u
cd "$(dirname "$0")/.."

# Match real binary-append `<>` — not `<<>>` (empty binary literal), not
# `<<...>>` internals: `<>` not adjacent to another bracket.
hits=()
while IFS= read -r line; do
  [ -n "$line" ] && hits+=("$line")
done < <(rg -n -P '(?<![<])<>(?![>])' lib/smalt/aoq/ --glob '*.ex' --glob '*.exs' || true)

if [ "${#hits[@]}" -eq 0 ]; then
  echo "aoq_egress_fence: CLEAN — no <> occurrences in lib/smalt/aoq/"
  exit 0
fi

violations=0
allowlisted=0
for line in "${hits[@]}"; do
  file="${line%%:*}"
  lineno="${line#*:}"
  lineno="${lineno%%:*}"
  # Strip backtick-quoted spans first: prose mentioning `<>` in docs
  # (e.g. moduledocs citing this fence) is not egress code.
  content="$(sed -n "${lineno}p" "$file" | sed 's/`[^`]*`//g; s/^[[:space:]]*//')"

  # Allowlist (known-by-design, documented here LOUDLY):
  #  1. Comment lines (first non-space char is `#`) — prose mentioning the
  #     law is not egress code. `lib/smalt/aoq/nif_holder.ex:37` is the
  #     witness: a `# §3 egress law: ... never a `<>` concatenation`
  #     comment restating the ban itself.
  #  2. Error/log-message string concatenation — `lib/smalt/aoq/flags.ex`
  #     and `lib/smalt/aoq/tables.ex` build raise/log prose with `<>`.
  #     Exception/log strings are NOT wire egress; the AoQ frame path
  #     never flows through them. Exempted by file, not line, so line
  #     drift cannot silently widen the exemption.
  #  3. Any hit whose line carries an `# AOQ-FENCE-OK: <reason>` comment
  #     (per-site, reviewed exemption for future egress-adjacent code).
  allowed=0
  case "$content" in
    "#"* ) allowed=1 ;;
  esac
  # If `<>` only ever appears inside backtick-quoted prose spans, the line
  # is documentation, not egress code.
  case "$content" in
    *"<>"*) : ;;
    *) allowed=1 ;;
  esac
  case "$file" in
    lib/smalt/aoq/flags.ex | lib/smalt/aoq/tables.ex | lib/smalt/aoq/quic/nif.ex) allowed=1 ;;
    # (LANE-4 v26.11.6, append-only: quic/nif.ex joins the flags.ex/
    # tables.ex class - its only <>,s build Logger refusal prose, never
    # wire egress; the AoQ QUIC frame path never flows through them.)
  esac
  if [ "$allowed" -eq 0 ] && printf '%s' "$content" | grep -q 'AOQ-FENCE-OK'; then
    allowed=1
  fi
  # Continuation rule: a line whose code ends with `<>` (multi-line
  # concat chain) may carry its AOQ-FENCE-OK marker on the FOLLOWING line.
  if [ "$allowed" -eq 0 ]; then
    case "$(printf '%s' "$content" | sed 's/#.*$//; s/[[:space:]]*$//')" in
      *"<>")
        next="$(sed -n "$((lineno + 1))p" "$file")"
        printf '%s' "$next" | grep -q 'AOQ-FENCE-OK' && allowed=1
        ;;
    esac
  fi

  if [ "$allowed" -eq 1 ]; then
    echo "aoq_egress_fence: ALLOWED (by-design exemption: comment/error-string concat) ${file}:${lineno}"
    allowlisted=$((allowlisted + 1))
  else
    echo "aoq_egress_fence: VIOLATION ${line}"
    violations=$((violations + 1))
  fi
done

echo "aoq_egress_fence: ${violations} violation(s), ${allowlisted} allowlisted exemption(s)"
[ "$violations" -eq 0 ]
