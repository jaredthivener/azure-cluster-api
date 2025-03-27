param acrName string
param location string = resourceGroup().location
param acrSku string = 'Basic'

resource acr 'Microsoft.ContainerRegistry/registries@2021-06-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: acrSku
  }
  properties: {}
}

output acrName string = acr.name
