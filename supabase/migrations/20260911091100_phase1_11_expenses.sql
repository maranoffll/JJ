-- ============================================================================
-- JJ MEDIA ERP — PHASE 1 : DATABASE FOUNDATION
-- Migration 11 : expenses & cost tracking
-- ----------------------------------------------------------------------------
-- Approved expenses are the only costs recognised in project profitability.
-- ============================================================================

create table if not exists public.expense_categories (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null,
  description         text,
  is_active           boolean not null default true,
  is_direct_cost      boolean not null default true,
  default_gst_rate    numeric(5,2) references public.gst_rates (rate),
  sort_order          int not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  constraint expense_categories_name_not_blank check (length(btrim(name)) > 0)
);

create unique index if not exists expense_categories_name_key on public.expense_categories (lower(name));
create index if not exists expense_categories_active_idx on public.expense_categories (sort_order) where is_active;

comment on table public.expense_categories is 'Expense category master data (direct production costs vs overheads).';

insert into public.expense_categories (name, description, is_direct_cost, default_gst_rate, sort_order) values
  ('Equipment Rental',      'Camera, lighting, grip and sound equipment hire', true, 18, 10),
  ('Studio / Location',     'Studio hire and location fees',                   true, 18, 20),
  ('Freelancer / Crew',     'Freelance crew and specialist fees',              true, 18, 30),
  ('Travel',                'Air, rail, road travel',                          true, 5,  40),
  ('Accommodation',         'Hotels and lodging',                              true, 12, 50),
  ('Food & Catering',       'Craft services and meals',                        true, 5,  60),
  ('Transport & Logistics', 'Vehicle hire, freight, fuel',                     true, 5,  70),
  ('Props, Art & Costume',  'Production design materials',                     true, 18, 80),
  ('Permits & Licenses',    'Shoot permits, clearances, legal',                true, 18, 90),
  ('Post Production',       'Editing, VFX, colour, sound, music',              true, 18, 100),
  ('Software & Subscriptions','Editing suites, plugins, cloud',                false, 18, 110),
  ('Marketing & Advertising','Promotions and campaign spend',                  false, 18, 120),
  ('Office & Admin',        'General administrative costs',                    false, 18, 130),
  ('Miscellaneous',         'Uncategorised expense',                           true, 18, 140)
on conflict do nothing;

-- ---------------------------------------------------------------------------
create table if not exists public.expenses (
  id                  uuid primary key default gen_random_uuid(),
  expense_number      text not null,
  sequence_value      bigint not null default 0,
  scope_key           text not null default 'GLOBAL',

  expense_date        date not null default current_date,
  category_id         uuid references public.expense_categories (id) on delete set null,
  project_id          uuid references public.projects (id) on delete set null,
  client_id           uuid references public.clients (id) on delete set null,

  vendor_name         text,
  vendor_gstin        text,
  vendor_state_code   char(2),
  invoice_reference   text,
  description         text not null,

  -- money: base amount is pre-tax, tax columns are computed by trigger
  amount              numeric(14,2) not null,
  gst_rate            numeric(5,2) references public.gst_rates (rate),
  tax_type            public.tax_type not null default 'INTRA_STATE',
  cgst_amount         numeric(14,2) not null default 0,
  sgst_amount         numeric(14,2) not null default 0,
  igst_amount         numeric(14,2) not null default 0,
  tax_amount          numeric(14,2) not null default 0,
  total_amount        numeric(14,2) not null default 0,

  payment_method      public.payment_method,
  paid_on             date,
  is_billable         boolean not null default false,
  is_reimbursable     boolean not null default false,
  is_itc_eligible     boolean not null default true,

  status              public.expense_status not null default 'DRAFT',
  approved_at         timestamptz,
  approved_by         uuid references public.user_profiles (id) on delete set null,
  voided_at           timestamptz,
  voided_by           uuid references public.user_profiles (id) on delete set null,
  void_reason         text,

  notes               text,

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid,
  updated_by          uuid,

  constraint expenses_amount_positive check (amount > 0),
  constraint expenses_number_not_blank check (length(btrim(expense_number)) > 0),
  constraint expenses_description_not_blank check (length(btrim(description)) > 0),
  constraint expenses_vendor_gstin_format check (
    vendor_gstin is null or vendor_gstin = '' or public.is_valid_gstin(vendor_gstin)
  ),
  constraint expenses_vendor_state_code_format check (
    vendor_state_code is null or vendor_state_code ~ '^[0-9]{2}$'
  ),
  constraint expenses_approved_consistency check (
    (status = 'APPROVED' and approved_at is not null)
    or (status <> 'APPROVED')
  ),
  constraint expenses_void_consistency check (
    (status = 'VOID' and voided_at is not null and coalesce(btrim(void_reason), '') <> '')
    or (status <> 'VOID' and voided_at is null)
  )
);

comment on table public.expenses is
  'Production cost record. APPROVED expenses feed project profitability; VOID expenses are excluded.';

create unique index if not exists expenses_number_key on public.expenses (expense_number);
create index if not exists expenses_project_idx on public.expenses (project_id, expense_date desc) where status = 'APPROVED';
create index if not exists expenses_category_idx on public.expenses (category_id, expense_date desc);
create index if not exists expenses_status_idx on public.expenses (status, expense_date desc);
create index if not exists expenses_client_idx on public.expenses (client_id) where client_id is not null;

-- Money computation: GST split derived from vendor state vs company state.
create or replace function public.expenses_compute_amounts()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_rate  numeric(5,2);
  v_split record;
  v_tax_type public.tax_type;
begin
  if tg_op = 'INSERT' then
    perform public.require_permission('expenses.create');
  else
    perform public.require_permission('expenses.update');
  end if;

  if new.expense_number is null or btrim(new.expense_number) = '' then
    new.expense_number := public.next_sequence_code('expense', 'EXP', 5);
  end if;

  -- Tax treatment: explicit override wins, otherwise derived from the vendor state.
  v_tax_type := public.resolve_tax_type(new.vendor_state_code);
  new.tax_type := coalesce(v_tax_type, 'INTRA_STATE');

  v_rate := public.effective_gst_rate(new.gst_rate);
  new.gst_rate := v_rate;

  select * into v_split from public.split_gst(new.amount, v_rate, new.tax_type);

  new.cgst_amount := v_split.cgst;
  new.sgst_amount := v_split.sgst;
  new.igst_amount := v_split.igst;
  new.tax_amount := v_split.total_tax;
  new.total_amount := public.round_money(new.amount + v_split.total_tax);

  return new;
end $$;

comment on function public.expenses_compute_amounts() is
  'BEFORE INSERT/UPDATE trigger: allocates the expense number and computes the GST split deterministically.';

-- Lifecycle: DRAFT -> APPROVED -> VOID; approved expenses are frozen except for voiding.
create or replace function public.expenses_guard_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_frozen_columns constant text[] := array[
    'expense_number', 'expense_date', 'category_id', 'project_id', 'client_id',
    'vendor_name', 'vendor_gstin', 'vendor_state_code', 'amount', 'gst_rate',
    'tax_type', 'cgst_amount', 'sgst_amount', 'igst_amount', 'tax_amount', 'total_amount'
  ];
  v_col text;
  v_old_json jsonb := to_jsonb(old);
  v_new_json jsonb := to_jsonb(new);
begin
  if tg_op = 'DELETE' then
    raise exception 'expenses cannot be deleted; void the expense instead'
      using errcode = 'insufficient_privilege';
  end if;

  if tg_op = 'INSERT' then
    -- A record may be created directly in APPROVED/VOID state (imports, bulk
    -- capture) but only with the matching permission, and it is stamped here so
    -- the consistency constraints always hold.
    if new.status = 'APPROVED' then
      perform public.require_permission('expenses.approve');
      new.approved_at := coalesce(new.approved_at, now());
      new.approved_by := coalesce(new.approved_by, auth.uid());
    elsif new.status = 'VOID' then
      perform public.require_permission('expenses.void');
      new.voided_at := coalesce(new.voided_at, now());
      new.voided_by := coalesce(new.voided_by, auth.uid());
      if coalesce(btrim(new.void_reason), '') = '' then
        raise exception 'a reason is required to void an expense' using errcode = 'check_violation';
      end if;
    end if;

    return new;
  end if;

  if old.status = 'VOID' then
    raise exception 'expense % is VOID and is terminal', old.expense_number
      using errcode = 'insufficient_privilege';
  end if;

  if old.status = 'APPROVED' then
    foreach v_col in array v_frozen_columns loop
      if v_new_json -> v_col is distinct from v_old_json -> v_col then
        raise exception 'expense % is APPROVED: % cannot be changed', old.expense_number, v_col
          using errcode = 'insufficient_privilege';
      end if;
    end loop;

    if new.status not in ('APPROVED', 'VOID') then
      raise exception 'invalid expense status transition: % -> %', old.status, new.status
        using errcode = 'check_violation';
    end if;

    if new.status = 'VOID' then
      perform public.require_permission('expenses.void');
      new.voided_at := coalesce(new.voided_at, now());
      new.voided_by := coalesce(new.voided_by, auth.uid());
      if coalesce(btrim(new.void_reason), '') = '' then
        raise exception 'a reason is required to void an expense' using errcode = 'check_violation';
      end if;
    end if;

    return new;
  end if;

  -- DRAFT
  if new.status is distinct from old.status then
    if new.status = 'APPROVED' then
      perform public.require_permission('expenses.approve');
      new.approved_at := coalesce(new.approved_at, now());
      new.approved_by := coalesce(new.approved_by, auth.uid());
    elsif new.status = 'VOID' then
      perform public.require_permission('expenses.void');
      new.voided_at := coalesce(new.voided_at, now());
      new.voided_by := coalesce(new.voided_by, auth.uid());
      if coalesce(btrim(new.void_reason), '') = '' then
        raise exception 'a reason is required to void an expense' using errcode = 'check_violation';
      end if;
    elsif new.status = 'DRAFT' then
      null;
    else
      raise exception 'invalid expense status transition: % -> %', old.status, new.status
        using errcode = 'check_violation';
    end if;
  end if;

  return new;
end $$;

drop trigger if exists expenses_compute_amounts on public.expenses;
create trigger expenses_compute_amounts
  before insert or update on public.expenses
  for each row execute function public.expenses_compute_amounts();

drop trigger if exists expenses_guard_lifecycle on public.expenses;
create trigger expenses_guard_lifecycle
  before insert or update or delete on public.expenses
  for each row execute function public.expenses_guard_lifecycle();

drop trigger if exists expenses_set_updated_at on public.expenses;
create trigger expenses_set_updated_at
  before update on public.expenses
  for each row execute function public.set_updated_at();

drop trigger if exists expenses_stamp_actor on public.expenses;
create trigger expenses_stamp_actor
  before insert or update on public.expenses
  for each row execute function public.stamp_actor_columns();

drop trigger if exists expenses_audit on public.expenses;
create trigger expenses_audit
  after insert or update on public.expenses
  for each row execute function public.audit_row_change();

create or replace function public.expense_categories_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists expense_categories_set_updated_at on public.expense_categories;
create trigger expense_categories_set_updated_at
  before update on public.expense_categories
  for each row execute function public.expense_categories_set_updated_at();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.expenses enable row level security;
alter table public.expense_categories enable row level security;

drop policy if exists expenses_select on public.expenses;
create policy expenses_select on public.expenses
  for select to authenticated
  using (public.has_permission('expenses.view'));

drop policy if exists expenses_insert on public.expenses;
create policy expenses_insert on public.expenses
  for insert to authenticated
  with check (public.has_permission('expenses.create'));

drop policy if exists expenses_update on public.expenses;
create policy expenses_update on public.expenses
  for update to authenticated
  using (public.has_permission('expenses.update') or public.has_permission('expenses.approve') or public.has_permission('expenses.void'))
  with check (public.has_permission('expenses.update') or public.has_permission('expenses.approve') or public.has_permission('expenses.void'));

drop policy if exists expense_categories_select on public.expense_categories;
create policy expense_categories_select on public.expense_categories
  for select to authenticated
  using (public.has_permission('expenses.view') or public.has_permission('reports.view'));

drop policy if exists expense_categories_write on public.expense_categories;
create policy expense_categories_write on public.expense_categories
  for all to authenticated
  using (public.has_permission('settings.update'))
  with check (public.has_permission('settings.update'));
