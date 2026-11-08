# Todos

A to-do list page for the phone: add tasks in one line, give them a due date, priority, list, notes or a repeat, and tick them off. It opens in the phone's browser at **http://localhost/todos/**.

```
phone browser ──► nginx (127.0.0.1:80) ──/todos/──► FastAPI (app.py, 127.0.0.1:8002) ──► PostgreSQL, schema `todos`
```

It runs on its own, from its own directory, with its own virtualenv, settings and logs. It shares the Postgres server, where the `todos` schema lives (`schema.sql`), and nginx's localhost site, which comes from the exocortex repo (`main` branch, `nginx/localhost.conf`) along with the home page at http://localhost/.

## The page

- **Today**: overdue tasks and tasks due today. **Upcoming**: dated tasks after today, by day. **All**: every open task, by list. **Done**: what you ticked off in the last 30 days.
- The box at the top adds a task in one line. It takes its due date from the tab you're on (Today → today, Upcoming → tomorrow) and its list from the list you've picked; the line under the box says which. The sliders button opens the full form.
- Tap a task to edit it; tap the circle to tick it off (Undo in the toast). The circle's colour is the priority.
- Lists: the chips under the tabs filter by list; **+ List** adds one, tapping the selected list renames or deletes it (its tasks move to the Inbox).
- A repeating task needs a due date. Ticking it off schedules the next one after today, on the same weekday or day of the month.

## Setup (inside Debian, as root)

```sh
apt install -y nginx
git clone -b todos https://github.com/hereliesadvaith/exocortex.git /root/todos
cd /root/todos
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Create the schema, and a database role that can use it and nothing else:

```sh
su postgres -c "psql -f schema.sql"
su postgres -c psql <<'SQL'
CREATE ROLE todos LOGIN PASSWORD 'choose-a-strong-password';
GRANT USAGE ON SCHEMA todos TO todos;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA todos TO todos;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA todos TO todos;
ALTER DEFAULT PRIVILEGES IN SCHEMA todos GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO todos;
ALTER DEFAULT PRIVILEGES IN SCHEMA todos GRANT USAGE ON SEQUENCES TO todos;
SQL
```

Then put that password in `.env`:

```sh
cp .env.example .env
chmod 600 .env
nano .env
```

### nginx

`nginx.conf` here is just the `/todos/` locations. `start.sh` links it in as `/etc/nginx/localhost.d/todos.conf`, which the exocortex localhost site includes, and links `app.json` into `/etc/exocortex/apps/` so the home page shows a Todos icon with its status. Start the exocortex server first on a fresh setup; `./start.sh status` says whether the include is in place.

## Run it

```sh
./start.sh start     # starts Postgres if it's down, then the app, and nginx if it's down
./start.sh stop      # stops the app only; nginx keeps serving the other apps
./start.sh restart
./start.sh status
./start.sh update    # git pull, reinstall requirements if they changed, restart
tail -f todos.log
```

After a phone reboot: open Termux → `proot-distro login debian` → `/root/todos/start.sh start`.

Both nginx and the app listen on 127.0.0.1 only, so the page has no login: only apps on the phone can reach it.

## From Claude

The `todos.open` view lists open tasks with their list name and whether they're overdue or due today, so over the Exocortex MCP server:

```sql
select * from todos.open;
insert into todos.tasks (title, due_on, priority) values ('Call the bank', current_date + 1, 2);
update todos.tasks set done_at = now() where id = 12;
```

(A repeat only rolls over when it's ticked off from the page or the API.)

## API

All paths are under `/todos/`.

| Method | Path | Body | Does |
|---|---|---|---|
| GET | `api/state?done_days=30` | | lists, every open task, and tasks done in the last `done_days` days |
| POST | `api/tasks` | `{title, notes, list_id, due_on, priority, repeat}` | add a task (`priority` 0–3, `repeat`: `daily`, `weekly`, `monthly`, `yearly`) |
| PATCH | `api/tasks/{id}` | any of those fields, or `done` | edit, tick off (`done: true`) or undo |
| DELETE | `api/tasks/{id}` | | delete a task |
| DELETE | `api/done` | | delete every completed task |
| POST | `api/lists` | `{name}` | add a list |
| PATCH | `api/lists/{id}` | `{name}` | rename a list |
| DELETE | `api/lists/{id}` | | delete a list; its tasks move to the Inbox |
