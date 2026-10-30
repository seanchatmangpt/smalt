# posh.bash — bash completion for the posh/provider `just` recipe family
# (gaps/64, v26.10.30 wave, lane 11/16). Default-off; opt-in install:
#
#   source /path/to/smalt/posh/completions/posh.bash
#   # or persist:
#   echo 'source ~/smalt/posh/completions/posh.bash' >> ~/.bashrc
#
# After sourcing, `just posh-<TAB>` completes the posh/provider recipe names
# (simple compgen over `just --list`; falls back to just's own completion
# behavior for non-posh prefixes — the _posh_just completion is registered
# per-word-list-posh: only kicks in when the first word starts with "posh").
#
# Exit/behavior contract: none — pure completion, no side effects.

_posh_just() {
  local cur prev recipes
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  # Only own the completion when completing the recipe word and it looks
  # posh (first recipe word starts with posh/provider/compat/tf-).
  if [ "$COMP_CWORD" -eq 1 ]; then
    case "$cur" in
      posh-*|provider-*|compat-*|tf-*)
        recipes="$(just --list 2>/dev/null | awk '{print $1}' \
          | grep -E '^(posh|provider|compat|tf-)' )"
        COMPREPLY=( $(compgen -W "$recipes" -- "$cur") )
        return 0
        ;;
    esac
  fi
  return 0
}
complete -o default -F _posh_just just
