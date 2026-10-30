package storage

import (
	"fmt"
	"sync"
)

// BlobManagementPolicy represents Azure Storage Blob Management lifecycle policies.
type BlobManagementPolicy struct {
	Rules []ManagementPolicyRule `json:"rules"`
}

// ManagementPolicyRule defines an individual lifecycle rule.
type ManagementPolicyRule struct {
	Name       string                     `json:"name"`
	Definition ManagementPolicyDefinition `json:"definition"`
}

// ManagementPolicyDefinition binds actions and filters.
type ManagementPolicyDefinition struct {
	Actions ManagementPolicyActions `json:"actions"`
	Filters ManagementPolicyFilters `json:"filters"`
}

// ManagementPolicyActions groups target blob actions.
type ManagementPolicyActions struct {
	BaseBlob BaseBlobActions `json:"baseBlob"`
}

// BaseBlobActions defines lifecycle operations on base blobs.
type BaseBlobActions struct {
	Delete DeleteAction `json:"delete"`
}

// DeleteAction specifies retention expiration.
type DeleteAction struct {
	DaysAfterModificationGreaterThan int `json:"daysAfterModificationGreaterThan"`
}

// ManagementPolicyFilters specifies blob matching criteria.
type ManagementPolicyFilters struct {
	BlobTypes   []string `json:"blobTypes"`
	PrefixMatch []string `json:"prefixMatch"`
}

// EventHubMessage captures an audited event stored in an Event Hub partition.
type EventHubMessage struct {
	Body       []byte            `json:"body"`
	Properties map[string]string `json:"properties"`
}

// Store maintains in-memory state for CRMH storage accounts and Event Hub partitions.
type Store struct {
	mu            sync.RWMutex
	policies      map[string]*BlobManagementPolicy
	eventHubQueues map[string][]EventHubMessage
}

// NewStore initializes a storage store.
func NewStore() *Store {
	return &Store{
		policies:      make(map[string]*BlobManagementPolicy),
		eventHubQueues: make(map[string][]EventHubMessage),
	}
}

// ProvisionCRMHAccount configures the 14-day retention lifecycle policy on an account.
func (s *Store) ProvisionCRMHAccount(resourceGroup, accountName string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	key := fmt.Sprintf("%s/%s", resourceGroup, accountName)
	policy := &BlobManagementPolicy{
		Rules: []ManagementPolicyRule{
			{
				Name: "CRMH-14Day-Retention",
				Definition: ManagementPolicyDefinition{
					Actions: ManagementPolicyActions{
						BaseBlob: BaseBlobActions{
							Delete: DeleteAction{
								DaysAfterModificationGreaterThan: 14,
							},
						},
					},
					Filters: ManagementPolicyFilters{
						BlobTypes:   []string{"blockBlob"},
						PrefixMatch: []string{"crmh/daily-exports/"},
					},
				},
			},
		},
	}
	s.policies[key] = policy
	return nil
}

// GetManagementPolicy retrieves the active lifecycle management policy for a storage account.
func (s *Store) GetManagementPolicy(resourceGroup, accountName string) (*BlobManagementPolicy, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	key := fmt.Sprintf("%s/%s", resourceGroup, accountName)
	p, ok := s.policies[key]
	if !ok {
		return nil, fmt.Errorf("management policy not found for %s", key)
	}
	return p, nil
}

// PublishEventHub records an audited message to an Event Hub partition queue.
func (s *Store) PublishEventHub(resourceGroup, namespace, topic string, msg EventHubMessage) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	key := fmt.Sprintf("%s/%s/%s", resourceGroup, namespace, topic)
	s.eventHubQueues[key] = append(s.eventHubQueues[key], msg)
	return nil
}

// DrainEventHub reads and clears (or inspects) all published messages from an Event Hub partition.
func (s *Store) DrainEventHub(resourceGroup, namespace, topic string) ([]EventHubMessage, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	key := fmt.Sprintf("%s/%s/%s", resourceGroup, namespace, topic)
	msgs, ok := s.eventHubQueues[key]
	if !ok || len(msgs) == 0 {
		return nil, fmt.Errorf("no messages found in event hub partition %s", key)
	}

	copied := make([]EventHubMessage, len(msgs))
	copy(copied, msgs)
	return copied, nil
}
