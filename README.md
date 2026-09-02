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
| `infra/connectivity.bicep` | **Optional, AVS Gen 1 only** — creates a VNet + ExpressRoute connection to your AVS private cloud (only if you don't already have one) |
| `app/` | The MCP server: `Dockerfile`, `mcp_server.py`, `requirements.txt`, `sources.yaml` |
| `docs/` | The technical blog (`blog.md`) and screenshots (`media/`) |

---

## Prerequisites

- **Azure CLI** (`az`) — **version 2.53.0 or newer**, logged in and set to the target subscription (`az account set --subscription <id>`). Older CLIs pin the `Microsoft.App` API to `2022-10-01`, which predates Container Apps *workload profiles*: `az containerapp update` fails with `WorkloadProfilePropertyNotSupportedInApiVersion`, and `az containerapp show` reports `workloadProfiles: null` and an empty `workloadProfileName` **even when they are correctly set** — which makes triage actively misleading. Check with `az version`; upgrade with `az upgrade`. To inspect the app with a stale CLI, bypass it: `az rest --method get --url "<appResourceId>?api-version=2024-03-01"`.
- **An AVS private cloud** with your databases on a workload segment.
- **A VNet that can reach AVS.** On **Gen 1** that means ExpressRoute connectivity — the simplest way is the built-in AVS **Azure vNet connect** feature (AVS private cloud → **Connectivity → Azure vNet connect**), which creates/selects a VNet with a `GatewaySubnet` and wires up ExpressRoute for you; alternatively use `connectivity.bicep` (below) to script it end to end. On **Gen 2** the private cloud already lives in one of your VNets, so you just use that VNet (or one peered to it) — see [AVS Gen 1 and Gen 2](#avs-gen-1-and-gen-2) below.
- **Permissions:** Contributor on the resource group; ability to create a Microsoft Entra app registration (for the token audience); a read-only login on each database.
- **Outbound internet from the AVS workload segment** is *not* required, but the SDDC must be able to route the segment over ExpressRoute. If your VMs need internet for setup (e.g. installing SQL Server), enable it on the private cloud first.

### AVS Gen 1 and Gen 2

The agent, the MCP server and its auth are **generation-agnostic** — they only need IP reachability to your database VMs on their SQL port. `main.bicep` never references an AVS resource either; it takes the name of an existing VNet, so it deploys unchanged on both generations. Only the **networking you point it at** differs:

| | Gen 1 | Gen 2 |
|---|---|---|
| How Azure reaches the private cloud | A Microsoft-managed **ExpressRoute circuit**; you connect a VNet with an ER gateway + authorization key | The private cloud is **injected into your own VNet**; no circuit or authorization key for Azure-side connectivity |
| Where the delegated `aca-subnet` goes | Any VNet connected to that circuit | The private cloud's **own VNet**, or a VNet peered to it |
| `infra/connectivity.bicep` | Use it (or *Azure vNet connect*) | **Doesn't apply** — skip it |

`connectivity.bicep` is **Gen 1 only**: it creates an ExpressRoute authorization on the private cloud and connects a gateway to `properties.circuit.expressRouteID`. A Gen 2 private cloud has no such circuit to authorize, so on Gen 2 you skip that template entirely and simply add the delegated `aca-subnet` to the private cloud's VNet (Gen 2 requires that VNet to sit in the same resource group as the private cloud). AVS Gen 2 programs your NSX segment routes into that VNet automatically, so a Container App there can reach workload VMs with no gateway at all. If you instead place the subnet in a *peered* VNet, you may need route-table entries carrying the specific NSX segment prefixes rather than relying on the broader address space.

> Validated end to end on **Gen 1** (`av36`). The Gen 2 path follows from the documented networking model but has not been exercised here.

---

## Quick start

```powershell
# 0. Make sure you have a VNet connected to AVS (skip if you already do).
#    EASIEST: AVS private cloud -> Connectivity -> "Azure vNet connect" -> create or
#    select a VNet (it needs a GatewaySubnet); AVS wires up ExpressRoute for you.
#    OR script it (creates the gateway + connection, ~30-45 min). NOTE: this creates an
#    ExpressRoute authorization ON the private cloud, so it must be deployed into the
#    private cloud's OWN resource group:
#      az deployment group create -g <avs-private-cloud-rg> --template-file infra/connectivity.bicep `
#        --parameters avsPrivateCloudName=<your-avs-private-cloud>
#    connectivity.bicep ALSO creates the delegated aca-subnet, so if you used it, add
#    -SkipAcaSubnet below. Otherwise main.bicep creates that subnet for you.

# 1. Register your databases
#    Edit app/sources.yaml with each database's host/port/database, engine type,
#    username, and the Key Vault secret name that will hold its password.

# 2. Deploy everything + build & push the MCP image (defaults to the bundled app/ folder)
#    -Location matters when the resource group is in a different region than the VNet.
#    -FoundryLocation lets Foundry live in a model-rich region (the agent reaches the
#    MCP server over public HTTPS, so it does not have to sit next to AVS).
./infra/deploy.ps1 -ResourceGroup <your-rg> -ExistingVnetName <your-vnet> `
             -Location <vnet-region> -FoundryLocation <model-region> `
             -SqlPassword (Read-Host 'DB password' -AsSecureString)
```

Then finish the **manual steps** below.

### Other ways to deploy the infra
```powershell
# Bicep + params file  (requires az CLI >= 2.53.0 - older CLIs don't understand .bicepparam
# and fail with "Chose only one of --template-file FILE | --template-uri URI")
az deployment group create -g <rg> --parameters infra/main.bicepparam --parameters sqlPassword=<pwd>

# Pure ARM JSON  (no Bicep tooling needed; main.json is generated from main.bicep,
# so regenerate it with `az bicep build --file main.bicep --outfile main.json` if you edit the Bicep)
az deployment group create -g <rg> --template-file infra/main.json `
  --parameters existingVnetName=<vnet> sqlPassword=<pwd> location=<vnet-region>
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

3. **Create the agent.** The template already created the account, the **project**
   (`foundryProjectName`) and the model deployment, so all that's left is the agent and its
   MCP tool. You can do this in the portal or from code — but **mind which agent API you use**:

   > **There are two different agent collections, and the portal only shows one of them.**
   > `POST {project}/assistants` (threads/runs) and `POST {project}/agents` (versioned agents,
   > **Responses** protocol) are *separate stores*. An agent created under `/assistants` does
   > **not** appear in the portal's Agents list, which makes it look like nothing was created.
   > Use **`/agents`**.

   Creating it from code (`api-version=v1`):
   ```jsonc
   POST {project}/agents?api-version=v1
   {
     "name": "avs-data-agent",
     "definition": {
       "kind": "prompt",                       // one of: prompt|hosted|workflow|external|voice
       "model": "gpt-5.4-mini",
       "instructions": "...",
       "tools": [{
         "type": "mcp",
         "server_label": "avs_data",
         "server_url": "<mcpEndpoint output>",
         "allowed_tools": ["list_sources", "get_schema", "run_query"],
         "require_approval": "never",
         "project_connection_id": "avs-mcp-auth"   // recommended; see below
       }]
     }
   }
   ```

   There are two ways to give that tool a credential:

   **a. A project connection (recommended)** — the credential lives on the project, not in
   the agent definition, so you can rotate it without touching the agent. Create a
   **CustomKeys** connection whose `target` is the MCP endpoint; the **key name is the HTTP
   header name** and the value is sent **verbatim**, so the `Bearer ` prefix belongs here:
   ```jsonc
   PUT {armId}/projects/{project}/connections/avs-mcp-auth?api-version=2025-06-01
   { "properties": {
       "category": "CustomKeys", "authType": "CustomKeys",
       "target": "<mcpEndpoint output>",
       "credentials": { "keys": { "Authorization": "Bearer <access token>" } } } }
   ```
   Then reference it by name (or full ARM ID) in `project_connection_id`, as shown above.

   **b. Inline** — set `"authorization": "<access token>"` on the tool instead. Simpler for a
   one-off test, but it puts a secret in the agent definition and you must re-create the
   agent to rotate it.

   Then invoke it — note the unusual path, and that **`api-version` must be omitted**:
   ```jsonc
   POST {project}/openai/v1/responses
   { "agent_reference": { "type": "agent_reference", "name": "avs-data-agent" },
     "input": "Which products are selling well but are at or below their reorder point?" }
   ```

   Give the agent instructions that suit a multi-source server. This one matters more than it
   looks: each source is a **separate** database server, so the model will happily emit
   `inventory.dbo.Products` from the `sales` source, get an error, and then conclude the
   question is unanswerable instead of correlating client-side.
   ```text
   You answer questions using ONLY the avs_data MCP tool, which reaches SQL Server databases
   running on virtual machines inside an Azure VMware Solution private cloud.
   Call list_sources first, then get_schema for each relevant source, then run_query with a
   single read-only SELECT. run_query takes "source" and "query".

   IMPORTANT: each source is a SEPARATE database server. You cannot join across sources in
   SQL, and a query naming another source will fail. To combine data, query each source
   independently and correlate the results yourself, matching on the shared business key.

   Never invent data. State which database each number came from.
   ```

   Gotchas that cost real debugging time:
   - **A brand-new connection may not be usable on the very first run.** Reference it
     immediately after creating it and the runtime can still send *no* credential — the
     server logs `AUTH deny: no bearer token` and the run fails `424`, which looks exactly
     like a misconfigured connection. If that happens, re-`PUT` the connection, pause
     briefly, and run again; it then works and keeps working.
   - **`authorization` takes the bare token — Foundry adds `Bearer ` itself.** Passing
     `"Bearer eyJ…"` yields a doubled prefix and the server rejects it with
     `invalid token: Invalid header padding`. Note this is the **opposite** convention to the
     connection `keys` value above, which is sent verbatim and *does* need the prefix.
   - **`headers` is refused outright** at create time: *"Headers that can include sensitive
     information are not allowed in the headers property for MCP tools. Use
     project_connection_id instead."* Use the connection route above.
   - **`audience` is accepted and stored by the create call but rejected at run time** with
     `Unknown parameter: 'tools[0].audience'`. Don't rely on it.
   - On the older `/assistants` surface, run-level `tool_resources.mcp[].headers` will **not**
     forward a *cryptographically valid* Entra token: the run dies with a generic
     `server_error` before any outbound call, while the same token with a corrupted signature
     — or a random string of identical length — goes through. Another reason to use `/agents`.
   - With no auth configured the agent calls **anonymously**, the server correctly answers
     `401`, and the run fails with `Server returned 424` /
     `MCP Connector error … Error retrieving tool list`. A `424` therefore means *"your tool
     has no working credential"*, not *"the server is down"*.

   Whichever route you pick, an Entra access token expires (typically ~1 hour). With a
   connection you refresh it in one place — re-`PUT` the connection — and every agent that
   references it picks the new value up on the next run.

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
| `createAcaSubnet` | `true` | Set **false** if `connectivity.bicep` already created `aca-subnet` — otherwise this template re-writes it, and a mismatched prefix silently reconfigures or fails it |
| `sqlPassword` | *(required, secure)* | Read-only DB password → Key Vault |
| `namePrefix` | `avsai` | Resource name prefix |
| `location` | RG location | Put this in the **VNet's** region |
| `foundryLocation` | `location` | Foundry may live elsewhere — the agent reaches the MCP server over public HTTPS. Use this when the AVS region has no GPT models (e.g. `westus2`) |
| `containerImage` | public placeholder | Swapped to your image by `deploy.ps1` |
| `deployFoundry` | `true` | Also create a Foundry account + **project** + model. The account is created with `allowProjectManagement`, without which no project can exist — and without a project you cannot create an agent at all |
| `foundryProjectName` | `<namePrefix>-project` | Foundry project that hosts the agent. Its endpoint and system-assigned principal are returned as the `foundryProjectEndpoint` / `foundryProjectPrincipalId` outputs |
| `modelName` / `modelVersion` | `gpt-5.4-mini` / `2026-03-17` | **Verify before deploying:** model availability *and lifecycle* vary by region, and a model whose `lifecycleStatus` is `Deprecating` is rejected for **new** deployments even where it still runs. Check with `az cognitiveservices model list -l <foundryLocation> --query "[?model.name=='<name>'].{v:model.version,s:model.lifecycleStatus,sku:model.skus[].name}"` |
| `allowedAudiences` / `allowedCallers` | `''` | Set after the agent exists (see step 4) |
| `discoveryMode` | `false` | Temporarily accept any valid Entra token so you can read the caller `azp` from the logs. **Never leave this on.** |

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
- **Read-only** — only `SELECT`/`WITH`; DML/DDL blocked; results row-capped per source. Back this with a genuinely read-only DB login (`db_datareader`) so the database enforces it too.
- **No secrets in code** — DB passwords live in Key Vault; the app reads them with its user-assigned managed identity and caches them for `SECRET_TTL_SECONDS` (default 1h) so rotations converge.
- **Managed-identity auth** — the agent presents an Entra token; the server validates signature, audience, issuer, and caller (`azp`) on **every** request.
- **Match `azp`, not `appid`** — Foundry calls the tool with a **v2** token whose `appid` claim is **empty**; the calling application's identity is carried in **`azp`**. Anything that authorizes on `appid` alone — including Container Apps **Easy Auth**, whose allowed-client-applications list matches `appid` — will therefore reject the agent no matter what you put in the list. That is why authorization is done in-app here: `AuthMiddleware` reads `azp` first and falls back to `appid` for other callers. (Easy Auth's "allow any application" toggle would sidestep the matching problem, but it also removes the caller check entirely, and many tenants disable it by policy.)
- **Fails closed** — the ingress is internet-facing, so an unset `ALLOWED_CALLERS` must never mean "allow anyone". With no allow-list the server returns `503` until you either set `ALLOWED_CALLERS` or *explicitly* opt into `discoveryMode`. Discovery mode still requires a valid, signature-verified Entra token from your tenant; it only relaxes the caller allow-list. Turn it off once you've read the `azp`.
- **Private** — reaches AVS over ExpressRoute; databases are never exposed to the internet.
- **Transport** — connections use `Encrypt=yes`, but default to `TrustServerCertificate=yes` because AVS workload VMs typically present self-signed SQL certificates. That encrypts the link without authenticating the server; set `SQL_TRUST_SERVER_CERT=false` once your databases use a trusted certificate.

---

## Troubleshooting
- **`503` / "server is not locked down":** `ALLOWED_CALLERS` is empty and discovery mode is off. This is deliberate — set `allowedCallers`, or deploy once with `discoveryMode=true` to learn the `azp`.
- **`401 unauthorized` after locking:** the token's `azp` doesn't match `ALLOWED_CALLERS`. Re-check the discovery log line, or redeploy with `discoveryMode=true` to re-enter discovery.
- **The agent you created isn't in the portal:** you almost certainly created it under `/assistants`. The portal lists the `/agents` collection — they are separate stores. Re-create it with `POST {project}/agents` (see step 3).
- **Run fails with `MCP Connector error. Http status: 424 …` or `Server returned 424`:** Foundry reached the server but couldn't list tools — nearly always because the tool has **no working credential**, so it called anonymously and got the server's `401`. Confirm the direction from the server side: a `401` in the container logs means the request arrived; *no* log line at all means Foundry never called out.
- **`AUTH deny: invalid token: Invalid header padding`:** you put `"Bearer …"` in the tool's `authorization` property. It takes the **bare token** — Foundry adds the `Bearer ` prefix itself.
- **`AUTH deny: no bearer token` when the tool uses `project_connection_id`:** the connection was created moments earlier. The agent runtime resolves connections with a short lag; until it does, it calls anonymously and you get a `424`. Pause after the `PUT`, then re-run.
- **`GET {project}/agents` looks empty:** the response is an **OpenAI-style envelope** — the agents are in `data` (with `first_id` / `last_id` / `has_more`), *not* in ARM's usual `value`. Reading `.value` yields zero agents and makes it look like nothing was created.
- **`Unknown parameter: 'tools[0].audience'` at run time,** even though the create call accepted `audience`: the management and runtime schemas disagree. Drop `audience`.
- **Run fails with a bare `server_error` and nothing reaches the server:** you are passing a real Entra token in `tool_resources.mcp[].headers` on the older `/assistants` surface. Foundry blocks forwarding valid Entra tokens there — use `/agents` with `authorization`, or a project connection.
- **`401 unauthorized` while the tool *is* configured:** the `aud` Foundry sends may be the **bare app ID**, not the `api://` URI. Put **both** forms in `ALLOWED_AUDIENCES` (`api://<appId>,<appId>`).
- **Env-var changes appear to do nothing:** the app reads its configuration once at process start, so `ALLOWED_CALLERS` / `ALLOWED_AUDIENCES` / `DISCOVERY_MODE` only take effect on a **new revision**. Redeploy, or restart the revision.
- **Container App stuck `InProgress` with no revisions:** almost always the image pull. The template uses a **user-assigned** identity precisely so `AcrPull` exists *before* the app is created; a system-assigned identity deadlocks (the role assignment needs the app's principal, the app needs the role to start).
- **`ModuleNotFoundError: No module named 'mcp.server.fastmcp'`:** you built with an unpinned MCP SDK. `requirements.txt` pins `mcp[cli]<2` because the 2.x SDK renamed `FastMCP`.
- **No container logs anywhere:** the environment must have `appLogsConfiguration`. The template creates a Log Analytics workspace and wires it up; a revision created *before* that config was added must be restarted to start shipping logs. Query with:
  `az monitor log-analytics query -w <workspaceGuid> --analytics-query "ContainerAppConsoleLogs_CL | where ContainerAppName_s == '<app>' | order by TimeGenerated desc | take 50"`
- **`az acr build` fails on Windows with `UnicodeEncodeError`:** a client-side log-streaming bug (colorama/cp1252). **The server-side build usually succeeded** — confirm with `az acr repository show-tags -n <acr> --repository avs-mcp` before rebuilding. `deploy.ps1` sets `PYTHONIOENCODING=utf-8` and verifies the tag rather than aborting.
- **`az containerapp` errors mentioning `WorkloadProfilePropertyNotSupportedInApiVersion`, or `workloadProfiles` showing as `null`:** your Azure CLI is too old (see Prerequisites). Upgrade, or read the app through `az rest ... --api-version 2024-03-01`.
- **Cancelling a stuck deployment doesn't help:** cancelling the ARM deployment does **not** cancel the underlying Container Apps operation. Later deploys then fail with `ContainerAppOperationInProgress`; wait for it to settle, then delete the app and redeploy.
- **`Query error: Invalid column/object name`:** the agent guessed a name — its instructions tell it to call `get_schema` first; the server also returns the available objects as a hint.
- **Connectivity deploy is slow:** the ExpressRoute gateway in `connectivity.bicep` takes ~30-45 minutes. This is expected and one-time.
