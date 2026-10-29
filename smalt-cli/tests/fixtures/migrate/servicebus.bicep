// Service Bus namespace + queue + topic + subscription
resource sbNs 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: 'smalt-sb'
  location: 'westus'
  sku: {
    name: 'Standard'
  }
}

resource ordersQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: sbNs
  name: 'orders-queue'
  properties: {
    maxDeliveryCount: 7
    lockDuration: 'PT5M'
  }
}

resource eventsTopic 'Microsoft.ServiceBus/namespaces/topics@2022-10-01-preview' = {
  parent: sbNs
  name: 'events-topic'
}

resource eventsSub 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2022-10-01-preview' = {
  parent: eventsTopic
  name: 'events-sub'
  properties: {
    maxDeliveryCount: 5
  }
}
