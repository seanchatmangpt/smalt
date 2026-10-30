package provider

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
)

// Resource group CRUD over the smalt ARM plane.
// PUT/GET/DELETE /subscriptions/{sub}/resourcegroups/{name}?api-version=2023-07-01
// (registry gate admits 2023-07-01, not 2024-03-01).

type resourceGroupBody struct {
	Name       string            `json:"name"`
	Location   string            `json:"location"`
	Tags       map[string]string `json:"tags,omitempty"`
	Properties struct {
		ProvisioningState string `json:"provisioningState,omitempty"`
	} `json:"properties,omitempty"`
}

func (c *Client) PutResourceGroup(ctx context.Context, name, location string, tags map[string]string) (*resourceGroupBody, error) {
	b := resourceGroupBody{Name: name, Location: location, Tags: tags}
	buf, _ := json.Marshal(b)
	path := fmt.Sprintf("/subscriptions/%s/resourcegroups/%s?api-version=%s", c.subscriptionID, name, rgAPIVersion)
	respBody, status, err := c.do(ctx, http.MethodPut, path, buf, "application/json")
	if err != nil {
		return nil, err
	}
	if status != http.StatusOK && status != http.StatusCreated {
		return nil, fmt.Errorf("PUT resourcegroup %s: status %d: %s", name, status, truncate(respBody))
	}
	return parseRG(respBody)
}

func (c *Client) GetResourceGroup(ctx context.Context, name string) (*resourceGroupBody, error) {
	path := fmt.Sprintf("/subscriptions/%s/resourcegroups/%s?api-version=%s", c.subscriptionID, name, rgAPIVersion)
	respBody, status, err := c.do(ctx, http.MethodGet, path, nil, "")
	if err != nil {
		var apiErr *ApiError
		if errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound {
			return nil, nil // gone
		}
		return nil, err
	}
	if status == http.StatusNotFound {
		return nil, nil // gone
	}
	if status != http.StatusOK {
		return nil, fmt.Errorf("GET resourcegroup %s: status %d: %s", name, status, truncate(respBody))
	}
	return parseRG(respBody)
}

func (c *Client) DeleteResourceGroup(ctx context.Context, name string) error {
	path := fmt.Sprintf("/subscriptions/%s/resourcegroups/%s?api-version=%s", c.subscriptionID, name, rgAPIVersion)
	_, status, err := c.do(ctx, http.MethodDelete, path, nil, "")
	if err != nil {
		var apiErr *ApiError
		if errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound {
			return nil // already gone
		}
		return err
	}
	if status != http.StatusOK && status != http.StatusAccepted && status != http.StatusNotFound {
		return fmt.Errorf("DELETE resourcegroup %s: status %d", name, status)
	}
	return nil
}

func parseRG(body []byte) (*resourceGroupBody, error) {
	var rg resourceGroupBody
	if err := json.Unmarshal(body, &rg); err != nil {
		return nil, fmt.Errorf("resource group response parse: %w", err)
	}
	return &rg, nil
}
