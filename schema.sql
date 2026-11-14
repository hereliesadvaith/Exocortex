-- Todos: schema "todos". Safe to run again; install.sh applies it.
--
-- todos.lists  optional lists to group tasks (Work, Home, ...). Tasks without a list
--              are in the Inbox. Deleting a list moves its tasks to the Inbox.
-- todos.tasks  one row per task. done_at is set when it's ticked off. A task with
--              `repeat` needs a due date; ticking it off creates the next one
--              (next_id points at it, so undoing can take it back).
-- todos.open   view: open tasks with how they stand today; handy from the MCP server.
--
-- Dates are days in the database time zone, so CURRENT_DATE decides what "today"
-- and "overdue" mean.
--
-- The page calls the functions at the end through PostgREST (/api/rpc/<fn> with
-- the "todos" profile). They're SECURITY DEFINER: the API role (home_web) can call
-- them and nothing else in this schema.

create schema if not exists todos;

create table if not exists todos.lists (
    id integer generated always as identity primary key,
    name text not null unique check (length(name) between 1 and 60),
    created_at timestamptz not null default now()
);

create table if not exists todos.tasks (
    id integer generated always as identity primary key,
    title text not null check (length(title) between 1 and 300),
    notes text check (length(notes) <= 5000),
    list_id integer references todos.lists(id) on delete set null,
    due_on date,
    priority smallint not null default 0 check (priority between 0 and 3),  -- 0 none, 1 low, 2 medium, 3 high
    repeat text check (repeat in ('daily', 'weekly', 'monthly', 'yearly')),
    done_at timestamptz,
    next_id integer references todos.tasks(id) on delete set null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint tasks_repeat_needs_due check (repeat is null or due_on is not null)
);
create index if not exists tasks_open_idx on todos.tasks (due_on) where done_at is null;
create index if not exists tasks_done_idx on todos.tasks (done_at) where done_at is not null;

-- updated_at on every update (Termux's Postgres has no moddatetime).
create or replace function todos.touch() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists tasks_mtime on todos.tasks;
create trigger tasks_mtime before update on todos.tasks for each row execute function todos.touch();

create or replace view todos.open as
select t.id, t.title, t.notes, l.name as list, t.due_on, t.priority, t.repeat,
       t.due_on < current_date as overdue,
       t.due_on = current_date as due_today,
       t.created_at
from todos.tasks t
left join todos.lists l on l.id = t.list_id
where t.done_at is null
order by t.due_on nulls last, t.priority desc, t.created_at;

-- ---- API ----------------------------------------------------------------------
-- Errors use SQLSTATEs PostgREST maps to HTTP: 23505 -> 409, PT404 -> 404,
-- 22023 -> 400; the page shows the message.

create or replace function todos.task_json(t todos.tasks) returns jsonb
language sql stable
as $$
  select jsonb_build_object('id', t.id, 'title', t.title, 'notes', t.notes, 'list_id', t.list_id,
                            'due_on', t.due_on, 'priority', t.priority, 'repeat', t.repeat,
                            'done_at', t.done_at, 'done_on', t.done_at::date, 'created_at', t.created_at)
$$;

-- Turn constraint errors into messages the page can show.
create or replace function todos.fail(err_state text, err_constraint text, err_message text) returns void
language plpgsql
as $$
begin
  if err_state = '23505' then
    raise exception 'A list with that name already exists' using errcode = '23505';
  elsif err_constraint = 'tasks_repeat_needs_due' then
    raise exception 'A repeating task needs a due date' using errcode = '22023';
  elsif err_state = '23503' then
    raise exception 'No such list' using errcode = 'PT404';
  elsif err_state in ('23514', '23502', '22P02', '22007', '22008') then
    raise exception 'Invalid value (%)', coalesce(nullif(err_constraint, ''), err_message) using errcode = '22023';
  end if;
  raise exception '%', err_message using errcode = err_state;
end $$;

-- Lists, every open task, and tasks completed in the last `done_days` days.
create or replace function todos.state(done_days int default 30) returns jsonb
language sql stable security definer
set search_path = pg_catalog, todos
as $$
  select jsonb_build_object(
    'today', current_date,
    'lists', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name) order by lower(l.name), l.id)
                       from todos.lists l), '[]'::jsonb),
    'tasks', coalesce((
      select jsonb_agg(todos.task_json(x.t) order by x.n)
      from (select t, row_number() over (order by t.done_at desc nulls first, t.due_on nulls last,
                                                  t.priority desc, t.created_at, t.id) as n
            from todos.tasks t
            where t.done_at is null
               or t.done_at > now() - make_interval(days => greatest(1, least(coalesce(done_days, 30), 366)))
            order by n
            limit 2000) x), '[]'::jsonb))
$$;

create or replace function todos.create_task(title text, notes text default null, list_id int default null,
                                             due_on date default null, priority int default 0,
                                             repeat text default null) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, todos
as $$
declare
  rec todos.tasks;
  st text; con text; msg text;
begin
  if btrim(coalesce(title, '')) = '' then
    raise exception 'The task needs a title' using errcode = '22023';
  end if;
  insert into todos.tasks (title, notes, list_id, due_on, priority, repeat)
  values (btrim(create_task.title), nullif(btrim(coalesce(create_task.notes, '')), ''), create_task.list_id,
          create_task.due_on, coalesce(create_task.priority, 0), nullif(create_task.repeat, ''))
  returning * into rec;
  return todos.task_json(rec);
exception when others then
  get stacked diagnostics st = returned_sqlstate, con = constraint_name, msg = message_text;
  perform todos.fail(st, con, msg);
end $$;

-- patch: any of title, notes, list_id, due_on, priority, repeat (null clears), and
-- done: true ticks it off (a repeating task then comes back on its next due date),
-- false undoes that (taking back the repeat it created, if that one is still open).
create or replace function todos.update_task(task_id int, patch jsonb) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, todos
as $$
declare
  old todos.tasks;
  rec todos.tasks;
  step interval;
  next_due date;
  new_id int;
  st text; con text; msg text;
begin
  select * into old from todos.tasks where id = update_task.task_id for update;
  if not found then
    raise exception 'No such task' using errcode = 'PT404';
  end if;
  if patch ? 'title' and btrim(coalesce(patch->>'title', '')) = '' then
    raise exception 'Title can''t be empty' using errcode = '22023';
  end if;

  update todos.tasks t set
    title    = case when patch ? 'title' then btrim(patch->>'title') else t.title end,
    notes    = case when patch ? 'notes' then nullif(btrim(coalesce(patch->>'notes', '')), '') else t.notes end,
    list_id  = case when patch ? 'list_id' then (patch->>'list_id')::int else t.list_id end,
    due_on   = case when patch ? 'due_on' then (patch->>'due_on')::date else t.due_on end,
    priority = case when patch ? 'priority' then coalesce((patch->>'priority')::smallint, 0) else t.priority end,
    repeat   = case when patch ? 'repeat' then nullif(patch->>'repeat', '') else t.repeat end
  where t.id = old.id
  returning * into rec;

  if (patch->>'done')::boolean is true and old.done_at is null then
    update todos.tasks set done_at = now() where id = old.id returning * into rec;
    if rec.repeat is not null then
      -- The next due date after today, stepping from the old due date so it stays
      -- on the same weekday / day of the month.
      step := case rec.repeat when 'daily' then interval '1 day' when 'weekly' then interval '7 days'
                              when 'monthly' then interval '1 month' else interval '1 year' end;
      select min(d)::date into next_due
      from generate_series(rec.due_on + step, greatest(rec.due_on, current_date) + step, step) d
      where d > current_date;
      insert into todos.tasks (title, notes, list_id, due_on, priority, repeat)
      values (rec.title, rec.notes, rec.list_id, next_due, rec.priority, rec.repeat)
      returning id into new_id;
      update todos.tasks set next_id = new_id where id = old.id returning * into rec;
    end if;
  elsif (patch->>'done')::boolean is false and old.done_at is not null then
    if old.next_id is not null then
      delete from todos.tasks where id = old.next_id and done_at is null;
    end if;
    update todos.tasks set done_at = null, next_id = null where id = old.id returning * into rec;
  end if;
  return todos.task_json(rec);
exception
  when sqlstate 'PT404' or sqlstate '22023' then raise;
  when others then
    get stacked diagnostics st = returned_sqlstate, con = constraint_name, msg = message_text;
    perform todos.fail(st, con, msg);
end $$;

create or replace function todos.delete_task(task_id int) returns void
language sql security definer
set search_path = pg_catalog, todos
as $$ delete from todos.tasks where id = delete_task.task_id $$;

-- Delete every completed task.
create or replace function todos.clear_done() returns void
language sql security definer
set search_path = pg_catalog, todos
as $$ delete from todos.tasks where done_at is not null $$;

create or replace function todos.create_list(name text) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, todos
as $$
declare
  result jsonb;
  st text; con text; msg text;
begin
  if btrim(coalesce(name, '')) = '' then
    raise exception 'Name can''t be empty' using errcode = '22023';
  end if;
  insert into todos.lists (name) values (btrim(create_list.name))
  returning jsonb_build_object('id', lists.id, 'name', lists.name) into result;
  return result;
exception
  when sqlstate '22023' then raise;
  when others then
    get stacked diagnostics st = returned_sqlstate, con = constraint_name, msg = message_text;
    perform todos.fail(st, con, msg);
end $$;

create or replace function todos.rename_list(list_id int, name text) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, todos
as $$
declare
  result jsonb;
  st text; con text; msg text;
begin
  if btrim(coalesce(name, '')) = '' then
    raise exception 'Name can''t be empty' using errcode = '22023';
  end if;
  update todos.lists l set name = btrim(rename_list.name) where l.id = rename_list.list_id
  returning jsonb_build_object('id', l.id, 'name', l.name) into result;
  if result is null then
    raise exception 'No such list' using errcode = 'PT404';
  end if;
  return result;
exception
  when sqlstate 'PT404' or sqlstate '22023' then raise;
  when others then
    get stacked diagnostics st = returned_sqlstate, con = constraint_name, msg = message_text;
    perform todos.fail(st, con, msg);
end $$;

-- Delete a list. Its tasks move to the Inbox.
create or replace function todos.delete_list(list_id int) returns void
language sql security definer
set search_path = pg_catalog, todos
as $$ delete from todos.lists where id = delete_list.list_id $$;

-- The API role can use these functions and nothing else here.
grant usage on schema todos to home_web;
revoke all on all functions in schema todos from public;
grant execute on function todos.state(int), todos.create_task(text, text, int, date, int, text),
  todos.update_task(int, jsonb), todos.delete_task(int), todos.clear_done(),
  todos.create_list(text), todos.rename_list(int, text), todos.delete_list(int) to home_web;
