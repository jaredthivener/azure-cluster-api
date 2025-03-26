// Bicep file for dev environment
param acrName string = 'devAcr'
param aksClusterName string = 'devAksCluster'
param dnsPrefix string = 'devDns'
param postgresServerName string = 'devPostgres'
param adminUsername string = 'adminUser'
param adminPassword string = 'adminPassword'

module acrModule '../modules/acr/main.bicep' = {
  name: 'acrDeployment'
  params: {
    acrName: acrName
  }
}

module aksModule '../modules/aks/main.bicep' = {
  name: 'aksDeployment'
  params: {
    aksClusterName: aksClusterName
    dnsPrefix: dnsPrefix
  }
}

module postgresModule '../modules/postgres/main.bicep' = {
  name: 'postgresDeployment'
  params: {
    postgresServerName: postgresServerName
    adminUsername: adminUsername
    adminPassword: adminPassword
  }
}

output acrLoginServer string = acrModule.outputs.acrLoginServer
output aksClusterId string = aksModule.outputs.aksClusterId
output postgresHost string = postgresModule.outputs.postgresHost
