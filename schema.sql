-- Jobs: schema "jobs", a job-hunt tracker. Safe to run again; install.sh applies it.
--
-- jobs.profile       one row: headline, experience, notice period, current and
--                    expected CTC (in LPA).
-- jobs.applications  one row per company/role, with its status:
--                    wishlist -> applied -> screening -> interviewing -> offer -> accepted,
--                    or rejected / withdrawn / ghosted. status_changed_at is set
--                    whenever the status changes.
-- jobs.rounds        interview rounds of an application, with when, how and the result.
-- jobs.pipeline      view: open applications, days in their status, next round.
-- jobs.upcoming      view: rounds still to happen or waiting for a result.
--
-- The page calls the functions at the end through PostgREST (/api/rpc/<fn> with
-- the "jobs" profile). They're SECURITY DEFINER: the API role (home_web) can call
-- them and nothing else in this schema.

create schema if not exists jobs;

create table if not exists jobs.profile (
    id boolean primary key default true check (id),   -- only ever one row
    headline text not null default 'Developer' check (length(headline) between 1 and 120),
    experience_years numeric(4,1) check (experience_years between 0 and 60),
    notice_ends_on date,
    current_ctc numeric(7,2) check (current_ctc >= 0),
    expected_ctc numeric(7,2) check (expected_ctc >= 0),
    notes text check (length(notes) <= 5000),
    updated_at timestamptz not null default now()
);
insert into jobs.profile default values on conflict do nothing;

create table if not exists jobs.applications (
    id integer generated always as identity primary key,
    company text not null check (length(company) between 1 and 120),
    role text not null check (length(role) between 1 and 160),
    status text not null default 'applied' check (status in (
        'wishlist',      -- want to apply
        'applied',       -- applied, no reply yet
        'screening',     -- recruiter / HR talking to you
        'interviewing',  -- in interview rounds
        'offer',         -- offer in hand, not decided
        'accepted',      -- took it
        'rejected',      -- they said no
        'withdrawn',     -- you said no
        'ghosted'        -- no reply for too long
    )),
    location text check (length(location) <= 120),
    work_mode text check (work_mode in ('remote', 'hybrid', 'onsite')),
    source text check (length(source) <= 60),       -- LinkedIn, Naukri, referral, ...
    url text check (length(url) <= 1000),
    contact text check (length(contact) <= 300),    -- recruiter name, phone, email
    expected_ctc numeric(7,2) check (expected_ctc >= 0),
    offered_ctc numeric(7,2) check (offered_ctc >= 0),
    applied_on date,
    notes text check (length(notes) <= 10000),
    status_changed_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
create index if not exists applications_status_idx on jobs.applications (status);

create table if not exists jobs.rounds (
    id integer generated always as identity primary key,
    application_id integer not null references jobs.applications(id) on delete cascade,
    kind text not null default 'technical' check (kind in (
        'hr', 'technical', 'assignment', 'manager', 'client', 'culture', 'final', 'other'
    )),
    scheduled_at timestamptz,
    mode text check (mode in ('video', 'phone', 'onsite')),
    outcome text not null default 'scheduled' check (outcome in (
        'scheduled',  -- coming up, or done and waiting to hear
        'passed', 'failed', 'cancelled'
    )),
    interviewer text check (length(interviewer) <= 200),
    notes text check (length(notes) <= 10000),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
create index if not exists rounds_application_idx on jobs.rounds (application_id);
create index if not exists rounds_scheduled_idx on jobs.rounds (scheduled_at) where outcome = 'scheduled';

-- updated_at on every update (Termux's Postgres has no moddatetime), and
-- status_changed_at when the status changes.
create or replace function jobs.touch() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
create or replace function jobs.status_changed() returns trigger language plpgsql as $$
begin
  if new.status is distinct from old.status then
    new.status_changed_at := now();
  end if;
  return new;
end $$;
drop trigger if exists applications_mtime on jobs.applications;
create trigger applications_mtime before update on jobs.applications for each row execute function jobs.touch();
drop trigger if exists applications_status on jobs.applications;
create trigger applications_status before update of status on jobs.applications for each row execute function jobs.status_changed();
drop trigger if exists rounds_mtime on jobs.rounds;
create trigger rounds_mtime before update on jobs.rounds for each row execute function jobs.touch();
drop trigger if exists profile_mtime on jobs.profile;
create trigger profile_mtime before update on jobs.profile for each row execute function jobs.touch();

create or replace view jobs.pipeline as
select a.id, a.company, a.role, a.status, a.location, a.work_mode, a.source,
       a.expected_ctc, a.offered_ctc, a.applied_on,
       current_date - a.status_changed_at::date as days_in_status,
       n.kind as next_round, n.scheduled_at as next_round_at,
       (select count(*) from jobs.rounds r where r.application_id = a.id and r.outcome = 'passed') as rounds_passed
from jobs.applications a
left join lateral (
    select r.kind, r.scheduled_at from jobs.rounds r
    where r.application_id = a.id and r.outcome = 'scheduled' and r.scheduled_at >= now()
    order by r.scheduled_at limit 1
) n on true
where a.status in ('wishlist', 'applied', 'screening', 'interviewing', 'offer')
order by array_position(array['offer', 'interviewing', 'screening', 'applied', 'wishlist'], a.status),
         n.scheduled_at nulls last, a.status_changed_at;

create or replace view jobs.upcoming as
select r.id, r.scheduled_at, r.kind, r.mode, a.company, a.role, r.interviewer,
       r.scheduled_at < now() as awaiting_result
from jobs.rounds r
join jobs.applications a on a.id = r.application_id
where r.outcome = 'scheduled' and r.scheduled_at is not null
order by r.scheduled_at;

-- ---- API ----------------------------------------------------------------------
-- Create and update functions take a JSON object of fields. jobs.clean() keeps the
-- allowed ones, trims text (blank becomes null) and refuses a missing required one.
-- Errors use SQLSTATEs PostgREST maps to HTTP: PT404 -> 404, 22023 -> 400; the page
-- shows the message.

create or replace function jobs.clean(fields jsonb, allowed text[], required text[], text_fields text[]) returns jsonb
language plpgsql immutable
as $$
declare
  k text;
  v jsonb;
  result jsonb := '{}'::jsonb;
begin
  for k, v in select * from jsonb_each(coalesce(fields, '{}'::jsonb)) loop
    continue when not k = any(allowed);
    if k = any(text_fields) and jsonb_typeof(v) = 'string' then
      v := coalesce(to_jsonb(nullif(btrim(v #>> '{}'), '')), 'null'::jsonb);
    end if;
    if k = any(required) and v = 'null'::jsonb then
      raise exception '% can''t be empty', initcap(replace(k, '_', ' ')) using errcode = '22023';
    end if;
    result := result || jsonb_build_object(k, v);
  end loop;
  return result;
end $$;

-- Constraint and type errors as messages the page can show.
create or replace function jobs.fail(err_state text, err_constraint text, err_message text) returns void
language plpgsql
as $$
begin
  if err_state = '23503' then
    raise exception 'No such application' using errcode = 'PT404';
  elsif err_state in ('23514', '23502', '22P02', '22007', '22008', '22003') then
    raise exception 'Invalid value (%)', coalesce(nullif(err_constraint, ''), err_message) using errcode = '22023';
  end if;
  raise exception '%', err_message using errcode = err_state;
end $$;

create or replace function jobs.app_fields() returns text[] language sql immutable as $$
  select array['company', 'role', 'status', 'location', 'work_mode', 'source', 'url', 'contact',
               'expected_ctc', 'offered_ctc', 'applied_on', 'notes']
$$;
create or replace function jobs.round_fields() returns text[] language sql immutable as $$
  select array['kind', 'scheduled_at', 'mode', 'outcome', 'interviewer', 'notes']
$$;

-- The profile, every application, and every round.
create or replace function jobs.state() returns jsonb
language sql stable security definer
set search_path = pg_catalog, jobs
as $$
  select jsonb_build_object(
    'today', current_date,
    'profile', (select jsonb_build_object('headline', p.headline, 'experience_years', p.experience_years,
                                          'notice_ends_on', p.notice_ends_on, 'current_ctc', p.current_ctc,
                                          'expected_ctc', p.expected_ctc, 'notes', p.notes)
                from jobs.profile p limit 1),
    'applications', coalesce((
      select jsonb_agg(to_jsonb(a) order by a.status_changed_at desc, a.id desc)
      from (select * from jobs.applications order by status_changed_at desc, id desc limit 2000) a), '[]'::jsonb),
    'rounds', coalesce((
      select jsonb_agg(jsonb_build_object('id', r.id, 'application_id', r.application_id, 'kind', r.kind,
                                          'scheduled_at', r.scheduled_at, 'mode', r.mode, 'outcome', r.outcome,
                                          'interviewer', r.interviewer, 'notes', r.notes)
                       order by r.scheduled_at nulls last, r.id)
      from (select * from jobs.rounds order by scheduled_at nulls last, id limit 5000) r), '[]'::jsonb))
$$;

-- Replace the profile: headline, experience_years, notice_ends_on, current_ctc,
-- expected_ctc, notes.
create or replace function jobs.put_profile(profile jsonb) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, jobs
as $$
declare
  f jsonb;
  p jobs.profile;
  st text; con text; msg text;
begin
  f := jobs.clean(profile, array['headline', 'experience_years', 'notice_ends_on', 'current_ctc', 'expected_ctc', 'notes'],
                  array['headline'], array['headline', 'notes']);
  if not f ? 'headline' then
    raise exception 'Headline can''t be empty' using errcode = '22023';
  end if;
  p := jsonb_populate_record(null::jobs.profile, f);
  insert into jobs.profile (id, headline, experience_years, notice_ends_on, current_ctc, expected_ctc, notes)
  values (true, p.headline, p.experience_years, p.notice_ends_on, p.current_ctc, p.expected_ctc, p.notes)
  on conflict (id) do update set headline = excluded.headline, experience_years = excluded.experience_years,
    notice_ends_on = excluded.notice_ends_on, current_ctc = excluded.current_ctc,
    expected_ctc = excluded.expected_ctc, notes = excluded.notes
  returning * into p;
  return jsonb_build_object('headline', p.headline, 'experience_years', p.experience_years,
                            'notice_ends_on', p.notice_ends_on, 'current_ctc', p.current_ctc,
                            'expected_ctc', p.expected_ctc, 'notes', p.notes);
exception
  when sqlstate '22023' then raise;
  when others then
    get stacked diagnostics st = returned_sqlstate, con = constraint_name, msg = message_text;
    perform jobs.fail(st, con, msg);
end $$;

create or replace function jobs.create_application(application jsonb) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, jobs
as $$
declare
  f jsonb;
  a jobs.applications;
  st text; con text; msg text;
begin
  f := jobs.clean(application, jobs.app_fields(), array['company', 'role', 'status'],
                  array['company', 'role', 'location', 'source', 'url', 'contact', 'notes']);
  if not (f ? 'company' and f ? 'role') then
    raise exception 'Company and role are needed' using errcode = '22023';
  end if;
  a := jsonb_populate_record(null::jobs.applications, f);
  insert into jobs.applications (company, role, status, location, work_mode, source, url, contact,
                                 expected_ctc, offered_ctc, applied_on, notes)
  values (a.company, a.role, coalesce(a.status, 'applied'), a.location, a.work_mode, a.source, a.url, a.contact,
          a.expected_ctc, a.offered_ctc, a.applied_on, a.notes)
  returning * into a;
  return to_jsonb(a);
exception
  when sqlstate '22023' then raise;
  when others then
    get stacked diagnostics st = returned_sqlstate, con = constraint_name, msg = message_text;
    perform jobs.fail(st, con, msg);
end $$;

-- patch: any of the application's fields; the rest stay as they are.
create or replace function jobs.update_application(app_id int, patch jsonb) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, jobs
as $$
declare
  f jsonb;
  a jobs.applications;
  st text; con text; msg text;
begin
  select * into a from jobs.applications where id = app_id for update;
  if not found then
    raise exception 'No such application' using errcode = 'PT404';
  end if;
  f := jobs.clean(patch, jobs.app_fields(), array['company', 'role', 'status'],
                  array['company', 'role', 'location', 'source', 'url', 'contact', 'notes']);
  a := jsonb_populate_record(a, f);
  update jobs.applications set company = a.company, role = a.role, status = a.status, location = a.location,
    work_mode = a.work_mode, source = a.source, url = a.url, contact = a.contact, expected_ctc = a.expected_ctc,
    offered_ctc = a.offered_ctc, applied_on = a.applied_on, notes = a.notes
  where id = app_id
  returning * into a;
  return to_jsonb(a);
exception
  when sqlstate 'PT404' or sqlstate '22023' then raise;
  when others then
    get stacked diagnostics st = returned_sqlstate, con = constraint_name, msg = message_text;
    perform jobs.fail(st, con, msg);
end $$;

-- Delete an application and its rounds.
create or replace function jobs.delete_application(app_id int) returns void
language sql security definer
set search_path = pg_catalog, jobs
as $$ delete from jobs.applications where id = app_id $$;

create or replace function jobs.round_json(r jobs.rounds) returns jsonb language sql immutable as $$
  select jsonb_build_object('id', r.id, 'application_id', r.application_id, 'kind', r.kind,
                            'scheduled_at', r.scheduled_at, 'mode', r.mode, 'outcome', r.outcome,
                            'interviewer', r.interviewer, 'notes', r.notes)
$$;

create or replace function jobs.create_round(app_id int, round jsonb) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, jobs
as $$
declare
  f jsonb;
  r jobs.rounds;
  st text; con text; msg text;
begin
  f := jobs.clean(round, jobs.round_fields(), array['kind', 'outcome'], array['interviewer', 'notes']);
  r := jsonb_populate_record(null::jobs.rounds, f);
  insert into jobs.rounds (application_id, kind, scheduled_at, mode, outcome, interviewer, notes)
  values (app_id, coalesce(r.kind, 'technical'), r.scheduled_at, r.mode, coalesce(r.outcome, 'scheduled'),
          r.interviewer, r.notes)
  returning * into r;
  return jobs.round_json(r);
exception
  when sqlstate '22023' then raise;
  when others then
    get stacked diagnostics st = returned_sqlstate, con = constraint_name, msg = message_text;
    perform jobs.fail(st, con, msg);
end $$;

-- patch: any of kind, scheduled_at, mode, outcome, interviewer, notes.
create or replace function jobs.update_round(round_id int, patch jsonb) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, jobs
as $$
declare
  f jsonb;
  r jobs.rounds;
  st text; con text; msg text;
begin
  select * into r from jobs.rounds where id = round_id for update;
  if not found then
    raise exception 'No such round' using errcode = 'PT404';
  end if;
  f := jobs.clean(patch, jobs.round_fields(), array['kind', 'outcome'], array['interviewer', 'notes']);
  r := jsonb_populate_record(r, f);
  update jobs.rounds set kind = r.kind, scheduled_at = r.scheduled_at, mode = r.mode, outcome = r.outcome,
    interviewer = r.interviewer, notes = r.notes
  where id = round_id
  returning * into r;
  return jobs.round_json(r);
exception
  when sqlstate 'PT404' or sqlstate '22023' then raise;
  when others then
    get stacked diagnostics st = returned_sqlstate, con = constraint_name, msg = message_text;
    perform jobs.fail(st, con, msg);
end $$;

create or replace function jobs.delete_round(round_id int) returns void
language sql security definer
set search_path = pg_catalog, jobs
as $$ delete from jobs.rounds where id = round_id $$;

-- The API role can use these functions and nothing else here.
grant usage on schema jobs to home_web;
revoke all on all functions in schema jobs from public;
grant execute on function jobs.state(), jobs.put_profile(jsonb), jobs.create_application(jsonb),
  jobs.update_application(int, jsonb), jobs.delete_application(int), jobs.create_round(int, jsonb),
  jobs.update_round(int, jsonb), jobs.delete_round(int) to home_web;
