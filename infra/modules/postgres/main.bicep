// Bicep module for PostgreSQL
param postgresServerName string
param location string = resourceGroup().location
param adminUsername string
param adminPassword string
param skuName string = 'B_Gen5_2'

resource postgres 'Microsoft.DBforPostgreSQL/servers@2017-12-01' = {
  name: postgresServerName
  location: location
  properties: {
    administratorLogin: adminUsername
    administratorLoginPassword: adminPassword
    version: '11'
    sslEnforcement: 'Enabled'
  }
  sku: {
    name: skuName
    tier: 'Basic'
    capacity: 2
  }
}

output postgresHost string = postgres.properties.fullyQualifiedDomainName
