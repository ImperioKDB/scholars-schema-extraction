-- Synthetic-only schema for Phase 2.1.8.
-- Executed by the bootstrap database user; passwords are injected at runtime.

CREATE ROLE app_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
CREATE ROLE restricted_extractor LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'restricted_password';

GRANT CONNECT ON DATABASE synthetic TO restricted_extractor;
GRANT CREATE ON DATABASE synthetic TO app_owner;

SET ROLE app_owner;
CREATE SCHEMA app AUTHORIZATION app_owner;
CREATE SEQUENCE app.scholarship_id_seq;

CREATE TABLE app.students (
  id bigint PRIMARY KEY DEFAULT nextval('app.scholarship_id_seq'),
  display_name text NOT NULL,
  fabricated_email text NOT NULL UNIQUE,
  is_admin boolean NOT NULL DEFAULT false
);

CREATE TABLE app.scholarships (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title text NOT NULL,
  owner_student_id bigint NOT NULL REFERENCES app.students(id),
  amount_cents integer NOT NULL CHECK (amount_cents > 0),
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'published'))
);

CREATE INDEX scholarships_owner_idx ON app.scholarships(owner_student_id);

INSERT INTO app.students (display_name, fabricated_email, is_admin)
VALUES ('Synthetic Student', 'student@example.invalid', false),
       ('Synthetic Administrator', 'admin@example.invalid', true);

INSERT INTO app.scholarships (title, owner_student_id, amount_cents, status)
VALUES ('Synthetic Scholarship', 1, 125000, 'published');

CREATE VIEW app.published_scholarships AS
SELECT s.id, s.title, s.amount_cents
FROM app.scholarships AS s
WHERE s.status = 'published';

CREATE OR REPLACE FUNCTION app.current_synthetic_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, pg_catalog
AS $$
  SELECT EXISTS (SELECT 1 FROM app.students WHERE fabricated_email = 'admin@example.invalid' AND is_admin);
$$;

CREATE TABLE app.audit_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  scholarship_id bigint NOT NULL REFERENCES app.scholarships(id),
  event_name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION app.record_scholarship_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = app, pg_catalog
AS $$
BEGIN
  INSERT INTO app.audit_events (scholarship_id, event_name)
  VALUES (NEW.id, 'inserted');
  RETURN NEW;
END;
$$;

CREATE TRIGGER scholarships_insert_audit
AFTER INSERT ON app.scholarships
FOR EACH ROW EXECUTE FUNCTION app.record_scholarship_insert();

ALTER TABLE app.students ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.scholarships ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.audit_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY synthetic_student_self_read ON app.students
  FOR SELECT TO restricted_extractor
  USING (false);

CREATE POLICY synthetic_public_scholarship_read ON app.scholarships
  FOR SELECT TO restricted_extractor
  USING (false);

CREATE POLICY synthetic_admin_only_audit ON app.audit_events
  FOR SELECT TO restricted_extractor
  USING (false);

-- Explicitly grant schema usage but no application-table SELECT/DML to the extractor.
GRANT USAGE ON SCHEMA app TO restricted_extractor;
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA app FROM restricted_extractor;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA app FROM restricted_extractor;
REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA app FROM restricted_extractor;

-- Document a default-privilege posture without granting application access.
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app REVOKE ALL ON TABLES FROM restricted_extractor;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app REVOKE ALL ON SEQUENCES FROM restricted_extractor;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app REVOKE ALL ON FUNCTIONS FROM restricted_extractor;

RESET ROLE;
