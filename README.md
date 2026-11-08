# Exocortex

A personal exocortex in your pocket: Postgres on Android (Termux), connected to AI assistants over MCP. Free, private, always on.

```
Claude / any MCP client
        │  HTTPS + GitHub OAuth
        ▼
  ngrok static domain ──► FastMCP server (server.py, :8000) ──► PostgreSQL 17 (:5432)
                          └──────────── Debian (proot-distro) inside Termux ────────────┘
```

The server exposes one MCP tool, `query(sql)`, which runs any SQL statement against your database. Only the GitHub usernames you allowlist can sign in. Optionally it can also give the assistant a shell on the phone and let it update and restart the server itself (see [Shell and self-update](#shell-and-self-update)).

## Requirements

- An Android phone with [Termux](https://f-droid.org/packages/com.termux/) (install from F-Droid; the Play Store build is outdated)
- A free [ngrok](https://ngrok.com) account (for an auth token and a free static domain)
- A GitHub account (for the OAuth app)

## 1. Debian inside Termux

In Termux:

```sh
pkg update && pkg upgrade
pkg install proot-distro
proot-distro install debian
proot-distro login debian
```

Everything below runs **inside Debian** as root.

```sh
apt update
apt install -y postgresql postgresql-contrib python3 python3-venv gcc libc6-dev git curl
```

Optional, for writing database functions in Python (`plpython3u`):

```sh
apt install -y postgresql-plpython3-17
```

## 2. Make PostgreSQL work under PRoot

PRoot doesn't support System V shared memory (`shmget` fails with `EIO`), so `initdb` and the server can't start as they are. `pgshm/fakeshm.c` is a small `LD_PRELOAD` shim that emulates the few SysV shm calls Postgres needs, using `mmap`.

```sh
gcc -O2 -shared -fPIC -o /usr/local/lib/libfakeshm.so pgshm/fakeshm.c
```

Create the cluster with the shim loaded, and make it permanent for the cluster:

```sh
mkdir -p /var/run/postgresql

LD_PRELOAD=/usr/local/lib/libfakeshm.so pg_createcluster 17 main
echo "LD_PRELOAD = '/usr/local/lib/libfakeshm.so'" >> /etc/postgresql/17/main/environment

su postgres -c "pg_ctlcluster 17 main start"
pg_lsclusters          # should show 17 main ... online
```

Start the cluster as the `postgres` user, not as root. Under PRoot, `chown` is a no-op and every file shows as owned by whichever user is looking, so as root the data directory looks root-owned and `pg_ctlcluster` refuses to start it. As `postgres`, the same directory looks owned by `postgres`. `start.sh` does this for you.

Set a password for the database user the server will use:

```sh
su postgres -c "psql -c \"ALTER USER postgres PASSWORD 'choose-a-strong-password'\""
```

Optional extensions (in each database you use):

```sh
su postgres -c "psql -c 'CREATE EXTENSION IF NOT EXISTS plpython3u'"
su postgres -c "psql -c 'CREATE EXTENSION IF NOT EXISTS jsonb_plpython3u CASCADE'"
```

## 3. ngrok

1. Copy your auth token from the [ngrok dashboard](https://dashboard.ngrok.com/get-started/your-authtoken).
2. Under **Domains**, claim your free static domain (something like `your-name.ngrok-free.dev`).

## 4. GitHub OAuth app

Go to GitHub → Settings → Developer settings → [OAuth Apps](https://github.com/settings/developers) → **New OAuth App**:

| Field | Value |
|---|---|
| Homepage URL | `https://<your-ngrok-domain>` |
| Authorization callback URL | `https://<your-ngrok-domain>/auth/callback` |

Copy the **Client ID** and generate a **Client secret**.

## 5. Install the server

```sh
git clone https://github.com/hereliesadvaith/exocortex.git
cd exocortex
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Create your `.env` from the template and fill it in. It's gitignored, so keep it private:

```sh
cp .env.example .env
chmod 600 .env
nano .env   # or any editor
```

### All settings

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `POSTGRES_PASSWORD` | yes | none | Database password |
| `POSTGRES_USER` / `POSTGRES_DB` | | `postgres` | Database user and name |
| `POSTGRES_HOST` / `POSTGRES_PORT` | | `localhost` / `5432` | Database address |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | yes | none | OAuth app credentials |
| `GITHUB_ALLOWED_USERS` | yes | none | Comma-separated GitHub usernames allowed to connect |
| `NGROK_AUTHTOKEN` | | none | If set, `server.py` opens the ngrok tunnel itself |
| `NGROK_DOMAIN` | yes* | none | Your static ngrok domain (*unless `MCP_BASE_URL` is set) |
| `MCP_BASE_URL` | | `https://$NGROK_DOMAIN` | Public URL, if you use a different tunnel or proxy |
| `MCP_HOST` / `MCP_PORT` | | `127.0.0.1` / `8000` | Where the server listens |
| `QUERY_TIMEOUT_MS` | | `15000` | Statements running longer than this are cancelled |
| `QUERY_MAX_ROWS` | | `500` | Maximum rows returned; extra rows are cut and a `{"truncated": true}` row is added |
| `ENABLE_SHELL` | | off | `true` adds the `shell` and `update_and_restart` tools (see below) |

## 6. Run it

```sh
./start.sh          # foreground (Ctrl+C to stop)
./start.sh -d       # background, appends to server.log (rotated to server.log.1-3 at 1 MB)
./start.sh stop     # stop the background server
./start.sh restart  # stop, start in the background, wait until it answers
./start.sh update   # git pull, then restart; rolls back if the new code doesn't start
tail -f server.log
```

`start.sh` also starts Postgres if it isn't running (it doesn't come back on its own after a phone restart), and takes a Termux wake lock when one is available.

Check it's reachable. An unauthenticated request should get `401`:

```sh
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://<your-ngrok-domain>/mcp
```

## 7. Connect an AI assistant

**Claude (claude.ai / desktop / mobile):** Settings → Connectors → **Add custom connector**, URL `https://<your-ngrok-domain>/mcp`. Sign in with GitHub when asked.

**Claude Code:**

```sh
claude mcp add --transport http exocortex https://<your-ngrok-domain>/mcp
```

Then run `/mcp` inside Claude Code to authenticate.

## Shell and self-update

Set `ENABLE_SHELL=true` in `.env` and restart to add two more tools:

| Tool | What it does |
|---|---|
| `shell(command, timeout_s=60)` | Runs a bash command in the repo directory, as the user running `server.py` (root inside Debian; under PRoot that is still only the Termux app's rights). Returns the exit code and output. Every command is written to `server.log`. |
| `update_and_restart(force_restart=False)` | Runs `./start.sh update` in the background: `git pull --ff-only` on the current branch, reinstall requirements if they changed, then restart. The connection drops for a few seconds. Without new commits it does nothing unless `force_restart` is true. Results go to `update.log`. |

`./start.sh update` protects you from a bad pull:

- It refuses to run if tracked files have uncommitted changes, so it never throws away local edits.
- If the new `server.py` doesn't compile or its requirements don't install, it resets the code to the previous commit and leaves the running server alone.
- If the new server doesn't answer on its port within 30 seconds, it resets to the previous commit and starts that again.

With the shell enabled, anyone you allowlist can run commands on the phone and read `.env`. Only enable it if the allowlist is just you.

## Keeping it alive on Android

- Disable battery optimisation for Termux (Android Settings → Apps → Termux → Battery → Unrestricted).
- Keep the Termux session open; `start.sh` runs `termux-wake-lock` when Termux exposes it. You can also run `termux-wake-lock` in Termux before `proot-distro login debian`.
- After a reboot: open Termux → `proot-distro login debian` → `cd exocortex && ./start.sh -d`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `initdb` / Postgres fails with `could not create shared memory segment` or `EIO` | The shim isn't loaded. Check `/usr/local/lib/libfakeshm.so` exists and `/etc/postgresql/17/main/environment` has the `LD_PRELOAD` line. |
| `Peer authentication failed for user "postgres"` | Run `psql` as the postgres user: `su postgres -c psql`. |
| `KeyError: 'POSTGRES_PASSWORD'` (or another variable) on start | That variable is missing from `.env`. |
| Every client gets `401` after signing in | Your GitHub username isn't in `GITHUB_ALLOWED_USERS`, or the callback URL in the OAuth app doesn't match your domain. |
| `QueryCanceled: canceling statement due to statement timeout` | The query took longer than `QUERY_TIMEOUT_MS`. Speed it up or raise the limit. |
| `Data directory /var/lib/postgresql/17/main must not be owned by root` | You started Postgres as root. Run `su postgres -c "pg_ctlcluster 17 main start"` instead (`chown` won't help under PRoot). |
| `already running` from `start.sh` | Run `./start.sh stop` first. |

## Security notes

- Anyone you allowlist gets full read/write SQL access, with the rights of `POSTGRES_USER`. Using the `postgres` superuser is convenient but powerful: a superuser can run shell commands through `COPY ... PROGRAM`. For tighter safety, create a dedicated role that isn't a superuser, grant it only your tables, and use that in `.env`.
- Never commit `.env`. It holds your OAuth secret and ngrok token.
