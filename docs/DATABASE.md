# JJ Media ERP — Database Reference

Authoritative backend: **Supabase / PostgreSQL**. All money is `NUMERIC`
(never floating point), all identifiers are UUIDs (except the append-only audit
ledger, which uses a monotonic `bigint` identity for reliable ordering), and all
timestamps are `timestamptz`.

---

## 1. Entity map

| Area | Tables |
| ---- | ------ |
| Configuration | `company_settings` (singleton), `gst_rates`, `role_permissions`, `document_sequences` |
| Identity | `user_profiles` (1:1 with `auth.users`) |
| CRM | `clients` |
| Production | `projects` |
| Commercial | `quotations`, `quotation_line_items` |
| Billing | `invoices`, `invoice_line_items`, `credit_notes`, `credit_note_line_items` |
| Collections | `payments` |
| Cost | `expenses`, `expense_categories` |
| Media assets | `hdds`, `hdd_locations`, `hdd_assignments`, `hdd_logs` |
| Files | `attachments` |
| Audit | `audit_logs` |
| Reporting | `v_invoice_financials`, `v_receivables_aging`, `v_client_financials`, `v_project_profitability`, `v_revenue_monthly`, `v_gst_summary`, `v_expense_summary`, `v_hdd_custody`, `v_project_activity`, `dashboard_metrics()` |

---

## 2. Financial rules enforced by the database

### GST

- Statutory rates only: **0 / 5 / 12 / 18 / 28 %**. Line items carry a foreign
  key to `gst_rates`, so a non-statutory rate is impossible.
- **INTRA_STATE** → CGST + SGST, split so that `cgst + sgst` equals the computed
  tax exactly (CGST is rounded, SGST takes the remainder).
- **INTER_STATE** → IGST.
- The treatment is **derived**, never trusted from the browser:
  `derive_document_tax_type(client, place_of_supply)` compares the place-of-supply
  state code with `company_settings.state_code`.
- Line amounts are computed by trigger
  (`compute_document_line_amounts`): `gross = qty × unit_price`,
  `discount = gross × discount_percent / 100` (or an explicit amount),
  `taxable = gross − discount`, then the GST split.
- Header totals are recomputed from the lines (`recalc_*_totals`); clients cannot
  write them. `grand_total = taxable + tax + round_off`, where round-off is
  applied to the nearest rupee when `company_settings.round_off_enabled`.

### Document numbering

`next_document_number(doc_type, prefix, scope, padding)` performs a single
`INSERT … ON CONFLICT DO UPDATE` that takes a row lock, so concurrent callers
serialise and never share a number. The scope defaults to the Indian financial
year, producing e.g. `INV/2026-27/0001`. `peek_next_document_number()` previews
without consuming. Business codes (`CL-0001`, `PRJ-0001`, `HDD-0001`, `EXP-00001`)
use `next_sequence_code()`.

### Invoice immutability

`invoices_guard_immutability` freezes an **ISSUED** invoice:

- financial columns, dates, client, tax context and number cannot change;
- line items can only be touched while the invoice is a **DRAFT**;
- a non-draft invoice can never be deleted;
- CANCELLED is terminal (a reason is mandatory and `cancelled_by` is stamped);
- the only columns that may still move are the derived collection columns
  (`amount_paid`, `amount_credited`) and the cancellation stamps.

Corrections therefore flow through **credit notes** or **cancellation**.

### Payments

- Lifecycle is `POSTED → VOIDED` (VOIDED is terminal).
- Only **POSTED** payments count towards collection; `refresh_invoice_collections`
  recomputes `amount_paid` from the payment ledger and `amount_credited` from
  issued credit notes, so the invoice can never drift from its sources.
- `payments_validate` locks the invoice row `FOR UPDATE` and rejects
  over-collection, payments against DRAFT/CANCELLED invoices, zero or negative
  amounts and payments attributed to a different client than the invoice.
- Posted payments are immutable (amount, invoice, client, method and dates are
  frozen); a receipt may only be produced for a POSTED payment
  (`payment_receipt_allowed`).

### Credit notes

- `DRAFT → ISSUED → CANCELLED`; ISSUED is immutable.
- A credit note can only target a non-draft invoice, must carry a reason, at
  least one line item, and the sum of issued credit notes for an invoice may
  never exceed the invoice value.

### Expenses

- `DRAFT → APPROVED → VOID`; approved expenses are frozen except for voiding,
  which requires a reason.
- GST comes from the vendor state and the expense's rate, with an
  ITC-eligibility flag.
- Only **APPROVED** expenses count as cost in profitability.

---

## 3. HDD custody

```
hdds.status: AVAILABLE | CHECKED_OUT | IN_TRANSIT | MAINTENANCE | ARCHIVED
hdd_assignments.status: ACTIVE | RETURNED | CANCELLED
```

- A partial unique index (`hdd_assignments_one_active_per_hdd`) guarantees at most
  **one ACTIVE assignment per drive**.
- `checkout_hdd()` locks the drive row, requires `AVAILABLE`, refuses a drive
  under maintenance/archived, and writes both the assignment and a custody log.
- `checkin_hdd()` closes the assignment, stamps the return condition and routes
  the drive to `AVAILABLE` or `MAINTENANCE` (damaged/failing condition).
- `transfer_hdd_location()`, `set_hdd_maintenance()`, `archive_hdd()` write
  custody events; `hdds_guard_status()` prevents a manual `CHECKED_OUT`/
  `AVAILABLE` flip that would desynchronise custody.
- Overdue detection is exposed by `v_hdd_custody` (`is_overdue`, `days_overdue`).
- A project with an active assignment cannot be marked COMPLETED.

---

## 4. Authorisation

### Roles

`ADMIN`, `MANAGER`, `FINANCE`, `PRODUCTION`, `VIEWER` — stored in
`public.user_profiles.role`, resolved server-side by `app_current_user_role()`.

### Permission matrix

`public.role_permissions` maps roles to permissions such as `clients.create`,
`invoices.issue`, `payments.void`, `hdd.checkout`, `settings.update`,
`users.manage`. The database is the source of truth; the frontend only mirrors it
to decide what to render.

Resolution chain used by every policy and RPC:

```
auth.uid()  →  user_profiles (role, is_active)  →  role_permissions  →  has_permission()
```

A missing or inactive profile resolves to no permissions at all (fail closed).
`require_permission()` raises `insufficient_privilege` inside triggers and RPCs;
when there is no session (migrations, `service_role` jobs) it is a no-op, because
that context is already trusted and never reachable from the browser.

### Privileges

- `anon`: **no** privileges on any `public` table or function.
- `authenticated`: DML privileges filtered by RLS; only application-facing
  functions are executable. Numbering, ledger writers, guard/assertion helpers and
  trigger functions are revoked.
- `service_role`: full access, server-side only.

### RLS notes

- Row Level Security is enabled on **every** business table; a migration-time
  assertion fails the deploy if a new table is added without it.
- `document_sequences` has RLS enabled and **no policies**, so counters are
  unreachable and numbers cannot be burned.
- Reporting views use `security_invoker = true`, so a view can never widen access
  beyond the caller's own policies.
- Column-level protection (for example `user_profiles.role`) is implemented with
  guard triggers, because RLS cannot restrict individual columns.

---

## 5. Audit

`public.audit_logs` (append-only) records inserts/updates/deletes of business
tables through the generic `audit_row_change()` trigger, plus explicit business
events (quotation conversion, payment posting/voiding, HDD checkout/check-in,
role changes, logins). Each row carries actor, action, entity, before/after
snapshots, changed fields, project link, IP and user agent.

Append-only is enforced by statement triggers that reject UPDATE/DELETE unless a
maintenance session explicitly sets `app.allow_audit_maintenance = 'on'`.

`public.hdd_logs` is deliberately separate and also append-only
(`app.allow_hdd_log_maintenance`).

---

## 6. Attachments & storage

`public.attachments` links a Supabase Storage object to a business entity through
the `attachment_entity` enum. Existence of the target row is verified, and
visibility follows the entity's own permission (`can_view_entity` /
`can_write_entity`). When the `storage` schema is present (Supabase), the
migration also provisions the private `erp-attachments` bucket and matching
`storage.objects` policies; on plain PostgreSQL that block is skipped.

---

## 7. Adding a migration

1. Create `supabase/migrations/<timestamp>_<phase>_<name>.sql`.
2. Keep it **additive and idempotent** (`if not exists`, `create or replace`,
   `drop policy if exists … create policy …`).
3. Enable RLS and define policies in the same file as the table — never leave a
   table unprotected between migrations.
4. Add `created_by`/`updated_by` stamping, an `updated_at` trigger, and an audit
   trigger for business tables.
5. Add assertions to a `supabase/tests/*.test.sql` suite.
6. Run `npm run verify` before reporting the phase.
