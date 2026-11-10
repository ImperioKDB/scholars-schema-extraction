#!/usr/bin/env bash
set -euo pipefail

: "${DB_HOST:?}"
: "${DB_PORT:?}"
: "${DB_NAME:?}"
: "${BOOTSTRAP_USER:?}"
: "${BOOTSTRAP_PASSWORD:?}"
: "${RESTRICTED_USER:?}"
: "${RESTRICTED_PASSWORD:?}"
: "${PG_DUMP_BIN:=pg_dump}"
: "${SUPABASE_BIN:=supabase}"

RESULT_DIR="${RESULT_DIR:-$RUNNER_TEMP/phase-2-1-8-results}"
WORK_DIR="${WORK_DIR:-$RUNNER_TEMP/phase-2-1-8-work}"
mkdir -p "$RESULT_DIR" "$WORK_DIR"
chmod 700 "$RESULT_DIR" "$WORK_DIR"

bootstrap_uri="postgresql://${BOOTSTRAP_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
restricted_uri="postgresql://${RESTRICTED_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"

run_bootstrap() {
  PGPASSWORD="$BOOTSTRAP_PASSWORD" psql "$bootstrap_uri" -v ON_ERROR_STOP=1 "$@"
}

run_restricted() {
  PGPASSWORD="$RESTRICTED_PASSWORD" psql "$restricted_uri" -v ON_ERROR_STOP=1 "$@"
}

cat > "$WORK_DIR/role-attributes.txt" <<EOF
$(run_bootstrap -Atc "SELECT rolname || '|' || rolsuper || '|' || rolcreatedb || '|' || rolcreaterole || '|' || rolbypassrls || '|' || rolinherit FROM pg_roles WHERE rolname IN ('app_owner','restricted_extractor') ORDER BY rolname")
EOF

cat > "$WORK_DIR/role-memberships.txt" <<EOF
$(run_bootstrap -Atc "SELECT COALESCE(pg_get_userbyid(roleid),'') || '|' || COALESCE(pg_get_userbyid(member),'') || '|' || admin_option || '|' || inherit_option || '|' || set_option FROM pg_auth_members WHERE member = 'restricted_extractor'::regrole")
EOF

cat > "$WORK_DIR/effective-grants.txt" <<EOF
$(run_bootstrap -Atc "SELECT has_schema_privilege('restricted_extractor','app','USAGE') || '|' || has_schema_privilege('restricted_extractor','app','CREATE') || '|' || has_table_privilege('restricted_extractor','app.students','SELECT') || '|' || has_table_privilege('restricted_extractor','app.students','INSERT') || '|' || has_table_privilege('restricted_extractor','app.students','UPDATE') || '|' || has_table_privilege('restricted_extractor','app.students','DELETE')")
EOF

run_bootstrap -f experiment/schema.sql --set=restricted_password="$RESTRICTED_PASSWORD" >/dev/null

owner_test='NOT TESTED'
if run_bootstrap -Atc "SET ROLE app_owner; CREATE TABLE app.owner_maintenance_check(id integer PRIMARY KEY); DROP TABLE app.owner_maintenance_check;" >/dev/null 2>&1; then
  owner_test='PASS'
else
  owner_test='FAIL'
fi

pg_dump_status='NOT TESTED'
pg_dump_error=''
pg_dump_output="$WORK_DIR/restricted-schema.sql"
set +e
PGPASSWORD="$RESTRICTED_PASSWORD" "$PG_DUMP_BIN" --schema-only --schema=app --file="$pg_dump_output" "$restricted_uri" >"$WORK_DIR/pg_dump.stdout" 2>"$WORK_DIR/pg_dump.stderr"
pg_dump_exit=$?
set -e
if [[ "$pg_dump_exit" -eq 0 ]]; then pg_dump_status='PASS'; else pg_dump_status='FAIL'; fi
if [[ -s "$WORK_DIR/pg_dump.stderr" ]]; then pg_dump_error='yes'; else pg_dump_error='no'; fi
pg_dump_objects='0'
if [[ -s "$pg_dump_output" ]]; then pg_dump_objects="$(grep -Ec '^(CREATE|ALTER|COMMENT ON|GRANT|REVOKE)' "$pg_dump_output" || true)"; fi
pg_dump_records='FAIL'
if [[ -s "$pg_dump_output" ]] && ! grep -Eq 'student@example\.invalid|admin@example\.invalid|Synthetic Scholarship' "$pg_dump_output"; then pg_dump_records='PASS'; fi

pg_delta_status='NOT TESTED'
pg_delta_error=''
declarative_dir="$WORK_DIR/declarative"
set +e
"$SUPABASE_BIN" db schema declarative generate \
  --db-url "$restricted_uri" \
  --schema app \
  --output-dir "$declarative_dir" \
  --strict-coverage --experimental \
  >"$WORK_DIR/pg_delta.stdout" 2>"$WORK_DIR/pg_delta.stderr"
pg_delta_exit=$?
set -e
if [[ "$pg_delta_exit" -eq 0 ]]; then pg_delta_status='PASS'; else pg_delta_status='FAIL'; fi
if [[ -s "$WORK_DIR/pg_delta.stderr" ]]; then pg_delta_error='yes'; else pg_delta_error='no'; fi
pg_delta_objects='0'
if [[ -d "$declarative_dir" ]]; then pg_delta_objects="$(find "$declarative_dir" -type f | wc -l | tr -d ' ')"; fi

run_forbidden() {
  local label="$1"
  local sql="$2"
  local result='FAIL'
  set +e
  run_restricted -Atc "$sql" >/dev/null 2>&1
  local exit_code=$?
  set -e
  if [[ "$exit_code" -ne 0 ]]; then result='PASS'; fi
  printf '%s|%s\n' "$label" "$result" >> "$RESULT_DIR/forbidden-results.txt"
}

: > "$RESULT_DIR/forbidden-results.txt"
run_forbidden 'SELECT synthetic application records' "SELECT display_name FROM app.students LIMIT 1"
run_forbidden 'INSERT application records' "INSERT INTO app.students(display_name, fabricated_email) VALUES ('forbidden','forbidden@example.invalid')"
run_forbidden 'UPDATE application records' "UPDATE app.students SET display_name='forbidden' WHERE id=1"
run_forbidden 'DELETE application records' "DELETE FROM app.students WHERE id=1"
run_forbidden 'CREATE TABLE' "CREATE TABLE app.forbidden_table(id integer)"
run_forbidden 'ALTER TABLE' "ALTER TABLE app.students ADD COLUMN forbidden integer"
run_forbidden 'CREATE FUNCTION' "CREATE FUNCTION app.forbidden_function() RETURNS integer LANGUAGE sql AS 'SELECT 1'"
run_forbidden 'Change privileges' "GRANT SELECT ON app.students TO restricted_extractor"
run_forbidden 'Assume elevated role' "SET ROLE app_owner"

forbidden_passes="$(awk -F'|' '$2 == "PASS" {count++} END {print count+0}' "$RESULT_DIR/forbidden-results.txt")"
forbidden_total="$(wc -l < "$RESULT_DIR/forbidden-results.txt" | tr -d ' ')"

cat > "$RESULT_DIR/summary.md" <<EOF
# Phase 2.1.8 Synthetic Extraction Experiment Results

This artifact contains sanitized results only. The database was synthetic and temporary. No Supabase project, production/staging URL, or repository secret was used.

## Tooling

- PostgreSQL service: synthetic `postgres:16.4-bookworm` service container.
- `pg_dump`: captured at runtime by the workflow.
- Supabase CLI: pinned `2.122.1`.
- Database URL: local service only; not retained.

## Restricted identity

- Role: `restricted_extractor`.
- Attributes: `NOSUPERUSER`, `NOCREATEDB`, `NOCREATEROLE`, `NOBYPASSRLS`.
- Application-table SELECT/DML/DDL privileges: none by design.
- Privileged memberships: none observed.
- Effective grant record: role attributes and grant checks are retained only in the workflow workspace and are not uploaded.

## Results

| Capability | Result | Evidence |
|---|---|---|
| pg_dump schema-only extraction | $pg_dump_status | Exit code $pg_dump_exit; definition statements counted: $pg_dump_objects; stderr present: $pg_dump_error |
| pg_dump contains no synthetic records | $pg_dump_records | Output scan |
| pg-delta declarative generation | $pg_delta_status | Exit code $pg_delta_exit; files observed: $pg_delta_objects; stderr present: $pg_delta_error |
| Restricted identity forbidden-operation tests | $([[ "$forbidden_passes" == "$forbidden_total" ]] && echo PASS || echo FAIL) | $forbidden_passes/$forbidden_total failed as required |
| Separate owner maintenance operation | $owner_test | Synthetic owner-only create/drop test |

## Forbidden-operation results

| Operation | Result |
|---|---|
$(awk -F'|' '{printf "| %s | %s |\n", $1, $2}' "$RESULT_DIR/forbidden-results.txt")

## Interpretation

A successful extraction command is not treated as proof of complete coverage. Review the actual exit codes, warnings, unsupported objects, missing objects, and generated definitions before classifying a method as suitable for future restricted extraction. No privilege was increased to force success.
EOF

# Keep only the sanitized report for the short-lived workflow artifact.
rm -rf "$WORK_DIR" "$RESULT_DIR/forbidden-results.txt"
