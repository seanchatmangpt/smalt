// ------------------------------------------------------------------------------
// Event Hubs (Bicep leg): 1 namespace, 2 hubs, 3 consumer groups.
// ------------------------------------------------------------------------------

resource ehNs 'Microsoft.EventHub/namespaces@2022-10-01-preview' = {
  name: 'eh-partners-${envName}'
  location: location
  sku: {
    name: 'Standard'
    capacity: 2
  }
}

resource partnerClicks 'Microsoft.EventHub/namespaces/eventhubs@2022-10-01-preview' = {
  parent: ehNs
  name: 'partner-clicks'
  properties: {
    partitionCount: 2
    messageRetentionInDays: 1
  }
}

resource partnerOrders 'Microsoft.EventHub/namespaces/eventhubs@2022-10-01-preview' = {
  parent: ehNs
  name: 'partner-orders'
  properties: {
    partitionCount: 2
    messageRetentionInDays: 1
  }
}

resource cgClicksIngest 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2022-10-01-preview' = {
  parent: partnerClicks
  name: 'ingest'
}

resource cgClicksRollup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2022-10-01-preview' = {
  parent: partnerClicks
  name: 'rollup'
}

resource cgOrdersIngest 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2022-10-01-preview' = {
  parent: partnerOrders
  name: 'ingest'
}
