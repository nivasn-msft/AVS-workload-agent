#Requires -Version 7
<#
.SYNOPSIS
  Deploys the AVS AI Data Agent infrastructure, then (optionally) builds + pushes the
  MCP server image and points the Container App at it.

.DESCRIPTION
  Runs main.bicep in the given resource group, captures the outputs, builds the MCP
  image into the created ACR from your app source folder, and updates the Container App.
  The Foundry agent + MCP-tool wiring is a one-time portal (data-plane) step, printed at the end.

.EXAMPLE
  ./deploy.ps1 -ResourceGroup avs-ai-rg -ExistingVnetName my-vnet `
               -SqlPassword (Read-Host 'DB password' -AsSecureString) `
               -AppSourcePath ../app
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]   $ResourceGroup,
    [Parameter(Mandatory)][string]   $ExistingVnetName,
    [string]                         $AcaSubnetPrefix = '10.40.8.0/23',
    [string]                         $NamePrefix      = 'avsai',
    [Parameter(Mandatory)][securestring] $SqlPassword,
    [string]                         $AppSourcePath   = 'app',    # folder with Dockerfile, mcp_server.py, sources.yaml (bundled)
    [string]                         $ImageTag        = 'avs-mcp:v1',
    [switch]                         $SkipImageBuild
)

$ErrorActionPreference = 'Stop'
$here     = Split-Path -Parent $PSCommandPath
$template = Join-Path $here 'main.bicep'
if (-not [System.IO.Path]::IsPathRooted($AppSourcePath)) { $AppSourcePath = Join-Path (Split-Path -Parent $here) $AppSourcePath }
$pwdPlain = [System.Net.NetworkCredential]::new('', $SqlPassword).Password

Write-Host '==> Deploying infrastructure (subnet, ACR, Key Vault, Container Apps, Foundry)...' -ForegroundColor Cyan
$deployName = "avs-ai-agent-$((Get-Date).ToString('yyyyMMddHHmmss'))"
$outJson = az deployment group create `
    --name $deployName `
    --resource-group $ResourceGroup `
    --template-file $template `
    --parameters existingVnetName=$ExistingVnetName acaSubnetPrefix=$AcaSubnetPrefix namePrefix=$NamePrefix sqlPassword=$pwdPlain `
    --query properties.outputs -o json
if ($LASTEXITCODE -ne 0) { throw 'Deployment failed.' }
$out = $outJson | ConvertFrom-Json

$acrName         = $out.acrName.value
$acrLoginServer  = $out.acrLoginServer.value
$mcpEndpoint     = $out.mcpEndpoint.value
$foundryEndpoint = $out.foundryEndpoint.value
$appName         = "$NamePrefix-mcp-server"

Write-Host "    ACR:          $acrName"     -ForegroundColor Green
Write-Host "    MCP endpoint: $mcpEndpoint" -ForegroundColor Green

if (-not $SkipImageBuild) {
    if (-not (Test-Path (Join-Path $AppSourcePath 'Dockerfile'))) {
        Write-Warning "No Dockerfile in '$AppSourcePath'. It should contain Dockerfile, mcp_server.py and sources.yaml (with YOUR database endpoints). Build manually, then run: az containerapp update -n $appName -g $ResourceGroup --image $acrLoginServer/$ImageTag"
    }
    else {
        Write-Host "==> Building + pushing $ImageTag from $AppSourcePath ..." -ForegroundColor Cyan
        az acr build --registry $acrName --image $ImageTag $AppSourcePath
        if ($LASTEXITCODE -ne 0) { throw 'Image build failed.' }

        Write-Host '==> Pointing the Container App at your image...' -ForegroundColor Cyan
        az containerapp update --name $appName --resource-group $ResourceGroup --image "$acrLoginServer/$ImageTag" | Out-Null
    }
}

Write-Host ''
Write-Host 'Infrastructure ready.' -ForegroundColor Green
Write-Host "  MCP endpoint : $mcpEndpoint"
Write-Host "  Foundry      : $foundryEndpoint"
Write-Host ''
Write-Host 'MANUAL STEPS (one-time, data plane):' -ForegroundColor Yellow
Write-Host '  1. Create the read-only SQL login on each database (matching -SqlPassword).'
Write-Host '  2. In the Azure AI Foundry portal: create a project + agent using the deployed model.'
Write-Host "  3. Add an MCP tool -> URL: $mcpEndpoint   (Auth: Microsoft Entra / Project Managed Identity)."
Write-Host '  4. Lock the endpoint to your agent (after it exists):'
Write-Host "       az containerapp update -n $appName -g $ResourceGroup ``"
Write-Host '         --set-env-vars ALLOWED_AUDIENCES=api://<your-app-reg> ALLOWED_CALLERS=<agent-azp>'
