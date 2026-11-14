-- Habits: schema "habits". Safe to run again; install.sh applies it.
--
-- habits.habits  one row per habit. kind: check (done or not), count, or minutes;
--                count/minutes need a daily target. times_per_week < 7 makes the
--                streak count weeks in which the habit was met that many days.
-- habits.logs    at most one row per habit per day; a day counts as met when
--                value >= target (1 for check habits).
-- habits.status  per active habit: done today, done this week, current streak, best
--                daily streak, last logged day. Uses CURRENT_DATE, so the database
--                time zone decides where a day ends.
--
-- The page calls the functions at the end through PostgREST (/api/rpc/<fn> with
-- the "habits" profile). They're SECURITY DEFINER: the API role (home_web) can
-- call them and nothing else in this schema.

create schema if not exists habits;

create table if not exists habits.habits (
    id integer generated always as identity primary key,
    name text not null unique,
    kind text not null default 'check' check (kind in ('check', 'count', 'minutes')),
    target numeric check (target > 0),
    times_per_week smallint not null default 7 check (times_per_week between 1 and 7),
    active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint habits_check check (kind = 'check' or target is not null)
);

create table if not exists habits.logs (
    id integer generated always as identity primary key,
    habit_id integer not null references habits.habits(id) on delete cascade,
    logged_on date not null default current_date,
    value numeric not null default 1 check (value > 0),
    note text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (habit_id, logged_on)
);

-- updated_at on every update (Termux's Postgres has no moddatetime).
create or replace function habits.touch() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists habits_mtime on habits.habits;
create trigger habits_mtime before update on habits.habits for each row execute function habits.touch();
drop trigger if exists logs_mtime on habits.logs;
create trigger logs_mtime before update on habits.logs for each row execute function habits.touch();

create or replace view habits.status as
with met as (
    select l.habit_id, l.logged_on as d
    from habits.logs l join habits.habits h on h.id = l.habit_id
    where l.value >= coalesce(h.target, 1)
), day_islands as (
    select habit_id, max(d) as last_d, count(*) as n
    from (select habit_id, d, d - (row_number() over (partition by habit_id order by d))::int as grp from met) x
    group by habit_id, grp
), weeks as (
    select m.habit_id, date_trunc('week', m.d)::date as wk
    from met m join habits.habits h on h.id = m.habit_id
    group by m.habit_id, date_trunc('week', m.d), h.times_per_week
    having count(*) >= h.times_per_week
), week_islands as (
    select habit_id, max(wk) as last_wk, count(*) as n
    from (select habit_id, wk, wk - 7 * (row_number() over (partition by habit_id order by wk))::int as grp from weeks) x
    group by habit_id, grp
)
select h.id, h.name, h.kind, h.target, h.times_per_week,
       exists (select 1 from met where met.habit_id = h.id and met.d = current_date) as done_today,
       (select count(*) from met where met.habit_id = h.id and met.d >= date_trunc('week', current_date)::date) as done_this_week,
       case when h.times_per_week = 7
            then coalesce((select di.n from day_islands di where di.habit_id = h.id and di.last_d >= current_date - 1), 0)
            else coalesce((select wi.n from week_islands wi
                           where wi.habit_id = h.id and wi.last_wk >= date_trunc('week', current_date)::date - 7), 0)
       end as current_streak,
       case when h.times_per_week = 7 then 'days' else 'weeks' end as streak_unit,
       coalesce((select max(di.n) from day_islands di where di.habit_id = h.id), 0) as best_day_streak,
       (select max(l.logged_on) from habits.logs l where l.habit_id = h.id) as last_logged
from habits.habits h
where h.active;

-- ---- API ------------------------------------------------------------------------
-- Errors use SQLSTATEs PostgREST maps to HTTP: 23505 -> 409, P0002 -> 404,
-- 22023 -> 400; the page shows the message.

-- Every habit (active first) with its status, plus the logs of the last `days` days.
create or replace function habits.state(days int default 84) returns jsonb
language sql stable security definer
set search_path = pg_catalog, habits
as $$
  select jsonb_build_object(
    'today', current_date,
    'habits', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', h.id, 'name', h.name, 'kind', h.kind, 'target', h.target,
               'times_per_week', h.times_per_week, 'active', h.active,
               'created_on', h.created_at::date,
               'done_today', coalesce(s.done_today, false),
               'done_this_week', coalesce(s.done_this_week, 0),
               'current_streak', coalesce(s.current_streak, 0),
               'streak_unit', coalesce(s.streak_unit, case when h.times_per_week = 7 then 'days' else 'weeks' end),
               'best_day_streak', coalesce(s.best_day_streak, 0),
               'last_logged', s.last_logged)
             order by h.active desc, h.created_at, h.id)
      from habits.habits h left join habits.status s on s.id = h.id), '[]'::jsonb),
    'logs', coalesce((
      select jsonb_agg(jsonb_build_object('habit_id', l.habit_id, 'logged_on', l.logged_on,
                                          'value', l.value, 'note', l.note) order by l.logged_on)
      from habits.logs l
      where l.logged_on > current_date - greatest(7, least(coalesce(days, 84), 371))), '[]'::jsonb))
$$;

create or replace function habits.create_habit(name text, kind text default 'check', target numeric default null,
                                               times_per_week int default 7) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, habits
as $$
declare
  new_id int;
begin
  name := btrim(coalesce(name, ''));
  if name = '' or length(name) > 80 then
    raise exception 'Give the habit a name (up to 80 characters)' using errcode = '22023';
  end if;
  if kind = 'check' then
    target := null;
  elsif target is null then
    raise exception 'Count and minutes habits need a target' using errcode = '22023';
  end if;
  insert into habits.habits (name, kind, target, times_per_week)
  values (create_habit.name, create_habit.kind, create_habit.target, create_habit.times_per_week)
  returning id into new_id;
  return jsonb_build_object('id', new_id);
exception
  when unique_violation then
    raise exception 'A habit with that name already exists' using errcode = '23505';
  when check_violation then
    raise exception 'Invalid value (%)', coalesce(nullif(sqlerrm, ''), 'constraint') using errcode = '22023';
end $$;

-- patch: any of name, kind, target, times_per_week, active.
create or replace function habits.update_habit(habit_id int, patch jsonb) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, habits
as $$
declare
  found_id int;
begin
  if patch ? 'name' and (btrim(coalesce(patch->>'name', '')) = '' or length(btrim(patch->>'name')) > 80) then
    raise exception 'Give the habit a name (up to 80 characters)' using errcode = '22023';
  end if;
  update habits.habits h set
    name = case when patch ? 'name' then btrim(patch->>'name') else h.name end,
    kind = coalesce(patch->>'kind', h.kind),
    target = case when coalesce(patch->>'kind', h.kind) = 'check' then null
                  when patch ? 'target' then (patch->>'target')::numeric
                  else h.target end,
    times_per_week = case when patch ? 'times_per_week' then (patch->>'times_per_week')::smallint else h.times_per_week end,
    active = case when patch ? 'active' then (patch->>'active')::boolean else h.active end
  where h.id = update_habit.habit_id
  returning h.id into found_id;
  if found_id is null then
    raise exception 'No such habit' using errcode = 'P0002';
  end if;
  return jsonb_build_object('id', found_id);
exception
  when unique_violation then
    raise exception 'A habit with that name already exists' using errcode = '23505';
  when check_violation then
    raise exception 'Count and minutes habits need a target' using errcode = '22023';
end $$;

create or replace function habits.delete_habit(habit_id int) returns void
language sql security definer
set search_path = pg_catalog, habits
as $$ delete from habits.habits where id = delete_habit.habit_id $$;

-- One value per habit per day; saving again replaces it.
create or replace function habits.set_log(habit_id int, day date, value numeric, note text default null) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, habits
as $$
declare
  result jsonb;
begin
  if value is null or value <= 0 then
    raise exception 'The value must be above 0 (use delete_log to clear a day)' using errcode = '22023';
  end if;
  note := nullif(btrim(coalesce(note, '')), '');
  if length(note) > 500 then
    raise exception 'Notes can be up to 500 characters' using errcode = '22023';
  end if;
  insert into habits.logs (habit_id, logged_on, value, note)
  values (set_log.habit_id, set_log.day, set_log.value, set_log.note)
  on conflict on constraint logs_habit_id_logged_on_key do update set value = excluded.value, note = excluded.note
  returning jsonb_build_object('habit_id', logs.habit_id, 'logged_on', logs.logged_on, 'value', logs.value, 'note', logs.note)
  into result;
  return result;
exception
  when foreign_key_violation then
    raise exception 'No such habit' using errcode = 'P0002';
end $$;

create or replace function habits.delete_log(habit_id int, day date) returns void
language sql security definer
set search_path = pg_catalog, habits
as $$ delete from habits.logs where habit_id = delete_log.habit_id and logged_on = delete_log.day $$;

-- The API role can use these functions and nothing else here.
grant usage on schema habits to home_web;
revoke all on all functions in schema habits from public;
grant execute on function habits.state(int), habits.create_habit(text, text, numeric, int),
  habits.update_habit(int, jsonb), habits.delete_habit(int), habits.set_log(int, date, numeric, text),
  habits.delete_log(int, date) to home_web;
