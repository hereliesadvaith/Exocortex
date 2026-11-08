-- Sample data: made-up companies, so the page has something in every status.
-- Load it once after schema.sql:   su postgres -c "psql -f sample.sql"
-- Dates are relative to the day you load it. Clear it before tracking for real:
--   su postgres -c "psql -c 'TRUNCATE jobs.applications RESTART IDENTITY CASCADE'"
-- (That keeps your profile.)

BEGIN;

UPDATE jobs.profile SET
    headline = 'Odoo Developer',
    experience_years = 3.5,
    notice_ends_on = DATE '2026-12-28',
    notes = 'Python, PostgreSQL, OWL/JS, Odoo 15–18. Sales, Inventory, Accounting, Website, custom modules and integrations.';

CREATE TEMP TABLE s (
    key text, company text, role text, status text, location text, work_mode text,
    source text, contact text, expected_ctc numeric, offered_ctc numeric,
    applied_ago int, status_ago int, notes text
) ON COMMIT DROP;

INSERT INTO s VALUES
('northwind', 'Northwind ERP Labs', 'Senior Odoo Developer', 'offer', 'Bengaluru', 'hybrid',
 'LinkedIn', 'Priya (HR)', 14, 13.5, 24, 1,
 'Offer letter received. Wants joining by Jan 4; my notice ends Dec 28, so that works. Ask if they can match 14 LPA.'),
('bluepeak', 'Bluepeak Technologies', 'Odoo Technical Consultant', 'interviewing', NULL, 'remote',
 'Naukri', 'Arjun, talent team', 13, NULL, 12, 5,
 'Odoo 17, mostly Accounting and Inventory customisation for EU clients.'),
('saffron', 'Saffron Retail Systems', 'Odoo Developer (POS & Inventory)', 'interviewing', 'Kochi', 'onsite',
 'Referral', 'Referred by Rahul', 12, NULL, 9, 6,
 'POS heavy. Revise POS OWL components and stock valuation before the technical.'),
('ledgerline', 'Ledgerline Solutions', 'Odoo Functional-Technical Lead', 'screening', 'Hyderabad', 'hybrid',
 'Recruiter', 'Sneha, Ledgerline HR', 15, NULL, 6, 3,
 'Recruiter reached out on LinkedIn. Lead role: small team of 3.'),
('cobalt', 'Cobalt Cloud Partners', 'Python / Odoo Backend Engineer', 'screening', NULL, 'remote',
 'Company site', NULL, 13, NULL, 8, 4,
 'HR call done, waiting to hear about the technical round.'),
('tidewater', 'Tidewater Logistics', 'Odoo Developer (Inventory / MRP)', 'applied', 'Chennai', 'onsite',
 'Naukri', NULL, 12, NULL, 4, 4, NULL),
('greenfield', 'Greenfield ERP Studio', 'Odoo Developer', 'applied', NULL, 'remote',
 'LinkedIn', NULL, 11, NULL, 9, 9, 'Easy Apply. Follow up if nothing by next week.'),
('meridian', 'Meridian Health Tech', 'Odoo Implementation Engineer', 'applied', 'Pune', 'hybrid',
 'Instahyre', NULL, 12.5, NULL, 2, 2, NULL),
('orbit', 'Orbit Commerce', 'Odoo + OWL Frontend Developer', 'wishlist', NULL, 'remote',
 'Company site', NULL, 13, NULL, NULL, 3, 'Add the OWL dashboard widget to GitHub before applying.'),
('kestrel', 'Kestrel Manufacturing', 'In-house Odoo Developer', 'wishlist', 'Coimbatore', 'onsite',
 'Referral', NULL, 11, NULL, NULL, 1, 'MRP and quality modules. Ask Anand about the team.'),
('vertex', 'Vertex Digital', 'Odoo Developer', 'rejected', 'Bengaluru', 'hybrid',
 'LinkedIn', NULL, 12, NULL, 18, 7, 'Rejected after the technical round.'),
('harbor', 'Harbor Fintech', 'Odoo Accounting Developer', 'rejected', 'Mumbai', 'onsite',
 'Naukri', NULL, 13, NULL, 20, 15, 'Rejected at resume screen: wanted 5+ years.'),
('pinecrest', 'Pinecrest Consulting', 'Odoo Developer', 'withdrawn', 'Kochi', 'onsite',
 'Recruiter', NULL, 10, NULL, 16, 10, 'Two-year service bond. Not interested.'),
('quillstone', 'Quillstone Software', 'Odoo Developer', 'ghosted', NULL, 'remote',
 'LinkedIn', NULL, 12, NULL, 30, 21, 'No reply after the HR call.');

CREATE TEMP TABLE ids (key text, id int) ON COMMIT DROP;

WITH ins AS (
    INSERT INTO jobs.applications
        (company, role, status, location, work_mode, source, contact, expected_ctc, offered_ctc,
         applied_on, notes, status_changed_at, created_at)
    SELECT company, role, status, location, work_mode, source, contact, expected_ctc, offered_ctc,
           current_date - applied_ago, notes,
           now() - make_interval(days => status_ago),
           now() - make_interval(days => coalesce(applied_ago, status_ago))
    FROM s ORDER BY key
    RETURNING id, company
)
INSERT INTO ids SELECT s.key, ins.id FROM ins JOIN s USING (company);

-- Rounds: day offset from today and a local (Asia/Kolkata) time.
CREATE TEMP TABLE r (
    key text, kind text, day int, at time, mode text, outcome text, interviewer text, notes text
) ON COMMIT DROP;

INSERT INTO r VALUES
('northwind', 'hr', -20, '11:00', 'phone', 'passed', 'Priya', 'Notice period and CTC discussion.'),
('northwind', 'technical', -15, '15:00', 'video', 'passed', 'Kiran, tech lead',
 'ORM, computed fields, record rules, a live exercise on inheriting sale.order.'),
('northwind', 'manager', -8, '12:00', 'video', 'passed', 'Delivery manager', 'Client handling and estimation.'),
('northwind', 'final', -3, '16:30', 'video', 'passed', 'Priya', 'Offer discussion.'),

('bluepeak', 'hr', -9, '10:30', 'phone', 'passed', 'Arjun', NULL),
('bluepeak', 'technical', -5, '14:00', 'video', 'passed', 'Two senior devs', 'Accounting: reconciliation, multi-currency, taxes.'),
('bluepeak', 'assignment', 2, '18:00', NULL, 'scheduled', NULL,
 'Take-home due: approval workflow on purchase orders in Odoo 17, with tests.'),
('bluepeak', 'manager', 4, '11:00', 'video', 'scheduled', 'Engineering manager', NULL),

('saffron', 'hr', -6, '12:00', 'phone', 'passed', NULL, NULL),
('saffron', 'technical', 1, '15:00', 'video', 'scheduled', NULL, 'POS + inventory. Revise OWL and stock valuation.'),

('ledgerline', 'hr', 3, '17:30', 'phone', 'scheduled', 'Sneha', NULL),

('cobalt', 'hr', -2, '16:00', 'video', 'scheduled', NULL, 'Went well; they said 2–3 days.'),

('vertex', 'hr', -14, '11:30', 'phone', 'passed', NULL, NULL),
('vertex', 'technical', -9, '15:30', 'video', 'failed', NULL,
 'Stuck on ORM performance: prefetching, read_group, avoiding N+1 in computes. Brush up.'),

('quillstone', 'hr', -26, '10:00', 'phone', 'passed', NULL, NULL);

INSERT INTO jobs.rounds (application_id, kind, scheduled_at, mode, outcome, interviewer, notes)
SELECT ids.id, r.kind, ((current_date + r.day) + r.at) AT TIME ZONE 'Asia/Kolkata',
       r.mode, r.outcome, r.interviewer, r.notes
FROM r JOIN ids USING (key);

COMMIT;
