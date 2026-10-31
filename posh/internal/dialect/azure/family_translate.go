// Deep per-family wire-shape translations for the Azure dialect
// (v26.10.31 wave-2 gap lane 3). Each function ports one azurerm-specific
// coercion the provider tree performs (see
// docs/jira/posh/v26.10.31/gaps/03-provider-mapping-inventory.md) into the
// posh azurerm-dialect package; neutral machinery stays in the provider
// core. Behavior parity is pinned against the BEAM face per the
// KNOWN_DIVERGENCES rows KD-04/05/07/09.
package azure

import (
	"crypto/md5"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// defaultMemoryGiB is the Container-App-specific 0.5 GiB default the
// provider applies when a memory quantity string cannot be parsed.
const defaultMemoryGiB = 0.5

// ParseMemoryGiB ports the provider's parseMemoryGiB
// (resource_container_app.go:590): unit-stripping quantity parse
// (Gi/G/Mi/M suffixes), 0.5 GiB fallback.
func ParseMemoryGiB(mem string) float64 {
	s := strings.TrimSpace(mem)
	s = strings.TrimSuffix(s, "Gi")
	s = strings.TrimSuffix(s, "G")
	s = strings.TrimSuffix(s, "Mi")
	s = strings.TrimSuffix(s, "M")
	if v, err := strconv.ParseFloat(strings.TrimSpace(s), 64); err == nil && v > 0 {
		return v
	}
	return defaultMemoryGiB
}

// CoerceNumericMemoryInBody ports coerceNumericMemoryInBody
// (resource_container_app.go:610): rewrites
// properties.template.containers[].resources.memory from an azurerm
// quantity string to the face's numeric memory value. No-op when the body
// does not carry the container template path.
func CoerceNumericMemoryInBody(body map[string]any) {
	props, ok := body["properties"].(map[string]any)
	if !ok {
		return
	}
	tmpl, ok := props["template"].(map[string]any)
	if !ok {
		return
	}
	containers, ok := tmpl["containers"].([]map[string]any)
	if ok {
		for i := range containers {
			coerceOneContainer(containers[i])
		}
		return
	}
	if anyContainers, ok := tmpl["containers"].([]any); ok {
		coerceContainersAny(anyContainers)
	}
}

func coerceOneContainer(c map[string]any) {
	if res, ok := c["resources"].(map[string]any); ok {
		if memStr, ok := res["memory"].(string); ok {
			res["memory"] = memoryWireValue(memStr)
		}
	}
}

// memoryWireValue translates a quantity string to the wire numeric: the
// smalt face stores bare numbers (KD-05: "Memory is numeric (bare integer
// MiB)"), so GiB quantities are emitted at MiB precision (0.5Gi -> 512).
func memoryWireValue(mem string) int {
	return int(ParseMemoryGiB(mem) * 1024)
}

func coerceContainersAny(items []any) {
	for _, item := range items {
		if cm, ok := item.(map[string]any); ok {
			coerceOneContainer(cm)
		}
	}
}

// StripCreateTraffic removes properties.configuration.ingress.traffic from
// a create body: the BEAM face applies traffic weights on update only
// (KD-04), so a create-time traffic block diverges. The dialect
// translation defers the split: strip on create; the caller re-applies via
// Update, where the face persists it. Returns false when the body carried
// no traffic block (the caller skips the follow-up update).
func StripCreateTraffic(body map[string]any) (stripped bool) {
	props, ok := body["properties"].(map[string]any)
	if !ok {
		return false
	}
	cfg, ok := props["configuration"].(map[string]any)
	if !ok {
		return false
	}
	ing, ok := cfg["ingress"].(map[string]any)
	if !ok {
		return false
	}
	if _, present := ing["traffic"]; present {
		delete(ing, "traffic")
		return true
	}
	return false
}

// WriteEnvIDDualKey writes the classic azurerm dual-key shape: build writes
// BOTH managedEnvironmentId and environmentId; read prefers
// managedEnvironmentId (resource_container_app.go:1007-1009 / :1287-1289).
func WriteEnvIDDualKey(props map[string]any, envID string) {
	props["managedEnvironmentId"] = envID
	props["environmentId"] = envID
}

// ReadEnvIDDualKey prefers managedEnvironmentId, falling back to
// environmentId. Empty when neither is present.
func ReadEnvIDDualKey(props map[string]any) string {
	if v, ok := props["managedEnvironmentId"].(string); ok && v != "" {
		return v
	}
	if v, ok := props["environmentId"].(string); ok && v != "" {
		return v
	}
	return ""
}

// SecretIDGeometry is the five-ID wire shape populateSecretState builds
// (resource_key_vault_secret.go:356).
type SecretIDGeometry struct {
	Version               string
	VersionlessID         string // https://{vault}.vault.azure.net/secrets/{name}
	ID                    string // versionlessID + "/" + version
	ResourceVersionlessID string // {armKVID}/secrets/{name} (normalized)
	ResourceID            string // resourceVersionlessID + "/versions/" + version
}

// BuildSecretIDGeometry ports the ID geometry of populateSecretState.
// version is taken as given (callers apply the read-prior / deterministic
// fallback ladder before calling).
func BuildSecretIDGeometry(vaultName, secretName, version, normKVID string) SecretIDGeometry {
	versionlessID := fmt.Sprintf("https://%s.vault.azure.net/secrets/%s", strings.ToLower(vaultName), secretName)
	fullID := versionlessID + "/" + version
	resourceVersionlessID := NormalizeARMID(normKVID + "/secrets/" + secretName)
	resourceID := resourceVersionlessID + "/versions/" + version
	return SecretIDGeometry{
		Version:               version,
		VersionlessID:         versionlessID,
		ID:                    fullID,
		ResourceVersionlessID: resourceVersionlessID,
		ResourceID:            resourceID,
	}
}

// DeterministicSecretVersion ports deterministicSecretVersion
// (resource_key_vault_secret.go:163): sha256("vault/name/value")[:16] hex.
func DeterministicSecretVersion(vaultName, secretName, value string) string {
	sum := sha256.Sum256([]byte(strings.ToLower(vaultName) + "/" + secretName + "/" + value))
	return hex.EncodeToString(sum[:16])
}

// roleDefUUIDNamespace is the provider's roleDefUUIDNamespace bytes
// (resource_remaining_v1.go:36).
var roleDefUUIDNamespace = []byte{106, 167, 184, 16, 157, 173, 17, 209, 128, 180, 0, 192, 79, 212, 48, 200}

// MintDeterministicGUID ports mintDeterministicGUID: sha1(namespace ||
// input), uuid5-style version/variant bit-setting, hex-dashed GUID.
func MintDeterministicGUID(input string) string {
	h := sha1.New()
	h.Write(roleDefUUIDNamespace)
	h.Write([]byte(input))
	digest := h.Sum(nil)
	digest[6] = (digest[6] & 0x0f) | 0x50
	digest[8] = (digest[8] & 0x3f) | 0x80
	hx := hex.EncodeToString(digest[:16])
	return fmt.Sprintf("%s-%s-%s-%s-%s", hx[0:8], hx[8:12], hx[12:16], hx[16:20], hx[20:32])
}

// MintRoleDefinitionGUID ports resolveRoleDefinitionInput's mint input:
// uuid5(name|scope) (KD-09).
func MintRoleDefinitionGUID(name, scope string) string {
	return MintDeterministicGUID(name + "|" + scope)
}

// MintAcrPassword ports mintDeterministicGUID("acr-pwd:"+armPath)
// (resource_remaining_v1.go:1967).
func MintAcrPassword(armPath string) string {
	return MintDeterministicGUID("acr-pwd:" + armPath)
}

// MintLawWorkspaceID ports mintDeterministicGUID("law-ws:"+armPath)
// (resource_remaining_v1.go:2313).
func MintLawWorkspaceID(armPath string) string {
	return MintDeterministicGUID("law-ws:" + armPath)
}

// MintLawSharedKey ports mintDeterministicGUID("law-key:"+armPath)
// (resource_remaining_v1.go:2317).
func MintLawSharedKey(armPath string) string {
	return MintDeterministicGUID("law-key:" + armPath)
}

// MintStorageKey ports mintDeterministicGUID("st-key:"+armPath)
// (resource_remaining_v1.go:2694).
func MintStorageKey(armPath string) string {
	return MintDeterministicGUID("st-key:" + armPath)
}

// ---------------------------------------------------------------------------
// #5 dialect half — ARM ID canonicalization (ARD-AZ-01)
// ---------------------------------------------------------------------------

// canonicalNamespaces is the ARM namespace-case table ported from the
// provider's canonicalNamespaces (arm_client.go ~460-489, trimmed to the
// namespaces the first MOVE families touch).
var canonicalNamespaces = map[string]string{
	"microsoft.app":               "Microsoft.App",
	"microsoft.keyvault":          "Microsoft.KeyVault",
	"microsoft.network":           "Microsoft.Network",
	"microsoft.storage":           "Microsoft.Storage",
	"microsoft.servicebus":        "Microsoft.ServiceBus",
	"microsoft.eventhub":          "Microsoft.EventHub",
	"microsoft.documentdb":        "Microsoft.DocumentDB",
	"microsoft.web":               "Microsoft.Web",
	"microsoft.eventgrid":         "Microsoft.EventGrid",
	"microsoft.containerregistry": "Microsoft.ContainerRegistry",
	"microsoft.insights":          "Microsoft.Insights",
	"microsoft.authorization":     "Microsoft.Authorization",
}

// canonicalResourceTypes is the resource-type case table ported from the
// provider's canonicalResourceTypes.
var canonicalResourceTypes = map[string]string{
	"microsoft.app/containerapps":                      "containerApps",
	"microsoft.keyvault/vaults":                        "vaults",
	"microsoft.keyvault/vaults/secrets":                "secrets",
	"microsoft.network/dnszones":                       "dnsZones",
	"microsoft.storage/storageaccounts":                "storageAccounts",
	"microsoft.servicebus/namespaces":                  "namespaces",
	"microsoft.eventhub/namespaces":                    "namespaces",
	"microsoft.documentdb/databaseaccounts":            "databaseAccounts",
	"microsoft.web/sites":                              "sites",
	"microsoft.eventgrid/topics":                       "topics",
	"microsoft.authorization/roledefinitions":          "roleDefinitions",
	"microsoft.authorization/roleassignments":          "roleAssignments",
	"microsoft.managedidentity/userassignedidentities": "userAssignedIdentities",
}

// NormalizeARMID ports the provider's NormalizeARMID (arm_client.go:490)
// ARD-AZ-01 canonicalization: segment case laws for subscriptions /
// resourcegroups / providers literals plus namespace and resource-type
// canonical casing. Non-ARM strings pass through unchanged.
func NormalizeARMID(id string) string {
	segs := strings.Split(strings.TrimPrefix(id, "/"), "/")
	for i, s := range segs {
		switch strings.ToLower(s) {
		case "subscriptions", "resourcegroups", "providers":
			segs[i] = mapCanonSegment(s)
		}
	}
	for i := 0; i+1 < len(segs); i++ {
		low := strings.ToLower(segs[i])
		if low == "providers" && i+2 < len(segs) {
			if canon, ok := canonicalNamespaces[lowNs(segs[i+1])]; ok {
				segs[i+1] = canon
			}
			if canon, ok := canonicalResourceTypes[lowNs(segs[i+1])+"/"+lowNs(segs[i+2])]; ok {
				segs[i+2] = canon
			}
		}
	}
	return "/" + strings.Join(segs, "/")
}

func mapCanonSegment(s string) string {
	switch strings.ToLower(s) {
	case "subscriptions":
		return "subscriptions"
	case "resourcegroups":
		return "resourceGroups"
	case "providers":
		return "providers"
	}
	return s
}

func lowNs(s string) string { return strings.ToLower(s) }

// ---------------------------------------------------------------------------
// Egress & Data-Plane Wire Framing Transforms
// ---------------------------------------------------------------------------

// BrokerProperties models the standard JSON header passed by Service Bus REST clients.
type BrokerProperties struct {
	MessageID               string `json:"MessageId,omitempty"`
	SessionID               string `json:"SessionId,omitempty"`
	PartitionKey            string `json:"PartitionKey,omitempty"`
	ViaPartitionKey         string `json:"ViaPartitionKey,omitempty"`
	Label                   string `json:"Label,omitempty"`
	CorrelationID           string `json:"CorrelationId,omitempty"`
	ScheduledEnqueueTimeUtc string `json:"ScheduledEnqueueTimeUtc,omitempty"`
}

// ParseBrokerProperties decodes the BrokerProperties JSON string from the HTTP header.
func ParseBrokerProperties(raw string) (BrokerProperties, error) {
	if strings.TrimSpace(raw) == "" {
		return BrokerProperties{}, nil
	}
	var bp BrokerProperties
	if err := json.Unmarshal([]byte(raw), &bp); err != nil {
		return BrokerProperties{}, fmt.Errorf("invalid BrokerProperties JSON: %w", err)
	}
	return bp, nil
}

// ValidateBrokeredEncoding checks if the x-ms-brokered-encoding header matches
// the accepted AtomPub or XML shapes.
func ValidateBrokeredEncoding(enc string) bool {
	s := strings.ToLower(strings.TrimSpace(enc))
	return s == "" || s == "application/atom+xml" || s == "application/xml"
}

// EventHubsPartitionKeyPinion hashes the partition key using MD5 and computes
// the partition id ("0" or "1") over the pinned 2-partition set (KD-76).
func EventHubsPartitionKeyPinion(pk string) string {
	sum := md5.Sum([]byte(pk))
	partitionIdx := int(sum[0]) % 2
	return strconv.Itoa(partitionIdx)
}

// ParseCosmosPartitionKey parses the x-ms-documentdb-partitionkey header.
// Real Azure SDKs send a JSON array (e.g. `["my-pk"]`).
func ParseCosmosPartitionKey(headerVal string) ([]string, error) {
	trimmed := strings.TrimSpace(headerVal)
	if trimmed == "" {
		return nil, nil
	}
	var arr []any
	if err := json.Unmarshal([]byte(trimmed), &arr); err != nil {
		return nil, fmt.Errorf("invalid cosmos partition key header: %w", err)
	}
	res := make([]string, len(arr))
	for i, v := range arr {
		res[i] = fmt.Sprintf("%v", v)
	}
	return res, nil
}

// RefuseACILogs returns a typed refusal for Container Instance log streaming
// (ACI execution is not emulated per design law).
func RefuseACILogs() (int, map[string]any) {
	return 400, map[string]any{
		"error": map[string]any{
			"code":    "NotSupportedOnSubstrate",
			"message": "Container execution and log streaming is not emulated on this substrate",
		},
	}
}
