// =============================================================================
//  AVS AI Data Agent - reusable deployment
// =============================================================================
//  Provisions the Azure infrastructure that lets a managed Azure AI Foundry
//  agent query PRIVATE databases running on VMs inside your AVS private cloud:
//
//    - A delegated Container Apps subnet in YOUR existing VNet
//    - Azure Container Registry (holds the MCP server image)
//    - Key Vault (+ the read-only DB secret) with RBAC
//    - A VNet-integrated Container Apps environment + the MCP server app
//    - Managed-identity role assignments (Key Vault Secrets User, AcrPull)
//    - (optional) an Azure AI Foundry (AIServices) account + a model deployment
//
//  PREREQUISITES (you already have these if you run AVS):
//    - An AVS private cloud with your databases on a workload segment
//    - A VNet with ExpressRoute connectivity to that AVS private cloud
//
//  DEPLOY:
//    az deployment group create -g <your-rg> --template-file main.bicep \
//      --parameters existingVnetName=<your-vnet> acaSubnetPrefix=10.40.8.0/23 \
//                   sqlPassword=<read-only-db-password>
//
//  AFTER DEPLOY (the parts ARM can't do):
//    1. Update sources.yaml with your DB endpoints, then build + push the image:
//         az acr build --registry <acrName output> --image avs-mcp:v1 .
//    2. Point the app at your image:
//         az containerapp update -n <namePrefix>-mcp-server -g <rg> \
//           --image <acrLoginServer output>/avs-mcp:v1
//    3. Create a read-only login (e.g. agentreader) on each database.
//    4. In the Azure AI Foundry portal: create a project + agent (use the model
//       deployed here), and attach the MCP tool:
//         URL   = https://<mcpFqdn output>/mcp
//         Auth  = Microsoft Entra / Project Managed Identity
//         Audience = api://<your MCP app registration>
//    5. Lock the endpoint to your agent by setting these app env vars:
//         ALLOWED_AUDIENCES = api://<your app registration>
//         ALLOWED_CALLERS   = <the Foundry project managed-identity app id (azp)>
// =============================================================================

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Short prefix used to name the resources.')
param namePrefix string = 'avsai'

@description('Name of the EXISTING VNet that already has ExpressRoute connectivity to your AVS private cloud.')
param existingVnetName string

@description('Name of the delegated subnet to create for Container Apps.')
param acaSubnetName string = 'aca-subnet'

@description('Address prefix for the delegated Container Apps subnet (must fit inside the existing VNet and be at least /23).')
param acaSubnetPrefix string = '10.40.8.0/23'

@description('Read-only SQL login the agent uses to query your databases.')
param sqlUser string = 'agentreader'

@description('Password for the read-only SQL login. Stored as a Key Vault secret.')
@secure()
param sqlPassword string

@description('Container image for the MCP server. Defaults to a public placeholder; swap to your ACR image after you build + push it.')
param containerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Microsoft Entra tenant ID used for in-app token validation.')
param tenantId string = subscription().tenantId

@description('Allowed audiences (comma-separated) for in-app token validation. Set to your MCP app-registration audience.')
param allowedAudiences string = ''

@description('Allowed caller app IDs / azp (comma-separated). Set to your Foundry project managed identity after the agent exists.')
param allowedCallers string = ''

@description('Also deploy an Azure AI Foundry (AIServices) account + model deployment.')
param deployFoundry bool = true

@description('Model to deploy in Foundry (only used when deployFoundry = true).')
param modelName string = 'gpt-4o-mini'

@description('Version of the model to deploy.')
param modelVersion string = '2024-07-18'

// ---- names -----------------------------------------------------------------
var kvName = '${namePrefix}-kv'
var acrName = '${namePrefix}acr${uniqueString(resourceGroup().id)}'
var envName = '${namePrefix}-mcp-env'
var appName = '${namePrefix}-mcp-server'
var foundryName = '${namePrefix}-foundry'
var secretName = 'sql-agentreader-password'

// built-in role definition IDs
var kvSecretsUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6') // Key Vault Secrets User
var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')       // AcrPull

// ---- existing VNet + new delegated subnet ----------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: existingVnetName
}

resource acaSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: vnet
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

// ---- Azure Container Registry -----------------------------------------------
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

// ---- Key Vault (RBAC) + read-only DB secret --------------------------------
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
  }
}

resource sqlSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: secretName
  properties: {
    value: sqlPassword
  }
}

// ---- Container Apps environment (VNet-integrated) --------------------------
resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: envName
  location: location
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: acaSubnet.id
      internal: false
    }
  }
}

// ---- MCP server Container App ----------------------------------------------
resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: 'system'
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'mcp'
          image: containerImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'KEY_VAULT_URL', value: kv.properties.vaultUri }
            { name: 'SQL_USER', value: sqlUser }
            { name: 'HOST', value: '0.0.0.0' }
            { name: 'PORT', value: '8000' }
            { name: 'TENANT_ID', value: tenantId }
            { name: 'ALLOWED_AUDIENCES', value: allowedAudiences }
            { name: 'ALLOWED_CALLERS', value: allowedCallers }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

// ---- RBAC: app managed identity -> Key Vault Secrets User + AcrPull ---------
resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, app.id, kvSecretsUserRoleId)
  scope: kv
  properties: {
    roleDefinitionId: kvSecretsUserRoleId
    principalId: app.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource acrRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, app.id, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: app.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---- (optional) Azure AI Foundry account + model deployment ----------------
resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' = if (deployFoundry) {
  name: foundryName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: toLower(foundryName)
    publicNetworkAccess: 'Enabled'
  }
}

resource model 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = if (deployFoundry) {
  parent: foundry
  name: modelName
  sku: {
    name: 'GlobalStandard'
    capacity: 50
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
}

// ---- outputs ----------------------------------------------------------------
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output mcpFqdn string = app.properties.configuration.ingress.fqdn
output mcpEndpoint string = 'https://${app.properties.configuration.ingress.fqdn}/mcp'
output keyVaultUri string = kv.properties.vaultUri
output appPrincipalId string = app.identity.principalId
output foundryEndpoint string = deployFoundry ? foundry!.properties.endpoint : ''
