#!/usr/bin/env bash
set -euo pipefail

: "${DB_HOST:?}"
: "${DB_PORT:?}"
: "${DB_NAME:?}"
: "${BOOTSTRAP_USER:?}"
BOOTSTRAP_PASSWORD="${BOOTSTRAP_PASSWORD:-}"
if [[ -n "$BOOTSTRAP_PASSWORD" ]]; then
  echo 'BOOTSTRAP_PASSWORD must be empty when the synthetic service uses trust authentication.' >&2
  exit 1
fi
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

# The service uses POSTGRES_HOST_AUTH_METHOD=trust, so the bootstrap password is
# intentionally empty. The restricted role still receives a generated password.
run_bootstrap -f experiment/schema.sql --set=restricted_password="$RESTRICTED_PASSWORD" >/dev/null

# Inspect and assert role state only after schema.sql has created all roles and objects.
run_bootstrap -Atc "SELECT rolname || '|' || rolsuper || '|' || rolcreatedb || '|' || rolcreaterole || '|' || rolbypassrls || '|' || rolinherit FROM pg_roles WHERE rolname IN ('app_owner','restricted_extractor','rls_probe') ORDER BY rolname" > "$WORK_DIR/role-attributes.txt"
run_bootstrap -Atc "SELECT COALESCE(pg_get_userbyid(roleid),'') || '|' || COALESCE(pg_get_userbyid(member),'') || '|' || admin_option || '|' || inherit_option || '|' || set_option FROM pg_auth_members WHERE member IN ('restricted_extractor'::regrole, 'rls_probe'::regrole) ORDER BY member, roleid" > "$WORK_DIR/role-memberships.txt"
run_bootstrap -Atc "SELECT has_schema_privilege('restricted_extractor','app','USAGE') || '|' || has_schema_privilege('restricted_extractor','app','CREATE') || '|' || has_table_privilege('restricted_extractor','app.students','SELECT') || '|' || has_table_privilege('restricted_extractor','app.students','INSERT') || '|' || has_table_privilege('restricted_extractor','app.students','UPDATE') || '|' || has_table_privilege('restricted_extractor','app.students','DELETE')" > "$WORK_DIR/effective-grants.txt"

role_attributes_status='PASS'
while IFS= read -r expected; do
  if ! grep -Fqx "$expected" "$WORK_DIR/role-attributes.txt"; then role_attributes_status='FAIL'; fi
done <<'EXPECTED_ROLE_ATTRIBUTES'
app_owner|f|f|f|f|f
restricted_extractor|f|f|f|f|t
rls_probe|f|f|f|f|f
EXPECTED_ROLE_ATTRIBUTES

role_memberships_status='PASS'
if [[ -s "$WORK_DIR/role-memberships.txt" ]]; then role_memberships_status='FAIL'; fi

effective_grants_status='PASS'
if ! grep -Fqx 't|f|f|f|f|f' "$WORK_DIR/effective-grants.txt"; then effective_grants_status='FAIL'; fi

default_privilege_status='NOT TESTED'
default_privilege_effective='NOT TESTED'
default_privilege_create_exit='NOT TESTED'
default_privilege_drop_exit='NOT TESTED'
set +e
run_bootstrap -Atc "SET ROLE app_owner; CREATE TABLE app.default_privilege_check(id integer PRIMARY KEY);" >"$WORK_DIR/default-privilege-create.stdout" 2>"$WORK_DIR/default-privilege-create.stderr"
default_privilege_create_exit=$?
set -e
if [[ "$default_privilege_create_exit" -eq 0 ]]; then
  set +e
  default_privilege_effective="$(run_bootstrap -Atc "SELECT has_table_privilege('restricted_extractor','app.default_privilege_check','SELECT') || '|' || has_table_privilege('restricted_extractor','app.default_privilege_check','INSERT') || '|' || has_table_privilege('restricted_extractor','app.default_privilege_check','UPDATE') || '|' || has_table_privilege('restricted_extractor','app.default_privilege_check','DELETE') || '|' || has_table_privilege('restricted_extractor','app.default_privilege_check','TRUNCATE') || '|' || has_table_privilege('restricted_extractor','app.default_privilege_check','REFERENCES') || '|' || has_table_privilege('restricted_extractor','app.default_privilege_check','TRIGGER')" 2>"$WORK_DIR/default-privilege-query.stderr")"
  default_privilege_query_exit=$?
  run_bootstrap -Atc "SET ROLE app_owner; DROP TABLE app.default_privilege_check;" >"$WORK_DIR/default-privilege-drop.stdout" 2>"$WORK_DIR/default-privilege-drop.stderr"
  default_privilege_drop_exit=$?
  set -e
  if [[ "$default_privilege_query_exit" -eq 0 && "$default_privilege_effective" == 'f|f|f|f|f|f|f' && "$default_privilege_drop_exit" -eq 0 ]]; then default_privilege_status='PASS'; else default_privilege_status='FAIL'; fi
fi

# Establish a successful restricted-identity connection before any denial test.
restricted_connection_status='FAIL'
restricted_connection_identity=''
set +e
restricted_connection_identity="$(run_restricted -Atc "SELECT current_user || '|' || current_database()" 2>"$WORK_DIR/restricted-connection.stderr")"
restricted_connection_exit=$?
set -e
if [[ "$restricted_connection_exit" -eq 0 && "$restricted_connection_identity" == "restricted_extractor|synthetic" ]]; then
  restricted_connection_status='PASS'
fi
if [[ "$restricted_connection_status" != 'PASS' ]]; then
  echo 'Restricted identity connection could not be established; stopping before denial tests.' >&2
  exit 1
fi

owner_test='NOT TESTED'
if run_bootstrap -Atc "SET ROLE app_owner; CREATE TABLE app.owner_maintenance_check(id integer PRIMARY KEY); DROP TABLE app.owner_maintenance_check;" >/dev/null 2>&1; then
  owner_test='PASS'
else
  owner_test='FAIL'
fi

# Demonstrate RLS separately: rls_probe has SELECT privilege, but its false policy
# must return zero rows. This is not the restricted identity and not a privilege test.
rls_select_privilege='false'
rls_visible_rows='NOT TESTED'
if [[ "$(run_bootstrap -Atc "SELECT has_table_privilege('rls_probe','app.students','SELECT')")" == 't' ]]; then
  rls_select_privilege='true'
fi
set +e
rls_visible_rows="$(run_bootstrap -Atc "SET ROLE rls_probe; SELECT count(*) FROM app.students" 2>"$WORK_DIR/rls.stderr")"
rls_exit=$?
set -e
rls_status='FAIL'
if [[ "$rls_select_privilege" == 'true' && "$rls_exit" -eq 0 && "$rls_visible_rows" == '0' ]]; then
  rls_status='PASS'
fi

expected_objects=(
  'table|app.students|CREATE[[:space:]]+TABLE[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?app[.]students[[:space:]]*[(]'
  'table|app.scholarships|CREATE[[:space:]]+TABLE[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?app[.]scholarships[[:space:]]*[(]'
  'sequence|app.scholarship_id_seq|CREATE[[:space:]]+SEQUENCE[[:space:]]+app[.]scholarship_id_seq([[:space:]]|;|$)'
  'index|scholarships_owner_idx|CREATE[[:space:]]+INDEX[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?scholarships_owner_idx([[:space:]]|;|$)'
  'view|app.published_scholarships|CREATE[[:space:]]+VIEW[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?app[.]published_scholarships([[:space:]]|;|$)'
  'function|app.current_synthetic_admin|CREATE[[:space:]]+(OR[[:space:]]+REPLACE[[:space:]]+)?FUNCTION[[:space:]]+app[.]current_synthetic_admin[[:space:]]*[(]'
  'table|app.audit_events|CREATE[[:space:]]+TABLE[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?app[.]audit_events[[:space:]]*[(]'
  'function|app.record_scholarship_insert|CREATE[[:space:]]+(OR[[:space:]]+REPLACE[[:space:]]+)?FUNCTION[[:space:]]+app[.]record_scholarship_insert[[:space:]]*[(]'
  'trigger|app.scholarships_insert_audit|CREATE[[:space:]]+TRIGGER[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?scholarships_insert_audit([[:space:]]|;|$)'
  'policy|synthetic_student_self_read|CREATE[[:space:]]+POLICY[[:space:]]+synthetic_student_self_read[[:space:]]+ON[[:space:]]+app[.]students([[:space:]]|;|$)'
  'policy|synthetic_rls_probe_denied|CREATE[[:space:]]+POLICY[[:space:]]+synthetic_rls_probe_denied[[:space:]]+ON[[:space:]]+app[.]students([[:space:]]|;|$)'
  'policy|synthetic_public_scholarship_read|CREATE[[:space:]]+POLICY[[:space:]]+synthetic_public_scholarship_read[[:space:]]+ON[[:space:]]+app[.]scholarships([[:space:]]|;|$)'
  'policy|synthetic_admin_only_audit|CREATE[[:space:]]+POLICY[[:space:]]+synthetic_admin_only_audit[[:space:]]+ON[[:space:]]+app[.]audit_events([[:space:]]|;|$)'
)
printf '%s\n' "${expected_objects[@]}" > "$WORK_DIR/expected-objects.txt"

extract_diagnostic() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    printf 'none'
    return
  fi
  # Keep only diagnostic words; never emit connection strings or raw output.
  tr '\n' ' ' < "$file" | sed -E 's/[[:space:]]+/ /g; s/[^[:alnum:]_.: -]//g' | cut -c1-400
}

record_object_inventory() {
  local label="$1"
  local target="$2"
  local object_type object_name definition_pattern
  : > "$RESULT_DIR/${label}-objects.tsv"
  while IFS='|' read -r object_type object_name definition_pattern; do
    if [[ -f "$target" ]]; then
      if grep -Eiq "$definition_pattern" "$target"; then printf '%s|%s|present\n' "$object_type" "$object_name" >> "$RESULT_DIR/${label}-objects.tsv"; else printf '%s|%s|missing\n' "$object_type" "$object_name" >> "$RESULT_DIR/${label}-objects.tsv"; fi
    elif [[ -d "$target" ]]; then
      if grep -RIlEq "$definition_pattern" "$target" >/dev/null 2>&1; then printf '%s|%s|present\n' "$object_type" "$object_name" >> "$RESULT_DIR/${label}-objects.tsv"; else printf '%s|%s|missing\n' "$object_type" "$object_name" >> "$RESULT_DIR/${label}-objects.tsv"; fi
    else
      printf '%s|%s|missing\n' "$object_type" "$object_name" >> "$RESULT_DIR/${label}-objects.tsv"
    fi
  done < "$WORK_DIR/expected-objects.txt"
}

scan_data_exclusion() {
  local target="$1"
  local data_pattern='^[[:space:]]*(COPY|INSERT[[:space:]]+INTO)([[:space:]]|$)|student@example[.]invalid|admin@example[.]invalid|Synthetic Student|Synthetic Administrator|Synthetic Scholarship'
  if [[ -f "$target" && -s "$target" ]]; then
    if grep -Eiq "$data_pattern" "$target"; then printf 'FAIL'; else printf 'PASS'; fi
  elif [[ -d "$target" ]] && find "$target" -type f -size +0c -print -quit | grep -q .; then
    if grep -RIlEq "$data_pattern" "$target" >/dev/null 2>&1; then printf 'FAIL'; else printf 'PASS'; fi
  else
    printf 'NOT TESTED'
  fi
}

pg_dump_output="$WORK_DIR/restricted-schema.sql"
set +e
PGPASSWORD="$RESTRICTED_PASSWORD" "$PG_DUMP_BIN" --schema-only --schema=app --file="$pg_dump_output" "$restricted_uri" >"$WORK_DIR/pg_dump.stdout" 2>"$WORK_DIR/pg_dump.stderr"
pg_dump_exit=$?
set -e
pg_dump_status='FAIL'
if [[ "$pg_dump_exit" -eq 0 && -s "$pg_dump_output" ]]; then pg_dump_status='PASS'; fi
pg_dump_stdout_diagnostic="$(extract_diagnostic "$WORK_DIR/pg_dump.stdout")"
pg_dump_stderr_diagnostic="$(extract_diagnostic "$WORK_DIR/pg_dump.stderr")"
pg_dump_object_count='0'
if [[ -s "$pg_dump_output" ]]; then pg_dump_object_count="$(grep -Ec '^[[:space:]]*CREATE[[:space:]]+(TABLE|SEQUENCE|INDEX|VIEW|FUNCTION|TRIGGER|POLICY)' "$pg_dump_output" || true)"; fi
pg_dump_data_statements="$(scan_data_exclusion "$pg_dump_output")"
record_object_inventory 'pg-dump' "$pg_dump_output"

pg_delta_output="$WORK_DIR/declarative"
set +e
"$SUPABASE_BIN" db schema declarative generate \
  --db-url "$restricted_uri" \
  --schema app \
  --output-dir "$pg_delta_output" \
  --strict-coverage --experimental \
  >"$WORK_DIR/pg_delta.stdout" 2>"$WORK_DIR/pg_delta.stderr"
pg_delta_exit=$?
set -e
pg_delta_nonempty_files='0'
if [[ -d "$pg_delta_output" ]]; then pg_delta_nonempty_files="$(find "$pg_delta_output" -type f -size +0c | wc -l | tr -d ' ')"; fi
pg_delta_status='FAIL'
if [[ "$pg_delta_exit" -eq 0 && "$pg_delta_nonempty_files" -gt 0 ]]; then pg_delta_status='PASS'; fi
pg_delta_stdout_diagnostic="$(extract_diagnostic "$WORK_DIR/pg_delta.stdout")"
pg_delta_stderr_diagnostic="$(extract_diagnostic "$WORK_DIR/pg_delta.stderr")"
pg_delta_object_count='0'
if [[ -d "$pg_delta_output" ]]; then pg_delta_object_count="$(find "$pg_delta_output" -type f | wc -l | tr -d ' ')"; fi
pg_delta_data_statements="$(scan_data_exclusion "$pg_delta_output")"
record_object_inventory 'pg-delta' "$pg_delta_output"

# Each denial test has its own SQLSTATE assertion. Connection failures, syntax
# errors, and missing-object errors are failures, never passes.
run_forbidden() {
  local label="$1"
  local sql="$2"
  local expected_sqlstate="$3"
  local key
  key="$(printf '%s' "$label" | tr '[:upper:] ' '[:lower:]_')"
  local stderr_file="$WORK_DIR/forbidden-${key}.stderr"
  local stdout_file="$WORK_DIR/forbidden-${key}.stdout"
  local observed_sqlstate='none'
  local result='FAIL'
  local reason='command_or_connection_failure'
  set +e
  run_restricted -v VERBOSITY=verbose -Atc "$sql" >"$stdout_file" 2>"$stderr_file"
  local exit_code=$?
  set -e
  observed_sqlstate="$(grep -Eo 'ERROR:[[:space:]]+[0-9A-Z]{5}:' "$stderr_file" | head -n1 | grep -Eo '[0-9A-Z]{5}' || true)"
  if [[ "$exit_code" -eq 0 ]]; then
    reason='unexpected_success'
  elif [[ "$observed_sqlstate" == '42P01' || "$observed_sqlstate" == '42601' ]]; then
    reason='missing_object_or_syntax_error'
  elif [[ "$observed_sqlstate" == "$expected_sqlstate" ]]; then
    result='PASS'
    reason='expected_privilege_denial'
  else
    reason='unexpected_sqlstate_or_connection_failure'
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$result" "$expected_sqlstate" "${observed_sqlstate:-none}" "$exit_code" "$reason" >> "$RESULT_DIR/forbidden-results.tsv"
}

: > "$RESULT_DIR/forbidden-results.tsv"
run_forbidden 'SELECT synthetic application records' "SELECT display_name FROM app.students LIMIT 1" '42501'
run_forbidden 'INSERT application records' "INSERT INTO app.students(display_name, fabricated_email) VALUES ('forbidden','forbidden@example.invalid')" '42501'
run_forbidden 'UPDATE application records' "UPDATE app.students SET display_name='forbidden' WHERE id=1" '42501'
run_forbidden 'DELETE application records' "DELETE FROM app.students WHERE id=1" '42501'
run_forbidden 'CREATE TABLE' "CREATE TABLE app.forbidden_table(id integer)" '42501'
run_forbidden 'ALTER TABLE' "ALTER TABLE app.students ADD COLUMN forbidden integer" '42501'
run_forbidden 'CREATE FUNCTION' "CREATE FUNCTION app.forbidden_function() RETURNS integer LANGUAGE sql AS 'SELECT 1'" '42501'
run_forbidden 'Change privileges' "GRANT SELECT ON app.students TO restricted_extractor" '42501'
run_forbidden 'Assume elevated role' "SET ROLE app_owner" '42501'

forbidden_passes="$(awk -F'\t' '$2 == "PASS" {count++} END {print count+0}' "$RESULT_DIR/forbidden-results.tsv")"
forbidden_total="$(wc -l < "$RESULT_DIR/forbidden-results.tsv" | tr -d ' ')"

cat > "$RESULT_DIR/summary.md" <<EOF
# Phase 2.1.8.1 Synthetic Extraction Correction Results

This artifact contains sanitized results only. The database was synthetic and temporary. No Supabase project, production/staging URL, or repository secret was used.

## Connection and RLS separation

| Check | Result | Evidence |
|---|---|---|
| Restricted identity connection | $restricted_connection_status | Identity/database: restricted_extractor/synthetic; exit: $restricted_connection_exit |
| RLS probe has SELECT privilege | $rls_select_privilege | Checked independently for rls_probe |
| RLS probe sees protected rows | $rls_status | rls_probe SELECT exit: $rls_exit; visible rows: $rls_visible_rows |
| Separate owner maintenance operation | $owner_test | Synthetic owner-only create/drop test |
| Role attributes asserted | $role_attributes_status | $(tr '\n' ';' < "$WORK_DIR/role-attributes.txt") |
| Role memberships asserted | $role_memberships_status | $(if [[ -s "$WORK_DIR/role-memberships.txt" ]]; then tr '\n' ';' < "$WORK_DIR/role-memberships.txt"; else printf 'none'; fi) |
| Effective restricted privileges asserted | $effective_grants_status | $(cat "$WORK_DIR/effective-grants.txt") |
| New-table default privileges | $default_privilege_status | restricted_extractor privileges: $default_privilege_effective; create exit: $default_privilege_create_exit; drop exit: $default_privilege_drop_exit |

## Extraction validation

| Capability | Result | Evidence |
|---|---|---|
| pg_dump schema-only extraction | $pg_dump_status | Exit: $pg_dump_exit; object statements: $pg_dump_object_count; stdout: $pg_dump_stdout_diagnostic; stderr: $pg_dump_stderr_diagnostic |
| pg_dump contains no data statements or fabricated values | $pg_dump_data_statements | Output scan |
| pg-delta declarative generation | $pg_delta_status | Exit: $pg_delta_exit; files: $pg_delta_object_count; stdout: $pg_delta_stdout_diagnostic; stderr: $pg_delta_stderr_diagnostic |
| pg-delta contains no data statements or fabricated values | $pg_delta_data_statements | Output scan |

Expected object presence is recorded separately for each method. Missing objects remain missing; successful exit does not imply complete extraction.

### pg_dump expected-object inventory

| Type | Object | Definition status |
|---|---|---|
$(awk -F'|' '{printf "| `%s` | `%s` | %s |\n", $1, $2, $3}' "$RESULT_DIR/pg-dump-objects.tsv")

### pg-delta expected-object inventory

| Type | Object | Definition status |
|---|---|---|
$(awk -F'|' '{printf "| `%s` | `%s` | %s |\n", $1, $2, $3}' "$RESULT_DIR/pg-delta-objects.tsv")

## Restricted forbidden-operation tests

Each row was run after a successful restricted-identity connection. A PASS requires the expected privilege-denial SQLSTATE `42501`; connection failures, syntax errors, missing-object errors, unexpected success, and other SQLSTATEs are failures.

| Operation | Result | Expected SQLSTATE | Observed SQLSTATE | Exit | Classification |
|---|---|---:|---:|---:|---|
$(awk -F'\t' '{printf "| %s | %s | `%s` | `%s` | %s | %s |\n", $1, $2, $3, ($4 == "" ? "none" : $4), $5, $6}' "$RESULT_DIR/forbidden-results.tsv")

**Forbidden-operation aggregate:** $forbidden_passes/$forbidden_total passed the explicit denial assertion.

## Interpretation

This experiment distinguishes missing object privileges from RLS. The restricted role has no application-table SELECT, so its SELECT failure is a privilege test. The separate `rls_probe` role has SELECT privilege but is denied all rows by an RLS policy, demonstrating RLS independently. Review warnings, SQLSTATEs, expected-object inventories, and omitted/unsupported objects before classifying a method as suitable for future restricted extraction.
EOF

validation_failed=0
for status in "$role_attributes_status" "$role_memberships_status" "$effective_grants_status" "$default_privilege_status"; do
  if [[ "$status" != 'PASS' ]]; then validation_failed=1; fi
done

# Keep only the sanitized report and inventories for the short-lived artifact.
rm -rf "$WORK_DIR" "$RESULT_DIR/forbidden-results.tsv"
if [[ "$validation_failed" -ne 0 ]]; then
  exit 1
fi
