targetScope = 'subscription'

param rgName string = 'rg-backstage-dev'
param location string = 'eastus2'
param tags object = {
  environment: 'dev'
  app: 'backstage'
  owner: 'jared'
}

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: rgName
  location: location
  tags: tags
}

module aksCluster './modules/aks-cluster.bicep' = {
  name: 'aksCluster'
  scope: resourceGroup
  params: {
    aksClusterName: 'aks-backstage-dev'
    location: location
  }
}
