# AVS AI Data Agent — deployment kit

Deploy a **managed Azure AI Foundry agent that queries private databases running on VMs inside your Azure VMware Solution (AVS) private cloud** — in natural language, read-only, credential-less, and without exposing anything to the internet.

The agent calls an **MCP server** hosted on a **VNet-integrated Azure Container App** that reaches your AVS databases over **ExpressRoute**, pulls credentials from **Key Vault** with a **managed identity**, and only ever runs `SELECT` queries.

---

## What's in the box

| Path | Purpose |
|---|---|
| `infra/main.bicep` / `infra/main.json` | The app infrastructure (subnet, ACR, Key Vault, Container Apps, RBAC, optional Foundry) |
| `infra/main.bicepparam` | Parameters file for `main.bicep` |
| `infra/deploy.ps1` | One command: deploy infra → build/push the MCP image → point the app at it |
| `infra/connectivity.bicep` | **Optional** — creates a VNet + ExpressRoute connection to your AVS private cloud (only if you don't already have one) |
| `app/` | The MCP server: `Dockerfile`, `mcp_server.py`, `requirements.txt`, `sources.yaml` |
| `docs/` | The technical blog (`blog.md`) and screenshots (`media/`) |

---

## Prerequisites

- **Azure CLI** (`az`) — logged in and set to the target subscription (`az account set --subscription <id>`).
- **An AVS private cloud** with your databases on a workload segment.
- **A VNet with ExpressRoute connectivity to AVS.** The simplest way is the built-in AVS **Azure vNet connect** feature (AVS private cloud → **Connectivity → Azure vNet connect**), which creates/selects a VNet with a `GatewaySubnet` and wires up ExpressRoute for you — no gateway to build by hand. Alternatively, use `connectivity.bicep` (below) to script it end to end.
- **Permissions:** Contributor on the resource group; ability to create a Microsoft Entra app registration (for the token audience); a read-only login on each database.

---

## Quick start

```powershell
# 0. Make sure you have a VNet connected to AVS (skip if you already do).
#    EASIEST: AVS private cloud -> Connectivity -> "Azure vNet connect" -> create or
#    select a VNet (it needs a GatewaySubnet); AVS wires up ExpressRoute for you.
#    OR script it (creates the gateway + connection, ~30-45 min):
#      az deployment group create -g <your-rg> --template-file infra/connectivity.bicep `
#        --parameters avsPrivateCloudName=<your-avs-private-cloud>
#    Either way, pass that VNet as -ExistingVnetName below; main.bicep adds the
#    delegated aca-subnet to it.

# 1. Register your databases
#    Edit app/sources.yaml with each database's host/port/database, engine type,
#    username, and the Key Vault secret name that will hold its password.

# 2. Deploy everything + build & push the MCP image (defaults to the bundled app/ folder)
./infra/deploy.ps1 -ResourceGroup <your-rg> -ExistingVnetName <your-vnet> `
             -SqlPassword (Read-Host 'DB password' -AsSecureString)
```

Then finish the **manual steps** below.

### Other ways to deploy the infra
```powershell
# Bicep + params file
az deployment group create -g <rg> --parameters infra/main.bicepparam --parameters sqlPassword=<pwd>

# Pure ARM JSON
az deployment group create -g <rg> --template-file infra/main.json `
  --parameters existingVnetName=<vnet> sqlPassword=<pwd>
```

---

## Manual steps (data plane — these can't live in ARM)

1. **Create the read-only DB login** on each database, matching the `-SqlPassword` you deployed with (e.g. a login `agentreader` with `db_datareader` only).

2. **Create a Microsoft Entra app registration** to serve as the token *audience* (one-time):
   ```powershell
   $app = az ad app create --display-name "avs-mcp-audience" | ConvertFrom-Json
   az ad app update --id $app.appId --identifier-uris "api://$($app.appId)"
   "audience = api://$($app.appId)"
   ```

3. **In the Azure AI Foundry portal:** create a project + agent (use the model deployed here), then **attach an MCP tool**:
   - **Server URL:** the `mcpEndpoint` output (e.g. `https://<app>.<region>.azurecontainerapps.io/mcp`)
   - **Authentication:** Microsoft Entra / **Project Managed Identity**
   - **Audience:** `api://<appId>` from step 2

4. **Lock the endpoint to your agent** (the server ships in *discovery mode* to make this painless):
   - Ask one test question in the playground. The server **logs the caller's identity**:
     ```powershell
     az containerapp logs show -n avsai-mcp-server -g <rg> --type console --tail 40 | Select-String AUTH
     #  -> AUTH discovery: caller azp=<GUID> aud=<...> -- set ALLOWED_CALLERS to this azp to lock the endpoint
     ```
   - Set the two env vars to switch from discovery to **enforced**:
     ```powershell
     az containerapp update -n avsai-mcp-server -g <rg> `
       --set-env-vars ALLOWED_AUDIENCES=api://<appId> ALLOWED_CALLERS=<azp-from-logs>
     ```
   From now on the server accepts calls **only** from your Foundry agent's identity.

---

## Configuration reference

### `infra/main.bicep` parameters
| Parameter | Default | Notes |
|---|---|---|
| `existingVnetName` | *(required)* | Your VNet with ExpressRoute to AVS |
| `acaSubnetPrefix` | `10.40.8.0/23` | Free /23 for the bridge subnet |
| `sqlPassword` | *(required, secure)* | Read-only DB password → Key Vault |
| `namePrefix` | `avsai` | Resource name prefix |
| `containerImage` | public placeholder | Swapped to your image by `deploy.ps1` |
| `deployFoundry` | `true` | Also create a Foundry account + model |
| `modelName` / `modelVersion` | `gpt-4o-mini` / `2024-07-18` | Model deployment |
| `allowedAudiences` / `allowedCallers` | `''` | Set after the agent exists (see step 4) |

### `app/sources.yaml`
Register each database the agent may read. The `type` selects the driver:
```yaml
sources:
  sales:
    type: mssql            # mssql | postgresql | mysql | oracle
    connection: { host: 10.0.0.10, port: 1433, database: SalesDB }
    auth: { kind: sql, username: agentreader, secret: sql-agentreader-password }
    governance: { allow_schemas: [dbo], max_rows: 200 }   # optional: deny_tables, mask
```
Onboarding a new database = add a block here + a Key Vault secret + rebuild the image.

### Adding another engine
Uncomment the driver in `app/requirements.txt` (`psycopg2-binary`, `pymysql`, `oracledb`), add the source block, add its Key Vault secret, and rebuild.

---

## Security model
- **Read-only** — only `SELECT`/`WITH`; DML/DDL blocked; results row-capped per source.
- **No secrets in code** — DB passwords live in Key Vault; the app reads them with its managed identity.
- **Managed-identity auth** — the agent presents an Entra token; the server validates signature, audience, issuer, and caller (`azp`).
- **Private** — reaches AVS over ExpressRoute; databases are never exposed to the internet.

---

## Troubleshooting
- **`401 unauthorized` after locking:** the token's `azp` doesn't match `ALLOWED_CALLERS`. Re-check the discovery log line, or temporarily clear `ALLOWED_CALLERS` to re-enter discovery mode.
- **App won't pull the image:** the `AcrPull` role is granted to the app's managed identity by the template; if you changed the ACR, re-assign it.
- **`Query error: Invalid column/object name`:** the agent guessed a name — its instructions tell it to call `get_schema` first; the server also returns the available objects as a hint.
- **Connectivity deploy is slow:** the ExpressRoute gateway in `connectivity.bicep` takes ~30-45 minutes. This is expected and one-time.
