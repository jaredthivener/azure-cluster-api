@description('Name of the AKS Cluster')
param aksClusterName string

@description('Location for the AKS Cluster')
param location string = resourceGroup().location

@description('Kubernetes version for the AKS Cluster')
param kubernetesVersion string = '1.30.10'

@description('Node pool VM size')
param nodeVmSize string = 'Standard_DS2_v2'

@description('Number of nodes in the default node pool')
param nodeCount int = 3

@description('Enable RBAC for the AKS Cluster')
param enableRBAC bool = true


resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-10-02-preview' = {
  name: aksClusterName
  location: location
  properties: {
    kubernetesVersion: kubernetesVersion
    enableRBAC: enableRBAC
    agentPoolProfiles: [
      {
        name: 'system'
        count: nodeCount
        vmSize: nodeVmSize
        osType: 'Linux'
        mode: 'System'
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
    }
  }
}

output aksClusterName string = aksCluster.name
