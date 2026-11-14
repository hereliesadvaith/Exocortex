# Todos

A to-do app for the phone: tasks with due dates, priorities, notes and repeats, grouped into lists, with Today, Upcoming, All and Done views and search. It opens at **http://localhost/todos/**, and has a tile on the exocortex home page at http://localhost/.

```
phone browser ──► nginx (127.0.0.1:80) ─┬─ /todos/  ──► public/ (static page)
                                        └─ /api/    ──► PostgREST ──► Postgres, schema "todos"
```

There's no server process of its own: the page is static, and its data and logic live in the `todos` schema, called through the PostgREST that the home page already runs. The look comes from the home page's `/ui.css`.

## Install

Needs the exocortex core (the `main` branch) set up first: Postgres with PL/Python, nginx, PostgREST and the home page (`~/exocortex/home/install.sh`).

```sh
git clone -b todos https://github.com/hereliesadvaith/exocortex.git ~/apps/todos
~/apps/todos/install.sh
```

`install.sh` is safe to run again (also after a `git pull`):

1. applies `schema.sql`: tables, the `open` view, and the API functions;
2. writes `$PREFIX/etc/nginx/apps.d/todos.conf`, serving `public/` at `/todos/`, and reloads nginx;
3. registers the app in `home.apps` (so it gets a tile) with `api_schema = 'todos'`, and runs `~/exocortex/home/sync-api.sh` so PostgREST serves the schema;
4. checks the page and the API answer.

`./install.sh remove` takes it off nginx and the home page; the data stays in schema `todos` (`drop schema todos cascade` to delete it).

## Data

| | |
|---|---|
| `todos.lists` | Optional lists (Work, Home, ...). Tasks without a list are in the Inbox; deleting a list moves its tasks there. |
| `todos.tasks` | One row per task: `title`, `notes`, `list_id`, `due_on`, `priority` (0 none, 1 low, 2 medium, 3 high), `repeat` (`daily`, `weekly`, `monthly`, `yearly`; needs a due date). `done_at` is set when it's ticked off; a repeating task then gets its next copy, and `next_id` points at it so undoing can take it back. |
| `todos.open` | View: open tasks with their list name, `overdue` and `due_today`. |

"Today" and "overdue" use Postgres's `current_date`, so the database time zone decides them.

## API

The page calls these through PostgREST at `/api/rpc/<function>` with the header `Accept-Profile: todos` (GET) or `Content-Profile: todos` (POST, JSON body). They're `SECURITY DEFINER`; the API role can call them and nothing else in the schema.

| Function | |
|---|---|
| `state(done_days = 30)` (GET) | Lists, every open task, and tasks completed in the last `done_days` days |
| `create_task(title, notes, list_id, due_on, priority = 0, repeat)` | Returns the task |
| `update_task(task_id, patch)` | `patch`: any of `title`, `notes`, `list_id`, `due_on`, `priority`, `repeat` (`null` clears), and `done`. `done: true` ticks it off (a repeating task comes back on its next due date, keeping its weekday or day of the month); `done: false` undoes that and takes back the repeat it created if that one is still open. |
| `delete_task(task_id)` | |
| `clear_done()` | Deletes every completed task |
| `create_list(name)`, `rename_list(list_id, name)`, `delete_list(list_id)` | Deleting a list moves its tasks to the Inbox |

```sh
curl -s -H 'Accept-Profile: todos' http://localhost/api/rpc/state
curl -s -X POST -H 'Content-Profile: todos' -H 'Content-Type: application/json' \
  -d '{"title": "Pay rent", "due_on": "2026-12-01", "repeat": "monthly", "priority": 3}' http://localhost/api/rpc/create_task
```

Errors come back with a message and a fitting status: 409 for a duplicate list name, 404 for a missing task or list, 400 for invalid values.
