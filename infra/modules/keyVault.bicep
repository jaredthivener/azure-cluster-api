param keyVaultName string
param location string = resourceGroup().location
param tenantId string = subscription().tenantId

resource keyVault 'Microsoft.KeyVault/vaults@2024-12-01-preview' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    accessPolicies: []
  }
}

output keyVaultName string = keyVault.name
