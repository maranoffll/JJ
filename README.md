# JJ Media ERP

Production-grade ERP for a media production house: clients, projects, quotations,
GST invoicing, payments and reconciliation, expenses, HDD/media-custody tracking,
reporting, printable documents, audit trails and company settings.

**Backend of record: Supabase / PostgreSQL.** Every business number in the
application comes from the database — there is no mock data, no simulated API and
no browser-side persistence of business records.

- Supabase project ref: `zfrgzunauxozqgdjghso`
- Supabase URL: `https://zfrgzunauxozqgdjghso.supabase.co`
- Stack: React + TypeScript + Vite + Tailwind CSS + React Router + Lucide React + `@supabase/supabase-js`

---

## Current status

| Phase | Scope | Status |
| ----- | ----- | ------ |
| **1** | **Database foundation** | **Complete — verified (248 database assertions + 15 concurrency checks)** |
| 2 | Authentication & Supabase client | Not started |
| 3 | RBAC & permissions (UI surface) | Not started |
| 4 | Dashboard | Not started |
| 5 | Clients & CRM | Not started |
| 6 | Projects & production | Not started |
| 7 | Quotations | Not started |
| 8 | Invoices & GST | Not started |
| 9 | Payments & reconciliation | Not started |
| 10 | Expenses | Not started |
| 11 | HDD & media assets | Not started |
| 12 | Reports & profitability | Not started |
| 13 | PDF & print documents | Not started |
| 14 | Audit logs | Not started |
| 15 | Company settings | Not started |
| 16 | Final production hardening | Not started |

Phase 1 delivered the complete, tested database layer that every later phase
builds on. See [`docs/phases/phase-1-database-foundation.md`](docs/phases/phase-1-database-foundation.md)
for the full report and [`docs/DATABASE.md`](docs/DATABASE.md) for the schema,
RLS and business-rule reference.

---

## Repository layout

```
supabase/
  migrations/    Production migrations, applied in filename order
  tests/         Local/CI harness + phase test suites (NEVER applied to production)
scripts/
  db.mjs               Database task runner: migrate / reset / test / verify
  concurrency-test.mjs Race-condition verification on an isolated scratch database
  secret-scan.mjs      Credential scan (fails the build on privileged material)
docs/
  DATABASE.md                 Schema, RLS, numbering, business rules
  phases/                     Per-phase delivery reports
.env.example     Environment template (real values are never committed)
```

---

## Getting started (database work)

```bash
npm install
cp .env.example .env.local          # fill in real values locally; never commit
```

### 1. Point the runner at a PostgreSQL database

Any PostgreSQL 15+ instance works. Two convenient options:

```bash
# a) local Docker instance (matches the defaults in the runner)
npm run db:local:docker

# b) the official Supabase local stack
npx supabase start
```

Then either export `DATABASE_URL`/`SUPABASE_DB_URL` or set `PGHOST`, `PGPORT`,
`PGUSER`, `PGPASSWORD`, `PGDATABASE`.

### 2. Commands

| Command | Purpose |
| ------- | ------- |
| `npm run db:migrate` | Apply `supabase/migrations/*.sql` in order (idempotent) |
| `npm run db:reset` | Drop `public` and re-apply everything — **local only** |
| `npm run db:test` | Apply the full migration set + run every test suite inside **one transaction that is rolled back** |
| `npm run db:concurrency` | Run the race-condition suite on an isolated scratch database that is created and dropped |
| `npm run db:verify` | Read-only verification of schema, RLS, functions, append-only guards |
| `npm run secret:scan` | Scan the tree for credentials, private keys and privileged Supabase keys |
| `npm run verify` | All of the above, in order |

Destructive commands refuse to run against a non-local host unless
`ALLOW_REMOTE_MIGRATIONS=1` is set explicitly.

### 3. Applying migrations to the live Supabase project

```bash
npx supabase link --project-ref zfrgzunauxozqgdjghso
npx supabase db push
```

or, equivalently, apply the files in `supabase/migrations/` in filename order
with `psql "$DATABASE_URL" -f <file>`. Migrations are written to be idempotent
and additive; none of them drop or weaken existing objects.

> `supabase/tests/` contains the **local** Supabase emulation used by the test
> harness. It must never be applied to the live project, where the `auth`
> schema, `auth.uid()` and the `anon`/`authenticated`/`service_role` roles are
> provided by the platform.

### 4. Creating the first ERP user

Public sign-up is disabled (this is an ERP, not a consumer app). Create the first
account in the Supabase dashboard (**Authentication → Users**); the database
trigger promotes the very first account to `ADMIN` and creates its
`public.user_profiles` row. Every later account starts as `VIEWER` and must be
promoted by an admin. Roles are never trusted from the browser.

---

## Security model (summary)

- **RLS on every business table.** `anon` holds *no* table privileges at all;
  `authenticated` holds table privileges that are then filtered by row-level
  security policies; `service_role` is server-side only and its key never ships.
- **Authorization lives in PostgreSQL.** `public.role_permissions` holds the
  role → permission matrix and `public.has_permission()` evaluates it from the
  server-side profile. A role supplied by the browser is ignored.
- **Ledgers are append-only.** `public.audit_logs` (business audit) and
  `public.hdd_logs` (custody history) reject UPDATE/DELETE.
- **Financial documents are protected by the database.** ISSUED invoices are
  immutable, payments can only move POSTED → VOIDED, and document numbers are
  allocated atomically so two users can never receive the same number.
- **Secrets.** Only the publishable Supabase key belongs in frontend code; the
  repository is scanned for privileged material by `npm run secret:scan`.

---

## Phase discipline

Each phase is implemented, tested, fixed, regression-tested, checked for RLS and
RBAC, linted/type-checked/built (once the frontend exists) and only then reported.
A phase is never reported complete on the strength of UI alone.
