"""Habit tracker: a page and a small JSON API over the `habits` Postgres schema.

Runs on 127.0.0.1:8001 behind nginx, which serves it at http://localhost/habits/.
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
    f"user={os.getenv('POSTGRES_USER', 'habits')} "
    f"password={os.environ['POSTGRES_PASSWORD']} "
    f"dbname={os.getenv('POSTGRES_DB', 'postgres')} "
    "options='-c statement_timeout=10000'"
)

app = FastAPI(title="Habit tracker", docs_url=None, redoc_url=None, openapi_url=None)

Kind = Literal["check", "count", "minutes"]


def db(sql: str, params=None) -> list[dict]:
    try:
        with psycopg.connect(DSN, row_factory=dict_row, autocommit=True) as conn:
            cur = conn.execute(sql, params)
            return cur.fetchall() if cur.description else []
    except psycopg.errors.UniqueViolation:
        raise HTTPException(409, "A habit with that name already exists")
    except (psycopg.errors.CheckViolation, psycopg.errors.NotNullViolation) as e:
        raise HTTPException(400, f"Invalid value ({e.diag.constraint_name or 'constraint'})")
    except psycopg.errors.ForeignKeyViolation:
        raise HTTPException(404, "No such habit")


class HabitIn(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    kind: Kind = "check"
    target: float | None = Field(default=None, gt=0)
    times_per_week: int = Field(default=7, ge=1, le=7)


class HabitPatch(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=80)
    kind: Kind | None = None
    target: float | None = Field(default=None, gt=0)
    times_per_week: int | None = Field(default=None, ge=1, le=7)
    active: bool | None = None


class LogIn(BaseModel):
    value: float = Field(default=1, gt=0)
    note: str | None = Field(default=None, max_length=500)


@app.get("/", include_in_schema=False)
def page():
    return FileResponse(HERE / "static" / "index.html", headers={"Cache-Control": "no-cache"})


@app.get("/api/state")
def state(days: int = Query(84, ge=7, le=371)):
    """Every habit (active first) with its status, plus the logs of the last `days` days."""
    habits = db(
        """
        select h.id, h.name, h.kind, h.target, h.times_per_week, h.active,
               h.created_at::date as created_on,
               coalesce(s.done_today, false) as done_today,
               coalesce(s.done_this_week, 0) as done_this_week,
               coalesce(s.current_streak, 0) as current_streak,
               coalesce(s.streak_unit, case when h.times_per_week = 7 then 'days' else 'weeks' end) as streak_unit,
               coalesce(s.best_day_streak, 0) as best_day_streak,
               s.last_logged
        from habits.habits h
        left join habits.status s on s.id = h.id
        order by h.active desc, h.created_at, h.id
        """
    )
    logs = db(
        """
        select habit_id, logged_on, value, note from habits.logs
        where logged_on > current_date - %s::int
        order by logged_on
        """,
        (days,),
    )
    today = db("select current_date as d")[0]["d"]
    return {"today": today, "habits": habits, "logs": logs}


@app.post("/api/habits", status_code=201)
def create_habit(h: HabitIn):
    target = None if h.kind == "check" else h.target
    if h.kind != "check" and target is None:
        raise HTTPException(400, "Count and minutes habits need a target")
    return db(
        """
        insert into habits.habits (name, kind, target, times_per_week)
        values (%s, %s, %s, %s)
        returning id
        """,
        (h.name.strip(), h.kind, target, h.times_per_week),
    )[0]


@app.patch("/api/habits/{habit_id}")
def update_habit(habit_id: int, patch: HabitPatch):
    fields = patch.model_dump(exclude_unset=True)
    if "name" in fields:
        fields["name"] = fields["name"].strip()
    if fields.get("kind") == "check":
        fields["target"] = None
    if not fields:
        return {"id": habit_id}
    sets = ", ".join(f"{k} = %s" for k in fields)
    rows = db(
        f"update habits.habits set {sets} where id = %s returning id",
        (*fields.values(), habit_id),
    )
    if not rows:
        raise HTTPException(404, "No such habit")
    return rows[0]


@app.delete("/api/habits/{habit_id}", status_code=204)
def delete_habit(habit_id: int):
    db("delete from habits.habits where id = %s", (habit_id,))


@app.put("/api/logs/{habit_id}/{day}")
def set_log(habit_id: int, day: date, log: LogIn):
    note = (log.note or "").strip() or None
    return db(
        """
        insert into habits.logs (habit_id, logged_on, value, note)
        values (%s, %s, %s, %s)
        on conflict (habit_id, logged_on)
        do update set value = excluded.value, note = excluded.note
        returning habit_id, logged_on, value, note
        """,
        (habit_id, day, log.value, note),
    )[0]


@app.delete("/api/logs/{habit_id}/{day}", status_code=204)
def delete_log(habit_id: int, day: date):
    db("delete from habits.logs where habit_id = %s and logged_on = %s", (habit_id, day))
