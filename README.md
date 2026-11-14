# Jobs

A job-hunt tracker for the phone: applications through their stages, interview rounds with times and results, a notice-period countdown, and nudges when an application goes quiet. It opens at **http://localhost/jobs/**, and has a tile on the exocortex home page at http://localhost/.

```
phone browser ──► nginx (127.0.0.1:80) ─┬─ /jobs/  ──► public/ (static page)
                                        └─ /api/   ──► PostgREST ──► Postgres, schema "jobs"
```

There's no server process of its own: the page is static, and its data and logic live in the `jobs` schema, called through the PostgREST that the home page already runs. The look comes from the home page's `/ui.css`.

## Install

Needs the exocortex core (the `main` branch) set up first: Postgres with PL/Python, nginx, PostgREST and the home page (`~/exocortex/home/install.sh`).

```sh
git clone -b jobs https://github.com/hereliesadvaith/exocortex.git ~/apps/jobs
~/apps/jobs/install.sh
```

`install.sh` is safe to run again (also after a `git pull`):

1. applies `schema.sql`: tables, the `pipeline` and `upcoming` views, and the API functions;
2. writes `$PREFIX/etc/nginx/apps.d/jobs.conf`, serving `public/` at `/jobs/`, and reloads nginx;
3. registers the app in `home.apps` (so it gets a tile) with `api_schema = 'jobs'`, and runs `~/exocortex/home/sync-api.sh` so PostgREST serves the schema;
4. checks the page and the API answer.

`./install.sh remove` takes it off nginx and the home page; the data stays in schema `jobs` (`drop schema jobs cascade` to delete it).

## Data

| | |
|---|---|
| `jobs.profile` | One row: `headline`, `experience_years`, `notice_ends_on`, `current_ctc`, `expected_ctc` (LPA), `notes`. |
| `jobs.applications` | One row per company and role. `status`: `wishlist` → `applied` → `screening` → `interviewing` → `offer` → `accepted`, or `rejected` / `withdrawn` / `ghosted`. Also `location`, `work_mode` (`remote`, `hybrid`, `onsite`), `source`, `url`, `contact`, `expected_ctc`, `offered_ctc`, `applied_on`, `notes`. `status_changed_at` is set whenever the status changes. |
| `jobs.rounds` | Interview rounds of an application: `kind` (`hr`, `technical`, `assignment`, `manager`, `client`, `culture`, `final`, `other`), `scheduled_at`, `mode` (`video`, `phone`, `onsite`), `outcome` (`scheduled`, `passed`, `failed`, `cancelled`), `interviewer`, `notes`. Deleting an application deletes its rounds. |
| `jobs.pipeline` | View: open applications with days in their status, next round, rounds passed. |
| `jobs.upcoming` | View: rounds still to happen or waiting for a result. |

## API

The page calls these through PostgREST at `/api/rpc/<function>` with the header `Accept-Profile: jobs` (GET) or `Content-Profile: jobs` (POST, JSON body). They're `SECURITY DEFINER`; the API role can call them and nothing else in the schema. Create and update functions take an object of fields: text is trimmed (blank becomes `null`), unknown fields are ignored, and in an update the fields you leave out stay as they are.

| Function | |
|---|---|
| `state()` (GET) | The profile, every application, and every round |
| `put_profile(profile)` | Replaces the profile (`headline` is required) |
| `create_application(application)` | `company` and `role` are required; `status` defaults to `applied` |
| `update_application(app_id, patch)` | |
| `delete_application(app_id)` | Deletes it and its rounds |
| `create_round(app_id, round)` | `kind` defaults to `technical`, `outcome` to `scheduled` |
| `update_round(round_id, patch)`, `delete_round(round_id)` | |

```sh
curl -s -H 'Accept-Profile: jobs' http://localhost/api/rpc/state
curl -s -X POST -H 'Content-Profile: jobs' -H 'Content-Type: application/json' \
  -d '{"application": {"company": "Acme", "role": "Odoo Developer", "source": "LinkedIn"}}' http://localhost/api/rpc/create_application
```

Errors come back with a message and a fitting status: 404 for a missing application or round, 400 for invalid values (an unknown status, a negative CTC, a bad date, a missing company).
