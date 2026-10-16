# 06-lane-cleanup — DoD lane module (owned by its lane; see docs/jira/v26.10.14)
#
# Lane build roots are leases, not assets (operator 2026-10-01 cleanup law).
# Coordinator deletes every lane's build root at integration, BEFORE the final commit.
#
# Canonical build root is `_build`. Every other `_build*` dir in the repo root is
# an orphaned lane lease UNLESS a live process still references it (lsof +D, or
# the cwd of a running beam/elixir process).

ROOT := justfile_directory()
CANONICAL := "_build"

# Shared shell prelude: defines live_refs() and candidates().
# live_refs: _build* basenames referenced by lsof +D or by a beam/elixir cwd.
# candidates: repo-root _build* dirs excluding the canonical _build.
prelude := '''
cd "''' + ROOT + '''" || exit 1
live_refs() {
  {
    lsof +D . 2>/dev/null | awk '{print $NF}' | grep '_build' || true
    for pid in $(pgrep -f 'beam.smp|elixir' 2>/dev/null); do
      lsof -p "$pid" 2>/dev/null | awk '$4 == "cwd" {print $NF}'
    done
  } | while IFS= read -r p; do
    case "$p" in
      ''' + ROOT + '''/_build*) d="${p#''' + ROOT + '''/}"; echo "${d%%/*}" ;;
    esac
  done | sort -u
}
candidates() {
  for d in _build*; do
    [ "$d" = "''' + CANONICAL + '''" ] && continue
    [ -d "$d" ] && printf '%s\n' "$d"
  done
}
'''

# Dry run: list what would go, with du -sh per dir and the total.
lane-clean-dry:
    #!/bin/sh
    {{prelude}}
    live="$(live_refs)"
    total=0
    echo "== lane-clean-dry (root: {{ROOT}}) =="
    for d in $(candidates); do
      case " $live " in
        *" $d "*) echo "SKIP (live-referenced): $d"; continue ;;
      esac
      sz=$(du -sk "$d" 2>/dev/null | cut -f1)
      total=$((total + sz))
      printf '%10s KB  %s\n' "$sz" "$d"
    done
    printf 'TOTAL: %d KB (%.2f GiB)\n' "$total" "$(echo "scale=4; $total/1048576" | bc)"

# Real cleanup: delete orphaned lane build roots; skip live-referenced dirs.
lane-clean:
    #!/bin/sh
    {{prelude}}
    live="$(live_refs)"
    freed=0
    n=0
    for d in $(candidates); do
      case " $live " in
        *" $d "*)
          echo "SKIP (live-referenced): $d"
          continue
          ;;
      esac
      sz=$(du -sk "$d" 2>/dev/null | cut -f1)
      if rm -rf "$d"; then
        freed=$((freed + sz))
        n=$((n + 1))
        echo "DELETED: $d (${sz} KB)"
      else
        echo "FAILED: $d" >&2
      fi
    done
    printf 'DELETED %d dirs, FREED: %d KB (%.2f GiB)\n' "$n" "$freed" "$(echo "scale=4; $freed/1048576" | bc)"
