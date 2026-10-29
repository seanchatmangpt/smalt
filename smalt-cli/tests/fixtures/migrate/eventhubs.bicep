// Event Hubs namespace + hub + consumer group
resource ehNs 'Microsoft.EventHub/namespaces@2022-10-01-preview' = {
  name: 'smalt-eh'
  location: 'westus'
  sku: {
    name: 'Standard'
  }
}

resource telemetryHub 'Microsoft.EventHub/namespaces/eventhubs@2022-10-01-preview' = {
  parent: ehNs
  name: 'telemetry'
  properties: {
    partitionCount: 4
    messageRetentionInDays: 1
  }
}

resource telemetryCg 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2022-10-01-preview' = {
  parent: telemetryHub
  name: 'readers'
}
