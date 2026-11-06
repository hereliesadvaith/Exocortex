# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "fastmcp==4.1.6",  # pinned: AllowlistedGitHubProvider relies on the "login" claim
#   "ngrok",
#   "psycopg[binary]",
#   "python-dotenv",
# ]
# ///
import os
from pathlib import Path

import ngrok
import psycopg
from dotenv import load_dotenv
from fastmcp import FastMCP
from fastmcp.server.auth.providers.github import GitHubProvider
from psycopg.rows import dict_row

load_dotenv(Path(__file__).parent / ".env")

DSN = (
    f"host={os.getenv('POSTGRES_HOST', 'localhost')} "
    f"port={os.getenv('POSTGRES_PORT', '5432')} "
    f"user={os.getenv('POSTGRES_USER', 'postgres')} "
    f"password={os.environ['POSTGRES_PASSWORD']} "
    f"dbname={os.getenv('POSTGRES_DB', 'postgres')} "
    f"options='-c statement_timeout={os.getenv('QUERY_TIMEOUT_MS', '15000')}'"
)

MAX_ROWS = int(os.getenv("QUERY_MAX_ROWS", "500"))

ALLOWED_USERS = {
    u.strip().lower()
    for u in os.environ["GITHUB_ALLOWED_USERS"].split(",")
    if u.strip()
}

PORT = int(os.getenv("MCP_PORT", "8000"))


class AllowlistedGitHubProvider(GitHubProvider):
    """GitHub OAuth that only accepts the GitHub usernames in GITHUB_ALLOWED_USERS."""

    async def load_access_token(self, token: str):
        access = await super().load_access_token(token)
        if access is None:
            return None
        login = (access.claims or {}).get("login") or ""
        return access if login.lower() in ALLOWED_USERS else None


auth = AllowlistedGitHubProvider(
    client_id=os.environ["GITHUB_CLIENT_ID"],
    client_secret=os.environ["GITHUB_CLIENT_SECRET"],
    base_url=os.getenv("MCP_BASE_URL") or f"https://{os.environ['NGROK_DOMAIN']}",
)

mcp = FastMCP("postgres", auth=auth)


@mcp.tool
def query(sql: str) -> list[dict]:
    """Run any SQL statement against the Postgres database (reads and writes).

    Returns result rows for queries that produce them (at most QUERY_MAX_ROWS;
    if more exist, a final {"truncated": true} row is appended, so use LIMIT/OFFSET);
    for other statements returns the affected row count. Changes are committed
    automatically. Statements are cancelled after QUERY_TIMEOUT_MS.
    """
    with psycopg.connect(DSN, row_factory=dict_row, autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            if cur.description:
                rows = cur.fetchmany(MAX_ROWS + 1)
                if len(rows) > MAX_ROWS:
                    return rows[:MAX_ROWS] + [{"truncated": True, "max_rows": MAX_ROWS}]
                return rows
            return [{"status": cur.statusmessage, "rowcount": cur.rowcount}]


if __name__ == "__main__":
    if os.getenv("NGROK_AUTHTOKEN"):
        tunnel = ngrok.forward(
            f"localhost:{PORT}",
            authtoken=os.environ["NGROK_AUTHTOKEN"],
            domain=os.environ["NGROK_DOMAIN"],
        )
        print(f"ngrok tunnel: {tunnel.url()} -> localhost:{PORT}", flush=True)
    mcp.run(transport="http", host=os.getenv("MCP_HOST", "127.0.0.1"), port=PORT)
