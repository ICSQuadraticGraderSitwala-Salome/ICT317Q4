-- ============================================================
-- ICT371 - QUESTION 4: Clinic Appointments and Daily Load
-- ============================================================

-- ------------------------------------------------------------
-- (a) DATABASE AND SEED DATA
-- ------------------------------------------------------------
DROP TABLE IF EXISTS daily_clinic_load, appointment_audit, appointments, doctors, patients CASCADE;

CREATE TABLE patients (
  patient_id SERIAL PRIMARY KEY,
  patient_number VARCHAR(20) NOT NULL UNIQUE,
  full_name VARCHAR(100) NOT NULL,
  date_of_birth DATE NOT NULL
);

CREATE TABLE doctors (
  doctor_id SERIAL PRIMARY KEY,
  doctor_name VARCHAR(100) NOT NULL,
  specialty VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
  appointment_id SERIAL PRIMARY KEY,
  patient_id INT NOT NULL REFERENCES patients(patient_id),
  doctor_id INT NOT NULL REFERENCES doctors(doctor_id),
  appointment_date DATE NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'booked'
    CHECK (status IN ('booked', 'completed', 'cancelled'))
);

CREATE TABLE appointment_audit (
  audit_id SERIAL PRIMARY KEY,
  appointment_id INT NOT NULL REFERENCES appointments(appointment_id),
  old_status VARCHAR(20) NULL,
  new_status VARCHAR(20) NULL,
  changed_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE daily_clinic_load (
  load_date DATE PRIMARY KEY,
  appointment_count INT NOT NULL DEFAULT 0,
  completed_count INT NOT NULL DEFAULT 0,
  cancelled_count INT NOT NULL DEFAULT 0
);

-- Seed: 3 patients, 3 doctors
INSERT INTO patients (patient_number, full_name, date_of_birth) VALUES
('PAT001', 'John Banda', '1998-05-10'),
('PAT002', 'Mary Zulu', '2000-08-15'),
('PAT003', 'Peter Mwale', '1995-02-20');

INSERT INTO doctors (doctor_name, specialty) VALUES
('Dr. Chanda', 'General'),
('Dr. Mwila', 'Paediatrics'),
('Dr. Banda', 'Dentistry');

-- ------------------------------------------------------------
-- (b) FUNCTION
-- fn_doctor_load(p_doctor_id, p_day) = non-cancelled appointments
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_doctor_load(p_doctor_id INT, p_day DATE)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_count INT;
BEGIN
  IF p_day IS NULL THEN RAISE EXCEPTION 'Date is required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
    RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
  END IF;
  SELECT COUNT(*) INTO v_count FROM appointments
  WHERE doctor_id = p_doctor_id AND appointment_date = p_day AND status <> 'cancelled';
  RETURN v_count;
END; $$;

-- ------------------------------------------------------------
-- (c) PROCEDURE 
-- pr_book_appointment(p_patient_id, p_doctor_id, p_date)
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_patient_id IS NULL THEN RAISE EXCEPTION 'Patient ID is required'; END IF;
  IF p_doctor_id IS NULL THEN RAISE EXCEPTION 'Doctor ID is required'; END IF;
  IF p_date IS NULL THEN RAISE EXCEPTION 'Date is required'; END IF;
  IF p_date < CURRENT_DATE THEN RAISE EXCEPTION 'Cannot book in the past: %', p_date; END IF;
  IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
    RAISE EXCEPTION 'Unknown patient: %', p_patient_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
    RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
  END IF;
  -- Double-booking: same patient + same doctor + same date, not cancelled
  IF EXISTS (SELECT 1 FROM appointments WHERE patient_id = p_patient_id
    AND doctor_id = p_doctor_id AND appointment_date = p_date AND status <> 'cancelled') THEN
    RAISE EXCEPTION 'Double booking: patient % already has appointment with doctor % on %', p_patient_id, p_doctor_id, p_date;
  END IF;
  INSERT INTO appointments (patient_id, doctor_id, appointment_date, status)
  VALUES (p_patient_id, p_doctor_id, p_date, 'booked');
END; $$;

-- ------------------------------------------------------------
-- (d) TRIGGER 
-- AFTER UPDATE on appointments -> appointment_audit only if status changed
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_appointment_audit_fn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    INSERT INTO appointment_audit (appointment_id, old_status, new_status, changed_at)
    VALUES (NEW.appointment_id, OLD.status, NEW.status, NOW());
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_appointment_audit ON appointments;
CREATE TRIGGER trg_appointment_audit
AFTER UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_appointment_audit_fn();

-- ------------------------------------------------------------
-- (a) CONTINUED: Seed 6 appointments THROUGH procedure
-- ------------------------------------------------------------
CALL pr_book_appointment(1, 1, '2026-11-25');
CALL pr_book_appointment(2, 1, '2026-11-25');
CALL pr_book_appointment(1, 2, '2026-11-26');
CALL pr_book_appointment(3, 2, '2026-11-26');
CALL pr_book_appointment(2, 3, '2026-11-27');
CALL pr_book_appointment(3, 1, '2026-11-27');

-- Change 2 statuses to test trigger - 1 completed, 1 cancelled
UPDATE appointments SET status = 'completed' WHERE appointment_id = 1;
UPDATE appointments SET status = 'cancelled' WHERE appointment_id = 2;

-- ------------------------------------------------------------
-- (e) VIEW
-- v_upcoming_appointments - booked and date >= CURRENT_DATE
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_upcoming_appointments AS
SELECT a.appointment_id, p.full_name AS patient_name,
  d.doctor_name, d.specialty, a.appointment_date, a.status
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors d ON d.doctor_id = a.doctor_id
WHERE a.status = 'booked' AND a.appointment_date >= CURRENT_DATE;

-- Query the view:
SELECT * FROM v_upcoming_appointments;

-- ------------------------------------------------------------
-- (f) INDEX 
-- For a doctor's appointments within a date range
-- ------------------------------------------------------------
CREATE INDEX idx_appointments_doctor_date ON appointments (doctor_id, appointment_date);

-- Justification: Composite (doctor_id, appointment_date) lets Postgres seek
-- directly to that doctor, then range-scan only those dates,
-- instead of scanning all appointments.

-- Matching query and EXPLAIN:
EXPLAIN ANALYZE
SELECT * FROM appointments
WHERE doctor_id = 1 AND appointment_date BETWEEN '2026-11-25' AND '2026-11-27';

-- ------------------------------------------------------------
-- (g) SCHEDULED JOB 
-- pr_refresh_clinic_load(p_day) - replace row on rerun
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_load(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_day IS NULL THEN RAISE EXCEPTION 'p_day is required'; END IF;
  INSERT INTO daily_clinic_load (load_date, appointment_count, completed_count, cancelled_count)
  SELECT p_day,
    COUNT(*),
    COUNT(*) FILTER (WHERE status = 'completed'),
    COUNT(*) FILTER (WHERE status = 'cancelled')
  FROM appointments WHERE appointment_date = p_day
  ON CONFLICT (load_date) DO UPDATE
  SET appointment_count = EXCLUDED.appointment_count,
      completed_count = EXCLUDED.completed_count,
      cancelled_count = EXCLUDED.cancelled_count;
END; $$;

-- Test: run twice, must NOT double-count
CALL pr_refresh_clinic_load('2026-11-25');
CALL pr_refresh_clinic_load('2026-11-25');
CALL pr_refresh_clinic_load('2026-11-26');

-- Verify:
SELECT * FROM daily_clinic_load ORDER BY load_date;
SELECT * FROM appointment_audit ORDER BY audit_id;
SELECT fn_doctor_load(1, '2026-11-25') AS doctor1_load_25th;

-- Schedule: Daily at 00:20 for the previous day
-- SELECT cron.schedule('q4_refresh_clinic', '20 0 * * *', $$CALL pr_refresh_clinic_load(CURRENT_DATE - 1);$$);
-- Inspect job: SELECT * FROM cron.job;