# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "fastmcp==4.1.6",  # keep in sync with requirements.txt
#   "python-dotenv",
# ]
# ///
"""Exocortex: an MCP server that gives an AI assistant a shell on this phone.

Tools: `shell` (run a bash command) and `update_and_restart` (pull this repo and
restart). Sign-in is GitHub OAuth, limited to GITHUB_ALLOWED_USERS. The server
listens on 127.0.0.1; start.sh runs the ngrok agent that publishes it.
"""
import asyncio
import copy
import os
import subprocess
from pathlib import Path

import uvicorn.config
from dotenv import dotenv_values, load_dotenv
from fastmcp import FastMCP
from fastmcp.server.auth.providers.github import GitHubProvider

HERE = Path(__file__).parent
load_dotenv(HERE / ".env")

ALLOWED_USERS = {
    u.strip().lower()
    for u in os.environ["GITHUB_ALLOWED_USERS"].split(",")
    if u.strip()
}

PORT = int(os.getenv("MCP_PORT", "8000"))
SHELL_MAX_OUTPUT = 50_000
SHELL_DEFAULT_CWD = Path(os.getenv("SHELL_CWD") or Path.home())

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

mcp = FastMCP("exocortex", auth=auth)


@mcp.tool
async def shell(command: str, timeout_s: int = 60, cwd: str | None = None) -> dict:
    """Run a bash command on the phone (Termux), as the Termux user.

    Starts in the home directory unless `cwd` is given. Returns exit_code and
    combined stdout/stderr (last 50k characters). The command is killed after
    timeout_s seconds (max 600). For anything longer, start it in the background
    (nohup ... > file.log 2>&1 &) and check the log later.
    Don't use it to stop or restart this server; use update_and_restart.
    """
    timeout_s = max(1, min(timeout_s, 600))
    workdir = Path(cwd).expanduser() if cwd else SHELL_DEFAULT_CWD
    print(f"shell ({workdir}): {command!r}", flush=True)
    proc = await asyncio.create_subprocess_exec(
        "bash", "-c", command,
        cwd=workdir,
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
    """Pull the latest code of this repo (git pull --ff-only) and restart this server.

    Runs `./start.sh update` in the background after this call returns, so the
    connection drops for a few seconds. If the new code doesn't start, it rolls
    back to the previous commit. Without new commits nothing restarts unless
    force_restart is true. Check the outcome afterwards with:
    tail -30 ~/exocortex/update.log
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
    return "update started; reconnect in ~15s and check: tail -30 ~/exocortex/update.log"


if __name__ == "__main__":
    mcp.run(
        transport="http",
        host=os.getenv("MCP_HOST", "127.0.0.1"),
        port=PORT,
        uvicorn_config={"log_config": LOG_CONFIG},
    )
