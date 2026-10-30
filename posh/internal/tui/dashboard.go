package tui

import (
	"context"
	"fmt"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type tickMsg time.Time

type reloadDoneMsg struct {
	pid int
	dur time.Duration
	err error
}

// DashboardModel implements tea.Model for the POSH developer console.
type DashboardModel struct {
	source        TelemetrySource
	snapshot      TelemetrySnapshot
	width         int
	height        int
	showDoctor    bool
	reloading     bool
	onReload      func(ctx context.Context) error
	logs          []string
	maxLogs       int
	statusMessage string
}

// NewDashboard creates an initialized dashboard model.
func NewDashboard(source TelemetrySource, onReload func(ctx context.Context) error) *DashboardModel {
	return &DashboardModel{
		source:   source,
		onReload: onReload,
		maxLogs:  8,
		logs:     []string{"Console initialized. Watching for UDS membrane events..."},
	}
}

// AddLog appends a timestamped log to the ticker window.
func (m *DashboardModel) AddLog(msg string) {
	ts := time.Now().Format("15:04:05")
	entry := fmt.Sprintf("[%s] %s", ts, msg)
	m.logs = append(m.logs, entry)
	if len(m.logs) > m.maxLogs {
		m.logs = m.logs[len(m.logs)-m.maxLogs:]
	}
}

// Init starts the periodic telemetry tick.
func (m *DashboardModel) Init() tea.Cmd {
	return tea.Tick(250*time.Millisecond, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
}

// Update processes messages, user keystrokes, and telemetry ticks.
func (m *DashboardModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "d":
			m.showDoctor = !m.showDoctor
			return m, nil
		case "c":
			m.logs = nil
			return m, nil
		case "r":
			if m.onReload != nil && !m.reloading {
				m.reloading = true
				m.statusMessage = "Recompiling and reloading..."
				return m, func() tea.Msg {
					t0 := time.Now()
					err := m.onReload(context.Background())
					return reloadDoneMsg{dur: time.Since(t0), err: err}
				}
			}
		}

	case reloadDoneMsg:
		m.reloading = false
		if msg.err != nil {
			m.statusMessage = fmt.Sprintf("Reload failed: %v", msg.err)
			m.AddLog(fmt.Sprintf("ERROR: reload failed (%s)", msg.dur.Round(time.Millisecond)))
		} else {
			m.statusMessage = fmt.Sprintf("Reloaded successfully in %s", msg.dur.Round(time.Millisecond))
			m.AddLog(fmt.Sprintf("Zero-downtime reload completed in %s", msg.dur.Round(time.Millisecond)))
		}
		return m, nil

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case tickMsg:
		if m.source != nil {
			m.snapshot = m.source.Snapshot(context.Background())
		}
		return m, tea.Tick(250*time.Millisecond, func(t time.Time) tea.Msg {
			return tickMsg(t)
		})
	}

	return m, nil
}

// View renders the terminal dashboard.
func (m *DashboardModel) View() string {
	w := m.width
	if w <= 0 {
		w = 80
	}

	var sb strings.Builder

	// Top Title Banner
	title := HeaderStyle.Render(" SMALT POSH MEMBRANE — DEV DASHBOARD ")
	uptime := SubHeaderStyle.Render(fmt.Sprintf(" Uptime: %s ", m.snapshot.Uptime.Round(time.Second)))
	headerBar := lipgloss.JoinHorizontal(lipgloss.Top, title, " ", uptime)
	sb.WriteString(headerBar)
	sb.WriteString("\n\n")

	// Andon Status Strip
	andonBadge := RenderAndonBadge(m.snapshot.AndonStatus)
	sb.WriteString("  ")
	sb.WriteString(andonBadge)
	if m.statusMessage != "" {
		sb.WriteString("  " + SubHeaderStyle.Render(m.statusMessage))
	}
	sb.WriteString("\n\n")

	// Core 3 Metrics Cards (Throughput, Latencies, Connections)
	cardWidth := (w - 8) / 3
	if cardWidth < 22 {
		cardWidth = 22
	}

	// Throughput Card
	tContent := fmt.Sprintf("%s\n%s\n%s",
		MetricTitleStyle.Render("THROUGHPUT"),
		MetricValueStyle.Render(fmt.Sprintf("%6.1f req/s", m.snapshot.ThroughputReqPerSec)),
		SubHeaderStyle.Render(fmt.Sprintf("Total: %d", m.snapshot.TotalRequests)),
	)
	tCard := CardStyle.Width(cardWidth).Render(tContent)

	// Latency Percentiles Card
	formatLatency := func(d time.Duration) string {
		if d == 0 {
			return "--"
		}
		if d < time.Millisecond {
			return fmt.Sprintf("%dµs", d.Microseconds())
		}
		return fmt.Sprintf("%.2fms", float64(d.Microseconds())/1000.0)
	}

	lContent := fmt.Sprintf("%s\n%s\n%s",
		MetricTitleStyle.Render("LATENCY PERCENTILES"),
		MetricValueStyle.Render(fmt.Sprintf("p50: %s  p95: %s",
			formatLatency(m.snapshot.P50Latency),
			formatLatency(m.snapshot.P95Latency))),
		SubHeaderStyle.Render(fmt.Sprintf("p99: %s", formatLatency(m.snapshot.P99Latency))),
	)
	lCard := CardStyle.Width(cardWidth).Render(lContent)

	// Active Connections Card
	cContent := fmt.Sprintf("%s\n%s\n%s",
		MetricTitleStyle.Render("CLIENT CONNS"),
		MetricValueStyle.Render(fmt.Sprintf("%d active UDS", m.snapshot.ActiveConnections)),
		SubHeaderStyle.Render("Wire: v1 (Length+JSON)"),
	)
	cCard := CardStyle.Width(cardWidth).Render(cContent)

	cardsRow := lipgloss.JoinHorizontal(lipgloss.Top, "  ", tCard, " ", lCard, " ", cCard)
	sb.WriteString(cardsRow)
	sb.WriteString("\n\n")

	// Middle Section: Toggle between Doctor Probes and Event Log
	if m.showDoctor {
		sb.WriteString("  " + MetricTitleStyle.Render("TPS SYSTEM DOCTOR (JIDOKA PROBES):") + "\n")
		for _, p := range m.snapshot.DoctorProbes {
			statusColor := ColorGreen
			switch p.Status {
			case "YELLOW":
				statusColor = ColorYellow
			case "RED":
				statusColor = ColorRed
			}
			badge := lipgloss.NewStyle().Foreground(statusColor).Render(fmt.Sprintf("[%-6s]", p.Status))
			sb.WriteString(fmt.Sprintf("   %s %-18s (%5.1fms)  %s\n", badge, p.ID, p.DurationMs, p.Summary))
		}
	} else {
		sb.WriteString("  " + MetricTitleStyle.Render("EVENT LOG / RELOAD STREAM:") + "\n")
		if len(m.logs) == 0 {
			sb.WriteString("   " + SubHeaderStyle.Render("(no recent events)") + "\n")
		} else {
			for _, l := range m.logs {
				sb.WriteString("   " + l + "\n")
			}
		}
	}

	sb.WriteString("\n")

	// Bottom Keymap Help Footer
	footer := fmt.Sprintf("  %s %s  •  %s %s  •  %s %s  •  %s %s",
		KeyStyle.Render("r"), KeyDescStyle.Render("recompile"),
		KeyStyle.Render("d"), KeyDescStyle.Render("toggle doctor"),
		KeyStyle.Render("c"), KeyDescStyle.Render("clear logs"),
		KeyStyle.Render("q"), KeyDescStyle.Render("quit"),
	)
	sb.WriteString(footer)
	sb.WriteString("\n")

	return sb.String()
}
