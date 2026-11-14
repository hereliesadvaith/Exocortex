# Habits

A habit tracker for the phone: tick off today's habits, step counts and minutes up or down, backfill the last week, add a note to any day, and see streaks and a 16-week history per habit. It opens at **http://localhost/habits/**, and has a tile on the exocortex home page at http://localhost/.

```
phone browser ──► nginx (127.0.0.1:80) ─┬─ /habits/  ──► public/ (static page)
                                        └─ /api/     ──► PostgREST ──► Postgres, schema "habits"
```

There's no server process of its own: the page is static, and its data and logic live in the `habits` schema, called through the PostgREST that the home page already runs. The look comes from the home page's `/ui.css`.

## Install

Needs the exocortex core (the `main` branch) set up first: Postgres with PL/Python, nginx, PostgREST and the home page (`~/exocortex/home/install.sh`).

```sh
git clone -b habits https://github.com/hereliesadvaith/exocortex.git ~/apps/habits
~/apps/habits/install.sh
```

`install.sh` is safe to run again (also after a `git pull`):

1. applies `schema.sql`: tables, the `status` view, and the API functions;
2. writes `$PREFIX/etc/nginx/apps.d/habits.conf`, serving `public/` at `/habits/`, and reloads nginx;
3. registers the app in `home.apps` (so it gets a tile) with `api_schema = 'habits'`, and runs `~/exocortex/home/sync-api.sh` so PostgREST serves the schema;
4. checks the page and the API answer.

`./install.sh remove` takes it off nginx and the home page; the data stays in schema `habits` (`drop schema habits cascade` to delete it).

## Data

| | |
|---|---|
| `habits.habits` | One row per habit. `kind`: `check` (done or not), `count` or `minutes`; count and minutes need a daily `target`. `times_per_week` below 7 makes the streak count weeks in which the habit was met that many days. `active = false` archives it. |
| `habits.logs` | At most one row per habit per day; a day counts as met when `value >= target` (1 for check habits). Optional `note`. |
| `habits.status` | View, per active habit: done today, done this week, current streak (days or weeks), best daily streak, last logged day. |

"Today" is Postgres's `current_date`, so the database time zone decides where a day ends.

## API

The page calls these through PostgREST at `/api/rpc/<function>` with the header `Accept-Profile: habits` (GET) or `Content-Profile: habits` (POST, JSON body). They're `SECURITY DEFINER`; the API role can call them and nothing else in the schema.

| Function | |
|---|---|
| `state(days = 84)` (GET) | Every habit with its status, plus the logs of the last `days` days |
| `create_habit(name, kind = 'check', target, times_per_week = 7)` | Returns `{"id": ...}` |
| `update_habit(habit_id, patch)` | `patch`: any of `name`, `kind`, `target`, `times_per_week`, `active` |
| `delete_habit(habit_id)` | Deletes the habit and its history |
| `set_log(habit_id, day, value, note)` | One value per habit per day; saving again replaces it |
| `delete_log(habit_id, day)` | Clears a day |

```sh
curl -s -H 'Accept-Profile: habits' 'http://localhost/api/rpc/state?days=7'
curl -s -X POST -H 'Content-Profile: habits' -H 'Content-Type: application/json' \
  -d '{"name": "Read", "kind": "minutes", "target": 20}' http://localhost/api/rpc/create_habit
```

Errors come back with a message and a fitting status: 409 for a duplicate name, 404 for a missing habit, 400 for invalid values.
