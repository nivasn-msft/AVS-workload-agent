// =============================================================================
//  OPTIONAL - VNet connectivity to your AVS private cloud
// =============================================================================
//  Run this ONLY if you do NOT already have a VNet connected to your AVS
//  private cloud. TIP: the simplest option is the built-in AVS portal feature
//  (AVS private cloud -> Connectivity -> "Azure vNet connect"), which wires up
//  ExpressRoute for you. Use this template instead if you prefer fully scripted IaC.
//  It creates:
//    - a hub VNet with a GatewaySubnet and a delegated Container Apps subnet
//    - an ExpressRoute authorization on your AVS private cloud
//    - an ExpressRoute virtual network gateway (+ public IP)
//    - an ExpressRoute connection from the gateway to the AVS circuit
//
//  NOTE: the ExpressRoute gateway takes ~30-45 minutes to provision.
//
//  DEPLOY:
//    az deployment group create -g <your-rg> --template-file connectivity.bicep \
//      --parameters avsPrivateCloudName=<your-avs-private-cloud>
//
//  Then run main.bicep with:  existingVnetName=<vnetName output>
// =============================================================================

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Name for the new hub VNet.')
param vnetName string = 'avs-hub-vnet'

@description('Address space for the new VNet (must contain the gateway + Container Apps subnets).')
param vnetAddressPrefix string = '10.40.0.0/16'

@description('Prefix for the GatewaySubnet (must be named exactly "GatewaySubnet").')
param gatewaySubnetPrefix string = '10.40.0.0/24'

@description('Prefix for the delegated Container Apps subnet (at least /23).')
param acaSubnetPrefix string = '10.40.8.0/23'

@description('Name of your EXISTING AVS private cloud (Microsoft.AVS/privateClouds) to connect to.')
param avsPrivateCloudName string

@description('ExpressRoute gateway SKU.')
@allowed([ 'ErGw1AZ', 'ErGw2AZ', 'ErGw3AZ', 'Standard', 'HighPerformance' ])
param erGatewaySku string = 'ErGw1AZ'

var acaSubnetName = 'aca-subnet'

// Your existing AVS private cloud (referenced for its ExpressRoute circuit).
resource avs 'Microsoft.AVS/privateClouds@2023-09-01' existing = {
  name: avsPrivateCloudName
}

// Authorization key on the AVS ExpressRoute circuit (lets our gateway connect).
resource avsAuth 'Microsoft.AVS/privateClouds/authorizations@2023-09-01' = {
  parent: avs
  name: 'avs-ai-agent-auth'
}

// Hub VNet with the gateway subnet + the delegated Container Apps subnet.
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ vnetAddressPrefix ]
    }
    subnets: [
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: gatewaySubnetPrefix
        }
      }
      {
        name: acaSubnetName
        properties: {
          addressPrefix: acaSubnetPrefix
          delegations: [
            {
              name: 'aca-delegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
    ]
  }
}

resource gwPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${vnetName}-ergw-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource erGw 'Microsoft.Network/virtualNetworkGateways@2023-11-01' = {
  name: '${vnetName}-ergw'
  location: location
  properties: {
    gatewayType: 'ExpressRoute'
    sku: {
      name: erGatewaySku
      tier: erGatewaySku
    }
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${vnet.id}/subnets/GatewaySubnet'
          }
          publicIPAddress: {
            id: gwPip.id
          }
        }
      }
    ]
  }
}

// Connect the gateway to the AVS ExpressRoute circuit using the authorization key.
resource erConn 'Microsoft.Network/connections@2023-11-01' = {
  name: '${vnetName}-to-avs'
  location: location
  properties: {
    connectionType: 'ExpressRoute'
    routingWeight: 0
    virtualNetworkGateway1: {
      id: erGw.id
      properties: {}
    }
    peer: {
      id: avs.properties.circuit.expressRouteID
    }
    authorizationKey: avsAuth.properties.expressRouteAuthorizationKey
  }
}

output vnetName string = vnet.name
output acaSubnetName string = acaSubnetName
