/* =====================================================================
   ICT371  QUESTION 10 - Scholarship Application Assessment      [50]
   Qualify only if: 18 <= age <= 25, monthly income <= K3,000,
                    average mark >= 70.
   ===================================================================== */
DROP SCHEMA IF EXISTS q10 CASCADE;
CREATE SCHEMA q10;
SET search_path TO q10, public;

-- Test helper (not part of the marked answer)
CREATE PROCEDURE expect_error(p_sql text) LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RAISE NOTICE 'UNEXPECTED: statement succeeded -> %', p_sql;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Rejected as expected -> %', SQLERRM;
END $$;


/* ---------------------------------------------------------------------
   (a) DATABASE AND SEED DATA                                       [6]
   - age > 0, income >= 0, mark BETWEEN 0 AND 100.
   - status limited to PENDING / APPROVED / REJECTED, default PENDING.
   - Six PENDING applications across four students. Each one tests a
     boundary of the rules (exactly on, or just past, a limit).
   --------------------------------------------------------------------- */
CREATE TABLE students (
    student_id      INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name       VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id      INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id          INTEGER       NOT NULL REFERENCES students (student_id),
    age_at_application  INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income      NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark        NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on        DATE          NOT NULL DEFAULT CURRENT_DATE,
    status              VARCHAR(8)    NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id  INTEGER     NOT NULL REFERENCES applications (application_id),
    old_status      VARCHAR(8)  NOT NULL,
    new_status      VARCHAR(8)  NOT NULL,
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('2025030301', 'Mwila Banda'),
    ('2025030302', 'Chanda Phiri'),
    ('2025030303', 'Natasha Zulu'),
    ('2025030304', 'Joseph Mulenga');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 40),  -- 1 all three EXACTLY on the limit -> qualifies
    (1, 19, 3000.01, 75.00, CURRENT_DATE - 10),  -- 2 income 1 ngwee over          -> fails
    (2, 25, 2200.00, 82.00, CURRENT_DATE - 35),  -- 3 oldest allowed age            -> qualifies
    (2, 25, 1800.00, 69.99, CURRENT_DATE - 5),   -- 4 mark just below 70            -> fails
    (3, 26, 1500.00, 88.00, CURRENT_DATE - 20),  -- 5 one year too old              -> fails
    (4, 17,  900.00, 91.00, CURRENT_DATE - 15);  -- 6 one year too young            -> fails


/* ---------------------------------------------------------------------
   (b) FUNCTION fn_scholarship_eligible                             [6]
   - Rejects NULLs, negative income, non-positive age, mark outside 0-100.
   - BETWEEN is inclusive on both ends, matching "18 to 25 inclusive".
   - "At most K3,000" -> <= 3000 ; "at least 70" -> >= 70.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INTEGER,
    p_income NUMERIC,
    p_mark   NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark are all required (got %, %, %)', p_age, p_income, p_mark;
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Invalid age %: must be positive', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Invalid income %: must not be negative', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Invalid mark %: must be between 0 and 100', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark   >= 70;
END;
$$;


/* ---------------------------------------------------------------------
   (c) PROCEDURE pr_assess_application                              [8]
   - FOR UPDATE locks the application so two assessors (or the job and a
     person) cannot assess it at the same time.
   - Unknown id -> exception; status not PENDING -> exception naming the
     current status ("clear exception").
   - Calls the function and sets APPROVED or REJECTED in one UPDATE.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_app      applications%ROWTYPE;
    v_eligible BOOLEAN;
BEGIN
    SELECT * INTO v_app
    FROM   applications
    WHERE  application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application % does not exist', p_application_id;
    END IF;

    IF v_app.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status %)',
                        p_application_id, v_app.status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_app.age_at_application,
                                          v_app.monthly_income,
                                          v_app.average_mark);

    UPDATE applications
    SET    status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE  application_id = p_application_id;
END;
$$;


/* ---------------------------------------------------------------------
   (d) TRIGGER: AFTER UPDATE, FOR EACH ROW, on applications         [8]
   - Audits only a real status change (IS DISTINCT FROM). An UPDATE that
     leaves status the same (e.g. correcting submitted_on) writes nothing.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, now());
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
EXECUTE FUNCTION trg_fn_decision_audit();


-- Tests for (b)
SELECT application_id,
       fn_scholarship_eligible(age_at_application, monthly_income, average_mark) AS eligible
FROM   applications ORDER BY application_id;        -- t, f, t, f, f, f
CALL expect_error('SELECT fn_scholarship_eligible(NULL, 1000, 80)');
CALL expect_error('SELECT fn_scholarship_eligible(20, -1, 80)');
CALL expect_error('SELECT fn_scholarship_eligible(0, 1000, 80)');
CALL expect_error('SELECT fn_scholarship_eligible(20, 1000, 101)');

-- Tests for (c)
CALL pr_assess_application(1);                                  -- APPROVED
CALL expect_error('CALL pr_assess_application(1)');             -- already assessed
CALL expect_error('CALL pr_assess_application(999)');           -- unknown

-- Tests for (d)
SELECT * FROM decision_audit;                                   -- PENDING -> APPROVED
UPDATE applications SET submitted_on = submitted_on WHERE application_id = 1;   -- no status change
UPDATE applications SET status = status WHERE application_id = 1;               -- same status
SELECT count(*) AS audit_rows_still_1 FROM decision_audit;


/* ---------------------------------------------------------------------
   (e) VIEW v_approved_applicants                                   [5]
   - APPROVED only; monthly_income is deliberately NOT selected (it is
     sensitive and the brief says to omit it).
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM   applications a
JOIN   students s ON s.student_id = a.student_id
WHERE  a.status = 'APPROVED';


/* ---------------------------------------------------------------------
   (f) INDEX                                                         [5]
   Query: WHERE status = ? AND submitted_on BETWEEN ? AND ?
   - Composite (status, submitted_on): status is compared with "=",
     submitted_on with a range. Equality column first means all
     applications of one status sit together in date order, so the range
     is one contiguous index slice.
   - (submitted_on, status) would read every status in the date range and
     discard the unwanted ones.
   - It also serves the job's "WHERE status = 'PENDING'" search (leading
     column alone).
   --------------------------------------------------------------------- */
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
ANALYZE applications;

EXPLAIN
SELECT application_id, student_id, submitted_on
FROM   applications
WHERE  status = 'PENDING'
AND    submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

SET enable_seqscan = off;     -- tiny table; show the plan used at real volume
EXPLAIN ANALYZE
SELECT application_id, student_id, submitted_on
FROM   applications
WHERE  status = 'PENDING'
AND    submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;


/* ---------------------------------------------------------------------
   (g) SCHEDULED JOB                                                 [6]
   - Query FOR loop over PENDING applications only, each passed to
     pr_assess_application.
   - Rerun safety: once assessed, an application is no longer PENDING, so
     the loop simply does not select it again -> no reassessment, no new
     status change, therefore no duplicate audit rows.
   - '0 8 * * 1' = 08:00 every Monday (day-of-week 1).
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
SET search_path = q10, public
AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT application_id
        FROM   applications
        WHERE  status = 'PENDING'
        ORDER  BY submitted_on, application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();                     -- assesses applications 2-6
SELECT application_id, status FROM applications ORDER BY application_id;
SELECT count(*) AS audit_rows_after_run FROM decision_audit;     -- 6
CALL pr_assess_pending();                     -- rerun: nothing PENDING left
SELECT count(*) AS audit_rows_after_rerun FROM decision_audit;   -- still 6

SELECT * FROM v_approved_applicants ORDER BY student_number;     -- applications 1 and 3

SELECT cron.schedule(
    'q10_assess_pending',
    '0 8 * * 1',
    $$CALL q10.pr_assess_pending()$$
);

SELECT jobid, jobname, schedule, command, active
FROM   cron.job
WHERE  jobname = 'q10_assess_pending';
