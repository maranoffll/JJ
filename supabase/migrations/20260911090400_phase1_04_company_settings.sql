-- ============================================================================
-- JJ MEDIA ERP — PHASE 1 : DATABASE FOUNDATION
-- Migration 04 : company settings, statutory GST rate catalogue, tax helpers
-- ============================================================================

-- ---------------------------------------------------------------------------
-- GST rate catalogue. Line items reference this table, so an invoice can only
-- ever carry a statutory rate (0 / 5 / 12 / 18 / 28).
-- ---------------------------------------------------------------------------
create table if not exists public.gst_rates (
  rate        numeric(5,2) primary key,
  label       text not null,
  description text,
  is_active   boolean not null default true,
  sort_order  int not null default 0,
  constraint gst_rates_statutory check (rate in (0, 5, 12, 18, 28))
);

comment on table public.gst_rates is
  'Statutory GST rate catalogue (0/5/12/18/28). Line items FK to this table.';

insert into public.gst_rates (rate, label, description, sort_order) values
  (0,  '0%',  'Nil rated / exempt',      1),
  (5,  '5%',  'Lower rate',              2),
  (12, '12%', 'Standard lower rate',     3),
  (18, '18%', 'Standard rate',           4),
  (28, '28%', 'Higher rate',             5)
on conflict (rate) do nothing;

-- ---------------------------------------------------------------------------
-- company_settings — a single row enforced by a unique index on a constant.
-- ADMIN-only mutation is enforced by RLS (see the policies at the end).
-- ---------------------------------------------------------------------------
create table if not exists public.company_settings (
  id                       uuid primary key default gen_random_uuid(),

  -- identity
  legal_name               text not null,
  display_name             text not null,
  tagline                  text,

  -- registered address
  address_line1            text,
  address_line2            text,
  city                     text,
  state                    text,
  state_code               char(2),
  pincode                  text,
  country                  text not null default 'India',

  -- statutory
  gstin                    text,
  pan                      text,
  is_gst_registered        boolean not null default true,
  cin                      text,
  hsn_sac_default          text,

  -- contact
  phone                    text,
  email                    text,
  website                  text,

  -- branding
  logo_url                 text,
  signature_url            text,
  brand_primary_color      text default '#0F172A',

  -- banking
  bank_name                text,
  bank_account_name        text,
  bank_account_number      text,
  bank_ifsc                text,
  bank_branch              text,
  upi_id                   text,

  -- document defaults
  invoice_prefix           text not null default 'INV',
  quotation_prefix         text not null default 'QT',
  credit_note_prefix       text not null default 'CN',
  payment_prefix           text not null default 'RCPT',
  default_gst_rate         numeric(5,2) not null default 18 references public.gst_rates (rate),
  default_tax_type         public.tax_type not null default 'INTRA_STATE',
  round_off_enabled        boolean not null default true,
  quotation_validity_days  int not null default 15,
  payment_terms_days       int not null default 30,
  fiscal_year_start_month  int not null default 4,
  currency_code            char(3) not null default 'INR',

  -- boilerplate
  invoice_terms            text,
  quotation_terms          text,
  invoice_notes            text,
  payment_terms_text       text,

  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  created_by               uuid,
  updated_by               uuid,

  constraint company_settings_legal_name_not_blank check (length(btrim(legal_name)) > 0),
  constraint company_settings_display_name_not_blank check (length(btrim(display_name)) > 0),
  constraint company_settings_state_code_format check (state_code is null or state_code ~ '^[0-9]{2}$'),
  constraint company_settings_gstin_format check (gstin is null or public.is_valid_gstin(gstin)),
  constraint company_settings_pan_format check (pan is null or public.is_valid_pan(pan)),
  constraint company_settings_email_format check (email is null or email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  constraint company_settings_fiscal_month_range check (fiscal_year_start_month between 1 and 12),
  constraint company_settings_validity_days_range check (quotation_validity_days between 0 and 365),
  constraint company_settings_payment_terms_range check (payment_terms_days between 0 and 365),
  constraint company_settings_ifsc_format check (bank_ifsc is null or bank_ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$')
);

-- Exactly one settings row.
create unique index if not exists company_settings_singleton_idx on public.company_settings ((true));

comment on table public.company_settings is
  'Singleton company configuration used by documents, GST logic and reports. Mutation is ADMIN-only.';

drop trigger if exists company_settings_set_updated_at on public.company_settings;
create trigger company_settings_set_updated_at
  before update on public.company_settings
  for each row execute function public.set_updated_at();

drop trigger if exists company_settings_stamp_actor on public.company_settings;
create trigger company_settings_stamp_actor
  before insert or update on public.company_settings
  for each row execute function public.stamp_actor_columns();

drop trigger if exists company_settings_audit on public.company_settings;
create trigger company_settings_audit
  after insert or update or delete on public.company_settings
  for each row execute function public.audit_row_change();

-- ---------------------------------------------------------------------------
-- Settings accessor. SECURITY DEFINER so GST calculations can read the
-- company's state code regardless of the caller's row-level permissions.
-- ---------------------------------------------------------------------------
create or replace function public.company_settings_row()
returns public.company_settings
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select * from public.company_settings limit 1;
$$;

comment on function public.company_settings_row() is
  'Returns the singleton company settings row (or an empty row set when unseeded).';

-- ---------------------------------------------------------------------------
-- Place of supply resolution: intra-state when the party's state code matches
-- the company's state code, otherwise inter-state. Falls back to the company
-- default when the party has no state code recorded.
-- ---------------------------------------------------------------------------
create or replace function public.resolve_tax_type(p_party_state_code text)
returns public.tax_type
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select case
    when coalesce(cs.state_code, '') = '' then cs.default_tax_type
    when coalesce(nullif(btrim(p_party_state_code), ''), '') = '' then cs.default_tax_type
    when btrim(p_party_state_code) = cs.state_code then 'INTRA_STATE'::public.tax_type
    else 'INTER_STATE'::public.tax_type
  end
  from public.company_settings cs
  limit 1;
$$;

comment on function public.resolve_tax_type(text) is
  'Derives INTRA_STATE/INTER_STATE by comparing the party state code with the company state code.';

-- Legacy-safe fallback so documents can be created before settings are seeded.
create or replace function public.effective_tax_type(p_explicit public.tax_type, p_party_state_code text)
returns public.tax_type
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select coalesce(p_explicit, public.resolve_tax_type(p_party_state_code), 'INTRA_STATE'::public.tax_type);
$$;

create or replace function public.effective_gst_rate(p_explicit numeric)
returns numeric
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select coalesce(
    p_explicit,
    (select cs.default_gst_rate from public.company_settings cs limit 1),
    18::numeric
  );
$$;

-- ---------------------------------------------------------------------------
-- RLS: every active ERP user may read settings (needed to render documents),
-- only ADMIN may change them.
-- ---------------------------------------------------------------------------
alter table public.company_settings enable row level security;

drop policy if exists company_settings_select on public.company_settings;
create policy company_settings_select on public.company_settings
  for select to authenticated
  using (public.has_permission('settings.view'));

drop policy if exists company_settings_insert on public.company_settings;
create policy company_settings_insert on public.company_settings
  for insert to authenticated
  with check (public.has_permission('settings.update'));

drop policy if exists company_settings_update on public.company_settings;
create policy company_settings_update on public.company_settings
  for update to authenticated
  using (public.has_permission('settings.update'))
  with check (public.has_permission('settings.update'));

-- No DELETE policy: company settings can never be deleted through the API.

alter table public.gst_rates enable row level security;

drop policy if exists gst_rates_select on public.gst_rates;
create policy gst_rates_select on public.gst_rates
  for select to authenticated
  using (public.is_authenticated_user());

drop policy if exists gst_rates_insert on public.gst_rates;
create policy gst_rates_insert on public.gst_rates
  for insert to authenticated
  with check (public.has_permission('settings.update'));

drop policy if exists gst_rates_update on public.gst_rates;
create policy gst_rates_update on public.gst_rates
  for update to authenticated
  using (public.has_permission('settings.update'))
  with check (public.has_permission('settings.update'));
