-- The `todos` schema the to-do app reads and writes.
-- Create it once, as postgres:   su postgres -c "psql -f schema.sql"
-- The app connects as the `todos` role (see README.md), which can use this schema only.
--
-- todos.lists  optional lists to group tasks (Work, Home, ...). Tasks without a list
--              are in the Inbox. Deleting a list moves its tasks to the Inbox.
-- todos.tasks  one row per task. done_at is set when it's ticked off. A task with
--              `repeat` needs a due date; ticking it off creates the next one
--              (next_id points at it, so undoing can take it back).
--
-- Dates are days in the database time zone (Asia/Kolkata), so CURRENT_DATE decides
-- what "today" and "overdue" mean.

CREATE EXTENSION IF NOT EXISTS moddatetime;

CREATE SCHEMA todos;

CREATE TABLE todos.lists (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 60),
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE todos.tasks (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title text NOT NULL CHECK (length(title) BETWEEN 1 AND 300),
    notes text CHECK (length(notes) <= 5000),
    list_id integer REFERENCES todos.lists(id) ON DELETE SET NULL,
    due_on date,
    priority smallint DEFAULT 0 NOT NULL CHECK (priority BETWEEN 0 AND 3),  -- 0 none, 1 low, 2 medium, 3 high
    repeat text CHECK (repeat IN ('daily', 'weekly', 'monthly', 'yearly')),
    done_at timestamp with time zone,
    next_id integer REFERENCES todos.tasks(id) ON DELETE SET NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT tasks_repeat_needs_due CHECK (repeat IS NULL OR due_on IS NOT NULL)
);

CREATE INDEX tasks_open_idx ON todos.tasks (due_on) WHERE done_at IS NULL;
CREATE INDEX tasks_done_idx ON todos.tasks (done_at) WHERE done_at IS NOT NULL;

CREATE TRIGGER tasks_mtime BEFORE UPDATE ON todos.tasks
    FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');

-- Open tasks with how they stand today; handy for querying from Claude.
CREATE VIEW todos.open AS
SELECT t.id, t.title, t.notes, l.name AS list, t.due_on, t.priority, t.repeat,
       t.due_on < CURRENT_DATE AS overdue,
       t.due_on = CURRENT_DATE AS due_today,
       t.created_at
FROM todos.tasks t
LEFT JOIN todos.lists l ON l.id = t.list_id
WHERE t.done_at IS NULL
ORDER BY t.due_on NULLS LAST, t.priority DESC, t.created_at;
