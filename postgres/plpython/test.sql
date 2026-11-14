-- Smoke test for plpython3u and jsonb_plpython3u. Runs in a transaction that is
-- rolled back, so it leaves nothing behind.
\pset footer off
begin;

create extension plpython3u;
create extension jsonb_plpython3u;

-- Plain Python, with the version it runs on.
create function pg_temp.py_info() returns text language plpython3u as $$
import sys
return f"python {sys.version.split()[0]} on {sys.platform}"
$$;

-- jsonb in and out, as Python dicts and lists.
create function pg_temp.py_jsonb(j jsonb) returns jsonb
language plpython3u transform for type jsonb as $$
j["count"] = len(j["items"])
j["upper"] = [s.upper() for s in j["items"]]
return j
$$;

-- Queries from Python (plpy.execute).
create function pg_temp.py_spi() returns int language plpython3u as $$
return plpy.execute("select 40 + 2 as n")[0]["n"]
$$;

-- Reading the system: what a status page needs.
create function pg_temp.py_system() returns text language plpython3u as $$
import os
with open("/proc/meminfo") as f:
    mem = f.readline().split()[1]
return f"MemTotal {int(mem) // 1024} MB, home {os.path.expanduser('~')}, pid {os.getpid()}"
$$;

-- Errors raised in Python come back as Postgres errors.
create function pg_temp.py_error() returns text language plpython3u as $$
plpy.error("raised from python")
$$;

select pg_temp.py_info() as info;
select pg_temp.py_jsonb('{"items": ["a", "b"]}') as jsonb_round_trip;
select pg_temp.py_spi() as spi;
select pg_temp.py_system() as system;

savepoint before_error;
do $$
begin
  perform pg_temp.py_error();
exception when others then
  raise notice 'error passed through: %', sqlerrm;
end $$;

rollback;
\echo 'plpython test passed (rolled back)'
