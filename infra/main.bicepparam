using './main.bicep'

// ---------------------------------------------------------------------------
//  Fill these in, then deploy with:
//    az deployment group create -g <your-rg> \
//      --parameters main.bicepparam --parameters sqlPassword=<db-password>
//  (pass sqlPassword on the command line so the secret isn't stored in the file)
// ---------------------------------------------------------------------------

// --- Required ---
param existingVnetName = 'REPLACE-with-your-vnet'   // VNet with ExpressRoute to your AVS private cloud
param acaSubnetPrefix  = '10.40.8.0/23'             // a free /23 inside that VNet for the bridge

// --- Secret: override at deploy time; do NOT commit a real value ---
param sqlPassword = 'REPLACE-at-deploy-time'

// --- Naming / options ---
param namePrefix     = 'avsai'
param sqlUser        = 'agentreader'
param containerImage = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest' // swap after az acr build

// --- Azure AI Foundry (optional) ---
param deployFoundry = true
param modelName     = 'gpt-4o-mini'
param modelVersion  = '2024-07-18'

// --- Fill in AFTER the Foundry agent exists (locks the endpoint to your agent) ---
param allowedAudiences = ''   // e.g. api://<your-mcp-app-registration>
param allowedCallers   = ''   // the Foundry project managed-identity app id (azp claim)
