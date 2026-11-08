# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "fastmcp==4.1.6",  # keep in sync with requirements.txt
#   "ngrok",
#   "psycopg[binary]",
#   "python-dotenv",
# ]
# ///
import asyncio
import copy
import logging
import os
import subprocess
from pathlib import Path

import ngrok
import psycopg
import uvicorn.config
from dotenv import dotenv_values, load_dotenv
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from fastmcp.server.auth.providers.github import GitHubProvider
from psycopg.rows import dict_row

HERE = Path(__file__).parent
load_dotenv(HERE / ".env")

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

# Shell access to the host (as the user running server.py). Off unless enabled in .env.
ENABLE_SHELL = os.getenv("ENABLE_SHELL", "").strip().lower() in ("1", "true", "yes")
SHELL_MAX_OUTPUT = 50_000

# Uvicorn's default log format has no timestamps and pads "INFO:" to align
# columns; prefix every line with a timestamp and use the bare level name.
LOG_CONFIG = copy.deepcopy(uvicorn.config.LOGGING_CONFIG)
for _formatter in LOG_CONFIG["formatters"].values():
    _formatter["fmt"] = "%(asctime)s " + _formatter["fmt"].replace(
        "%(levelprefix)s", "%(levelname)s"
    )
    _formatter["datefmt"] = "%Y-%m-%d %H:%M:%S"


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
    try:
        with psycopg.connect(DSN, row_factory=dict_row, autocommit=True) as conn:
            with conn.cursor() as cur:
                cur.execute(sql)
                if cur.description:
                    rows = cur.fetchmany(MAX_ROWS + 1)
                    if len(rows) > MAX_ROWS:
                        return rows[:MAX_ROWS] + [{"truncated": True, "max_rows": MAX_ROWS}]
                    return rows
                return [{"status": cur.statusmessage, "rowcount": cur.rowcount}]
    except psycopg.Error as e:
        # SQL errors are the caller's to fix, not server bugs: log one line instead of
        # FastMCP's full traceback, and send the complete message back to the client.
        message = str(e).strip() or type(e).__name__
        first_line = message.splitlines()[0][:200]
        print(f"query error [{e.sqlstate or type(e).__name__}]: {first_line}", flush=True)
        raise ToolError(message, log_level=logging.DEBUG) from None


if ENABLE_SHELL:

    @mcp.tool
    async def shell(command: str, timeout_s: int = 60) -> dict:
        """Run a bash command on the server host, from the repo directory.

        Runs as the user that started server.py (root inside the PRoot Debian).
        Returns exit_code and combined stdout/stderr (last 50k characters).
        The command is killed after timeout_s seconds (max 600).
        Don't use it to stop or restart the server; use update_and_restart.
        """
        timeout_s = max(1, min(timeout_s, 600))
        print(f"shell: {command!r}", flush=True)
        proc = await asyncio.create_subprocess_exec(
            "bash", "-c", command,
            cwd=HERE,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        chunks: list[bytes] = []

        async def pump():
            while chunk := await proc.stdout.read(65536):
                chunks.append(chunk)

        reader = asyncio.create_task(pump())
        timed_out = False
        try:
            await asyncio.wait_for(proc.wait(), timeout_s)
        except asyncio.TimeoutError:
            timed_out = True
            try:
                os.killpg(proc.pid, 9)
            except ProcessLookupError:
                pass
            await proc.wait()
        # A backgrounded child can keep the pipe open; don't wait on it forever.
        try:
            await asyncio.wait_for(reader, 2)
        except asyncio.TimeoutError:
            reader.cancel()
        text = b"".join(chunks).decode(errors="replace")
        result = {"exit_code": proc.returncode, "output": text[-SHELL_MAX_OUTPUT:]}
        if len(text) > SHELL_MAX_OUTPUT:
            result["truncated_chars"] = len(text) - SHELL_MAX_OUTPUT
        if timed_out:
            result["timed_out"] = True
        return result

    @mcp.tool
    def update_and_restart(force_restart: bool = False) -> str:
        """Pull the latest code (git pull --ff-only) and restart this server.

        Runs `./start.sh update` in the background after this call returns, so the
        connection drops for a few seconds. If the new code doesn't start, it rolls
        back to the previous commit. Without new commits nothing restarts unless
        force_restart is true. Check the outcome afterwards with: tail -30 update.log
        """
        # Don't hand the restarted server the values loaded from the old .env, so edits to .env apply.
        env = {k: v for k, v in os.environ.items() if k not in dotenv_values(HERE / ".env")}
        if force_restart:
            env["FORCE_RESTART"] = "1"
        print(f"update_and_restart(force_restart={force_restart})", flush=True)
        with open(HERE / "update.log", "a") as log:
            subprocess.Popen(
                ["bash", "-c", "sleep 2; exec ./start.sh update"],
                cwd=HERE,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        return "update started; reconnect in ~15s and check: tail -30 update.log"


if __name__ == "__main__":
    if os.getenv("NGROK_AUTHTOKEN"):
        tunnel = ngrok.forward(
            f"localhost:{PORT}",
            authtoken=os.environ["NGROK_AUTHTOKEN"],
            domain=os.environ["NGROK_DOMAIN"],
        )
        print(f"ngrok tunnel: {tunnel.url()} -> localhost:{PORT}", flush=True)
    mcp.run(
        transport="http",
        host=os.getenv("MCP_HOST", "127.0.0.1"),
        port=PORT,
        uvicorn_config={"log_config": LOG_CONFIG},
    )
