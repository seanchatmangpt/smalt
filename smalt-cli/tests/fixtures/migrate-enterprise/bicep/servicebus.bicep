// ------------------------------------------------------------------------------
// Service Bus (Bicep leg): 1 namespace, 3 queues, 2 topics, 3 subscriptions.
// parent: symbol chains exercise the bicep ancestor resolution.
// ------------------------------------------------------------------------------

resource sbNs 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: 'sb-partners-${envName}'
  location: location
  sku: {
    name: 'Premium'
  }
}

resource partnerQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: sbNs
  name: 'partner-inbound'
  properties: {
    maxDeliveryCount: 7
    lockDuration: 'PT5M'
  }
}

resource partnerDlq 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: sbNs
  name: 'partner-inbound-dlq'
  properties: {
    maxDeliveryCount: 3
  }
}

resource partnerPoisonQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: sbNs
  name: 'partner-poison'
  properties: {
    maxDeliveryCount: 2
  }
}

resource partnerEvents 'Microsoft.ServiceBus/namespaces/topics@2022-10-01-preview' = {
  parent: sbNs
  name: 'partner-events'
}

resource partnerEventsFwd 'Microsoft.ServiceBus/namespaces/topics@2022-10-01-preview' = {
  parent: sbNs
  name: 'partner-events-fwd'
}

resource subFulfillment 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2022-10-01-preview' = {
  parent: partnerEvents
  name: 'fulfillment'
  properties: {
    maxDeliveryCount: 5
  }
}

resource subAnalytics 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2022-10-01-preview' = {
  parent: partnerEvents
  name: 'analytics'
  properties: {
    maxDeliveryCount: 5
  }
}

resource subForwarder 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2022-10-01-preview' = {
  parent: partnerEventsFwd
  name: 'forwarder'
  properties: {
    maxDeliveryCount: 9
  }
}
