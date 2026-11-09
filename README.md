# Scholars private schema extraction

This repository contains a temporary, owner-controlled workflow for preparing a schema-only snapshot of the Scholars production Supabase database. It is separate from the application and documentation repositories. The workflow is not scheduled and is not triggered by pushes, pull requests, forks, or external events. It runs only through `workflow_dispatch` on `main`, requires the operator to type the expected production project reference, and fails before connecting if `SUPABASE_DB_URL` is absent or does not identify that project.

## Owner setup and use

After reviewing `.github/workflows/schema-only.yml`, add a repository secret in **Settings → Secrets and variables → Actions → New repository secret** with the name `SUPABASE_DB_URL`. Enter the production database connection string only in GitHub's secret field; do not put it in this repository, a workflow input, a commit, an issue, or a log, and do not send it through chat. Manus has not created or populated this secret.

When ready, open **Actions → Manual production schema-only extraction → Run workflow**, select `main`, type the production project reference shown in the workflow's required confirmation field, and start the run yourself. The workflow uses the GitHub-hosted `ubuntu-latest` runner and the pinned Supabase CLI `2.122.1` installed through the official `supabase/setup-cli` action pinned to a full commit SHA. It runs only the schema-only `supabase db dump --db-url ... --file scholars-production-schema-only.sql` command. It does not run migrations, DDL, `db push`, imports, row-data exports, or role exports.

## Artifact handling

The SQL file is written under the ephemeral runner's temporary directory, never to the Git workspace. If the run succeeds, it is uploaded only as a private GitHub Actions artifact with a **one-day retention period**, then the runner's temporary copy is removed. Download it only while signed in to this private repository, inspect it locally, and keep any retained copy private. Do not commit it or republish it to Issues, pull requests, public file hosts, or the Updates report. The short retention setting is the shortest supported per-artifact period; delete the artifact sooner after the review if no longer needed.

The dump is schema-only, but it is still sensitive: object names, function bodies, security-definer definitions, grants, and internal configuration may be present. Review it before sharing or using it. The artifact is intended only for the authorized owner.

## Expected exclusions and limits

Supabase documents that the default `db dump` excludes Supabase-managed schemas, including `auth` and `storage`, and schemas created by extensions. The default dump contains no row data and no custom roles. Consequently, customizations within `auth` or `storage`, extension-owned objects, role definitions, Auth/Storage records, and project-level settings may be absent or require separate reconstruction decisions. This workflow deliberately does not query production to compensate for those exclusions, and the dump must not be treated as a complete backup or a complete staging-reconstruction package.

No production or staging database has been connected to by this setup task. The workflow has not been triggered and no database objects have been modified.
