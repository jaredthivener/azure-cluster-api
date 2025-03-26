// Bicep module for AKS
param aksClusterName string
param location string = resourceGroup().location
param dnsPrefix string
param nodeCount int = 3
param nodeVmSize string = 'Standard_DS2_v2'
param kubernetesVersion string = '1.23.5'

resource aks 'Microsoft.ContainerService/managedClusters@2024-10-02-preview' = {
  name: aksClusterName
  location: location
  properties: {
    dnsPrefix: dnsPrefix
    agentPoolProfiles: [
      {
        name: 'nodepool1'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        mode: 'System'
      }
    ]
    kubernetesVersion: kubernetesVersion
  }
}

output aksClusterId string = aks.id
