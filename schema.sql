-- The `jobs` schema the job-hunt tracker reads and writes.
-- Create it once, as postgres:   su postgres -c "psql -f schema.sql"
-- The app connects as the `jobs` role (see README.md), which can use this schema only.
--
-- jobs.profile       one row: what you're looking for and when your notice period ends.
-- jobs.applications  one row per company/role. `status` is where it stands in the
--                    pipeline; status_changed_at is set whenever status changes, so the
--                    page can say how long it's been sitting there.
-- jobs.rounds        the interview rounds for an application: HR call, technical,
--                    assignment, ... with when it is and how it went.
--
-- Salaries are in lakhs per annum (LPA). Dates are days in the database time zone
-- (Asia/Kolkata).

CREATE EXTENSION IF NOT EXISTS moddatetime;

CREATE SCHEMA jobs;

CREATE TABLE jobs.profile (
    id boolean PRIMARY KEY DEFAULT true CHECK (id),   -- only ever one row
    headline text NOT NULL DEFAULT 'Developer' CHECK (length(headline) BETWEEN 1 AND 120),
    experience_years numeric(4,1) CHECK (experience_years BETWEEN 0 AND 60),
    notice_ends_on date,
    current_ctc numeric(7,2) CHECK (current_ctc >= 0),
    expected_ctc numeric(7,2) CHECK (expected_ctc >= 0),
    notes text CHECK (length(notes) <= 5000),
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);
INSERT INTO jobs.profile DEFAULT VALUES;

CREATE TABLE jobs.applications (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company text NOT NULL CHECK (length(company) BETWEEN 1 AND 120),
    role text NOT NULL CHECK (length(role) BETWEEN 1 AND 160),
    status text NOT NULL DEFAULT 'applied' CHECK (status IN (
        'wishlist',      -- want to apply
        'applied',       -- applied, no reply yet
        'screening',     -- recruiter / HR talking to you
        'interviewing',  -- in interview rounds
        'offer',         -- offer in hand, not decided
        'accepted',      -- took it
        'rejected',      -- they said no
        'withdrawn',     -- you said no
        'ghosted'        -- no reply for too long
    )),
    location text CHECK (length(location) <= 120),
    work_mode text CHECK (work_mode IN ('remote', 'hybrid', 'onsite')),
    source text CHECK (length(source) <= 60),       -- LinkedIn, Naukri, referral, ...
    url text CHECK (length(url) <= 1000),
    contact text CHECK (length(contact) <= 300),    -- recruiter name, phone, email
    expected_ctc numeric(7,2) CHECK (expected_ctc >= 0),
    offered_ctc numeric(7,2) CHECK (offered_ctc >= 0),
    applied_on date,
    notes text CHECK (length(notes) <= 10000),
    status_changed_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE INDEX applications_status_idx ON jobs.applications (status);

CREATE TRIGGER applications_mtime BEFORE UPDATE ON jobs.applications
    FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');

CREATE FUNCTION jobs.status_changed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        NEW.status_changed_at := now();
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER applications_status BEFORE UPDATE OF status ON jobs.applications
    FOR EACH ROW EXECUTE FUNCTION jobs.status_changed();

CREATE TABLE jobs.rounds (
    id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id integer NOT NULL REFERENCES jobs.applications(id) ON DELETE CASCADE,
    kind text NOT NULL DEFAULT 'technical' CHECK (kind IN (
        'hr', 'technical', 'assignment', 'manager', 'client', 'culture', 'final', 'other'
    )),
    scheduled_at timestamp with time zone,
    mode text CHECK (mode IN ('video', 'phone', 'onsite')),
    outcome text NOT NULL DEFAULT 'scheduled' CHECK (outcome IN (
        'scheduled',  -- coming up, or done and waiting to hear
        'passed', 'failed', 'cancelled'
    )),
    interviewer text CHECK (length(interviewer) <= 200),
    notes text CHECK (length(notes) <= 10000),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE INDEX rounds_application_idx ON jobs.rounds (application_id);
CREATE INDEX rounds_scheduled_idx ON jobs.rounds (scheduled_at) WHERE outcome = 'scheduled';

CREATE TRIGGER rounds_mtime BEFORE UPDATE ON jobs.rounds
    FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');

-- Open applications with their next round; handy for querying from Claude.
CREATE VIEW jobs.pipeline AS
SELECT a.id, a.company, a.role, a.status, a.location, a.work_mode, a.source,
       a.expected_ctc, a.offered_ctc, a.applied_on,
       current_date - a.status_changed_at::date AS days_in_status,
       n.kind AS next_round, n.scheduled_at AS next_round_at,
       (SELECT count(*) FROM jobs.rounds r WHERE r.application_id = a.id AND r.outcome = 'passed') AS rounds_passed
FROM jobs.applications a
LEFT JOIN LATERAL (
    SELECT r.kind, r.scheduled_at FROM jobs.rounds r
    WHERE r.application_id = a.id AND r.outcome = 'scheduled' AND r.scheduled_at >= now()
    ORDER BY r.scheduled_at LIMIT 1
) n ON true
WHERE a.status IN ('wishlist', 'applied', 'screening', 'interviewing', 'offer')
ORDER BY array_position(ARRAY['offer', 'interviewing', 'screening', 'applied', 'wishlist'], a.status),
         n.scheduled_at NULLS LAST, a.status_changed_at;

-- Rounds still marked scheduled, soonest first (past ones are waiting for a result).
CREATE VIEW jobs.upcoming AS
SELECT r.id, r.scheduled_at, r.kind, r.mode, a.company, a.role, r.interviewer,
       r.scheduled_at < now() AS awaiting_result
FROM jobs.rounds r
JOIN jobs.applications a ON a.id = r.application_id
WHERE r.outcome = 'scheduled' AND r.scheduled_at IS NOT NULL
ORDER BY r.scheduled_at;
