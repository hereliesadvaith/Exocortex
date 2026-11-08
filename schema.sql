-- The `habits` schema the tracker reads and writes (schema-only dump from the phone).
-- The tables already exist; this file is for reference and for recreating them:
--   su postgres -c "psql -f schema.sql"
-- The app connects as the `habits` role (see README.md), which can use this schema only.
--
-- habits.habits  one row per habit. kind: check (done or not), count, or minutes;
--                count/minutes need a daily target. times_per_week < 7 makes the
--                streak count weeks in which the habit was met that many days.
-- habits.logs    at most one row per habit per day; a day counts as met when
--                value >= target (1 for check habits).
-- habits.status  per active habit: done today, done this week, current streak, best
--                daily streak, last logged day. Uses CURRENT_DATE, so the database
--                time zone (Asia/Kolkata) decides where a day ends.

CREATE EXTENSION IF NOT EXISTS moddatetime;

CREATE SCHEMA habits;

CREATE TABLE habits.habits (
    id integer NOT NULL,
    name text NOT NULL,
    kind text DEFAULT 'check'::text NOT NULL,
    target numeric,
    times_per_week smallint DEFAULT 7 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT habits_check CHECK (((kind = 'check'::text) OR (target IS NOT NULL))),
    CONSTRAINT habits_kind_check CHECK ((kind = ANY (ARRAY['check'::text, 'count'::text, 'minutes'::text]))),
    CONSTRAINT habits_target_check CHECK ((target > (0)::numeric)),
    CONSTRAINT habits_times_per_week_check CHECK (((times_per_week >= 1) AND (times_per_week <= 7)))
);

ALTER TABLE habits.habits ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME habits.habits_id_seq
);

CREATE TABLE habits.logs (
    id integer NOT NULL,
    habit_id integer NOT NULL,
    logged_on date DEFAULT CURRENT_DATE NOT NULL,
    value numeric DEFAULT 1 NOT NULL,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT logs_value_check CHECK ((value > (0)::numeric))
);

ALTER TABLE habits.logs ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME habits.logs_id_seq
);

ALTER TABLE ONLY habits.habits ADD CONSTRAINT habits_name_key UNIQUE (name);
ALTER TABLE ONLY habits.habits ADD CONSTRAINT habits_pkey PRIMARY KEY (id);
ALTER TABLE ONLY habits.logs ADD CONSTRAINT logs_habit_id_logged_on_key UNIQUE (habit_id, logged_on);
ALTER TABLE ONLY habits.logs ADD CONSTRAINT logs_pkey PRIMARY KEY (id);
ALTER TABLE ONLY habits.logs
    ADD CONSTRAINT logs_habit_id_fkey FOREIGN KEY (habit_id) REFERENCES habits.habits(id) ON DELETE CASCADE;

CREATE TRIGGER habits_mtime BEFORE UPDATE ON habits.habits FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');
CREATE TRIGGER logs_mtime BEFORE UPDATE ON habits.logs FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');

CREATE VIEW habits.status AS
 WITH met AS (
         SELECT l.habit_id,
            l.logged_on AS d
           FROM (habits.logs l
             JOIN habits.habits h_1 ON ((h_1.id = l.habit_id)))
          WHERE (l.value >= COALESCE(h_1.target, (1)::numeric))
        ), day_islands AS (
         SELECT x.habit_id,
            max(x.d) AS last_d,
            count(*) AS n
           FROM ( SELECT met.habit_id,
                    met.d,
                    (met.d - (row_number() OVER (PARTITION BY met.habit_id ORDER BY met.d))::integer) AS grp
                   FROM met) x
          GROUP BY x.habit_id, x.grp
        ), weeks AS (
         SELECT m.habit_id,
            (date_trunc('week'::text, (m.d)::timestamp with time zone))::date AS wk
           FROM (met m
             JOIN habits.habits h_1 ON ((h_1.id = m.habit_id)))
          GROUP BY m.habit_id, (date_trunc('week'::text, (m.d)::timestamp with time zone)), h_1.times_per_week
         HAVING (count(*) >= h_1.times_per_week)
        ), week_islands AS (
         SELECT x.habit_id,
            max(x.wk) AS last_wk,
            count(*) AS n
           FROM ( SELECT weeks.habit_id,
                    weeks.wk,
                    (weeks.wk - (7 * (row_number() OVER (PARTITION BY weeks.habit_id ORDER BY weeks.wk))::integer)) AS grp
                   FROM weeks) x
          GROUP BY x.habit_id, x.grp
        )
 SELECT id,
    name,
    kind,
    target,
    times_per_week,
    (EXISTS ( SELECT 1
           FROM met
          WHERE ((met.habit_id = h.id) AND (met.d = CURRENT_DATE)))) AS done_today,
    ( SELECT count(*) AS count
           FROM met
          WHERE ((met.habit_id = h.id) AND (met.d >= (date_trunc('week'::text, (CURRENT_DATE)::timestamp with time zone))::date))) AS done_this_week,
        CASE
            WHEN (times_per_week = 7) THEN COALESCE(( SELECT di.n
               FROM day_islands di
              WHERE ((di.habit_id = h.id) AND (di.last_d >= (CURRENT_DATE - 1)))), (0)::bigint)
            ELSE COALESCE(( SELECT wi.n
               FROM week_islands wi
              WHERE ((wi.habit_id = h.id) AND (wi.last_wk >= ((date_trunc('week'::text, (CURRENT_DATE)::timestamp with time zone))::date - 7)))), (0)::bigint)
        END AS current_streak,
        CASE
            WHEN (times_per_week = 7) THEN 'days'::text
            ELSE 'weeks'::text
        END AS streak_unit,
    COALESCE(( SELECT max(di.n) AS max
           FROM day_islands di
          WHERE (di.habit_id = h.id)), (0)::bigint) AS best_day_streak,
    ( SELECT max(l.logged_on) AS max
           FROM habits.logs l
          WHERE (l.habit_id = h.id)) AS last_logged
   FROM habits.habits h
  WHERE active;
