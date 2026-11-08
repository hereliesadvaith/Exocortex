"""Exocortex home: the page at http://localhost/ with the phone's apps and server status.

Runs on 127.0.0.1:8003 (HOME_PORT) behind nginx; ../start.sh starts and stops it with
the MCP server. It only reads: process and port checks, /proc, a few Postgres catalog
queries, and the tail of each log. Nothing here is reachable through ngrok.

Apps register themselves by linking a manifest into /etc/exocortex/apps/<id>.json:
    {"name": "Habits", "path": "/habits/", "health": "http://127.0.0.1:8001/...",
     "description": "...", "color": "#2f7d57", "icon": "<svg ...>", "log": "habits.log"}
`log` is relative to the directory the manifest really lives in.
"""
import asyncio
import json
import os
import re
import shutil
import time
import urllib.error
import urllib.request
from pathlib import Path

import psycopg
from dotenv import load_dotenv
from psycopg.rows import dict_row
from starlette.applications import Starlette
from starlette.responses import FileResponse, JSONResponse
from starlette.routing import Route

HERE = Path(__file__).parent
ROOT = HERE.parent  # the exocortex checkout
load_dotenv(ROOT / ".env")

APPS_DIR = Path(os.getenv("EXOCORTEX_APPS_DIR", "/etc/exocortex/apps"))
MCP_PORT = int(os.getenv("MCP_PORT", "8000"))
NGINX_PID = Path("/run/nginx.pid")

DSN = (
    f"host={os.getenv('POSTGRES_HOST', 'localhost')} "
    f"port={os.getenv('POSTGRES_PORT', '5432')} "
    f"user={os.getenv('POSTGRES_USER', 'postgres')} "
    f"password={os.environ['POSTGRES_PASSWORD']} "
    f"dbname={os.getenv('POSTGRES_DB', 'postgres')} "
    "connect_timeout=3 options='-c statement_timeout=5000'"
)


# ---- small helpers ---------------------------------------------------------

def pid_alive(pidfile: Path) -> int | None:
    try:
        pid = int(pidfile.read_text().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


def http_get(url: str, timeout: float = 4, headers: dict | None = None) -> tuple[int | None, dict, float]:
    """(status, headers, ms). Any HTTP answer counts, including 4xx/5xx; None if no answer."""
    t = time.monotonic()
    req = urllib.request.Request(url, headers={"User-Agent": "exocortex-home", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            status, hdrs = r.status, dict(r.headers)
    except urllib.error.HTTPError as e:
        status, hdrs = e.code, dict(e.headers)
    except Exception:
        status, hdrs = None, {}
    return status, hdrs, round((time.monotonic() - t) * 1000)


def tail(path: Path, max_bytes: int = 256 * 1024) -> list[str]:
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - max_bytes))
            data = f.read().decode("utf-8", "replace")
    except OSError:
        return []
    lines = data.splitlines()
    return lines[1:] if size > max_bytes else lines


ERROR_RE = re.compile(
    r"\b(ERROR|CRITICAL|FATAL)\b"                      # log levels
    r"|^\s*[\w.]*(Error|Exception|Violation)\b.*?:"    # last line of a traceback
    r'|" 5\d\d\b'                                      # 5xx in an access log
)
TS_RE = re.compile(r"^\[?(\d{4}-\d\d-\d\d[ T]\d\d:\d\d(:\d\d)?)")


def recent_errors(path: Path, n: int = 5) -> list[dict]:
    out = []
    for line in tail(path):
        if ERROR_RE.search(line) and "Traceback (most recent call last)" not in line:
            line = line.strip()
            if out and out[-1]["line"] == line:
                out[-1]["count"] += 1
                continue
            m = TS_RE.match(line)
            out.append({"line": line[:400], "time": m.group(1) if m else None, "count": 1})
    return out[-n:]


# ---- checks ----------------------------------------------------------------

def check_mcp() -> dict:
    pid = pid_alive(ROOT / "server.pid")
    status, _, ms = http_get(f"http://127.0.0.1:{MCP_PORT}/mcp", timeout=3)
    since = None
    if pid:
        try:
            since = (ROOT / "server.pid").stat().st_mtime
        except OSError:
            pass
    return {
        "id": "mcp", "name": "MCP server", "ok": status is not None,
        "detail": f"pid {pid} · port {MCP_PORT}" if pid else f"port {MCP_PORT}",
        "since": since, "ms": ms if status else None,
    }


_tunnel_cache: dict = {"at": 0, "result": None}


def check_tunnel() -> dict:
    # The public URL is the last one server.py printed; checking it goes out over the
    # internet and back, so do that at most once a minute.
    url = None
    for line in reversed(tail(ROOT / "server.log")):
        if "ngrok tunnel:" in line:
            url = line.split("ngrok tunnel:", 1)[1].split("->")[0].strip()
            break
    base = {"id": "tunnel", "name": "ngrok tunnel", "url": url}
    if not url:
        return {**base, "ok": False, "detail": "no tunnel in server.log"}
    if _tunnel_cache["result"] and time.time() - _tunnel_cache["at"] < 60 and _tunnel_cache["result"]["url"] == url:
        return _tunnel_cache["result"]
    status, hdrs, ms = http_get(url.rstrip("/") + "/mcp", timeout=6)
    ngrok_err = next((v for k, v in hdrs.items() if k.lower() == "ngrok-error-code"), None)
    ok = status is not None and not ngrok_err
    detail = url.replace("https://", "") if ok else (f"ngrok {ngrok_err}" if ngrok_err else "public URL not answering")
    result = {**base, "ok": ok, "detail": detail, "ms": ms if ok else None}
    _tunnel_cache.update(at=time.time(), result=result)
    return result


def check_nginx() -> dict:
    pid = pid_alive(NGINX_PID)
    return {"id": "nginx", "name": "nginx", "ok": pid is not None,
            "detail": f"pid {pid} · 127.0.0.1:80" if pid else "not running"}


def check_postgres() -> tuple[dict, dict | None]:
    try:
        with psycopg.connect(DSN, row_factory=dict_row, autocommit=True) as conn:
            info = conn.execute(
                """
                select current_setting('server_version') as version,
                       extract(epoch from pg_postmaster_start_time()) as since,
                       current_database() as db,
                       pg_database_size(current_database()) as bytes,
                       (select count(*) from pg_stat_activity where datname = current_database()) as connections
                """
            ).fetchone()
            schemas = conn.execute(
                r"""
                select n.nspname as schema,
                       count(c.oid) filter (where c.relkind in ('r', 'p')) as tables,
                       count(c.oid) filter (where c.relkind in ('v', 'm')) as views,
                       coalesce(sum(greatest(s.n_live_tup, c.reltuples::bigint, 0)), 0) as rows,
                       coalesce(sum(pg_total_relation_size(c.oid)) filter (where c.relkind in ('r', 'p', 'm')), 0) as bytes
                from pg_namespace n
                left join pg_class c on c.relnamespace = n.oid and c.relkind in ('r', 'p', 'v', 'm')
                left join pg_stat_user_tables s on s.relid = c.oid
                where n.nspname !~ '^pg_' and n.nspname <> 'information_schema'
                group by n.nspname
                having count(c.oid) > 0
                order by bytes desc, n.nspname
                """
            ).fetchall()
    except Exception as e:
        msg = str(e).strip().splitlines()[0] if str(e).strip() else type(e).__name__
        return {"id": "postgres", "name": "PostgreSQL", "ok": False, "detail": msg[:200]}, None
    service = {
        "id": "postgres", "name": "PostgreSQL", "ok": True,
        "detail": f"{info['version'].split()[0]} · {info['connections']} connection{'s' if info['connections'] != 1 else ''}",
        "since": float(info["since"]),
    }
    db = {
        "name": info["db"], "version": info["version"], "bytes": info["bytes"],
        "connections": info["connections"],
        "schemas": [{**s, "rows": int(s["rows"]), "bytes": int(s["bytes"])} for s in schemas],
    }
    return service, db


def load_apps() -> list[dict]:
    apps = []
    for f in sorted(APPS_DIR.glob("*.json")):
        try:
            real = f.resolve(strict=True)
            m = json.loads(real.read_text())
        except (OSError, ValueError):
            continue
        m["id"] = f.stem
        m["_dir"] = real.parent
        apps.append(m)
    return apps


def check_app(m: dict) -> dict:
    status, _, ms = http_get(m["health"], timeout=4) if m.get("health") else (None, {}, None)
    ok = status is not None and status < 500
    return {
        "id": m["id"], "name": m.get("name", m["id"]), "path": m.get("path", f"/{m['id']}/"),
        "description": m.get("description", ""), "color": m.get("color", "#555"),
        "icon": m.get("icon", ""), "ok": ok, "ms": ms if ok else None,
        "detail": f"HTTP {status}" if status and not ok else ("not answering" if not ok else None),
    }


def host() -> dict:
    h: dict = {}
    try:
        h["load"] = [float(x) for x in Path("/proc/loadavg").read_text().split()[:3]]
    except (OSError, ValueError):
        pass
    try:
        mem = {}
        for line in Path("/proc/meminfo").read_text().splitlines():
            k, v = line.split(":", 1)
            mem[k] = int(v.split()[0]) * 1024
        h["mem"] = {"total": mem["MemTotal"], "available": mem.get("MemAvailable", mem.get("MemFree", 0))}
    except (OSError, ValueError, KeyError):
        pass
    try:
        du = shutil.disk_usage("/")
        h["disk"] = {"total": du.total, "free": du.free}
    except OSError:
        pass
    h["cpus"] = os.cpu_count()
    return h


def errors(apps: list[dict]) -> list[dict]:
    sources = [("MCP server", ROOT / "server.log"), ("Home", HERE / "home.log")]
    sources += [(m.get("name", m["id"]), m["_dir"] / m["log"]) for m in apps if m.get("log")]
    out = []
    for name, path in sources:
        errs = recent_errors(path)
        if errs:
            out.append({"source": name, "file": str(path), "errors": errs})
    return out


# ---- routes ----------------------------------------------------------------

async def status(request):
    apps = load_apps()
    run = asyncio.to_thread
    mcp, tunnel, (pg, db), app_states, h, errs = await asyncio.gather(
        run(check_mcp), run(check_tunnel), run(check_postgres),
        asyncio.gather(*(run(check_app, m) for m in apps)),
        run(host), run(errors, apps),
    )
    return JSONResponse(
        {
            "now": time.time(),
            "services": [mcp, tunnel, pg, check_nginx()],
            "apps": list(app_states),
            "host": h,
            "database": db,
            "errors": errs,
        },
        headers={"Cache-Control": "no-store"},
    )


async def page(request):
    return FileResponse(HERE / "index.html", headers={"Cache-Control": "no-cache"})


app = Starlette(routes=[Route("/", page), Route("/api/status", status)])
