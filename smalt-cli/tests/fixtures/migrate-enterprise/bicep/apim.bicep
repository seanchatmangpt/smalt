// ------------------------------------------------------------------------------
// API Management (Bicep leg): 1 gateway.
// ------------------------------------------------------------------------------

resource partnerApim 'Microsoft.ApiManagement/service@2021-08-01' = {
  name: 'apim-partners-${envName}'
  location: location
  sku: {
    name: 'Developer'
    capacity: 1
  }
  properties: {
    publisherEmail: 'partner-apis@example.com'
    publisherName: 'Partner APIs'
  }
}
