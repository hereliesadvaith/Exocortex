# Exocortex

An MCP server on your Android phone that gives an AI assistant a shell on it. It runs natively in Termux (no PRoot) and is published through an ngrok static domain. Only the GitHub usernames you allowlist can sign in.

```
Claude / any MCP client
        │  HTTPS + GitHub OAuth
        ▼
  ngrok static domain ──► ngrok agent ──► server.py (FastMCP, 127.0.0.1:8000) ──► bash
                          └──────────────────── Termux ───────────────────────┘
```

| Tool | What it does |
|---|---|
| `shell(command, timeout_s=60, cwd=None)` | Runs a bash command as the Termux user, starting in `~` unless `cwd` is given. Returns the exit code and the last 50k characters of output. Every command is written to `server.log`. |
| `update_and_restart(force_restart=False)` | Runs `./start.sh update` in the background: `git pull --ff-only`, reinstall requirements if they changed, restart the server. The connection drops for a few seconds. Without new commits it does nothing unless `force_restart` is true. Results go to `update.log`. |

Everything else on the phone (databases, apps, backups) is built and run through `shell`; this repo is only the server.

## Requirements

- [Termux](https://f-droid.org/packages/com.termux/) **and** [Termux:Boot](https://f-droid.org/packages/com.termux.boot/), both from F-Droid. Add-ons only work with a Termux from the same source, and the Google Play build has no Termux:Boot.
- A free [ngrok](https://ngrok.com) account (auth token and a free static domain)
- A GitHub account (for the OAuth app)

## 1. Termux packages

```sh
pkg update && pkg upgrade
pkg install -y git python rust binutils python-cryptography
```

FastMCP depends on a few packages written in Rust (`pydantic-core`, `rpds-py`, `watchfiles`) that have no ready-made Android builds, so pip compiles them on the phone. `rust` and `binutils` are for that; `python-cryptography` is Termux's prebuilt `cryptography`, which saves the longest compile.

## 2. ngrok

1. Copy your auth token from the [ngrok dashboard](https://dashboard.ngrok.com/get-started/your-authtoken).
2. Under **Domains**, claim your free static domain (something like `your-name.ngrok-free.dev`).
3. Install the agent (the `ngrok` Python package has no Android build, so `start.sh` runs the agent binary instead):

```sh
curl -LO https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-arm64.tgz
tar xzf ngrok-v3-stable-linux-arm64.tgz -C $PREFIX/bin && rm ngrok-v3-stable-linux-arm64.tgz
ngrok version
```

## 3. GitHub OAuth app

Go to GitHub → Settings → Developer settings → [OAuth Apps](https://github.com/settings/developers) → **New OAuth App**:

| Field | Value |
|---|---|
| Homepage URL | `https://<your-ngrok-domain>` |
| Authorization callback URL | `https://<your-ngrok-domain>/auth/callback` |

Copy the **Client ID** and generate a **Client secret**.

## 4. Install the server

```sh
git clone https://github.com/hereliesadvaith/exocortex.git ~/exocortex
cd ~/exocortex
python -m venv --system-site-packages .venv      # sees Termux's python-cryptography
export ANDROID_API_LEVEL=$(getprop ro.build.version.sdk)   # needed to compile the Rust packages
.venv/bin/pip install -r requirements.txt        # the first time takes a while
```

Create your `.env` from the template and fill it in. It's gitignored, so keep it private:

```sh
cp .env.example .env
chmod 600 .env
nano .env
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

## 5. Run it

```sh
./start.sh -d       # server and ngrok in the background
./start.sh status   # is each one up, and the public URL
./start.sh stop     # stop both
./start.sh restart  # stop, then start both in the background
./start.sh update   # git pull, then restart the server; rolls back if the new code doesn't start
./start.sh          # ngrok in the background, server in the foreground (Ctrl+C stops the server)
tail -f server.log ngrok.log
```

Logs are kept across restarts and rotated to `.1`–`.3` at 1 MB. `start.sh` takes a Termux wake lock so Android is less likely to kill it with the screen off.

Check it's reachable. An unauthenticated request should get `401`:

```sh
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://<your-ngrok-domain>/mcp
```

## 6. Start on boot

Open the Termux:Boot app once (Android only lets it run at boot after that), then:

```sh
mkdir -p ~/.termux/boot
cp ~/exocortex/termux-boot/exocortex ~/.termux/boot/
chmod +x ~/.termux/boot/exocortex
```

After a reboot it waits 10 seconds for the network, then runs `./start.sh -d`; its output goes to `~/exocortex/boot.log`. Also set Android Settings → Apps → Termux (and Termux:Boot) → Battery → **Unrestricted**.

## 7. Connect an AI assistant

**Claude (claude.ai / desktop / mobile):** Settings → Connectors → **Add custom connector**, URL `https://<your-ngrok-domain>/mcp`. Sign in with GitHub when asked.

**Claude Code:**

```sh
claude mcp add --transport http exocortex https://<your-ngrok-domain>/mcp
```

Then run `/mcp` inside Claude Code to authenticate.

## How updates protect you

- `./start.sh update` refuses to run if tracked files have uncommitted changes, so it never throws away local edits.
- If the pull fails, or the new `server.py` doesn't compile, or its requirements don't install, the code is reset to the previous commit and the running server is left alone.
- If the new server doesn't answer within 30 seconds, it resets to the previous commit and starts that again.
- ngrok keeps running through an update, so only the server restarts.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `pip install` fails building `pydantic-core` / `rpds-py` / `watchfiles` | Check `rust` and `binutils` are installed and `ANDROID_API_LEVEL` is exported in the same shell, then retry. |
| `pip install` tries to build `cryptography` | The venv can't see Termux's package: recreate it with `--system-site-packages`. |
| `ngrok.log` shows DNS errors like `lookup ... on [::1]:53` | The Linux ngrok binary looks for `/etc/resolv.conf`, which Android doesn't have. `pkg install proot`, then set `NGROK_BIN` to a wrapper script that runs `proot -b $PREFIX/etc/resolv.conf:/etc/resolv.conf ngrok "$@"`. |
| `ngrok.log` says the domain is already in use | Another ngrok agent is still connected with that domain (an old session, or another device). Stop it, then `./start.sh restart`. |
| `KeyError: 'GITHUB_CLIENT_ID'` (or another variable) on start | That variable is missing from `.env`. |
| Every client gets `401` after signing in | Your GitHub username isn't in `GITHUB_ALLOWED_USERS`, or the callback URL in the OAuth app doesn't match your domain. |
| `server already running` from `start.sh` | Use `./start.sh restart`. |

## Security notes

- Anyone you allowlist can run any command on the phone with Termux's rights, including reading `.env`, so keep the allowlist to yourself.
- Never commit `.env`. It holds your OAuth secret and ngrok token.
