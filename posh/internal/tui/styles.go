package tui

import (
	"github.com/charmbracelet/lipgloss"
)

var (
	// Brand and Accent colors
	ColorPrimary   = lipgloss.Color("#00D7D7") // Cyan
	ColorSecondary = lipgloss.Color("#7D56F4") // Purple
	ColorDim       = lipgloss.Color("#626262") // Gray
	ColorHighlight = lipgloss.Color("#FFFFFF") // White

	// Andon Signal Colors (TPS Visual Board)
	ColorGreen  = lipgloss.Color("#04B575") // Bright Green
	ColorYellow = lipgloss.Color("#FFAF00") // Warm Amber
	ColorRed    = lipgloss.Color("#FF4444") // Alert Red

	// Header & Title
	HeaderStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(ColorHighlight).
			Background(ColorSecondary).
			Padding(0, 1)

	SubHeaderStyle = lipgloss.NewStyle().
			Foreground(ColorDim).
			Italic(true)

	// Card Box
	CardStyle = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(ColorPrimary).
			Padding(0, 1)

	// Metric Titles & Values
	MetricTitleStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(ColorDim)

	MetricValueStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(ColorHighlight)

	// Andon Badges
	AndonGreenBadge = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("#000000")).
			Background(ColorGreen).
			Padding(0, 1)

	AndonYellowBadge = lipgloss.NewStyle().
				Bold(true).
				Foreground(lipgloss.Color("#000000")).
				Background(ColorYellow).
				Padding(0, 1)

	AndonRedBadge = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("#FFFFFF")).
			Background(ColorRed).
			Padding(0, 1)

	// Keymap Footer
	KeyStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(ColorPrimary)

	KeyDescStyle = lipgloss.NewStyle().
			Foreground(ColorDim)
)

// RenderAndonBadge returns a styled badge for the given Andon status string.
func RenderAndonBadge(status string) string {
	switch status {
	case "GREEN":
		return AndonGreenBadge.Render("● ANDON GREEN (NOMINAL)")
	case "YELLOW":
		return AndonYellowBadge.Render("▲ ANDON YELLOW (ADVISORY)")
	case "RED":
		return AndonRedBadge.Render("■ ANDON RED (LINE HALTED)")
	default:
		return lipgloss.NewStyle().Background(ColorDim).Render(status)
	}
}
