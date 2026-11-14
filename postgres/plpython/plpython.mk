# PGXS makefile for PL/Python, so it builds against the installed Postgres (its
# headers and pg_config.h) instead of a configured source tree. build.sh copies this
# into src/pl/plpython and passes PY_INCLUDES / PY_LIBS from python3-config.

MODULE_big = plpython3
OBJS = \
	plpy_cursorobject.o \
	plpy_elog.o \
	plpy_exec.o \
	plpy_main.o \
	plpy_planobject.o \
	plpy_plpymodule.o \
	plpy_procedure.o \
	plpy_resultobject.o \
	plpy_spi.o \
	plpy_subxactobject.o \
	plpy_typeio.o \
	plpy_util.o
PGFILEDESC = "PL/Python - procedural language"

EXTENSION = plpython3u
DATA = plpython3u--1.0.sql

PG_CPPFLAGS = -I. $(PY_INCLUDES)
SHLIB_LINK = $(PY_LIBS)

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
