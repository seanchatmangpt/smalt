package storage_test

import (
	"testing"

	"smalt.dev/posh/internal/storage"
)

func TestStorage_CRMHPolicy(t *testing.T) {
	s := storage.NewStore()
	err := s.ProvisionCRMHAccount("rg-test", "stcrmhtest")
	if err != nil {
		t.Fatalf("provision failed: %v", err)
	}

	p, err := s.GetManagementPolicy("rg-test", "stcrmhtest")
	if err != nil {
		t.Fatalf("get policy failed: %v", err)
	}

	if len(p.Rules) != 1 || p.Rules[0].Name != "CRMH-14Day-Retention" {
		t.Fatalf("unexpected rules: %+v", p.Rules)
	}

	rule := p.Rules[0]
	if rule.Definition.Actions.BaseBlob.Delete.DaysAfterModificationGreaterThan != 14 {
		t.Fatalf("expected 14 days, got %d", rule.Definition.Actions.BaseBlob.Delete.DaysAfterModificationGreaterThan)
	}
}

func TestStorage_EventHubDrain(t *testing.T) {
	s := storage.NewStore()
	msg := storage.EventHubMessage{
		Body: []byte("payload"),
		Properties: map[string]string{
			"MatterID": "matter-1",
		},
	}

	err := s.PublishEventHub("rg", "ns", "topic", msg)
	if err != nil {
		t.Fatalf("publish failed: %v", err)
	}

	msgs, err := s.DrainEventHub("rg", "ns", "topic")
	if err != nil {
		t.Fatalf("drain failed: %v", err)
	}

	if len(msgs) != 1 || msgs[0].Properties["MatterID"] != "matter-1" {
		t.Fatalf("unexpected messages: %+v", msgs)
	}
}
