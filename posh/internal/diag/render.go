package diag

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

// Render formats the diagnostic into a human-centered Rust/Elm-style diagnostic block.
func (d *Diagnostic) Render(cfg ColorConfig) string {
	useColor := ShouldUseColor(cfg)

	// Style helpers
	colorSeverity := func(s string) string {
		if !useColor {
			return s
		}
		switch d.Severity {
		case SeverityError:
			return ansiRed + s + ansiReset
		case SeverityWarning:
			return ansiYellow + s + ansiReset
		case SeverityHelp, SeverityNote:
			return ansiCyan + s + ansiReset
		default:
			return s
		}
	}

	bold := func(s string) string {
		if !useColor {
			return s
		}
		return ansiBold + s + ansiReset
	}

	blue := func(s string) string {
		if !useColor {
			return s
		}
		return ansiBlue + s + ansiReset
	}

	cyan := func(s string) string {
		if !useColor {
			return s
		}
		return ansiCyan + s + ansiReset
	}

	green := func(s string) string {
		if !useColor {
			return s
		}
		return ansiGreen + s + ansiReset
	}

	gutter := func(s string) string {
		if !useColor {
			return s
		}
		return ansiGutter + s + ansiReset
	}

	var sb strings.Builder

	// Header line: error[E0101]: egress request refused
	sb.WriteString(colorSeverity(fmt.Sprintf("%s[%s]", d.Severity, d.Code)))
	sb.WriteString(": ")
	sb.WriteString(bold(d.Title))
	sb.WriteString("\n")

	// Location pointer:  --> posh.yaml:12:5
	if d.Span.File != "" {
		sb.WriteString(blue("  --> "))
		if d.Span.Line > 0 {
			if d.Span.Col > 0 {
				sb.WriteString(fmt.Sprintf("%s:%d:%d", d.Span.File, d.Span.Line, d.Span.Col))
			} else {
				sb.WriteString(fmt.Sprintf("%s:%d", d.Span.File, d.Span.Line))
			}
		} else {
			sb.WriteString(d.Span.File)
		}
		sb.WriteString("\n")
	}

	// Code snippet rendering
	if d.Span.File != "" && d.Span.Line > 0 {
		snippetLines, startLine := readContextLines(d.Span.File, d.Span.Line, 2, d.CustomSnippet)
		if len(snippetLines) > 0 {
			maxLineNum := startLine + len(snippetLines) - 1
			gutterWidth := len(fmt.Sprintf("%d", maxLineNum))
			if gutterWidth < 2 {
				gutterWidth = 2
			}
			emptyGutter := strings.Repeat(" ", gutterWidth)

			sb.WriteString(gutter(fmt.Sprintf("%s │\n", emptyGutter)))

			for i, line := range snippetLines {
				currLineNum := startLine + i
				isTarget := currLineNum == d.Span.Line

				lineGutter := fmt.Sprintf("%*d", gutterWidth, currLineNum)
				sb.WriteString(gutter(fmt.Sprintf("%s │ ", lineGutter)))
				sb.WriteString(line)
				sb.WriteString("\n")

				if isTarget {
					sb.WriteString(gutter(fmt.Sprintf("%s │ ", emptyGutter)))
					col := d.Span.Col
					if col < 1 {
						col = 1
					}
					length := d.Span.Length
					if length < 1 {
						length = 1
					}

					prefixSpaces := col - 1
					if prefixSpaces > len(line) {
						prefixSpaces = len(line)
					}
					sb.WriteString(strings.Repeat(" ", prefixSpaces))

					carets := strings.Repeat("^", length)
					if useColor {
						carets = ansiUnderline + carets + ansiReset
					}
					sb.WriteString(carets)

					if d.HighlightMessage != "" {
						sb.WriteString(" ")
						if useColor {
							sb.WriteString(ansiRed + d.HighlightMessage + ansiReset)
						} else {
							sb.WriteString(d.HighlightMessage)
						}
					}
					sb.WriteString("\n")
				}
			}
			sb.WriteString(gutter(fmt.Sprintf("%s │\n", emptyGutter)))
		}
	}

	// Invariant
	if d.Invariant != "" {
		sb.WriteString(blue("   = "))
		sb.WriteString(bold("invariant: "))
		sb.WriteString(d.Invariant)
		sb.WriteString("\n")
	}

	// 5-Whys
	if d.RootCause5Whys != "" {
		sb.WriteString(blue("   = "))
		sb.WriteString(cyan("5-whys: "))
		sb.WriteString(d.RootCause5Whys)
		sb.WriteString("\n")
	}

	// Help
	if d.Help != "" {
		sb.WriteString(blue("   = "))
		sb.WriteString(green("help: "))
		sb.WriteString(d.Help)
		sb.WriteString("\n")
	}

	// Fix command
	if d.FixCommand != "" {
		sb.WriteString(blue("   = "))
		sb.WriteString(bold("remediation: "))
		if useColor {
			sb.WriteString(ansiWhite + d.FixCommand + ansiReset)
		} else {
			sb.WriteString(d.FixCommand)
		}
		sb.WriteString("\n")
	}

	return sb.String()
}

// readContextLines reads source lines surrounding targetLine.
func readContextLines(filePath string, targetLine, contextWindow int, customSnippet string) ([]string, int) {
	var lines []string

	if customSnippet != "" {
		scanner := bufio.NewScanner(strings.NewReader(customSnippet))
		for scanner.Scan() {
			lines = append(lines, scanner.Text())
		}
	} else {
		f, err := os.Open(filePath)
		if err != nil {
			return nil, 0
		}
		defer f.Close()

		scanner := bufio.NewScanner(f)
		for scanner.Scan() {
			lines = append(lines, scanner.Text())
		}
	}

	if len(lines) == 0 {
		return nil, 0
	}

	start := targetLine - 1 - contextWindow
	if start < 0 {
		start = 0
	}
	end := targetLine - 1 + contextWindow + 1
	if end > len(lines) {
		end = len(lines)
	}

	if start >= end {
		return nil, 0
	}

	return lines[start:end], start + 1
}
