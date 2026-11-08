"""Job hunt tracker: a page and a small JSON API over the `jobs` Postgres schema.

Runs on 127.0.0.1:8004 behind nginx, which serves it at http://localhost/jobs/.
Start and stop it with ./start.sh.
"""
import os
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path
from typing import Literal

import psycopg
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from psycopg.rows import dict_row
from pydantic import BaseModel, Field

HERE = Path(__file__).parent
load_dotenv(HERE / ".env")

DSN = (
    f"host={os.getenv('POSTGRES_HOST', 'localhost')} "
    f"port={os.getenv('POSTGRES_PORT', '5432')} "
    f"user={os.getenv('POSTGRES_USER', 'jobs')} "
    f"password={os.environ['POSTGRES_PASSWORD']} "
    f"dbname={os.getenv('POSTGRES_DB', 'postgres')} "
    "options='-c statement_timeout=10000'"
)

app = FastAPI(title="Jobs", docs_url=None, redoc_url=None, openapi_url=None)

Status = Literal["wishlist", "applied", "screening", "interviewing", "offer",
                 "accepted", "rejected", "withdrawn", "ghosted"]
WorkMode = Literal["remote", "hybrid", "onsite"]
Kind = Literal["hr", "technical", "assignment", "manager", "client", "culture", "final", "other"]
Mode = Literal["video", "phone", "onsite"]
Outcome = Literal["scheduled", "passed", "failed", "cancelled"]
Ctc = Field(default=None, ge=0, le=99999)

APP_COLS = """id, company, role, status, location, work_mode, source, url, contact,
              expected_ctc, offered_ctc, applied_on, notes, status_changed_at, created_at, updated_at"""
ROUND_COLS = "id, application_id, kind, scheduled_at, mode, outcome, interviewer, notes"
PROFILE_COLS = "headline, experience_years, notice_ends_on, current_ctc, expected_ctc, notes"


def _errors(e: Exception):
    if isinstance(e, (psycopg.errors.CheckViolation, psycopg.errors.NotNullViolation)):
        raise HTTPException(400, f"Invalid value ({e.diag.constraint_name or 'constraint'})")
    if isinstance(e, psycopg.errors.ForeignKeyViolation):
        raise HTTPException(404, "No such application")
    raise e


def db(sql: str, params=None) -> list[dict]:
    try:
        with psycopg.connect(DSN, row_factory=dict_row, autocommit=True) as conn:
            cur = conn.execute(sql, params)
            return cur.fetchall() if cur.description else []
    except psycopg.errors.IntegrityError as e:
        _errors(e)


def clean(s: str | None) -> str | None:
    return (s or "").strip() or None


def numbers(row: dict) -> dict:
    """numeric columns come back as Decimal; send them as plain JSON numbers."""
    return {k: float(v) if isinstance(v, Decimal) else v for k, v in row.items()}


class ApplicationIn(BaseModel):
    company: str = Field(min_length=1, max_length=120)
    role: str = Field(min_length=1, max_length=160)
    status: Status = "applied"
    location: str | None = Field(default=None, max_length=120)
    work_mode: WorkMode | None = None
    source: str | None = Field(default=None, max_length=60)
    url: str | None = Field(default=None, max_length=1000)
    contact: str | None = Field(default=None, max_length=300)
    expected_ctc: float | None = Ctc
    offered_ctc: float | None = Ctc
    applied_on: date | None = None
    notes: str | None = Field(default=None, max_length=10000)


class ApplicationPatch(BaseModel):
    company: str | None = Field(default=None, min_length=1, max_length=120)
    role: str | None = Field(default=None, min_length=1, max_length=160)
    status: Status | None = None
    location: str | None = Field(default=None, max_length=120)
    work_mode: WorkMode | None = None
    source: str | None = Field(default=None, max_length=60)
    url: str | None = Field(default=None, max_length=1000)
    contact: str | None = Field(default=None, max_length=300)
    expected_ctc: float | None = Ctc
    offered_ctc: float | None = Ctc
    applied_on: date | None = None
    notes: str | None = Field(default=None, max_length=10000)


class RoundIn(BaseModel):
    kind: Kind = "technical"
    scheduled_at: datetime | None = None
    mode: Mode | None = None
    outcome: Outcome = "scheduled"
    interviewer: str | None = Field(default=None, max_length=200)
    notes: str | None = Field(default=None, max_length=10000)


class RoundPatch(BaseModel):
    kind: Kind | None = None
    scheduled_at: datetime | None = None
    mode: Mode | None = None
    outcome: Outcome | None = None
    interviewer: str | None = Field(default=None, max_length=200)
    notes: str | None = Field(default=None, max_length=10000)


class ProfileIn(BaseModel):
    headline: str = Field(min_length=1, max_length=120)
    experience_years: float | None = Field(default=None, ge=0, le=60)
    notice_ends_on: date | None = None
    current_ctc: float | None = Ctc
    expected_ctc: float | None = Ctc
    notes: str | None = Field(default=None, max_length=5000)


TEXT_FIELDS = {"company", "role", "location", "source", "url", "contact", "notes", "interviewer", "headline"}
REQUIRED = {"company", "role", "headline", "status", "kind", "outcome"}


def prepare(fields: dict) -> dict:
    for k in list(fields):
        if k in TEXT_FIELDS:
            fields[k] = clean(fields[k])
        if k in REQUIRED and fields[k] is None:
            raise HTTPException(400, f"{k.replace('_', ' ').capitalize()} can't be empty")
    return fields


@app.get("/", include_in_schema=False)
def page():
    return FileResponse(HERE / "static" / "index.html", headers={"Cache-Control": "no-cache"})


@app.get("/api/state")
def state():
    """The profile, every application, and every round."""
    profile = db(f"select {PROFILE_COLS} from jobs.profile")
    apps = db(f"select {APP_COLS} from jobs.applications order by status_changed_at desc, id desc limit 2000")
    rounds = db(f"select {ROUND_COLS} from jobs.rounds order by scheduled_at nulls last, id limit 5000")
    today = db("select current_date as d")[0]["d"]
    return {
        "today": today,
        "profile": numbers(profile[0]) if profile else None,
        "applications": [numbers(a) for a in apps],
        "rounds": rounds,
    }


@app.put("/api/profile")
def put_profile(p: ProfileIn):
    fields = prepare(p.model_dump())
    cols = ", ".join(fields)
    marks = ", ".join(["%s"] * len(fields))
    sets = ", ".join(f"{k} = excluded.{k}" for k in fields)
    rows = db(
        f"""
        insert into jobs.profile (id, {cols}) values (true, {marks})
        on conflict (id) do update set {sets}, updated_at = now()
        returning {PROFILE_COLS}
        """,
        tuple(fields.values()),
    )
    return numbers(rows[0])


@app.post("/api/applications", status_code=201)
def create_application(a: ApplicationIn):
    fields = prepare(a.model_dump())
    cols = ", ".join(fields)
    marks = ", ".join(["%s"] * len(fields))
    return numbers(db(
        f"insert into jobs.applications ({cols}) values ({marks}) returning {APP_COLS}",
        tuple(fields.values()),
    )[0])


@app.patch("/api/applications/{app_id}")
def update_application(app_id: int, patch: ApplicationPatch):
    fields = prepare(patch.model_dump(exclude_unset=True))
    if not fields:
        rows = db(f"select {APP_COLS} from jobs.applications where id = %s", (app_id,))
    else:
        sets = ", ".join(f"{k} = %s" for k in fields)
        rows = db(
            f"update jobs.applications set {sets} where id = %s returning {APP_COLS}",
            (*fields.values(), app_id),
        )
    if not rows:
        raise HTTPException(404, "No such application")
    return numbers(rows[0])


@app.delete("/api/applications/{app_id}", status_code=204)
def delete_application(app_id: int):
    """Delete an application and its rounds."""
    db("delete from jobs.applications where id = %s", (app_id,))


@app.post("/api/applications/{app_id}/rounds", status_code=201)
def create_round(app_id: int, r: RoundIn):
    fields = prepare(r.model_dump())
    cols = ", ".join(fields)
    marks = ", ".join(["%s"] * len(fields))
    return db(
        f"insert into jobs.rounds (application_id, {cols}) values (%s, {marks}) returning {ROUND_COLS}",
        (app_id, *fields.values()),
    )[0]


@app.patch("/api/rounds/{round_id}")
def update_round(round_id: int, patch: RoundPatch):
    fields = prepare(patch.model_dump(exclude_unset=True))
    if not fields:
        rows = db(f"select {ROUND_COLS} from jobs.rounds where id = %s", (round_id,))
    else:
        sets = ", ".join(f"{k} = %s" for k in fields)
        rows = db(
            f"update jobs.rounds set {sets} where id = %s returning {ROUND_COLS}",
            (*fields.values(), round_id),
        )
    if not rows:
        raise HTTPException(404, "No such round")
    return rows[0]


@app.delete("/api/rounds/{round_id}", status_code=204)
def delete_round(round_id: int):
    db("delete from jobs.rounds where id = %s", (round_id,))
