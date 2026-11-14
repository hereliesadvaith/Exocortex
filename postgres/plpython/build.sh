#!/usr/bin/env bash
# Build and install PL/Python (plpython3u) and its jsonb transform (jsonb_plpython3u)
# for Termux's PostgreSQL, which ships without them.
#
#   ./build.sh            build, install, test (the test rolls back; nothing is created)
#   ./build.sh --no-hold  same, but don't apt-mark hold the postgresql package
#
# Rerun after upgrading postgresql or python. Everything is built against the
# installed Postgres (pg_config / PGXS), so the result matches the running server.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

HOLD=1
[[ ${1:-} == --no-hold ]] && HOLD=0

[[ -n ${PREFIX:-} && -d $PREFIX ]] || { echo "run this in Termux (PREFIX isn't set)" >&2; exit 1; }
for cmd in pg_config python3 python3-config perl clang make curl sha256sum; do
  command -v $cmd >/dev/null || { echo "missing $cmd: pkg install postgresql python perl clang make curl" >&2; exit 1; }
done

PGVER=$(pg_config --version | awk '{print $2}')
PYVER=$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')
PY_INCLUDES=$(python3-config --includes)
PY_LIBS=$(python3-config --ldflags --embed)
WORK=${WORK:-$HOME/src}
SRC=$WORK/postgresql-$PGVER
TARBALL=postgresql-$PGVER.tar.bz2
URL=https://ftp.postgresql.org/pub/source/v$PGVER/$TARBALL

echo "PostgreSQL $PGVER, Python $PYVER"

# ---- source -----------------------------------------------------------------
mkdir -p "$WORK"
cd "$WORK"
if [[ ! -f $TARBALL ]]; then
  echo "downloading $URL"
  curl -fSL --retry 5 -o "$TARBALL.part" "$URL"
  mv "$TARBALL.part" "$TARBALL"
fi
curl -fsSL --retry 5 -o "$TARBALL.sha256" "$URL.sha256"
expected=$(awk '{print $1}' "$TARBALL.sha256")
actual=$(sha256sum "$TARBALL" | awk '{print $1}')
if [[ $expected != "$actual" ]]; then
  echo "checksum mismatch for $TARBALL (expected $expected, got $actual)" >&2
  rm -f "$TARBALL"
  exit 1
fi
rm -rf "$SRC"
tar xjf "$TARBALL" \
  "postgresql-$PGVER/src/pl/plpython" \
  "postgresql-$PGVER/contrib/jsonb_plpython" \
  "postgresql-$PGVER/src/backend/utils/errcodes.txt"

# Termux's pg_config names its cross-compiler (aarch64-linux-android-clang); on the
# phone it's just clang.
MAKEVARS=(CC=clang "PY_INCLUDES=$PY_INCLUDES" "PY_LIBS=$PY_LIBS")

# ---- plpython3u ---------------------------------------------------------------
cd "$SRC/src/pl/plpython"
perl generate-spiexceptions.pl ../../backend/utils/errcodes.txt > spiexceptions.h
cp "$HERE/plpython.mk" Makefile.pgxs
make -f Makefile.pgxs -j"$(nproc)" "${MAKEVARS[@]}"
make -f Makefile.pgxs install "${MAKEVARS[@]}"

# ---- jsonb_plpython3u ---------------------------------------------------------
cd "$SRC/contrib/jsonb_plpython"
JSONB_VARS=(
  USE_PGXS=1 CC=clang python_majorversion=3
  "PG_CPPFLAGS=-I../../src/pl/plpython $PY_INCLUDES -DPLPYTHON_LIBNAME='\"plpython3\"'"
  "SHLIB_LINK=$PY_LIBS"
)
make -j"$(nproc)" "${JSONB_VARS[@]}"
make install "${JSONB_VARS[@]}"

echo "installed into $(pg_config --pkglibdir) and $(pg_config --sharedir)/extension"

# ---- keep pkg upgrade from breaking it -----------------------------------------
if [[ $HOLD == 1 ]]; then
  apt-mark hold postgresql >/dev/null && echo "postgresql package held (apt-mark unhold postgresql to allow upgrades)"
fi

# ---- test ---------------------------------------------------------------------
if pg_ctl -D "$PREFIX/var/lib/postgresql" status >/dev/null 2>&1; then
  echo "testing (in a transaction that is rolled back)..."
  psql -U postgres -v ON_ERROR_STOP=1 -X -q -f "$HERE/test.sql"
else
  echo "postgres isn't running; skipped the test (run: psql -U postgres -f $HERE/test.sql)"
fi
