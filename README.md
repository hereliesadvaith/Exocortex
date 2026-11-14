# Exocortex

A personal server on an Android phone, running natively in Termux (no PRoot):

- an **MCP server** that gives an AI assistant a shell on the phone, published through an ngrok static domain and limited to allowlisted GitHub accounts;
- **PostgreSQL** with PL/Python, for data;
- a **home page** at `http://localhost:8080/` with your apps, an on/off switch for the MCP server, and the phone's status.

Custom apps live on their own branches and plug into the home page; this branch (`main`) is the core.

```
Claude / any MCP client
   │ HTTPS + GitHub OAuth
   ▼
ngrok static domain ──► ngrok agent ──► server.py (MCP, 127.0.0.1:8000) ──► bash
                                                   ▲ started/stopped by the switch
phone browser ──► nginx 127.0.0.1:8080             │
                    ├─ /        home/public (static page)
                    ├─ /api/    PostgREST 127.0.0.1:3000 ──► Postgres 18 (schema "home",
                    │                                         PL/Python functions)
                    └─ /<app>/  custom apps ($PREFIX/etc/nginx/apps.d/)
```

| Path | What |
|---|---|
| `server.py`, `start.sh`, `ngrok.yml` | MCP server and its ngrok tunnel |
| `home/` | Home page: static files, `schema.sql`, `install.sh`, `services.sh`, nginx template |
| `postgres/plpython/` | Builds PL/Python for Termux's Postgres |
| `termux-boot/exocortex` | Starts everything after a reboot |

## Requirements

- [Termux](https://f-droid.org/packages/com.termux/) **and** [Termux:Boot](https://f-droid.org/packages/com.termux.boot/), both from F-Droid. Add-ons only work with a Termux from the same source, and the Google Play build has no Termux:Boot.
- A free [ngrok](https://ngrok.com) account (auth token and a free static domain)
- A GitHub account (for the OAuth app)

## 1. Termux packages

```sh
pkg update && pkg upgrade
pkg install -y git python rust binutils python-cryptography postgresql nginx perl clang make curl
```

FastMCP depends on a few packages written in Rust (`pydantic-core`, `rpds-py`, `watchfiles`) that have no ready-made Android builds, so pip compiles them on the phone; `rust` and `binutils` are for that, and `python-cryptography` is Termux's prebuilt `cryptography`. `perl`, `clang` and `make` build PL/Python.

Then in Android settings: Apps → Termux and Termux:Boot → Battery → **Unrestricted**. Open Termux:Boot once so Android lets it run at boot (you can hide its icon afterwards, but don't disable it).

## 2. MCP server

### ngrok

1. Copy your auth token from the [ngrok dashboard](https://dashboard.ngrok.com/get-started/your-authtoken).
2. Under **Domains**, claim your free static domain (something like `your-name.ngrok-free.dev`).
3. Install the agent (the `ngrok` Python package has no Android build, so `start.sh` runs the agent binary):

```sh
curl -LO https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-arm64.tgz
tar xzf ngrok-v3-stable-linux-arm64.tgz -C $PREFIX/bin && rm ngrok-v3-stable-linux-arm64.tgz
```

`start.sh` passes `ngrok.yml` to the agent. ngrok is a Linux build: it looks names up through `/etc/resolv.conf`, which Android doesn't have, so it falls back to a DNS server on the phone itself (`[::1]:53`), which only answers while the phone's hotspot is on. `ngrok.yml` points it at public DNS (Google, Cloudflare, Quad9; IPv4 and IPv6) and turns off the update check and the revocation-list download, which do their own lookups. If the tunnel isn't up within 30 seconds, `start.sh` leaves ngrok running: it keeps retrying.

### GitHub OAuth app

GitHub → Settings → Developer settings → [OAuth Apps](https://github.com/settings/developers) → **New OAuth App**:

| Field | Value |
|---|---|
| Homepage URL | `https://<your-ngrok-domain>` |
| Authorization callback URL | `https://<your-ngrok-domain>/auth/callback` |

Copy the **Client ID** and generate a **Client secret**.

### Install

```sh
git clone https://github.com/hereliesadvaith/exocortex.git ~/exocortex
cd ~/exocortex
python -m venv --system-site-packages .venv                # sees Termux's python-cryptography
export ANDROID_API_LEVEL=$(getprop ro.build.version.sdk)   # needed to compile the Rust packages
.venv/bin/pip install --retries 10 --timeout 60 -r requirements.txt   # the first time takes 20-40 minutes
cp .env.example .env && chmod 600 .env && nano .env
```

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | yes | none | OAuth app credentials |
| `GITHUB_ALLOWED_USERS` | yes | none | Comma-separated GitHub usernames allowed to connect |
| `NGROK_AUTHTOKEN` | yes | none | ngrok auth token |
| `NGROK_DOMAIN` | yes | none | Your static ngrok domain |
| `NGROK_BIN` | | `ngrok` | Path to the ngrok binary, if it isn't on `PATH` |
| `MCP_BASE_URL` | | `https://$NGROK_DOMAIN` | Public URL, if you use a different tunnel or proxy |
| `MCP_HOST` / `MCP_PORT` | | `127.0.0.1` / `8000` | Where the server listens |
| `SHELL_CWD` | | `~` | Where `shell` commands start when no `cwd` is given |

### Tools

| Tool | What it does |
|---|---|
| `shell(command, timeout_s=60, cwd=None)` | Runs a bash command as the Termux user, starting in `~` unless `cwd` is given. Returns the exit code and the last 50k characters of output. Every command is written to `server.log`. |
| `update_and_restart(force_restart=False)` | Runs `./start.sh update` in the background: `git pull --ff-only`, reinstall requirements if they changed, restart the server, and run `home/install.sh` if the home page changed. Results go to `update.log`. |

### Run

```sh
./start.sh -d       # server and ngrok in the background
./start.sh status   # is each one up, and the public URL
./start.sh stop     # stop both
./start.sh restart  # stop, then start both
./start.sh update   # git pull, then restart the server; rolls back if the new code doesn't start
tail -f server.log ngrok.log
```

Logs are kept across restarts and rotated to `.1`–`.3` at 1 MB. Check it's reachable (an unauthenticated request gets `401`):

```sh
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://<your-ngrok-domain>/mcp
```

`./start.sh update` protects you from a bad pull: it refuses to run over uncommitted changes in tracked files; if the pull fails or the new `server.py` doesn't compile or install, it resets to the previous commit and leaves the running server alone; if the new server doesn't answer within 30 seconds, it resets and starts the previous commit again. ngrok keeps running through an update.

### Connect an AI assistant

**Claude (claude.ai / desktop / mobile):** Settings → Connectors → **Add custom connector**, URL `https://<your-ngrok-domain>/mcp`. Sign in with GitHub when asked.

**Claude Code:** `claude mcp add --transport http exocortex https://<your-ngrok-domain>/mcp`, then `/mcp` inside Claude Code to authenticate.

## 3. PostgreSQL

Termux's `postgresql` runs natively; no shared-memory shim is needed.

```sh
PGDATA=$PREFIX/var/lib/postgresql
mkdir -p $PGDATA $PREFIX/var/log
# Superuser "postgres". Local socket: no password (only Termux can reach it).
# TCP on 127.0.0.1: password, since any app on the phone can reach localhost.
python -c "import secrets; print(secrets.token_urlsafe(24))" > ~/.pg-pw
initdb -D $PGDATA -U postgres -E UTF8 --locale-provider=builtin --builtin-locale=C.UTF-8 \
  --auth-local=trust --auth-host=scram-sha-256 --pwfile=$HOME/.pg-pw
printf '127.0.0.1:5432:*:postgres:%s\nlocalhost:5432:*:postgres:%s\n' "$(cat ~/.pg-pw)" "$(cat ~/.pg-pw)" > ~/.pgpass
chmod 600 ~/.pgpass && rm ~/.pg-pw
pg_ctl -D $PGDATA -l $PREFIX/var/log/postgresql.log -w start
psql -U postgres -c 'select version()'
```

| | |
|---|---|
| Data | `$PREFIX/var/lib/postgresql` |
| Log | `$PREFIX/var/log/postgresql.log` |
| Listens | `localhost:5432` and the socket in `$PREFIX/tmp` |
| Superuser password | only in `~/.pgpass` (so `psql -h 127.0.0.1` works without typing it) |
| Extensions | Termux's contrib set (`pg_trgm`, `pgcrypto`, `uuid-ossp`, `citext`, `hstore`, `unaccent`, ...) plus PL/Python below. Not available: `moddatetime` (use a small plpgsql trigger) |

### PL/Python

Termux's package is built without it. `postgres/plpython/build.sh` builds `plpython3u` and `jsonb_plpython3u` against the installed Postgres (about a minute), installs them, holds the `postgresql` package so `pkg upgrade` can't break them, and runs a test that rolls back. `home/install.sh` runs it automatically if PL/Python is missing. Details and upgrade steps: [`postgres/plpython/README.md`](postgres/plpython/README.md).

## 4. Home page

```sh
cd ~/exocortex && home/install.sh
```

`install.sh` (safe to run again; `start.sh update` runs it when `home/` changes):

1. builds PL/Python if it's missing;
2. installs PostgREST 16.5 (static ARM64 build, checksum pinned) to `$PREFIX/bin/postgrest`;
3. writes nginx's config: `$PREFIX/etc/nginx/nginx.conf` includes `exocortex.conf`, generated from `home/nginx.conf.in` (Termux's original is kept as `nginx.conf.orig`);
4. starts Postgres, applies `home/schema.sql`, restarts PostgREST, starts or reloads nginx;
5. installs the boot script.

Then open **http://localhost:8080/** on the phone.

| Section | Shows |
|---|---|
| **Apps** | A tile per registered app, with a dot if its health check fails |
| **MCP** | The switch (starts or stops the server **and** ngrok together), server and tunnel state, public URL (tap to copy), uptime, last call, the last five shell commands |
| **System** | Phone model, memory and storage, each service's state and memory, and error lines from the last 24 hours of every log |

It refreshes every 5 seconds while it's open (every second while switching). Light and dark follow the system; the button at the top right cycles auto → light → dark. The switch doesn't survive a reboot: the boot script always starts the MCP server.

### How it works

- **nginx** (`127.0.0.1:8080`) serves `home/public/` and proxies `/api/` to PostgREST. It only listens on loopback, and `/api/` rejects requests whose `Origin` isn't `localhost:8080`, so a website open in the phone's browser can't call it.
- **PostgREST** (`127.0.0.1:3000`) logs in over the local socket as `home_api` and serves schema `home` as `home_web`, which can only read `home.apps` and call two functions.
- **`home.status()`** and **`home.mcp_set(enabled)`** are PL/Python `SECURITY DEFINER` functions, so they run as the Termux user: they read `/proc`, PID files and logs, and `mcp_set` runs `start.sh -d` or `stop` detached. Only one switch runs at a time.

| Endpoint | |
|---|---|
| `GET /api/rpc/status` | Everything the page shows |
| `POST /api/rpc/mcp_set` `{"enabled": true}` | Start or stop the MCP server and tunnel |
| `GET /api/apps` | Registered apps |

`home/services.sh start|stop|restart|status` manages Postgres, PostgREST and nginx (`restart-postgrest` and `start-postgres` for one). PostgREST logs to `home/postgrest.log`, switch runs to `home/mcp-switch.log`.

Android doesn't let apps read load, uptime, CPU, battery or temperature, so the page doesn't show them.

### Adding a custom app

Each app lives on its own branch with its own `start.sh`, and plugs in with two things:

1. **nginx:** a file in `$PREFIX/etc/nginx/apps.d/<app>.conf` with its `location /<app>/ { proxy_pass http://127.0.0.1:<port>/; }` blocks, then `nginx -s reload`.
2. **Home page:** a row in `home.apps`:

```sql
insert into home.apps (id, name, description, path, health_url, log_file, icon)
values ('habits', 'Habits', 'Daily habits', '/habits/', 'http://127.0.0.1:8001/health',
        '/data/data/com.termux/files/home/habits/habits.log', '<svg ...>...</svg>')
on conflict (id) do update set name = excluded.name, path = excluded.path,
  health_url = excluded.health_url, log_file = excluded.log_file, icon = excluded.icon;
```

`health_url` counts as up for any answer below 500; `icon` is an SVG drawn in the page's text colour (as a mask, so it can't run script); `log_file` feeds the error list.

## 5. Start on boot

`home/install.sh` installs `termux-boot/exocortex` as `~/.termux/boot/exocortex`. After a reboot it takes a wake lock, runs `home/services.sh start` (Postgres, PostgREST, nginx), waits 10 seconds for the network, then `./start.sh -d`. Output goes to `~/exocortex/boot.log`. It also clears a stale Postgres PID file left by an unclean shutdown.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `pip install` fails building `pydantic-core` / `rpds-py` / `watchfiles` | Check `rust` and `binutils` are installed and `ANDROID_API_LEVEL` is exported in the same shell, then retry. |
| `pip install` tries to build `cryptography` | The venv can't see Termux's package: recreate it with `--system-site-packages`. |
| `pip` fails with `Connection reset by peer` | The network dropped; rerun with `--retries 10 --timeout 60`. Wi-Fi helps for the long compile. |
| `ngrok.log`: `lookup ... on [::1]:53 ... connection refused` | ngrok was started without `ngrok.yml` (an old `start.sh`?). See [ngrok](#ngrok). |
| `ngrok.log`: `read udp ... :53: i/o timeout` | The network briefly dropped DNS; ngrok keeps retrying. If it lasts, check the phone's connection. |
| `ngrok.log`: `ERR_NGROK_108` / domain already in use | Another ngrok agent is connected with your account (an old process or another device). `pkill -f 'ngrok http'`, check the ngrok dashboard's Agents page, then `./start.sh restart`. |
| `ngrok.log`: `unable to check interfaces ... netlinkrib: permission denied` | Harmless: Android hides network interfaces from apps. |
| Home page: "Can't reach the home API" | `home/services.sh status`; start what's down with `home/services.sh start`. |
| Postgres won't start after an unclean shutdown: `lock file "postmaster.pid" already exists` | `home/services.sh start` removes a stale PID file; or delete `$PREFIX/var/lib/postgresql/postmaster.pid` if no Postgres is running. |
| `KeyError: 'GITHUB_CLIENT_ID'` (or another variable) on start | That variable is missing from `.env`. |
| Every client gets `401` after signing in | Your GitHub username isn't in `GITHUB_ALLOWED_USERS`, or the OAuth app's callback URL doesn't match your domain. |
| `server already running` from `start.sh` | Use `./start.sh restart`. |

## Security notes

- Anyone you allowlist can run any command on the phone with Termux's rights, including reading `.env` and `~/.pgpass`, so keep the allowlist to yourself.
- The home page and its API are reachable only from the phone (loopback), and only the page itself can call the API from a browser. Any app installed on the phone could still call `localhost:8080/api/` directly, including the MCP switch.
- Never commit `.env`. It holds your OAuth secret and ngrok token.
