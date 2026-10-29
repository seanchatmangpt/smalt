// API Management
resource apim 'Microsoft.ApiManagement/service@2022-08-01' = {
  name: 'smalt-apim'
  location: 'westus'
  sku: {
    name: 'Developer'
  }
  properties: {
    publisherEmail: 'admin@example.com'
    publisherName: 'Smalt'
  }
}
