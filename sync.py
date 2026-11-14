#!/usr/bin/env python3
"""Fill in TV Time's titles from IMDb.

  python sync.py --posters    poster links for titles that have none yet, from IMDb's
                              search suggestions (one small request per title)
  python sync.py --datasets   genres, runtime, years and aired-episode totals from
                              IMDb's datasets (https://datasets.imdbws.com/; about
                              250 MB to download, streamed: only your titles are kept)
  python sync.py              both

Standard library only; it talks to Postgres through psql (as the postgres user, over
the local socket). Safe to run again. IMDb's datasets are for personal and
non-commercial use.
"""
import csv
import datetime
import gzip
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

DATASETS = "https://datasets.imdbws.com/"
SUGGEST = "https://v3.sg.media-imdb.com/suggestion/x/{}.json"
UA = {"User-Agent": "Mozilla/5.0 (exocortex tvtime sync)"}


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def psql(sql, *args):
    out = subprocess.run(["psql", "-U", "postgres", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", *args, "-c", sql],
                         capture_output=True, text=True)
    if out.returncode:
        raise SystemExit(f"psql failed: {out.stderr.strip()}")
    return [line.split("\t") for line in out.stdout.splitlines() if line]


def load_tsv(rows, table, columns):
    """Write rows to a temp TSV and \\copy them into a tvtime staging table."""
    with tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False, encoding="utf-8") as f:
        for r in rows:
            f.write("\t".join("\\N" if v is None else str(v).replace("\t", " ").replace("\n", " ") for v in r) + "\n")
        path = f.name
    try:
        psql(f"\\copy {table} ({', '.join(columns)}) from '{path}'")
    finally:
        os.unlink(path)


# ---- posters ------------------------------------------------------------------------

def posters():
    todo = psql("select 'movies', imdb_id from tvtime.movies where poster_url is null and imdb_id is not null "
                "union all select 'series', imdb_id from tvtime.series where poster_url is null and imdb_id is not null")
    log(f"posters: {len(todo)} titles without one")
    found = []
    for n, (table, imdb_id) in enumerate(todo, 1):
        url = None
        try:
            req = urllib.request.Request(SUGGEST.format(imdb_id), headers=UA)
            with urllib.request.urlopen(req, timeout=15) as r:
                for x in json.load(r).get("d", []):
                    if x.get("id") == imdb_id:
                        url = (x.get("i") or {}).get("imageUrl")
                        break
        except Exception as e:
            log(f"  {imdb_id}: {type(e).__name__}")
        if url:
            found.append((table, imdb_id, url))
        if n % 50 == 0:
            log(f"  {n}/{len(todo)}, {len(found)} found")
        time.sleep(0.25)   # be gentle: this is IMDb's search box endpoint
    psql("create table if not exists tvtime.sync_posters (kind text, imdb_id text, url text); truncate tvtime.sync_posters")
    load_tsv(found, "tvtime.sync_posters", ["kind", "imdb_id", "url"])
    psql("""
        update tvtime.movies m set poster_url = p.url from tvtime.sync_posters p where p.kind = 'movies' and p.imdb_id = m.imdb_id;
        update tvtime.series s set poster_url = p.url from tvtime.sync_posters p where p.kind = 'series' and p.imdb_id = s.imdb_id;
        drop table tvtime.sync_posters;
    """)
    log(f"posters: {len(found)} of {len(todo)} saved")


# ---- datasets -----------------------------------------------------------------------

def stream_tsv(name):
    """Rows of one of IMDb's gzipped TSVs, read as it downloads."""
    req = urllib.request.Request(DATASETS + name, headers=UA)
    resp = urllib.request.urlopen(req, timeout=60)
    total = int(resp.headers.get("Content-Length") or 0)
    text = io.TextIOWrapper(gzip.GzipFile(fileobj=resp), encoding="utf-8", newline="")
    header = text.readline().rstrip("\n").split("\t")
    log(f"{name}: {total / 1e6:.0f} MB")
    for n, line in enumerate(text):
        if n and n % 2_000_000 == 0:
            log(f"  {name}: {n / 1e6:.0f}M rows")
        yield dict(zip(header, line.rstrip("\n").split("\t")))


def num(v):
    return None if v in ("\\N", "", None) else int(v)


def datasets():
    ours = {imdb_id: kind for kind, imdb_id in psql(
        "select 'movie', imdb_id from tvtime.movies where imdb_id is not null "
        "union all select 'series', imdb_id from tvtime.series where imdb_id is not null")}
    series_ids = {i for i, k in ours.items() if k == "series"}
    log(f"datasets: {len(ours)} titles ({len(series_ids)} series)")

    # 1. Every episode of our series.
    episode_parent = {}
    for r in stream_tsv("title.episode.tsv.gz"):
        if r["parentTconst"] in series_ids:
            episode_parent[r["tconst"]] = r["parentTconst"]
    log(f"  {len(episode_parent)} episodes of your series")

    # 2. Our titles' genres, runtime and years; our episodes' years.
    this_year = datetime.date.today().year
    titles, aired = [], {}
    for r in stream_tsv("title.basics.tsv.gz"):
        t = r["tconst"]
        if t in ours:
            titles.append((t, num(r["startYear"]), num(r["endYear"]), num(r["runtimeMinutes"]),
                           "" if r["genres"] == "\\N" else r["genres"]))
        elif t in episode_parent:
            year = num(r["startYear"])
            # Aired: has a year, and it isn't in the future. (IMDb lists announced
            # episodes without one.)
            if year is not None and year <= this_year:
                p = episode_parent[t]
                aired[p] = aired.get(p, 0) + 1
    log(f"  found {len(titles)} of your {len(ours)} titles")

    psql("""
        create table if not exists tvtime.sync_titles (imdb_id text, start_year int, end_year int, runtime int, genres text);
        create table if not exists tvtime.sync_episodes (imdb_id text, aired int);
        truncate tvtime.sync_titles, tvtime.sync_episodes;
    """)
    load_tsv(titles, "tvtime.sync_titles", ["imdb_id", "start_year", "end_year", "runtime", "genres"])
    load_tsv(aired.items(), "tvtime.sync_episodes", ["imdb_id", "aired"])
    stats = psql("""
        insert into tvtime.genres (name)
          select distinct g from tvtime.sync_titles, unnest(string_to_array(nullif(genres, ''), ',')) g
          on conflict (name) do nothing;

        update tvtime.movies m set runtime_min = t.runtime, year = coalesce(m.year, t.start_year), imdb_synced_at = now()
          from tvtime.sync_titles t where t.imdb_id = m.imdb_id;
        delete from tvtime.movie_genres mg using tvtime.movies m, tvtime.sync_titles t
          where mg.movie_id = m.id and m.imdb_id = t.imdb_id;
        insert into tvtime.movie_genres (movie_id, genre_id)
          select m.id, g.id from tvtime.sync_titles t join tvtime.movies m on m.imdb_id = t.imdb_id,
               unnest(string_to_array(nullif(t.genres, ''), ',')) gn join tvtime.genres g on g.name = gn
          on conflict do nothing;

        update tvtime.series s set runtime_min = t.runtime, end_year = t.end_year,
               year = coalesce(s.year, t.start_year), imdb_synced_at = now(),
               total_episodes = coalesce(e.aired, s.total_episodes)
          from tvtime.sync_titles t left join tvtime.sync_episodes e on e.imdb_id = t.imdb_id
          where t.imdb_id = s.imdb_id;
        delete from tvtime.series_genres sg using tvtime.series s, tvtime.sync_titles t
          where sg.series_id = s.id and s.imdb_id = t.imdb_id;
        insert into tvtime.series_genres (series_id, genre_id)
          select s.id, g.id from tvtime.sync_titles t join tvtime.series s on s.imdb_id = t.imdb_id,
               unnest(string_to_array(nullif(t.genres, ''), ',')) gn join tvtime.genres g on g.name = gn
          on conflict do nothing;

        drop table tvtime.sync_titles, tvtime.sync_episodes;
        select (select count(*) from tvtime.movies where imdb_synced_at > now() - interval '1 hour'),
               (select count(*) from tvtime.series where imdb_synced_at > now() - interval '1 hour'),
               (select count(*) from tvtime.series where status = 'up_to_date' and total_episodes > episodes_watched);
    """)
    m, s, behind = stats[-1]
    log(f"datasets: updated {m} movies and {s} series; {behind} up-to-date series have new episodes")


if __name__ == "__main__":
    args = set(sys.argv[1:]) or {"--posters", "--datasets"}
    if args - {"--posters", "--datasets"}:
        raise SystemExit(__doc__)
    if "--posters" in args:
        posters()
    if "--datasets" in args:
        datasets()
