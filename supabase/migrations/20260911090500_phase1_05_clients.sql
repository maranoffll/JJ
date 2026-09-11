-- ============================================================================
-- JJ MEDIA ERP — PHASE 1 : DATABASE FOUNDATION
-- Migration 05 : clients (CRM master data)
-- ============================================================================

create table if not exists public.clients (
  id                  uuid primary key default gen_random_uuid(),
  client_code         text not null,
  name                text not null,
  legal_name          text,
  client_type         public.client_type not null default 'CORPORATE',
  status              public.client_status not null default 'ACTIVE',

  -- statutory
  gstin               text,
  pan                 text,
  is_gst_registered   boolean not null default true,

  -- billing address
  billing_line1       text,
  billing_line2       text,
  billing_city        text,
  billing_state       text,
  billing_state_code  char(2),
  billing_pincode     text,
  country             text not null default 'India',

  -- shipping / site address
  shipping_line1      text,
  shipping_line2      text,
  shipping_city       text,
  shipping_state      text,
  shipping_state_code char(2),
  shipping_pincode    text,

  -- contact
  contact_person      text,
  contact_designation text,
  email               text,
  phone               text,
  alt_phone           text,
  website             text,

  -- commercial
  payment_terms_days  int not null default 30,
  credit_limit        numeric(14,2),
  default_gst_rate    numeric(5,2) references public.gst_rates (rate),
  notes               text,
  tags                text[] not null default '{}',

  -- ownership
  account_manager_id  uuid references public.user_profiles (id) on delete set null,

  -- lifecycle
  is_deleted          boolean not null default false,
  deleted_at          timestamptz,
  deleted_by          uuid references public.user_profiles (id) on delete set null,

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid,
  updated_by          uuid,

  constraint clients_name_not_blank check (length(btrim(name)) > 0),
  constraint clients_gstin_format check (gstin is null or gstin = '' or public.is_valid_gstin(gstin)),
  constraint clients_pan_format check (pan is null or pan = '' or public.is_valid_pan(pan)),
  constraint clients_state_code_format check (billing_state_code is null or billing_state_code ~ '^[0-9]{2}$'),
  constraint clients_shipping_state_code_format check (shipping_state_code is null or shipping_state_code ~ '^[0-9]{2}$'),
  constraint clients_email_format check (email is null or email = '' or email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  constraint clients_payment_terms_range check (payment_terms_days between 0 and 365),
  constraint clients_credit_limit_non_negative check (credit_limit is null or credit_limit >= 0),
  constraint clients_deleted_consistency check ((is_deleted and deleted_at is not null) or (not is_deleted))
);

comment on table public.clients is
  'Client / prospect master data. Deletion is soft (is_deleted + deleted_at) to preserve financial history.';

create unique index if not exists clients_client_code_key on public.clients (client_code);
create unique index if not exists clients_gstin_key on public.clients (gstin) where gstin is not null and gstin <> '';
create index if not exists clients_name_trgm_idx on public.clients using gin (name extensions.gin_trgm_ops);
create index if not exists clients_status_idx on public.clients (status) where not is_deleted;
create index if not exists clients_active_idx on public.clients (id) where not is_deleted;
create index if not exists clients_account_manager_idx on public.clients (account_manager_id) where not is_deleted;

-- Client code is allocated by the database when not supplied.
create or replace function public.clients_assign_code()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if new.client_code is null or btrim(new.client_code) = '' then
    new.client_code := public.next_sequence_code('client', 'CL', 4);
  end if;
  return new;
end $$;

drop trigger if exists clients_assign_code on public.clients;
create trigger clients_assign_code
  before insert on public.clients
  for each row execute function public.clients_assign_code();

-- Billing defaults inherited from the company profile.
create or replace function public.clients_apply_defaults()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_settings public.company_settings;
begin
  select * into v_settings from public.company_settings limit 1;

  if new.payment_terms_days is null or new.payment_terms_days = 30 then
    if v_settings.payment_terms_days is not null and tg_op = 'INSERT' then
      new.payment_terms_days := v_settings.payment_terms_days;
    end if;
  end if;

  if new.default_gst_rate is null and v_settings.default_gst_rate is not null then
    new.default_gst_rate := v_settings.default_gst_rate;
  end if;

  if new.is_gst_registered and (new.gstin is null or btrim(new.gstin) = '') then
    new.is_gst_registered := false;
  end if;

  return new;
end $$;

drop trigger if exists clients_apply_defaults on public.clients;
create trigger clients_apply_defaults
  before insert or update on public.clients
  for each row execute function public.clients_apply_defaults();

drop trigger if exists clients_set_updated_at on public.clients;
create trigger clients_set_updated_at
  before update on public.clients
  for each row execute function public.set_updated_at();

drop trigger if exists clients_stamp_actor on public.clients;
create trigger clients_stamp_actor
  before insert or update on public.clients
  for each row execute function public.stamp_actor_columns();

-- Soft deletion must be explicit: hard DELETE is never allowed, and flipping
-- is_deleted requires the clients.delete permission.
create or replace function public.clients_guard_delete()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'clients cannot be hard deleted; mark the client archived instead'
      using errcode = 'insufficient_privilege';
  end if;

  if new.is_deleted is distinct from old.is_deleted then
    perform public.require_permission('clients.delete');

    if new.is_deleted then
      new.deleted_at := coalesce(new.deleted_at, now());
      new.deleted_by := coalesce(new.deleted_by, auth.uid());
      if new.status <> 'ARCHIVED' then
        new.status := 'ARCHIVED';
      end if;
    else
      new.deleted_at := null;
      new.deleted_by := null;
    end if;
  end if;

  return new;
end $$;

drop trigger if exists clients_guard_delete on public.clients;
create trigger clients_guard_delete
  before update or delete on public.clients
  for each row execute function public.clients_guard_delete();

drop trigger if exists clients_audit on public.clients;
create trigger clients_audit
  after insert or update on public.clients
  for each row execute function public.audit_row_change();

-- Tax treatment helper used by quotations and invoices.
create or replace function public.client_tax_type(p_client_id uuid)
returns public.tax_type
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select public.resolve_tax_type(c.billing_state_code)
  from public.clients c
  where c.id = p_client_id;
$$;

comment on function public.client_tax_type(uuid) is
  'GST treatment for a client derived from its billing state code.';

-- Place-of-supply resolution for a document. An explicit place of supply wins
-- (bill-to vs ship-to), otherwise the client's billing state is used. The
-- resulting tax_type is ALWAYS derived here — a browser-supplied value is
-- never trusted.
create or replace function public.derive_document_tax_type(
  p_client_id  uuid,
  p_state_code text default null
)
returns public.tax_type
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select public.resolve_tax_type(
    coalesce(
      nullif(btrim(coalesce(p_state_code, '')), ''),
      (select c.billing_state_code from public.clients c where c.id = p_client_id)
    )
  );
$$;

comment on function public.derive_document_tax_type(uuid, text) is
  'Authoritative GST treatment for a document: explicit place of supply, else the client billing state.';

create or replace function public.derive_place_of_supply_state_code(
  p_client_id  uuid,
  p_state_code text default null
)
returns char(2)
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select coalesce(
    nullif(btrim(coalesce(p_state_code, '')), ''),
    (select c.billing_state_code from public.clients c where c.id = p_client_id)
  );
$$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.clients enable row level security;

drop policy if exists clients_select on public.clients;
create policy clients_select on public.clients
  for select to authenticated
  using (public.has_permission('clients.view'));

drop policy if exists clients_insert on public.clients;
create policy clients_insert on public.clients
  for insert to authenticated
  with check (public.has_permission('clients.create'));

drop policy if exists clients_update on public.clients;
create policy clients_update on public.clients
  for update to authenticated
  using (public.has_permission('clients.update'))
  with check (public.has_permission('clients.update'));

-- Intentionally no DELETE policy: archiving is an UPDATE (clients_guard_delete).
