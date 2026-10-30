package doctor

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// JSONLDCausalNode represents a single step in a 5-Whys causal analysis graph.
type JSONLDCausalNode struct {
	ID        string `json:"@id"`
	Type      string `json:"@type"`
	WhyIndex  int    `json:"dflss:whyIndex"`
	Statement string `json:"dflss:statement"`
	CausedBy  string `json:"prov:wasDerivedFrom,omitempty"`
}

// JSONLDProbeReport represents a single probe result mapped into the DfSS / RDF schema.
type JSONLDProbeReport struct {
	ID              string             `json:"@id"`
	Type            string             `json:"@type"`
	ProbeID         string             `json:"dflss:probeId"`
	Status          string             `json:"tps:status"`
	DurationMs      float64            `json:"dflss:durationMs"`
	Invariant       string             `json:"tps:invariant"`
	Summary         string             `json:"dflss:summary"`
	WhatBroke       string             `json:"dflss:whatBroke,omitempty"`
	CausalChain     []JSONLDCausalNode `json:"dflss:causalChain,omitempty"`
	PrescriptionCmd string             `json:"dflss:prescriptionCmd,omitempty"`
	Fixed           bool               `json:"dflss:fixed"`
	FixAction       string             `json:"dflss:fixAction,omitempty"`
	Telemetry       any                `json:"dflss:telemetry,omitempty"`
}

// JSONLDDiagnosticAudit is the top-level RDF JSON-LD diagnostic document.
type JSONLDDiagnosticAudit struct {
	Context         map[string]any      `json:"@context"`
	ID              string              `json:"@id"`
	Type            []string            `json:"@type"`
	WorkOrderID     string              `json:"sj:workOrderId,omitempty"`
	SubjectSHA      string              `json:"chatman:subjectSha,omitempty"`
	Timestamp       string              `json:"prov:generatedAtTime"`
	OverallStatus   string              `json:"tps:overallStatus"`
	TotalDurationMs float64             `json:"dflss:totalDurationMs"`
	FixedCount      int                 `json:"dflss:fixedCount"`
	Probes          []JSONLDProbeReport `json:"dflss:probes"`
}

// buildCausalChain decomposes a 5-Whys string or causal statement into linked RDF nodes.
func buildCausalChain(probeID, whatBroke, rootCause string) []JSONLDCausalNode {
	if whatBroke == "" && rootCause == "" {
		return nil
	}

	var steps []string
	if whatBroke != "" {
		steps = append(steps, "Symptom: "+whatBroke)
	}

	// If root cause contains multiple sentences or semicolons, split them into causal steps
	parts := strings.Split(rootCause, ";")
	for _, p := range parts {
		trimmed := strings.TrimSpace(p)
		if trimmed != "" {
			steps = append(steps, trimmed)
		}
	}

	if len(steps) == 0 {
		return nil
	}

	nodes := make([]JSONLDCausalNode, len(steps))
	for i, step := range steps {
		nodeID := fmt.Sprintf("urn:smalt:doctor:probe:%s:why:%d", probeID, i+1)
		node := JSONLDCausalNode{
			ID:        nodeID,
			Type:      "dflss:CausalNode",
			WhyIndex:  i + 1,
			Statement: step,
		}
		if i > 0 {
			node.CausedBy = nodes[i-1].ID
		}
		nodes[i] = node
	}
	return nodes
}

// FormatJSONLD renders a Report as a JSON-LD 1.1 / RDF audit document binding to DfCM WorkOrders.
func FormatJSONLD(rep Report, workOrderID, subjectSHA string) ([]byte, error) {
	ctxMap := map[string]any{
		"@vocab":          "https://smalt.dev/ontology/doctor#",
		"sj":              "https://chatmangpt.com/schema/sj#",
		"dflss":           "https://smalt.dev/schema/dflss#",
		"tps":             "https://smalt.dev/schema/tps#",
		"chatman":         "https://chatmangpt.com/schema/receipt/v2#",
		"prov":            "http://www.w3.org/ns/prov#",
		"xsd":             "http://www.w3.org/2001/XMLSchema#",
		"overallStatus":   map[string]any{"@id": "tps:overallStatus", "@type": "xsd:string"},
		"probes":          map[string]any{"@id": "dflss:probes", "@container": "@set"},
		"causalChain":     map[string]any{"@id": "dflss:causalChain", "@container": "@list"},
		"wasDerivedFrom":  map[string]any{"@id": "prov:wasDerivedFrom", "@type": "@id"},
		"generatedAtTime": map[string]any{"@id": "prov:generatedAtTime", "@type": "xsd:dateTime"},
	}

	reportTime := rep.Timestamp
	if reportTime == "" {
		reportTime = time.Now().UTC().Format(time.RFC3339)
	}

	probeReports := make([]JSONLDProbeReport, len(rep.Probes))
	for i, p := range rep.Probes {
		chain := buildCausalChain(p.ID, p.WhatBroke, p.RootCause5Whys)
		probeReports[i] = JSONLDProbeReport{
			ID:              fmt.Sprintf("urn:smalt:doctor:probe:%s", p.ID),
			Type:            "dflss:HealthProbe",
			ProbeID:         p.ID,
			Status:          p.Status,
			DurationMs:      p.DurationMs,
			Invariant:       p.Invariant,
			Summary:         p.Summary,
			WhatBroke:       p.WhatBroke,
			CausalChain:     chain,
			PrescriptionCmd: p.PrescriptionCmd,
			Fixed:           p.Fixed,
			FixAction:       p.FixAction,
			Telemetry:       p.Telemetry,
		}
	}

	doc := JSONLDDiagnosticAudit{
		Context:         ctxMap,
		ID:              fmt.Sprintf("urn:smalt:doctor:audit:%d", time.Now().UnixNano()),
		Type:            []string{"dflss:DiagnosticAudit", "sj:WorkOrderAudit"},
		WorkOrderID:     workOrderID,
		SubjectSHA:      subjectSHA,
		Timestamp:       reportTime,
		OverallStatus:   rep.OverallStatus,
		TotalDurationMs: rep.TotalDurationMs,
		FixedCount:      rep.FixedCount,
		Probes:          probeReports,
	}

	return json.MarshalIndent(doc, "", "  ")
}
