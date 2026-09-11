# Phase 1 — Database Foundation (complete, verified)

**Date:** 2026-09-11
**Scope:** database foundation for the whole ERP — schema, constraints, RLS,
RBAC, numbering, financial engine, audit, reporting foundation.

---

## 1. Discovery (before any change)

| Checked | Finding |
| ------- | ------- |
| `git status` | clean working tree, branch `arena/01a08f46-jj`, single commit `7d29950` |
| `package.json` | **did not exist** |
| `src/`, `supabase/`, services, components, routing | **did not exist** |
| README | 5 bytes containing `# JJ` |
| Other branches / remote repos | `main` identical; the other repos on the account (`Armorinno`, `Moorthysir`) are unrelated projects |
| Live Supabase (`zfrgzunauxozqgdjghso`) | **not reachable from the execution sandbox** (network blocked to `supabase.co`; DNS resolves but TCP is refused). No schema could be inspected, and nothing was applied to it. |

**Conclusion:** the connected repository contained no implementation, so there was
nothing to preserve or rebuild. Phase 1 was therefore built from the ground up
against the specification, on the migration set below.

> The live project was **not** modified in any way. The user must apply the
> migrations from an environment with network access to Supabase
> (`npx supabase link --project-ref zfrgzunauxozqgdjghso && npx supabase db push`)
> and then run `npm run db:verify` against it to confirm the live schema.

---

## 2. Migrations added (`supabase/migrations/`)

| # | File | Contents |
| - | ---- | -------- |
| 00 | `20260911090000_phase1_00_extensions_and_enums.sql` | `pg_trgm`, prerequisite roles (no-op on Supabase), 14 domain enums (`user_role`, `tax_type`, `client_status`, `project_status`, `quotation_status`, `invoice_status`, `credit_note_status`, `payment_status`, `payment_method`, `expense_status`, `hdd_status`, `hdd_assignment_status`, `hdd_event_type`, `attachment_entity`, `audit_action`) |
| 01 | `20260911090100_phase1_01_core_helpers.sql` | `set_updated_at`, money rounding, GST split, financial-year label, GSTIN/PAN validation, safe `inet` cast, amount-in-words (Indian system) |
| 02 | `20260911090200_phase1_02_identity_and_audit.sql` | `user_profiles`, identity helpers (`app_current_user_role`, `has_role`, `has_permission`, `is_admin`), `role_permissions` matrix, signup bootstrap trigger, `audit_logs` + append-only guards + `write_audit_log`, generic `audit_row_change` |
| 03 | `20260911090300_phase1_03_numbering_and_rbac.sql` | actor stamping, `document_sequences`, concurrency-safe `next_document_number` / `peek_next_document_number` / `next_sequence_code`, full role→permission seed, `require_permission` / `require_role` |
| 04 | `20260911090400_phase1_04_company_settings.sql` | `gst_rates` (0/5/12/18/28), singleton `company_settings`, `resolve_tax_type`, `effective_gst_rate`, RLS |
| 05 | `20260911090500_phase1_05_clients.sql` | `clients` (+ soft delete guard, auto client code, trgm search index), `client_tax_type`, `derive_document_tax_type`, RLS |
| 06 | `20260911090600_phase1_06_projects.sql` | `projects` (lifecycle guard, completion blocked while media is out, soft delete), RLS |
| 07 | `20260911090700_phase1_07_quotations.sql` | `quotations` + line items, line money engine, header recalculation, lifecycle state machine, numbering, RLS |
| 08 | `20260911090800_phase1_08_invoices.sql` | `invoices` + line items, issue requirements, **immutability**, derived collection refresh, quotation→invoice conversion, RLS |
| 09 | `20260911090900_phase1_09_credit_notes.sql` | `credit_notes` + line items, issue validation (lines, reason, value cap), immutability, RLS |
| 10 | `20260911091000_phase1_10_payments.sql` | `payments` with POSTED/VOIDED lifecycle, over-collection guard with row lock, `post_payment`, `void_payment`, `payment_receipt_allowed`, RLS |
| 11 | `20260911091100_phase1_11_expenses.sql` | `expense_categories` (seeded), `expenses` (GST split, DRAFT→APPROVED→VOID, immutability), RLS |
| 12 | `20260911091200_phase1_12_hdd.sql` | `hdd_locations`, `hdds`, `hdd_assignments` (one ACTIVE per drive), append-only `hdd_logs`, `checkout_hdd`, `checkin_hdd`, `transfer_hdd_location`, `set_hdd_maintenance`, `archive_hdd`, RLS |
| 13 | `20260911091300_phase1_13_attachments.sql` | entity view/write permission helpers, `attachments`, Supabase Storage bucket + `storage.objects` policies (skipped on plain PostgreSQL), RLS |
| 14 | `20260911091400_phase1_14_reporting_views.sql` | `v_invoice_financials`, `v_receivables_aging`, `v_client_financials`, `v_project_profitability`, `v_revenue_monthly`, `v_gst_summary`, `v_expense_summary`, `v_hdd_custody`, `v_project_activity`, `dashboard_metrics()` |
| 15 | `20260911091500_phase1_15_grants_and_hardening.sql` | privileges (anon revoked entirely), function-exposure rules, `user_profiles` policies + field guards, `role_permissions`/`audit_logs`/`document_sequences` RLS, `record_login`, `set_user_role`, `set_user_active`, `bootstrap_company_settings`, deploy-time assertions |

Supporting (non-migration) assets:

- `supabase/tests/00_local_supabase_stub.sql` — local emulation of the
  Supabase-managed `auth` schema and roles (never applied to production).
- `supabase/tests/00_test_harness.sql` — assertion framework and result reporting.
- `scripts/db.mjs` — migrate / reset / test / verify runner with a
  non-local-host safety guard.
- `scripts/concurrency-test.mjs` — isolated scratch-database race-condition suite.
- `scripts/secret-scan.mjs` — credential scan.
- `package.json`, `.gitignore`, `.env.example`, `README.md`, `docs/DATABASE.md`.

---

## 3. Bugs found and fixed during verification

Verification was not cosmetic — the suites caught real defects:

1. **`amount_in_words` produced wrong output** (ignored the hundreds digit and
   mangled crore values). Rewritten with `_integer_words` / `_two_digit_words`.
2. **CHECK constraints were unusable for application roles** —
   `is_valid_gstin`/`is_valid_pan` had had their `EXECUTE` revoked, so every client
   insert by an authenticated user failed. The grant strategy is now rule-based:
   all functions except trigger functions and a small internal list are executable
   by `authenticated`.
3. **`next_document_number` raised "column reference scope_key is ambiguous"** —
   the OUT parameter collided with the `ON CONFLICT` target; switched to
   `ON CONFLICT ON CONSTRAINT`.
4. **`credit_notes` has no `total_amount` column** — two call sites referenced it;
   corrected to `grand_total` (this silently broke credit-note accounting).
5. **Tax treatment was trusted from the client** on quotations; a supplied
   `tax_type` survived. Documents now recompute place of supply and `tax_type`
   from master data on every write.
6. **Quotation state machine was inconsistent** — conversion allowed
   `SENT → CONVERTED` but the guard rejected it.
7. **Credit notes could be created directly in `ISSUED` state** with no line items
   and an unbounded value; issue validation is now shared by INSERT and UPDATE.
8. **`convert_quotation_to_invoice(..., p_issue => true)` was broken** — it
   inserted an ISSUED invoice before its lines existed; it now creates a draft,
   adds the lines, then issues through the standard path.
9. **Expenses created directly as APPROVED** violated the approved-consistency
   constraint; the guard now stamps `approved_at`/`approved_by` on INSERT.
10. **Statement-level append-only triggers referenced `NEW`/`OLD`**, which is not
    valid for statement triggers.
11. **Test-suite isolation**: JWT claims leaked between suites; the harness now
    resets role and claims at the start of every suite.

---

## 4. Verification executed

All commands were run against a real PostgreSQL 18.4 instance.

### `npm run db:test` — 248 assertions, 0 failures

| Suite | Assertions |
| ----- | ---------- |
| phase1: schema & helpers | 39 / 39 |
| phase1: financial engine | 92 / 92 |
| phase1: rls & rbac | 38 / 38 |
| phase1: hdd & attachments | 35 / 35 |
| phase1: reporting views | 44 / 44 |

Covers: enum catalogue, helper determinism, statutory rate enforcement,
GSTIN/PAN validation, numbering format and increment, audit append-only,
intra/inter-state GST, discount and round-off arithmetic, invoice immutability
(7 distinct attack paths), payment lifecycle, over-collection, credit-note caps,
expense workflow, HDD custody state machine, overdue detection, attachment
scoping, RLS for `anon`/no-session/VIEWER/MANAGER/FINANCE/PRODUCTION/deactivated
users, role-escalation and forged-claim attempts, internal-function exposure,
reporting-view arithmetic and dashboard aggregates.

### `npm run db:concurrency` — 15 checks, 0 failures

| Scenario | Result |
| -------- | ------ |
| 24 parallel document-number allocations | 24 distinct numbers, no duplicates |
| 6 parallel quotation→invoice conversions | exactly 1 succeeded, 1 invoice created |
| 24 parallel payments of ₹1,000 against a ₹11,800 invoice | 11 accepted, 13 rejected, collected 0 ≤ total, ledger matches invoice |
| 8 parallel checkouts of one drive | exactly 1 succeeded, exactly 1 ACTIVE assignment |
| 6 parallel issues of one draft invoice | exactly 1 winner, single issue timestamp |

### `npm run db:verify` — 6 checks, 0 failures

Tables present · RLS enabled on all business tables · 58 RLS policies ·
required functions present · numbering table unreachable from the client ·
audit append-only triggers installed.

### `npm run secret:scan`

31 files scanned — **no secrets, private keys or privileged credentials**. The
scanner enforces that `service_role` material, `sb_secret_…` keys, inline database
passwords, JWTs and committed `.env` files never enter the repository.

### Not applicable yet

`npx tsc --noEmit`, `npm run lint`, `npm run build` — no frontend exists until
Phase 2. They become part of the per-phase gate from then on.

---

## 5. Design decisions worth recording

- **Append-only audit is enforced for everyone**, including admins, unless a
  maintenance session sets `app.allow_audit_maintenance = 'on'`.
- **`service_role`/no-session contexts are trusted** by `require_permission`, while
  any real user session is fully checked — this keeps RLS meaningful without
  breaking server-side jobs.
- **Company settings are not seeded with placeholder data.** The singleton is
  created by an admin through `bootstrap_company_settings()`; helper functions
  fall back to safe defaults until then, so no fake company details exist.
- **Public sign-up is disabled.** The first account created (dashboard or admin
  API) becomes ADMIN automatically via trigger; later accounts start as VIEWER.
- **No hard deletes for financial data.** Clients/projects soft-delete with a
  permission check; invoices/payments/expenses/credit notes can only be
  cancelled/voided and remain auditable.
- **RLS is not `FORCE`d**, so the table owner (migrations, `SECURITY DEFINER`
  functions) is not blocked, while every application role remains fully
  constrained — including via views (`security_invoker`).

---

## 6. Remaining issues / caveats

1. **Live Supabase schema was never inspected** (sandbox cannot reach
   `supabase.co`). Phase 1 is verified against a real PostgreSQL 18.4 instance
   running the exact production migration set, including the Supabase-specific
   storage block being skipped. After `supabase db push`, run `npm run db:verify`
   with `DATABASE_URL` set to the live project to confirm parity.
2. **Migrations are pre-release**: nothing has been applied to the live project,
   so these files are the initial revision. Once deployed, they must be treated as
   immutable and only extended by new migrations.
3. **`hdds.status = IN_TRANSIT`** exists in the enum and state machine but no
   transfer workflow writes it yet; it will be wired in Phase 11 (HDD module).
4. **Reconciliation columns** (bank-statement matching) are intentionally deferred
   to Phase 9.
5. **The frontend does not exist yet** — Phases 2 onward will add it on top of
   this schema.

---

## 7. Next

**Phase 2 — Authentication & Supabase client**: Vite/React/TypeScript project
scaffold, Supabase client with publishable-key-only configuration, session
handling, login/logout, protected routing and the app shell. It builds directly on
`public.user_profiles`, `record_login()` and the permission matrix delivered here.
