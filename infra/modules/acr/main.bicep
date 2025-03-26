// Bicep module for ACR
param acrName string
param acrSku string = 'Basic'
param location string = resourceGroup().location

resource acr 'Microsoft.ContainerRegistry/registries@2021-06-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: acrSku
  }
  properties: {}
}

output acrLoginServer string = acr.properties.loginServer
