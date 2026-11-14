# PL/Python for Termux PostgreSQL

Termux's `postgresql` package is built without PL/Python. This branch builds the two extensions it leaves out and installs them into Termux's Postgres:

| Extension | What it adds |
|---|---|
| `plpython3u` | Functions, procedures, triggers and `DO` blocks written in Python |
| `jsonb_plpython3u` | Passes `jsonb` to and from Python as dicts and lists (`transform for type jsonb`) |

They're compiled against the installed Postgres's own headers and `pg_config.h` (through PGXS), not a separately configured source tree, so the result matches the running server. The Python is Termux's `python`, the same one everything else on the phone uses.

## Build and install

```sh
pkg install -y postgresql python perl clang make
git clone -b plpython https://github.com/hereliesadvaith/exocortex.git ~/plpython
cd ~/plpython
./build.sh
```

`build.sh`:

1. Downloads the PostgreSQL source for the installed version (`pg_config --version`) to `~/src` and checks its SHA-256.
2. Builds `plpython3u` with `plpython.mk` (a PGXS makefile; the upstream one only works inside a configured source tree) and `jsonb_plpython3u` with its own PGXS support.
3. Installs both into `$PREFIX/lib/postgresql` and `$PREFIX/share/postgresql/extension`.
4. Holds the `postgresql` package (`apt-mark hold`) so `pkg upgrade` can't swap the server for a version these weren't built for. Pass `--no-hold` to skip that.
5. If Postgres is running, runs `test.sql`: Python functions, jsonb round trip, `plpy.execute`, reading `/proc`, and error handling, all in a transaction that's rolled back.

It takes about a minute. Then enable the extensions in each database that uses them:

```sql
create extension plpython3u;
create extension jsonb_plpython3u;
```

## Upgrading

The extensions are tied to the Postgres and Python they were built with.

**Postgres** (held, so it only changes when you choose to):

```sh
apt-mark unhold postgresql
pkg upgrade postgresql
cd ~/plpython && git pull && ./build.sh      # rebuilds for the new version and holds it again
pg_ctl -D $PREFIX/var/lib/postgresql restart
```

A new major version (19) also needs the usual `pg_upgrade` or dump and restore of the data directory; rebuild before starting the new server.

**Python**: a new minor version (3.14 → 3.15) removes the `libpython3.14.so` that `plpython3.so` links to, and every Python function then fails to load. Rerun `./build.sh` after `pkg upgrade` installs a new Python, then restart Postgres.

## Notes

- `plpython3u` is "untrusted": its functions run with the full rights of the Termux user (files, network, processes). Only superusers can create them, which is how it should stay.
- Python packages installed with `pip` into Termux's system Python (not a venv) can be imported from database functions.
- Removing it: `drop extension jsonb_plpython3u; drop extension plpython3u;` in each database, then delete `plpython3.so` and `jsonb_plpython3.so` from `$PREFIX/lib/postgresql` and the `*plpython3u*` files from `$PREFIX/share/postgresql/extension`.
