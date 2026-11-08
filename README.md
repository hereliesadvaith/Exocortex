# Habits

A habit tracker page for the phone: tick off today's habits, step counts and minutes up or down, backfill the last week, add a note to any day, and see streaks and a 16-week heatmap per habit. It opens in the phone's browser at **http://localhost/habits/**.

```
phone browser ──► nginx (127.0.0.1:80) ──/habits/──► FastAPI (app.py, 127.0.0.1:8001) ──► PostgreSQL, schema `habits`
```

It runs on its own, from its own directory, with its own virtualenv, settings and logs. It only shares the Postgres server, where the `habits` schema lives (`schema.sql`).

## Setup (inside Debian, as root)

```sh
apt install -y nginx
git clone -b habits https://github.com/hereliesadvaith/exocortex.git /root/habits
cd /root/habits
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Create a database role that can use the `habits` schema and nothing else:

```sh
su postgres -c psql <<'SQL'
CREATE ROLE habits LOGIN PASSWORD 'choose-a-strong-password';
GRANT USAGE ON SCHEMA habits TO habits;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA habits TO habits;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA habits TO habits;
ALTER DEFAULT PRIVILEGES IN SCHEMA habits GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO habits;
ALTER DEFAULT PRIVILEGES IN SCHEMA habits GRANT USAGE ON SEQUENCES TO habits;
SQL
```

Then put that password in `.env`:

```sh
cp .env.example .env
chmod 600 .env
nano .env
```

## Run it

```sh
./start.sh start     # starts Postgres if it's down, then the app and nginx
./start.sh stop
./start.sh restart
./start.sh status
./start.sh update    # git pull, reinstall requirements if they changed, restart
tail -f habits.log
```

After a phone reboot: open Termux → `proot-distro login debian` → `/root/habits/start.sh start`.

`start.sh` links `nginx.conf` in as `/etc/nginx/sites-enabled/habits` and removes Debian's default site. Both nginx and the app listen on 127.0.0.1 only, so the page has no login: only apps on the phone can reach it.

## API

All paths are under `/habits/`.

| Method | Path | Body | Does |
|---|---|---|---|
| GET | `api/state?days=84` | | every habit with streaks, plus logs of the last `days` days |
| POST | `api/habits` | `{name, kind, target, times_per_week}` | add a habit (`kind`: `check`, `count` or `minutes`) |
| PATCH | `api/habits/{id}` | any of those fields, or `active` | edit, archive (`active: false`) or restore |
| DELETE | `api/habits/{id}` | | delete a habit and its history |
| PUT | `api/logs/{id}/{YYYY-MM-DD}` | `{value, note}` | set a day's value and note |
| DELETE | `api/logs/{id}/{YYYY-MM-DD}` | | clear a day |
