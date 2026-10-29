// Key Vault + secret
resource vault 'Microsoft.KeyVault/vaults@2022-07-01' = {
  name: 'smalt-vault'
  location: 'westus'
  properties: {
    tenantId: '00000000-0000-0000-0000-000000000000'
    enabledForDeployment: true
  }
}

resource apiSecret 'Microsoft.KeyVault/vaults/secrets@2022-07-01' = {
  parent: vault
  name: 'api-key'
}
