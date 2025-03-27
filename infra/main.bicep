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

module aks 'br/public:avm/ptn/azd/aks:0.1.4' = {
  name: 'aks'
  scope: resourceGroup
  params:{
    name: 'aks-backstage-dev'
    containerRegistryName: acr.outputs.acrName
    keyVaultName: kv.outputs.keyVaultName
    monitoringWorkspaceResourceId: law.outputs.workspaceResourceId
    principalId: deployer().objectId
    disableLocalAccounts: true
    enableKeyvaultSecretsProvider: true
    kubernetesVersion: '1.30.10'
    loadBalancerSku: 'standard'
    enableAzureRbac: true
    networkDataplane: 'cilium'
    networkPolicy: 'azure'
    networkPlugin: 'azure'
    systemPoolSize: 'CostOptimised'
    agentPoolConfig: [
      {
        name: 'backstage'
        count: 3
        vmSize: 'Standard_D2s_v3'
        osDiskSizeGB: 128
        type: 'VirtualMachineScaleSets'
        osSku: 'AzureLinux'
        enableAutoScaling: true
        enableDefaultTelemetry: true
        osDiskType: 'Ephemeral'
        mode: 'User'
        osType: 'Linux'
        minCount: 1
        maxCount: 3
        availabilityZones: [
          1
          2
          3
        ]
      }
    ]
    skuTier: 'Free'
    networkPluginMode: 'overlay'
    aadProfile: {
      aadProfileEnableAzureRBAC: true
      aadProfileManaged: true
    }
  }
}

module law 'modules/logAnalyticsWorkspace.bicep' = {
  scope: resourceGroup
  params: {
    workspaceName: 'law-backstage-dev'
  }
}

module uai 'modules/userIdentity.bicep' = {
  scope: resourceGroup
  params: {
    identityName: 'uai-backstage-dev'
  }
}

module acr 'modules/acr.bicep' = {
  scope: resourceGroup
  params: {
    acrName: 'acr${uniqueString(subscription().id)}'
  }
}

module kv 'modules/keyVault.bicep' = {
  scope: resourceGroup
  params: {
    keyVaultName: 'kv${uniqueString(subscription().id)}'
  }
}
