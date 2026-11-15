-- Home page API: schema "home", served by PostgREST at /api/ (see home/README in the
-- main README). Safe to run again; install.sh applies it on every install/update.
--
--   GET  /api/rpc/status            everything the page shows, in one call
--   POST /api/rpc/mcp_set {"enabled":b}  start or stop the MCP server and its ngrok tunnel
--   GET  /api/apps                  the registered apps
--
-- PostgREST logs in as home_api and switches to home_web, which can only read
-- home.apps and call these two functions. The functions are SECURITY DEFINER
-- (owned by postgres) and written in PL/Python, so they run as the Termux user and
-- can read process, log and /proc files and run ~/exocortex/start.sh.

create extension if not exists plpython3u;

create schema if not exists home;

do $$
begin
  if not exists (select from pg_roles where rolname = 'home_api') then
    create role home_api login noinherit;
  end if;
  if not exists (select from pg_roles where rolname = 'home_web') then
    create role home_web nologin;
  end if;
end $$;
grant home_web to home_api;
grant usage on schema home to home_web;

-- ---- apps ----------------------------------------------------------------------
-- Each custom app (its own branch) adds a row when it's installed and an nginx
-- location file in $PREFIX/etc/nginx/apps.d/.
create table if not exists home.apps (
  id          text primary key check (id ~ '^[a-z0-9][a-z0-9-]*$'),
  name        text not null,
  description text not null default '',
  path        text not null,              -- where nginx serves it, e.g. /habits/
  health_url  text,                       -- any HTTP answer below 500 counts as up
  log_file    text,                       -- absolute path; error lines show on the page
  icon        text,                       -- inline <svg>, drawn in the page's text colour
  sort        int not null default 100,
  created_at  timestamptz not null default now()
);
alter table home.apps add column if not exists api_schema text;   -- the app's schema, if it has an API
revoke all on home.apps from public;
grant select on home.apps to home_web;

-- PostgREST serves "home" plus every registered app's schema. App installers call
-- this after changing home.apps (home/sync-api.sh does it and then reloads
-- PostgREST's schema cache). The list is stored as a setting on home_api, which
-- PostgREST reads on "reload config"; it overrides PGRST_DB_SCHEMAS.
create or replace function home.sync_api_schemas() returns text
language plpgsql
set search_path = pg_catalog, home
as $$
declare
  schemas text;
begin
  select string_agg(s, ',' order by first, s) into schemas
  from (select 'home' as s, 0 as first
        union
        select distinct api_schema, 1 from home.apps where api_schema is not null) x;
  execute format('alter role home_api set pgrst.db_schemas = %L', schemas);
  perform pg_notify('pgrst', 'reload config');
  return schemas;
end $$;
revoke all on function home.sync_api_schemas() from public;

-- ---- status ---------------------------------------------------------------------
create or replace function home.status() returns jsonb
language plpython3u stable security definer
set search_path = pg_catalog, home
as $py$
import ast, calendar, concurrent.futures, json, os, re, shutil, subprocess, time, urllib.error, urllib.request

HOME = os.path.expanduser("~")
REPO = os.path.join(HOME, "exocortex")
PREFIX = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")

def read(path, limit=None):
    try:
        with open(path, "rb") as f:
            if limit:
                f.seek(0, 2)
                size = f.tell()
                f.seek(max(0, size - limit))
            return f.read().decode("utf-8", "replace")
    except OSError:
        return None

def pid_in(path):
    text = read(path)
    try:
        return int(text.split()[0]) if text else None
    except ValueError:
        return None

def mtime(path):
    try:
        return os.stat(path).st_mtime
    except OSError:
        return None

def http(url, timeout=2.0):
    """(status, ms); any HTTP answer counts, None if nothing answered."""
    start = time.monotonic()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "exocortex-home"}), timeout=timeout) as r:
            status = r.status
    except urllib.error.HTTPError as e:
        status = e.code
    except Exception:
        status = None
    return status, round((time.monotonic() - start) * 1000)

# Our own processes (Android only shows this app's): pid -> (cmdline, rss bytes).
procs = {}
for entry in os.listdir("/proc"):
    if not entry.isdigit():
        continue
    cmd = read(f"/proc/{entry}/cmdline")
    if not cmd:
        continue
    rss = 0
    for line in (read(f"/proc/{entry}/status") or "").splitlines():
        if line.startswith("VmRSS:"):
            rss = int(line.split()[1]) * 1024
            break
    procs[int(entry)] = (cmd.replace("\0", " ").strip(), rss)

def alive(pid, needle):
    return pid is not None and pid in procs and needle in procs[pid][0]

def mem_of(match):
    return sum(rss for cmd, rss in procs.values() if match(cmd))

# ---- services ----------------------------------------------------------------
pg = plpy.execute("""
    select split_part(current_setting('server_version'), ' ', 1) as version,
           extract(epoch from pg_postmaster_start_time())::float8 as since,
           pg_database_size(current_database()) as bytes,
           (select count(*) from pg_stat_activity where backend_type = 'client backend') as connections
""")[0]
services = [{
    "id": "postgres", "name": "PostgreSQL", "ok": True, "since": pg["since"],
    "detail": f"{pg['version']} · {pg['connections']} conn · {pg['bytes'] // 1048576} MB",
    "mem": mem_of(lambda c: c.startswith("postgres")),
}]

ng_pid = pid_in(f"{PREFIX}/tmp/nginx.pid")
services.append({
    "id": "nginx", "name": "nginx", "ok": alive(ng_pid, "nginx"),
    "since": mtime(f"{PREFIX}/tmp/nginx.pid"), "detail": "localhost:80",
    "mem": mem_of(lambda c: c.startswith("nginx")),
})

pr_pid = pid_in(f"{REPO}/home/postgrest.pid")
services.append({
    "id": "postgrest", "name": "PostgREST", "ok": alive(pr_pid, "postgrest"),
    "since": mtime(f"{REPO}/home/postgrest.pid"), "detail": "127.0.0.1:3000",
    "mem": mem_of(lambda c: "postgrest" in c.split(" ")[0]),
})

# ---- MCP server + ngrok -------------------------------------------------------
env = {}
for line in (read(f"{REPO}/.env") or "").splitlines():
    if "=" in line and not line.lstrip().startswith("#"):
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()
port = env.get("MCP_PORT") or "8000"

srv_pid = pid_in(f"{REPO}/server.pid")
srv_alive = alive(srv_pid, "server.py")
srv_status, srv_ms = http(f"http://127.0.0.1:{port}/mcp") if srv_alive else (None, None)
ngrok_pid = pid_in(f"{REPO}/ngrok.pid")
ngrok_alive = alive(ngrok_pid, "ngrok")
url = None
if ngrok_alive:
    try:
        with urllib.request.urlopen("http://127.0.0.1:4040/api/tunnels", timeout=2) as r:
            tunnels = json.load(r).get("tunnels") or []
            url = tunnels[0]["public_url"] if tunnels else None
    except Exception:
        pass

# Last request and the last shell commands, from the end of server.log.
last_request, commands, stamp = None, [], None
ts_re = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) ")
shell_re = re.compile(r"^shell \((.*?)\): (.*)$")
for line in (read(f"{REPO}/server.log", 512 * 1024) or "").splitlines():
    m = ts_re.match(line)
    if m:
        stamp = m.group(1)
        if '"POST /mcp' in line:
            last_request = stamp
        continue
    m = shell_re.match(line)
    if m:
        # server.py logs the command as a Python string literal (repr); decode it.
        try:
            cmd = ast.literal_eval(m.group(2))
        except (ValueError, SyntaxError):
            cmd = m.group(2)
        commands.append({"at": stamp, "cwd": m.group(1), "command": str(cmd)[:400]})

def to_epoch(s):
    return time.mktime(time.strptime(s, "%Y-%m-%d %H:%M:%S")) if s else None

switch = None
try:
    switch = json.loads(read(f"{REPO}/home/mcp-switch.json") or "null")
except ValueError:
    pass
on = srv_alive and ngrok_alive
# A switch is pending until it has fully happened: for "on", the server answers
# and the tunnel has its public URL (ngrok can run a moment before it connects).
pending = None
if switch and time.time() - switch.get("at", 0) < 45:
    if switch.get("on"):
        done = srv_status is not None and url is not None
    else:
        done = not srv_alive and not ngrok_alive
    if not done:
        pending = "starting" if switch.get("on") else "stopping"

mcp = {
    "on": on, "pending": pending, "url": url,
    "server": {"ok": srv_status is not None, "pid": srv_pid if srv_alive else None, "port": int(port),
               "since": mtime(f"{REPO}/server.pid") if srv_alive else None, "ms": srv_ms,
               "mem": mem_of(lambda c: "server.py" in c)},
    "tunnel": {"ok": url is not None, "pid": ngrok_pid if ngrok_alive else None,
               "since": mtime(f"{REPO}/ngrok.pid") if ngrok_alive else None,
               "mem": mem_of(lambda c: c.split(" ")[0].endswith("ngrok"))},
    "last_request": to_epoch(last_request),
    "commands": [dict(c, at=to_epoch(c["at"])) for c in commands[-5:]][::-1],
}

# ---- apps -----------------------------------------------------------------------
apps = plpy.execute("select id, name, description, path, health_url, log_file, icon from home.apps order by sort, name")
def check(app):
    if not app["health_url"]:
        return {"ok": None, "ms": None}
    status, ms = http(app["health_url"])
    return {"ok": status is not None and status < 500, "ms": ms, "status": status}
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    results = list(pool.map(check, apps))
app_list = [{k: a[k] for k in ("id", "name", "description", "path", "icon")} | r for a, r in zip(apps, results)]

# ---- system ---------------------------------------------------------------------
cache = GD.setdefault("home_static", {})
if "model" not in cache:
    def prop(name):
        try:
            return subprocess.run(["getprop", name], capture_output=True, text=True, timeout=3).stdout.strip()
        except Exception:
            return ""
    cache["model"] = " ".join(x for x in (prop("ro.product.manufacturer"), prop("ro.product.model")) if x)
    cache["android"] = prop("ro.build.version.release")
mem = {}
for line in (read("/proc/meminfo") or "").splitlines():
    k, _, v = line.partition(":")
    if v.strip():
        mem[k] = int(v.split()[0]) * 1024
disk = shutil.disk_usage(HOME)
system = {
    "model": cache["model"], "android": cache["android"], "cpus": os.cpu_count(),
    "mem": {"total": mem.get("MemTotal"), "available": mem.get("MemAvailable")},
    "swap": {"total": mem.get("SwapTotal"), "free": mem.get("SwapFree")},
    "disk": {"total": disk.total, "free": disk.free},
    "ours": sum(rss for _, rss in procs.values()),
}

# ---- recent errors (last 24 hours) ----------------------------------------------------
# Each log has its own timestamp format; local-time ones are read in the phone's zone.
STAMPS = [
    (re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)"), "%Y-%m-%d %H:%M:%S", False),        # server.log, postgres
    (re.compile(r"^(\d{4}/\d\d/\d\d \d\d:\d\d:\d\d)"), "%Y/%m/%d %H:%M:%S", False),        # nginx
    (re.compile(r"^(\d\d/\w{3}/\d{4}:\d\d:\d\d:\d\d) \+0000"), "%d/%b/%Y:%H:%M:%S", True),  # postgrest (UTC)
    (re.compile(r"^t=(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)\+0000"), "%Y-%m-%dT%H:%M:%S", True),  # ngrok (UTC)
]
def stamp_of(line):
    for rx, fmt, utc in STAMPS:
        m = rx.match(line)
        if m:
            try:
                t = time.strptime(m.group(1), fmt)
                return calendar.timegm(t) if utc else time.mktime(t)
            except ValueError:
                return None
    return None

CUTOFF = time.time() - 24 * 3600
def errors_in(path, pattern, skip=None, n=3):
    out, at = [], None
    for line in (read(path, 256 * 1024) or "").splitlines():
        at = stamp_of(line) or at   # lines without a stamp belong to the last one seen
        if not pattern.search(line) or (skip and skip.search(line)):
            continue
        if at is not None and at < CUTOFF:
            continue
        line = line.strip()[:300]
        if out and out[-1]["line"] == line:
            out[-1]["count"] += 1
            out[-1]["at"] = at
        else:
            out.append({"line": line, "count": 1, "at": at})
    return out[-n:]

sources = [
    ("MCP server", f"{REPO}/server.log", re.compile(r"\b(ERROR|CRITICAL)\b|Traceback|^\S*Error:"), None),
    ("ngrok", f"{REPO}/ngrok.log", re.compile(r"lvl=(eror|crit)"), re.compile(r"netlinkrib")),
    ("PostgREST", f"{REPO}/home/postgrest.log", re.compile(r"(?i)\berror\b|FATAL"), None),
    ("PostgreSQL", f"{PREFIX}/var/log/postgresql.log", re.compile(r"\b(ERROR|FATAL|PANIC):"), None),
    ("nginx", f"{PREFIX}/var/log/nginx/error.log", re.compile(r"\[(error|crit|alert|emerg)\]"), None),
    ("Backup", f"{REPO}/home/backup.log", re.compile(r"FAILED"), None),
] + [(a["name"], a["log_file"], re.compile(r"\b(ERROR|CRITICAL|FATAL)\b|Traceback"), None) for a in apps if a["log_file"]]
errors = []
for name, path, pattern, skip in sources:
    found = errors_in(path, pattern, skip)
    if found:
        errors.append({"source": name, "file": path, "errors": found})

return json.dumps({
    "now": time.time(), "mcp": mcp, "apps": app_list,
    "services": services, "system": system, "errors": errors,
})
$py$;

-- ---- MCP switch -------------------------------------------------------------------
create or replace function home.mcp_set(enabled boolean) returns jsonb
language plpython3u volatile security definer
set search_path = pg_catalog, home
as $py$
import json, os, subprocess, time

HOME = os.path.expanduser("~")
REPO = os.path.join(HOME, "exocortex")
marker = f"{REPO}/home/mcp-switch.json"

log_path = f"{REPO}/home/mcp-switch.log"

def running(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return b"start.sh" in f.read()
    except OSError:
        return False

# One switch at a time: refuse while the previous start/stop is still running.
try:
    with open(marker) as f:
        prev = json.load(f)
except (OSError, ValueError):
    prev = {}
on = enabled
if prev.get("pid") and running(prev["pid"]) and time.time() - prev.get("at", 0) < 60:
    plpy.error("the MCP server is already switching; try again in a few seconds")

with open(log_path, "a") as log:
    log.write(f"===== {time.strftime('%Y-%m-%d %H:%M:%S')} switch {'on' if on else 'off'} =====\n")

# Double fork: bash backgrounds start.sh and exits at once, so start.sh is reparented
# away from this database backend (no zombie here) and outlives the connection.
out = subprocess.run(
    ["bash", "-c", 'bash "$1" "$2" >> "$3" 2>&1 < /dev/null & echo $!',
     "switch", f"{REPO}/start.sh", "-d" if on else "stop", log_path],
    cwd=REPO, stdin=subprocess.DEVNULL, capture_output=True, text=True,
    start_new_session=True, timeout=10,
)
pid = int(out.stdout.strip()) if out.stdout.strip().isdigit() else None
with open(marker, "w") as f:
    json.dump({"on": on, "at": time.time(), "pid": pid}, f)
return json.dumps({"on": on, "requested": True})
$py$;

revoke all on function home.status() from public;
revoke all on function home.mcp_set(boolean) from public;
grant execute on function home.status() to home_web;
grant execute on function home.mcp_set(boolean) to home_web;

-- Let PostgREST pick up changes without a restart.
notify pgrst, 'reload schema';
