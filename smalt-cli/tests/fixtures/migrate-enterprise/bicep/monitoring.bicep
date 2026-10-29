// ------------------------------------------------------------------------------
// Monitoring (Bicep leg): DELIBERATE unsupported ARM types. Each occurrence
// must be COUNTED in unsupported_resource_types (fail-closed), never dropped.
// ------------------------------------------------------------------------------

// DELIBERATE unsupported types:
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-orders-${envName}'
  location: 'global'
  properties: {
    groupShortName: 'orders'
    enabled: true
  }
}

resource logWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'law-partners-${envName}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
  }
}
