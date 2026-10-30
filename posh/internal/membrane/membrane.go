package membrane

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"smalt.dev/posh/internal/court"
	"smalt.dev/posh/internal/receipt"
	"smalt.dev/posh/internal/storage"
)

// TenantStateFixture defines the inputs for provisioning tenant and matter infrastructure.
type TenantStateFixture struct {
	TenantID      string `json:"tenant_id"`
	MatterID      string `json:"matter_id"`
	ResourceGroup string `json:"resource_group"`
	VNetID        string `json:"vnet_id"`
	AppID         string `json:"app_id,omitempty"`
}

// Receipt represents a cryptographically verified turnstile settlement receipt.
type Receipt struct {
	ReceiptID  string `json:"receipt_id"`
	BLAKE3Hash string `json:"blake3_hash"`
	Timestamp  uint64 `json:"timestamp"`
}

// ResourceGroupState represents the actual wire/state representation of an ARM Resource Group.
type ResourceGroupState struct {
	ID   string            `json:"id"`
	Name string            `json:"name"`
	Tags map[string]string `json:"tags"`
}

// ContainerAppState represents the deployed state of an Azure Container App instance.
type ContainerAppState struct {
	InstanceCount int                  `json:"instance_count"`
	Template      ContainerAppTemplate `json:"template"`
}

// ContainerAppTemplate groups the co-located containers and pod settings.
type ContainerAppTemplate struct {
	Containers      []ContainerSpec          `json:"containers"`
	SharingSettings ContainerSharingSettings `json:"sharing_settings"`
}

// ContainerSpec defines an individual container definition.
type ContainerSpec struct {
	Name  string `json:"name"`
	Image string `json:"image"`
}

// ContainerSharingSettings models pod-level networking sharing.
type ContainerSharingSettings struct {
	LocalhostNetworking bool `json:"localhost_networking"`
}

// SmaltTestEnvironment serves as the stateful in-memory and loopback Chicago testbed.
type SmaltTestEnvironment struct {
	mu             sync.RWMutex
	resourceGroups map[string]ResourceGroupState
	containerApps  map[string]ContainerAppState
	vnetTenants    map[string]string
	storageStore   *storage.Store
	keyVaultSecrets map[string]string
}

// NewSmaltTestEnvironment initializes a clean Chicago-style test harness.
func NewSmaltTestEnvironment() *SmaltTestEnvironment {
	return &SmaltTestEnvironment{
		resourceGroups: make(map[string]ResourceGroupState),
		containerApps:  make(map[string]ContainerAppState),
		vnetTenants:    make(map[string]string),
		storageStore:   storage.NewStore(),
		keyVaultSecrets: make(map[string]string),
	}
}

// ApplyTenantConfig applies the tenant matter configuration, enforcing dedicated boundaries
// and issuing a mathematical BLAKE3 turnstile settlement receipt.
func (e *SmaltTestEnvironment) ApplyTenantConfig(ctx context.Context, fixture TenantStateFixture) (*Receipt, error) {
	e.mu.Lock()
	defer e.mu.Unlock()

	// 1. Provision Resource Group state
	rgID := fmt.Sprintf("/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/%s", fixture.ResourceGroup)
	rgState := ResourceGroupState{
		ID:   rgID,
		Name: fixture.ResourceGroup,
		Tags: map[string]string{
			"TenantID": fixture.TenantID,
			"MatterID": fixture.MatterID,
		},
	}
	e.resourceGroups[fixture.ResourceGroup] = rgState

	// 2. Register VNet tenant boundary
	if fixture.VNetID != "" {
		e.vnetTenants[fixture.VNetID] = fixture.TenantID
	}

	// 3. Provision consolidated ContainerApp if requested
	if fixture.AppID != "" {
		caKey := fmt.Sprintf("%s/%s", fixture.ResourceGroup, fixture.AppID)
		e.containerApps[caKey] = ContainerAppState{
			InstanceCount: 1,
			Template: ContainerAppTemplate{
				Containers: []ContainerSpec{
					{Name: "courtroom-frontend", Image: "smalt/courtroom-frontend:v26.10.30"},
					{Name: "courtroom-backend", Image: "smalt/courtroom-backend:v26.10.30"},
				},
				SharingSettings: ContainerSharingSettings{
					LocalhostNetworking: true,
				},
			},
		}
	}

	// 4. Compute bit-exact BLAKE3 turnstile settlement hash
	now := uint64(time.Now().UnixNano())
	payloadBytes, _ := json.Marshal(fixture)
	h := receipt.TurnstileReceipt("arm.apply.tenant", now, payloadBytes)
	hashHex := receipt.Hex(h)

	r := &Receipt{
		ReceiptID:  fmt.Sprintf("rcpt-%s-%s", fixture.MatterID, hashHex[:12]),
		BLAKE3Hash: hashHex,
		Timestamp:  now,
	}
	return r, nil
}

// GetResourceGroupState inspects the actual wire state for a Resource Group.
func (e *SmaltTestEnvironment) GetResourceGroupState(ctx context.Context, rgName string) ResourceGroupState {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.resourceGroups[rgName]
}

// SimulatePacket tests network-level boundary traversal between VNets.
// Returns 403 Forbidden if cross-tenant spillover is attempted.
func (e *SmaltTestEnvironment) SimulatePacket(ctx context.Context, srcVNet, dstVNet string) *http.Response {
	e.mu.RLock()
	defer e.mu.RUnlock()

	srcTenant := e.vnetTenants[srcVNet]
	dstTenant := e.vnetTenants[dstVNet]

	if srcTenant == "" || dstTenant == "" || srcTenant != dstTenant {
		return &http.Response{
			StatusCode: http.StatusForbidden,
			Status:     "403 Forbidden",
		}
	}

	return &http.Response{
		StatusCode: http.StatusOK,
		Status:     "200 OK",
	}
}

// GetContainerAppState inspects the deployed state of a ContainerApp.
func (e *SmaltTestEnvironment) GetContainerAppState(ctx context.Context, rgName, appID string) (*ContainerAppState, error) {
	e.mu.RLock()
	defer e.mu.RUnlock()

	key := fmt.Sprintf("%s/%s", rgName, appID)
	ca, ok := e.containerApps[key]
	if !ok {
		return nil, fmt.Errorf("container app %s not found in resource group %s", appID, rgName)
	}
	return &ca, nil
}

// ProvisionBlobAccountWithCRMH configures the CRMH 14-day retention policy.
func (e *SmaltTestEnvironment) ProvisionBlobAccountWithCRMH(ctx context.Context, rgName, accountName string) error {
	return e.storageStore.ProvisionCRMHAccount(rgName, accountName)
}

// GetBlobManagementPolicy retrieves the CRMH management policy.
func (e *SmaltTestEnvironment) GetBlobManagementPolicy(ctx context.Context, rgName, accountName string) (*storage.BlobManagementPolicy, error) {
	return e.storageStore.GetManagementPolicy(rgName, accountName)
}

// PublishAuditedSIEMEvent stamps an event with a BLAKE3 turnstile hash and routes to Event Hub partition.
func (e *SmaltTestEnvironment) PublishAuditedSIEMEvent(ctx context.Context, rgName, namespaceName, matterID string, securityEvent any) (*Receipt, error) {
	now := uint64(time.Now().UnixNano())
	eventBytes, err := json.Marshal(securityEvent)
	if err != nil {
		return nil, err
	}

	h := receipt.TurnstileReceipt("siem.event.audit", now, eventBytes)
	hashHex := receipt.Hex(h)

	msg := storage.EventHubMessage{
		Body: eventBytes,
		Properties: map[string]string{
			"MatterID":         matterID,
			"TurnstileReceipt": hashHex,
			"Timestamp":        fmt.Sprintf("%d", now),
		},
	}

	if err := e.storageStore.PublishEventHub(rgName, namespaceName, "audit-events", msg); err != nil {
		return nil, err
	}

	return &Receipt{
		ReceiptID:  fmt.Sprintf("siem-%s-%s", matterID, hashHex[:12]),
		BLAKE3Hash: hashHex,
		Timestamp:  now,
	}, nil
}

// DrainEventHubPartition reads all messages from an Event Hub partition queue.
func (e *SmaltTestEnvironment) DrainEventHubPartition(ctx context.Context, rgName, namespaceName, topic string) ([]storage.EventHubMessage, error) {
	return e.storageStore.DrainEventHub(rgName, namespaceName, topic)
}

// RunGuardFence evaluates raw configurations against the mechanical guard refusal rules.
func (e *SmaltTestEnvironment) RunGuardFence(ctx context.Context, dirtyConfig []byte) (*court.GuardResult, error) {
	return court.EvaluateGuard(ctx, dirtyConfig)
}

// PutSecret stores a secret in Key Vault data plane and returns a bit-exact receipt.
func (e *SmaltTestEnvironment) PutSecret(ctx context.Context, vaultName, secretName, value string) (*Receipt, error) {
	e.mu.Lock()
	defer e.mu.Unlock()

	key := fmt.Sprintf("%s/%s", strings.ToLower(vaultName), secretName)
	e.keyVaultSecrets[key] = value

	now := uint64(time.Now().UnixNano())
	payloadBytes := []byte(fmt.Sprintf("%s:%s", key, value))
	h := receipt.TurnstileReceipt("kv7.put.secret", now, payloadBytes)
	hashHex := receipt.Hex(h)

	return &Receipt{
		ReceiptID:  fmt.Sprintf("kv-rcpt-%s-%s", secretName, hashHex[:12]),
		BLAKE3Hash: hashHex,
		Timestamp:  now,
	}, nil
}

// GetSecret reads a secret from Key Vault data plane.
func (e *SmaltTestEnvironment) GetSecret(ctx context.Context, vaultName, secretName string) (string, error) {
	e.mu.RLock()
	defer e.mu.RUnlock()

	key := fmt.Sprintf("%s/%s", strings.ToLower(vaultName), secretName)
	val, ok := e.keyVaultSecrets[key]
	if !ok {
		return "", fmt.Errorf("secret %s not found in vault %s", secretName, vaultName)
	}
	return val, nil
}

// EvaluateGroundTruth runs a bit-exact ground-truth comparison against expected state.
func (e *SmaltTestEnvironment) EvaluateGroundTruth(ctx context.Context, runID string, expected, actual map[string]string) (bool, []string) {
	var divergences []string
	for k, expVal := range expected {
		if actVal, ok := actual[k]; !ok {
			divergences = append(divergences, fmt.Sprintf("missing key: %s (expected %s)", k, expVal))
		} else if actVal != expVal {
			divergences = append(divergences, fmt.Sprintf("value mismatch for %s: got %s, want %s", k, actVal, expVal))
		}
	}
	for k, actVal := range actual {
		if _, ok := expected[k]; !ok {
			divergences = append(divergences, fmt.Sprintf("unexpected key: %s = %s", k, actVal))
		}
	}
	return len(divergences) == 0, divergences
}
