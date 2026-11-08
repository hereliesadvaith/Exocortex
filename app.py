"""To-do list: a page and a small JSON API over the `todos` Postgres schema.

Runs on 127.0.0.1:8002 behind nginx, which serves it at http://localhost/todos/.
Start and stop it with ./start.sh.
"""
import os
from datetime import date
from pathlib import Path
from typing import Literal

import psycopg
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from psycopg.rows import dict_row
from pydantic import BaseModel, Field

HERE = Path(__file__).parent
load_dotenv(HERE / ".env")

DSN = (
    f"host={os.getenv('POSTGRES_HOST', 'localhost')} "
    f"port={os.getenv('POSTGRES_PORT', '5432')} "
    f"user={os.getenv('POSTGRES_USER', 'todos')} "
    f"password={os.environ['POSTGRES_PASSWORD']} "
    f"dbname={os.getenv('POSTGRES_DB', 'postgres')} "
    "options='-c statement_timeout=10000'"
)

app = FastAPI(title="Todos", docs_url=None, redoc_url=None, openapi_url=None)

Repeat = Literal["daily", "weekly", "monthly", "yearly"]
INTERVAL = {"daily": "1 day", "weekly": "7 days", "monthly": "1 month", "yearly": "1 year"}

TASK_COLS = """t.id, t.title, t.notes, t.list_id, t.due_on, t.priority, t.repeat,
               t.done_at, (t.done_at)::date as done_on, t.created_at"""


def _errors(e: Exception):
    if isinstance(e, psycopg.errors.UniqueViolation):
        raise HTTPException(409, "A list with that name already exists")
    if isinstance(e, (psycopg.errors.CheckViolation, psycopg.errors.NotNullViolation)):
        if e.diag.constraint_name == "tasks_repeat_needs_due":
            raise HTTPException(400, "A repeating task needs a due date")
        raise HTTPException(400, f"Invalid value ({e.diag.constraint_name or 'constraint'})")
    if isinstance(e, psycopg.errors.ForeignKeyViolation):
        raise HTTPException(404, "No such list")
    raise e


def db(sql: str, params=None) -> list[dict]:
    try:
        with psycopg.connect(DSN, row_factory=dict_row, autocommit=True) as conn:
            cur = conn.execute(sql, params)
            return cur.fetchall() if cur.description else []
    except psycopg.errors.IntegrityError as e:
        _errors(e)


class TaskIn(BaseModel):
    title: str = Field(min_length=1, max_length=300)
    notes: str | None = Field(default=None, max_length=5000)
    list_id: int | None = None
    due_on: date | None = None
    priority: int = Field(default=0, ge=0, le=3)
    repeat: Repeat | None = None


class TaskPatch(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=300)
    notes: str | None = Field(default=None, max_length=5000)
    list_id: int | None = None
    due_on: date | None = None
    priority: int | None = Field(default=None, ge=0, le=3)
    repeat: Repeat | None = None
    done: bool | None = None


class ListIn(BaseModel):
    name: str = Field(min_length=1, max_length=60)


def clean(s: str | None) -> str | None:
    return (s or "").strip() or None


@app.get("/", include_in_schema=False)
def page():
    return FileResponse(HERE / "static" / "index.html", headers={"Cache-Control": "no-cache"})


@app.get("/api/state")
def state(done_days: int = Query(30, ge=1, le=366)):
    """Lists, every open task, and tasks completed in the last `done_days` days."""
    lists = db("select id, name from todos.lists order by lower(name), id")
    tasks = db(
        f"""
        select {TASK_COLS} from todos.tasks t
        where t.done_at is null or t.done_at > now() - make_interval(days => %s)
        order by t.done_at desc nulls first, t.due_on nulls last, t.priority desc, t.created_at, t.id
        limit 2000
        """,
        (done_days,),
    )
    today = db("select current_date as d")[0]["d"]
    return {"today": today, "lists": lists, "tasks": tasks}


@app.post("/api/tasks", status_code=201)
def create_task(t: TaskIn):
    return db(
        f"""
        insert into todos.tasks as t (title, notes, list_id, due_on, priority, repeat)
        values (%s, %s, %s, %s, %s, %s)
        returning {TASK_COLS}
        """,
        (t.title.strip(), clean(t.notes), t.list_id, t.due_on, t.priority, t.repeat),
    )[0]


@app.patch("/api/tasks/{task_id}")
def update_task(task_id: int, patch: TaskPatch):
    fields = patch.model_dump(exclude_unset=True)
    done = fields.pop("done", None)
    if "title" in fields:
        if not clean(fields["title"]):
            raise HTTPException(400, "Title can't be empty")
        fields["title"] = fields["title"].strip()
    if "notes" in fields:
        fields["notes"] = clean(fields["notes"])
    if "priority" in fields and fields["priority"] is None:
        fields["priority"] = 0

    try:
        with psycopg.connect(DSN, row_factory=dict_row) as conn, conn.transaction():
            cur = conn.execute(
                "select id, done_at, repeat, due_on, next_id from todos.tasks where id = %s for update",
                (task_id,),
            )
            old = cur.fetchone()
            if not old:
                raise HTTPException(404, "No such task")
            if fields:
                sets = ", ".join(f"{k} = %s" for k in fields)
                conn.execute(f"update todos.tasks set {sets} where id = %s", (*fields.values(), task_id))

            if done is True and old["done_at"] is None:
                conn.execute("update todos.tasks set done_at = now() where id = %s", (task_id,))
                # A repeating task comes back: the next due date after today, stepping
                # from the old due date so it stays on the same weekday / day of month.
                conn.execute(
                    """
                    with t as (select * from todos.tasks where id = %(id)s and repeat is not null),
                    nxt as (
                        insert into todos.tasks (title, notes, list_id, due_on, priority, repeat)
                        select title, notes, list_id,
                               (select min(d)::date from generate_series(
                                    due_on + %(step)s::interval,
                                    greatest(due_on, current_date) + %(step)s::interval,
                                    %(step)s::interval) d
                                where d > current_date),
                               priority, repeat
                        from t
                        returning id
                    )
                    update todos.tasks set next_id = (select id from nxt) where id = %(id)s and exists (select 1 from nxt)
                    """,
                    {"id": task_id, "step": INTERVAL.get(fields.get("repeat") or old["repeat"], "1 day")},
                )
            elif done is False and old["done_at"] is not None:
                # Undo: take back the repeat it spawned, if that one is still open.
                if old["next_id"]:
                    conn.execute(
                        "delete from todos.tasks where id = %s and done_at is null", (old["next_id"],)
                    )
                conn.execute(
                    "update todos.tasks set done_at = null, next_id = null where id = %s", (task_id,)
                )

            return conn.execute(
                f"select {TASK_COLS} from todos.tasks t where t.id = %s", (task_id,)
            ).fetchone()
    except psycopg.errors.IntegrityError as e:
        _errors(e)


@app.delete("/api/tasks/{task_id}", status_code=204)
def delete_task(task_id: int):
    db("delete from todos.tasks where id = %s", (task_id,))


@app.delete("/api/done", status_code=204)
def clear_done():
    """Delete every completed task."""
    db("delete from todos.tasks where done_at is not null")


@app.post("/api/lists", status_code=201)
def create_list(l: ListIn):
    name = clean(l.name)
    if not name:
        raise HTTPException(400, "Name can't be empty")
    return db("insert into todos.lists (name) values (%s) returning id, name", (name,))[0]


@app.patch("/api/lists/{list_id}")
def rename_list(list_id: int, l: ListIn):
    name = clean(l.name)
    if not name:
        raise HTTPException(400, "Name can't be empty")
    rows = db("update todos.lists set name = %s where id = %s returning id, name", (name, list_id))
    if not rows:
        raise HTTPException(404, "No such list")
    return rows[0]


@app.delete("/api/lists/{list_id}", status_code=204)
def delete_list(list_id: int):
    """Delete a list. Its tasks move to the Inbox."""
    db("delete from todos.lists where id = %s", (list_id,))
