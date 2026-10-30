package completion

import (
	"fmt"
	"io"
	"strings"
)

// SupportedShells returns the list of supported shell names.
func SupportedShells() []string {
	return []string{"bash", "zsh", "fish"}
}

// Generate writes the completion script for the requested shell to w.
func Generate(shell string, w io.Writer) error {
	switch strings.ToLower(shell) {
	case "bash":
		return GenerateBash(w)
	case "zsh":
		return GenerateZsh(w)
	case "fish":
		return GenerateFish(w)
	default:
		return fmt.Errorf("unsupported shell %q (supported: %s)", shell, strings.Join(SupportedShells(), ", "))
	}
}

// GenerateBash outputs a standard programmable completion script for GNU Bash.
func GenerateBash(w io.Writer) error {
	script := `# bash completion for posh                               -*- shell-script -*-

_posh_completions() {
    local cur prev words cword
    _init_completion -n : || return

    local commands="dev doctor arm tui setup completion replay mock"
    local top_flags="-config -version --help -h"

    if [[ ${cword} -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "${commands} ${top_flags}" -- "${cur}") )
        return 0
    fi

    local command="${words[1]}"
    case "${command}" in
        dev)
            local dev_flags="-config --config -port --port -tui --tui"
            if [[ "${prev}" == "-config" || "${prev}" == "--config" ]]; then
                COMPREPLY=( $(compgen -f -X '!*.yaml' -- "${cur}") )
                return 0
            fi
            COMPREPLY=( $(compgen -W "${dev_flags}" -- "${cur}") )
            return 0
            ;;
        doctor)
            local doc_flags="-config --config -repo-root --repo-root -fix --fix -json --json -strict --strict"
            if [[ "${prev}" == "-config" || "${prev}" == "--config" ]]; then
                COMPREPLY=( $(compgen -f -X '!*.yaml' -- "${cur}") )
                return 0
            elif [[ "${prev}" == "-repo-root" || "${prev}" == "--repo-root" ]]; then
                COMPREPLY=( $(compgen -d -- "${cur}") )
                return 0
            fi
            COMPREPLY=( $(compgen -W "${doc_flags}" -- "${cur}") )
            return 0
            ;;
        tui)
            local tui_flags="-metrics-addr --metrics-addr"
            COMPREPLY=( $(compgen -W "${tui_flags}" -- "${cur}") )
            return 0
            ;;
        setup)
            local setup_flags="-force --force -dry-run --dry-run -repo-root --repo-root"
            COMPREPLY=( $(compgen -W "${setup_flags}" -- "${cur}") )
            return 0
            ;;
        completion)
            local shells="bash zsh fish"
            COMPREPLY=( $(compgen -W "${shells}" -- "${cur}") )
            return 0
            ;;
        *)
            COMPREPLY=( $(compgen -W "${top_flags}" -- "${cur}") )
            return 0
            ;;
    esac
}

complete -F _posh_completions posh
`
	_, err := io.WriteString(w, script)
	return err
}

// GenerateZsh outputs a rich, descriptive completion function for Zsh.
func GenerateZsh(w io.Writer) error {
	script := `#compdef posh
# zsh completion for posh

_posh() {
    local -a commands
    commands=(
        'dev:Start zero-downtime file watching and live UDS socket hot-reload loop'
        'doctor:Run TPS Jidoka diagnostics and mistake-proofing probes'
        'arm:Mint local STS token and query loopback ARM control plane'
        'tui:Launch interactive Charm Bubbletea & Lipgloss telemetry dashboard'
        'setup:Self-healing zero-to-running environment bootstrap'
        'completion:Generate shell autocompletion script (bash, zsh, fish)'
        'replay:Deterministic Time-Travel Replay Debugger for BLAKE3 turnstile validation'
        'mock:Zero-dependency Local Mock ARM Provider for offline Terraform workflows'
    )

    _arguments -C \
        '1: :->command' \
        '*:: :->args'

    case $state in
        command)
            _describe -t commands 'posh subcommands' commands
            _arguments \
                '-config[Path to posh.yaml]:file:_files -g "*.yaml"' \
                '-version[Print stamped version and exit]'
            ;;
        args)
            case $line[1] in
                dev)
                    _arguments \
                        {-config,--config}'[Path to posh.yaml]:file:_files -g "*.yaml"' \
                        {-port,--port}'[TCP bind address]:host:port:' \
                        {-tui,--tui}'[Attach interactive TUI console directly to watch loop]'
                    ;;
                doctor)
                    _arguments \
                        {-config,--config}'[Path to posh.yaml]:file:_files -g "*.yaml"' \
                        {-repo-root,--repo-root}'[Repository root path]:directory:_files -/' \
                        {-fix,--fix}'[Auto-heal stale sockets, dirs, and dev_overrides]' \
                        {-json,--json}'[Emit machine-readable JSON report]' \
                        {-strict,--strict}'[Treat YELLOW advisories as non-zero exit]'
                    ;;
                tui)
                    _arguments \
                        {-metrics-addr,--metrics-addr}'[Prometheus metrics scrape address]:host:port:'
                    ;;
                setup)
                    _arguments \
                        {-force,--force}'[Overwrite existing config templates]' \
                        {-dry-run,--dry-run}'[Print proposed fixes without modifying disk]' \
                        {-repo-root,--repo-root}'[Repository root path]:directory:_files -/'
                    ;;
                completion)
                    _arguments \
                        '1:shell:(bash zsh fish)'
                    ;;
            esac
            ;;
    esac
}

_posh "$@"
`
	_, err := io.WriteString(w, script)
	return err
}

// GenerateFish outputs fish shell completion definitions.
func GenerateFish(w io.Writer) error {
	script := `# fish completion for posh

function __fish_posh_no_subcommand
    for i in (commandline -opc)
        if contains -- $i dev doctor arm tui setup completion replay mock
            return 1
        end
    end
    return 0
end

# Commands
complete -c posh -n "__fish_posh_no_subcommand" -a dev -d "Start zero-downtime file watch & reload loop"
complete -c posh -n "__fish_posh_no_subcommand" -a doctor -d "Run TPS Jidoka health and mistake-proofing probes"
complete -c posh -n "__fish_posh_no_subcommand" -a arm -d "Mint local STS token and query loopback ARM plane"
complete -c posh -n "__fish_posh_no_subcommand" -a tui -d "Launch interactive Bubbletea telemetry dashboard"
complete -c posh -n "__fish_posh_no_subcommand" -a setup -d "Self-healing zero-to-running environment bootstrap"
complete -c posh -n "__fish_posh_no_subcommand" -a completion -d "Generate shell autocompletion script"
complete -c posh -n "__fish_posh_no_subcommand" -a replay -d "Deterministic Time-Travel Replay Debugger"
complete -c posh -n "__fish_posh_no_subcommand" -a mock -d "Zero-dependency Local Mock ARM Provider"
complete -c posh -n "__fish_posh_no_subcommand" -a setup -d "Self-healing environment bootstrap"
complete -c posh -n "__fish_posh_no_subcommand" -a completion -d "Generate shell completion script"

# Top level options
complete -c posh -l config -r -d "Path to posh.yaml"
complete -c posh -l version -d "Print stamped version and exit"

# Dev options
complete -c posh -n "__fish_seen_subcommand_from dev" -l config -r -d "Path to posh.yaml"
complete -c posh -n "__fish_seen_subcommand_from dev" -l tui -d "Attach TUI dashboard to reload loop"
complete -c posh -n "__fish_seen_subcommand_from dev" -l port -r -d "TCP bind address"

# Doctor options
complete -c posh -n "__fish_seen_subcommand_from doctor" -l config -r -d "Path to posh.yaml"
complete -c posh -n "__fish_seen_subcommand_from doctor" -l repo-root -r -d "Path to repository root"
complete -c posh -n "__fish_seen_subcommand_from doctor" -l fix -d "Auto-heal stale sockets and dev_overrides"
complete -c posh -n "__fish_seen_subcommand_from doctor" -l json -d "Emit JSON report"
complete -c posh -n "__fish_seen_subcommand_from doctor" -l strict -d "Treat YELLOW advisories as failure"

# Completion subcommands
complete -c posh -n "__fish_seen_subcommand_from completion" -a "bash zsh fish"
`
	_, err := io.WriteString(w, script)
	return err
}
