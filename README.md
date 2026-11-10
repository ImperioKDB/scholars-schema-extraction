# Scholars private schema extraction

**Status: HOLD — do not create or populate `SUPABASE_DB_URL`, and do not run this workflow.** The A0.8.2 security review found that the current workflow does not enforce a read-only database role and its project-reference substring check does not verify the actual endpoint or login role. The workflow YAML is unchanged. Wait for owner review and a separately authorized next stage.

See the [A0.8.2 security refinement report](https://github.com/ImperioKDB/Updates/blob/main/SCHOLARS_A0_8_2_EXTRACTION_WORKFLOW_SECURITY_REFINEMENT_2026-11.md) for the evidence and GO/NO-GO rationale. This notice supersedes A0.8.1 setup guidance that suggested adding the secret and manually starting a run.

## Current workflow scope

The workflow is separate from the Scholars application repository and runs only through `workflow_dispatch` on `main`. It pins the Supabase CLI and actions, uses no checkout, and runs the default `supabase db dump` command. Supabase documents that this command emits schema definitions by default, not row data or custom roles, and excludes managed schemas including `auth`, `storage`, and extension-created schemas. These output limits do not make the supplied database credential read-only.

The existing typed project-reference confirmation is not endpoint verification. The workflow currently tests whether the secret string contains the expected reference; it does not compare the exact host, port, database name, or username, and it does not inspect effective PostgreSQL privileges. Do not rely on that check as proof that the connection reaches production or is safe to use.

## Requirements before any future run

Do not add `SUPABASE_DB_URL` until the owner has reviewed and explicitly approved a revised design. At minimum, that design must:

- use a provider-enforced read-only source if preventing database writes is required, preferably a Supabase Read Replica where available, and account for asynchronous replication lag;
- use a dedicated non-owner login with no privileged role attributes or memberships, no direct application-table `SELECT`, and no indirect row-exposing access paths;
- demonstrate in a disposable non-production database that the pinned CLI can complete a schema-only dump with the proposed least privileges, without granting broad production access;
- validate the parsed host, port, database, and username against values copied from the intended production source’s Dashboard connection panel before any database connection; never print the secret; and require TLS server verification;
- confirm the private repository’s current reader and writer access, keep artifact retention at one day or less, and keep any generated artifact private.

No production or staging database connection, query, role change, secret inspection, workflow run, or artifact generation was performed for A0.8.2. Do not add data-only or role-only exports, import an artifact to staging, or deploy the Scholars application under this workflow.
