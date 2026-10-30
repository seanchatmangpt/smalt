package diag

import (
	"fmt"
	"os"
)

// Severity indicates the seriousness of the diagnostic.
type Severity int

const (
	SeverityError Severity = iota
	SeverityWarning
	SeverityNote
	SeverityHelp
)

func (s Severity) String() string {
	switch s {
	case SeverityError:
		return "error"
	case SeverityWarning:
		return "warning"
	case SeverityNote:
		return "note"
	case SeverityHelp:
		return "help"
	default:
		return "unknown"
	}
}

// Span marks the exact source code location of an issue.
type Span struct {
	File   string `json:"file"`
	Line   int    `json:"line"`
	Col    int    `json:"col"`
	Length int    `json:"length"`
}

// Diagnostic represents an Elm/Rust-style actionable compiler or runtime error.
type Diagnostic struct {
	Code             string   `json:"code"`              // E.g. "E0101"
	Severity         Severity `json:"severity"`          // Error, Warning, etc.
	Title            string   `json:"title"`             // Concise summary
	Span             Span     `json:"span"`              // Exact file:line:col
	HighlightMessage string   `json:"highlight_message"` // Message attached directly to the caret/underline
	Invariant        string   `json:"invariant"`         // SPAF/POSH charter invariant violated
	RootCause5Whys   string   `json:"root_cause_5_whys"` // 5-Whys causal root breakdown
	Help             string   `json:"help"`              // Actionable guidance
	FixCommand       string   `json:"fix_command"`       // Exact copy-paste shell command
	DocURL           string   `json:"doc_url,omitempty"` // Reference link
	CustomSnippet    string   `json:"-"`                 // Optional overridden snippet for virtual sources
}

// New creates an Error-severity diagnostic with the given code and title.
func New(code, title string) *Diagnostic {
	return &Diagnostic{
		Code:     code,
		Severity: SeverityError,
		Title:    title,
	}
}

// WithSpan attaches the source span.
func (d *Diagnostic) WithSpan(file string, line, col, length int) *Diagnostic {
	d.Span = Span{File: file, Line: line, Col: col, Length: length}
	return d
}

// WithHighlight attaches the inline caret message.
func (d *Diagnostic) WithHighlight(msg string) *Diagnostic {
	d.HighlightMessage = msg
	return d
}

// WithInvariant documents the system invariant violated.
func (d *Diagnostic) WithInvariant(inv string) *Diagnostic {
	d.Invariant = inv
	return d
}

// WithWhy documents the 5-Whys causal chain.
func (d *Diagnostic) WithWhy(why string) *Diagnostic {
	d.RootCause5Whys = why
	return d
}

// WithHelp documents the explanation and fix strategy.
func (d *Diagnostic) WithHelp(help string) *Diagnostic {
	d.Help = help
	return d
}

// WithFixCommand provides the verbatim copy-paste remediation command.
func (d *Diagnostic) WithFixCommand(cmd string) *Diagnostic {
	d.FixCommand = cmd
	return d
}

// WithCustomSnippet overrides disk file reading with a provided snippet.
func (d *Diagnostic) WithCustomSnippet(snippet string) *Diagnostic {
	d.CustomSnippet = snippet
	return d
}

// Error implements the standard error interface.
func (d *Diagnostic) Error() string {
	if d.Span.File != "" && d.Span.Line > 0 {
		return fmt.Sprintf("%s[%s]: %s (%s:%d:%d)", d.Severity, d.Code, d.Title, d.Span.File, d.Span.Line, d.Span.Col)
	}
	return fmt.Sprintf("%s[%s]: %s", d.Severity, d.Code, d.Title)
}

// ColorConfig controls ANSI styling.
type ColorConfig struct {
	NoColor    bool
	ForceColor bool
}

// ShouldUseColor evaluates NO_COLOR environment standard and overrides.
func ShouldUseColor(cfg ColorConfig) bool {
	if cfg.ForceColor {
		return true
	}
	if cfg.NoColor || os.Getenv("NO_COLOR") != "" || os.Getenv("TERM") == "dumb" {
		return false
	}
	return true
}

const (
	ansiReset     = "\033[0m"
	ansiBold      = "\033[1m"
	ansiRed       = "\033[1;31m"
	ansiYellow    = "\033[1;33m"
	ansiGreen     = "\033[1;32m"
	ansiCyan      = "\033[1;36m"
	ansiBlue      = "\033[1;34m"
	ansiGutter    = "\033[38;5;244m"
	ansiUnderline = "\033[1;31m"
	ansiWhite     = "\033[1;37m"
	ansiLightGray = "\033[38;5;250m"
)
