"""
MCP data server for the AVS AI Data Agent.

Exposes three read-only tools (list_sources, get_schema, run_query) over MCP
(streamable-http) against any SQL databases declared in sources.yaml. Multi-engine
via SQLAlchemy. Credentials are pulled from Key Vault at runtime using the
container's managed identity. Requests to /mcp are validated as Microsoft Entra
tokens from your Foundry agent.

Environment variables:
  KEY_VAULT_URL      required. https://<vault>.vault.azure.net/
  SQL_USER           fallback DB username if a source omits one (default: agentreader)
  HOST / PORT        listen address (default 0.0.0.0:8000)
  TENANT_ID          Entra tenant used to validate tokens
  ALLOWED_AUDIENCES  comma-separated allowed token audiences (your app registration)
  ALLOWED_CALLERS    comma-separated allowed caller app ids (azp) = your Foundry agent.
                     If EMPTY, the server runs in DISCOVERY mode: it logs each caller's
                     azp so you can find it, then set ALLOWED_CALLERS to lock the endpoint.
"""
import base64
import fnmatch
import json
import os
from functools import lru_cache

import jwt
import uvicorn
import yaml
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from dotenv import load_dotenv
from jwt import PyJWKClient
from mcp.server.fastmcp import FastMCP
from sqlalchemy import create_engine, inspect
from sqlalchemy.engine import URL
from starlette.responses import JSONResponse

load_dotenv()
KEY_VAULT_URL = os.environ["KEY_VAULT_URL"]
SQL_USER = os.getenv("SQL_USER", "agentreader")

# ---- Entra token validation (all env-driven; nothing baked in) --------------
TENANT_ID = os.getenv("TENANT_ID", "")
ALLOWED_AUDIENCES = [a for a in os.getenv("ALLOWED_AUDIENCES", "").split(",") if a]
ALLOWED_CALLERS = {c for c in os.getenv("ALLOWED_CALLERS", "").split(",") if c}
ALLOWED_ISSUERS = {
    f"https://login.microsoftonline.com/{TENANT_ID}/v2.0",
    f"https://sts.windows.net/{TENANT_ID}/",
} if TENANT_ID else set()
_jwks = PyJWKClient(f"https://login.microsoftonline.com/{TENANT_ID}/discovery/v2.0/keys") if TENANT_ID else None

# ---- Source catalog ---------------------------------------------------------
with open("sources.yaml") as f:
    SOURCES = yaml.safe_load(f)["sources"]

_kv = SecretClient(vault_url=KEY_VAULT_URL, credential=DefaultAzureCredential())


@lru_cache
def _secret(name: str) -> str:
    return _kv.get_secret(name).value


_DIALECTS = {
    "mssql": ("mssql+pyodbc", {"driver": "ODBC Driver 18 for SQL Server",
                                "Encrypt": "yes", "TrustServerCertificate": "yes"}),
    "postgresql": ("postgresql+psycopg2", {}),
    "mysql": ("mysql+pymysql", {}),
    "oracle": ("oracle+oracledb", {}),
}


@lru_cache
def _engine(source: str):
    if source not in SOURCES:
        raise ValueError(f"Unknown source '{source}'. Options: {', '.join(SOURCES)}")
    s = SOURCES[source]
    drivername, query = _DIALECTS[s["type"]]
    auth = s.get("auth", {})
    url = URL.create(
        drivername,
        username=auth.get("username", SQL_USER),
        password=_secret(auth["secret"]) if auth.get("secret") else None,
        host=s["connection"]["host"],
        port=s["connection"].get("port"),
        database=s["connection"]["database"],
        query=query,
    )
    return create_engine(url, pool_pre_ping=True)


def _gov(source: str) -> dict:
    return SOURCES[source].get("governance", {}) or {}


def _schema_allowed(source: str, schema: str) -> bool:
    allow = _gov(source).get("allow_schemas")
    return schema in allow if allow else True


def _table_denied(source: str, fq_table: str) -> bool:
    return any(fnmatch.fnmatch(fq_table.lower(), p.lower())
               for p in _gov(source).get("deny_tables", []))


mcp = FastMCP("avs-data", host=os.getenv("HOST", "0.0.0.0"), port=int(os.getenv("PORT", "8000")))


@mcp.tool()
def list_sources() -> str:
    """List the available data sources (databases) and what each contains."""
    return "\n".join(f"- {n}: {s.get('description','')} [{s['type']}]" for n, s in SOURCES.items())


@mcp.tool()
def get_schema(source: str) -> str:
    """Get the tables and columns for a data source. Call list_sources first for valid names."""
    insp = inspect(_engine(source))
    lines = []
    for schema in insp.get_schema_names():
        if not _schema_allowed(source, schema):
            continue
        for table in insp.get_table_names(schema=schema):
            fq = f"{schema}.{table}"
            if _table_denied(source, fq):
                continue
            cols = ", ".join(f"{c['name']} ({c['type']})" for c in insp.get_columns(table, schema=schema))
            lines.append(f"{fq}: {cols}")
    return "\n".join(lines) or "No tables."


_BLOCKED = (" insert ", " update ", " delete ", " drop ", " alter ", " truncate ",
            " exec ", " execute ", " merge ", " create ", " grant ", " revoke ", " into ")


@mcp.tool()
def run_query(source: str, query: str) -> str:
    """Run ONE read-only SELECT against a named source and return up to the source's row cap.
    Use the SQL dialect of that source (shown by list_sources)."""
    q = query.strip().rstrip(";")
    low = f" {q.lower()} "
    if not (low.lstrip().startswith("select") or low.lstrip().startswith("with")):
        return "Error: only a single read-only SELECT (or WITH ... SELECT) is allowed."
    if ";" in q or any(w in low for w in _BLOCKED):
        return "Error: only a single read-only SELECT statement is allowed."
    max_rows = int(_gov(source).get("max_rows", 200))
    try:
        with _engine(source).connect() as conn:
            result = conn.exec_driver_sql(q)
            cols = list(result.keys())
            rows = result.fetchmany(max_rows)
    except Exception as e:
        return f"Query error: {e}\n\nTip: call get_schema('{source}') and use the exact table/column names."
    if not rows:
        return "No rows returned."
    return "\n".join([" | ".join(cols)] + [" | ".join(str(v) for v in r) for r in rows])


class AuthMiddleware:
    """Validate the Entra token on /mcp.
    DISCOVERY mode (ALLOWED_CALLERS empty): log the caller azp, then allow.
    ENFORCED mode: require signature (JWKS) + audience + issuer + caller in the allow-list."""
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and scope.get("path", "").startswith("/mcp"):
            hdrs = dict(scope.get("headers") or [])
            auth = hdrs.get(b"authorization", b"").decode()
            token = auth[7:] if auth.lower().startswith("bearer ") else ""

            if not ALLOWED_CALLERS:
                # discovery: help the operator find the caller azp so they can lock the endpoint
                if token:
                    try:
                        p = token.split(".")[1]
                        p += "=" * (-len(p) % 4)
                        c = json.loads(base64.urlsafe_b64decode(p))
                        print(f"AUTH discovery: caller azp={c.get('azp') or c.get('appid')} "
                              f"aud={c.get('aud')} -- set ALLOWED_CALLERS to this azp to lock the endpoint",
                              flush=True)
                    except Exception:
                        pass
                await self.app(scope, receive, send)
                return

            reason = None
            if not token:
                reason = "no bearer token"
            elif _jwks is None:
                reason = "server missing TENANT_ID"
            else:
                try:
                    key = _jwks.get_signing_key_from_jwt(token)
                    claims = jwt.decode(token, key.key, algorithms=["RS256"],
                                        audience=ALLOWED_AUDIENCES or None,
                                        options={"verify_aud": bool(ALLOWED_AUDIENCES)})
                    if ALLOWED_ISSUERS and claims.get("iss") not in ALLOWED_ISSUERS:
                        reason = f"bad issuer {claims.get('iss')}"
                    elif (claims.get("azp") or claims.get("appid")) not in ALLOWED_CALLERS:
                        reason = "caller not allowed"
                except Exception as e:
                    reason = f"invalid token: {e}"
            if reason:
                print(f"AUTH deny: {reason}", flush=True)
                await JSONResponse({"error": "unauthorized"}, status_code=401)(scope, receive, send)
                return
        await self.app(scope, receive, send)


if __name__ == "__main__":
    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8000"))
    app = mcp.streamable_http_app()
    app.add_middleware(AuthMiddleware)
    uvicorn.run(app, host=host, port=port)
