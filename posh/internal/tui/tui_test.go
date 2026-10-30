package tui

import (
	"context"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"smalt.dev/posh/internal/doctor"
)

type mockTelemetrySource struct {
	snap TelemetrySnapshot
}

func (m *mockTelemetrySource) Snapshot(ctx context.Context) TelemetrySnapshot {
	return m.snap
}

func TestDashboardModelView(t *testing.T) {
	mock := &mockTelemetrySource{
		snap: TelemetrySnapshot{
			AndonStatus:         "GREEN",
			ThroughputReqPerSec: 142.5,
			TotalRequests:       9876,
			P50Latency:          120 * time.Microsecond,
			P95Latency:          380 * time.Microsecond,
			P99Latency:          1200 * time.Microsecond,
			ActiveConnections:   4,
			Uptime:              15 * time.Minute,
			DoctorProbes: []doctor.ProbeResult{
				{ID: "egress-allowlist", Status: "GREEN", DurationMs: 1.2, Summary: "allowlist valid"},
			},
		},
	}

	model := NewDashboard(mock, nil)
	model.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	model.Update(tickMsg(time.Now()))

	view := model.View()

	if !strings.Contains(view, "SMALT POSH MEMBRANE") {
		t.Errorf("view missing header title")
	}
	if !strings.Contains(view, "ANDON GREEN") {
		t.Errorf("view missing Andon green status")
	}
	if !strings.Contains(view, "142.5 req/s") {
		t.Errorf("view missing throughput metric")
	}
	if !strings.Contains(view, "4 active UDS") {
		t.Errorf("view missing active connection count")
	}
}

func TestDashboardKeyNavigation(t *testing.T) {
	model := NewDashboard(&mockTelemetrySource{}, nil)

	// Test 'd' toggle doctor
	if model.showDoctor {
		t.Errorf("expected showDoctor to start false")
	}
	model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'d'}})
	if !model.showDoctor {
		t.Errorf("expected showDoctor to be true after 'd'")
	}
	model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'d'}})
	if model.showDoctor {
		t.Errorf("expected showDoctor to be false after second 'd'")
	}

	// Test 'c' clear logs
	model.AddLog("test log 1")
	model.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'c'}})
	if len(model.logs) != 0 {
		t.Errorf("expected logs to be empty after 'c'")
	}
}
