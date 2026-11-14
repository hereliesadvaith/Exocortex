# TV Time

Movies and series you watch, on the phone: new series you haven't started, what you're watching with a +1 per episode, what you're up to date on (and when new episodes are out), paused and finished series, every movie by the month you watched it, and a watchlist. Titles are IMDb titles: add them by searching IMDb by name, or with an IMDb link. It opens at **http://localhost/tvtime/**, and has a tile on the exocortex home page at http://localhost/.

```
phone browser ──► nginx (127.0.0.1:80) ─┬─ /tvtime/  ──► public/ (static page)
                                        └─ /api/     ──► PostgREST ──► Postgres, schema "tvtime"
                     posters ◄── IMDb's image server (m.media-amazon.com), by link
```

There's no server process of its own: the page is static, and its data and logic live in the `tvtime` schema, called through the PostgREST the home page already runs. The look comes from the home page's `/ui.css`.

## Install

Needs the exocortex core (the `main` branch) set up first: Postgres with PL/Python, nginx, PostgREST and the home page (`~/exocortex/home/install.sh`).

```sh
git clone -b tvtime https://github.com/hereliesadvaith/exocortex.git ~/apps/tvtime
~/apps/tvtime/install.sh
```

`install.sh` is safe to run again (also after a `git pull`): it applies `schema.sql`, serves `public/` at `/tvtime/` through `$PREFIX/etc/nginx/apps.d/tvtime.conf`, registers the tile in `home.apps` with `api_schema = 'tvtime'`, runs `~/exocortex/home/sync-api.sh`, and checks that the page and the API answer. `./install.sh remove` takes it off nginx and the home page; the data stays in schema `tvtime`.

## Data from IMDb

Two kinds, both without an API key:

| What | From | How |
|---|---|---|
| Poster links | IMDb's search suggestions (`v3.sg.media-imdb.com`), the endpoint IMDb's own search box uses | One small request per title, once; the link is saved and the page shows the image straight from IMDb's image server. Also how the + button searches IMDb. Not a documented API, so IMDb could change it. |
| Genres, runtime, years (running or ended), aired-episode totals | [IMDb's datasets](https://developer.imdb.com/non-commercial-datasets/) (`title.basics`, `title.episode`), free for personal, non-commercial use | Streamed, keeping only your titles: about 250 MB to download, best on Wi-Fi. |

```sh
cd ~/apps/tvtime
python sync.py --posters    # poster links for titles without one (new titles get theirs when added)
python sync.py --datasets   # genres, runtime, years, episode totals; run now and then for new episodes
```

An episode counts as aired when IMDb gives it a year that isn't in the future (announced episodes have none). After a datasets sync, an up-to-date series with more aired episodes than you've watched shows "N new".

## Data

| | |
|---|---|
| `tvtime.movies` | `imdb_id`, `title`, `year`, `status` (`watchlist` or `watched`), `watched_on`, `rewatch_count`, `runtime_min`, `poster_url` |
| `tvtime.series` | `imdb_id`, `title`, `year`, `end_year` (null while running), `status` (`watchlist`, `new`, `watching`, `up_to_date`, `paused`, `finished`), `episodes_watched`, `total_episodes`, `last_watched_on`, `runtime_min` (per episode), `poster_url` |
| `tvtime.genres`, `tvtime.movie_genres`, `tvtime.series_genres` | IMDb's genres and which titles have them |

## API

The page calls these through PostgREST at `/api/rpc/<function>` with the header `Accept-Profile: tvtime` (GET) or `Content-Profile: tvtime` (POST, JSON body). They're `SECURITY DEFINER`; the API role can call them and nothing else in the schema.

| Function | |
|---|---|
| `state()` (GET) | Every movie and series, with genres |
| `search(q)` (GET) | Up to 8 IMDb movies and series for a name, id or IMDb link, with poster links and whether each is already in your lists |
| `add_movie(imdb_id, title, year, poster_url, status = 'watched', watched_on)` | A watched movie without a date is watched today |
| `add_series(imdb_id, title, year, poster_url, status = 'watching', episodes_watched = 0)` | |
| `episode(series_id, delta = 1)` | One more (or fewer) episode. Reaching the total marks it finished (ended) or up to date (still running); watching again moves a new, paused, up-to-date or watchlist series to watching. |
| `rewatch(movie_id)` | One more rewatch |
| `update_movie(movie_id, patch)`, `update_series(series_id, patch)` | `patch`: the fields to change |
| `delete_movie(movie_id)`, `delete_series(series_id)` | |

```sh
curl -s -H 'Accept-Profile: tvtime' 'http://localhost/api/rpc/search?q=severance'
curl -s -X POST -H 'Content-Profile: tvtime' -H 'Content-Type: application/json' \
  -d '{"series_id": 12, "delta": 1}' http://localhost/api/rpc/episode
```
