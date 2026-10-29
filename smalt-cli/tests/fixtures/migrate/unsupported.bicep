// Types outside smalt's emulatable surface -> typed unsupported, never silent
resource vm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: 'not-emulated'
  location: 'westus'
}

// interpolation is typed unresolved
resource interpNs 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: 'sb-${environment().name}'
  location: resourceGroup().location
}

// broken: no body
resource brokenQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = [
  for q in []: {
    name: q
  }
]
