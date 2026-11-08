# Jobs

A job-hunt tracker for the phone: every application with where it stands, its interview rounds, and a countdown to the end of your notice period. It opens in the phone's browser at **http://localhost/jobs/**.

```
phone browser ──► nginx (127.0.0.1:80) ──/jobs/──► FastAPI (app.py, 127.0.0.1:8004) ──► PostgreSQL, schema `jobs`
```

It runs on its own, from its own directory, with its own virtualenv, settings and logs, like the habits and todos apps. It shares the Postgres server, where the `jobs` schema lives (`schema.sql`), and nginx's localhost site, which comes from the exocortex repo (`main` branch, `nginx/localhost.conf`) along with the home page at http://localhost/.

## The page

- **Header**: your headline and experience, and the days left on your notice period. Tap the countdown to edit the profile (notice end date, current and expected CTC, notes).
- **Pipeline**: open applications grouped by status (Offer, Interviewing, Screening, Applied, Wishlist). Each card shows where and how long it's been in that status, the next round or *Waiting to hear* when a round is over but has no result yet, and a dot per round (green passed, red failed). Applications with no reply for 7 days say so.
- **Interviews**: rounds waiting for a result, then upcoming rounds by day.
- **Closed**: rejected, withdrawn, ghosted and accepted.
- The search bar finds applications by company, role, location, source, contact, notes, or the notes and interviewers of their rounds.
- The + button adds an application. Tap one to edit it, change its status, or add a round. Adding the first round moves a wishlist or applied application to Screening (for an HR call) or Interviewing.

Statuses: `wishlist`, `applied`, `screening`, `interviewing`, `offer`, `accepted`, `rejected`, `withdrawn`, `ghosted`.
Rounds: `hr`, `technical`, `assignment`, `manager`, `client`, `culture`, `final`, `other`, each `scheduled` (pending), `passed`, `failed` or `cancelled`.
Salaries are in lakhs per annum (LPA).

## Setup (inside Debian, as root)

```sh
git clone -b jobs https://github.com/hereliesadvaith/exocortex.git /root/jobs
cd /root/jobs
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Create the schema, and a database role that can use it and nothing else:

```sh
su postgres -c "psql -f schema.sql"
su postgres -c psql <<'SQL'
CREATE ROLE jobs LOGIN PASSWORD 'choose-a-strong-password';
GRANT USAGE ON SCHEMA jobs TO jobs;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA jobs TO jobs;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA jobs TO jobs;
ALTER DEFAULT PRIVILEGES IN SCHEMA jobs GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO jobs;
ALTER DEFAULT PRIVILEGES IN SCHEMA jobs GRANT USAGE ON SEQUENCES TO jobs;
SQL
```

Then put that password in `.env`:

```sh
cp .env.example .env
chmod 600 .env
nano .env
```

### Sample data

`sample.sql` fills in a profile (Odoo developer, 3.5 years, notice ending 28 Dec 2026) and 14 made-up applications across every status, with rounds dated around the day you load it:

```sh
su postgres -c "psql -f sample.sql"
```

To clear the applications and start tracking for real (the profile stays):

```sh
su postgres -c "psql -c 'TRUNCATE jobs.applications RESTART IDENTITY CASCADE'"
```

### nginx

`nginx.conf` here is just the `/jobs/` locations. `start.sh` links it in as `/etc/nginx/localhost.d/jobs.conf`, which the exocortex localhost site includes, and links `app.json` into `/etc/exocortex/apps/` so the home page shows a Jobs icon with its status.

## Run it

```sh
./start.sh start     # starts Postgres if it's down, then the app, and nginx if it's down
./start.sh stop      # stops the app only; nginx keeps serving the other apps
./start.sh restart
./start.sh status
./start.sh update    # git pull, reinstall requirements if they changed, restart
tail -f jobs.log
```

After a phone reboot: open Termux → `proot-distro login debian` → `/root/jobs/start.sh start`.

Both nginx and the app listen on 127.0.0.1 only, so the page has no login: only apps on the phone can reach it.

## From Claude

Over the Exocortex MCP server:

```sql
select * from jobs.pipeline;   -- open applications with their next round and days in status
select * from jobs.upcoming;   -- pending rounds, soonest first; awaiting_result for past ones
insert into jobs.applications (company, role, source, applied_on) values ('Acme', 'Odoo Developer', 'LinkedIn', current_date);
update jobs.applications set status = 'interviewing' where id = 3;
insert into jobs.rounds (application_id, kind, scheduled_at, mode)
  values (3, 'technical', '2026-11-12 11:00 Asia/Kolkata', 'video');
update jobs.rounds set outcome = 'passed' where id = 7;
```

## API

All paths are under `/jobs/`.

| Method | Path | Body | Does |
|---|---|---|---|
| GET | `api/state` | | profile, every application and every round |
| PUT | `api/profile` | `{headline, experience_years, notice_ends_on, current_ctc, expected_ctc, notes}` | save the profile |
| POST | `api/applications` | `{company, role, status, location, work_mode, source, url, contact, expected_ctc, offered_ctc, applied_on, notes}` | add an application |
| PATCH | `api/applications/{id}` | any of those fields | edit an application |
| DELETE | `api/applications/{id}` | | delete an application and its rounds |
| POST | `api/applications/{id}/rounds` | `{kind, scheduled_at, mode, outcome, interviewer, notes}` | add a round |
| PATCH | `api/rounds/{id}` | any of those fields | edit a round |
| DELETE | `api/rounds/{id}` | | delete a round |
