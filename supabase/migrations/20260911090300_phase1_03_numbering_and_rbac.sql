-- ============================================================================
-- JJ MEDIA ERP — PHASE 1 : DATABASE FOUNDATION
-- Migration 03 : concurrency-safe document numbering, actor stamping,
--                and the role -> permission matrix.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Actor stamping. created_by / updated_by are always taken from the session,
-- never from client-supplied values, so an API caller cannot impersonate
-- another user or backdate authorship.
-- ---------------------------------------------------------------------------
create or replace function public.stamp_actor_columns()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if tg_op = 'INSERT' then
    if v_actor is not null then
      new.created_by := v_actor;
    end if;
    new.updated_by := nullif(to_jsonb(new) ->> 'updated_by', '')::uuid;
    if v_actor is not null then
      new.updated_by := v_actor;
    end if;
  else
    if v_actor is not null then
      new.updated_by := v_actor;
    end if;
    -- authorship is immutable
    new.created_by := old.created_by;
  end if;

  return new;
end $$;

comment on function public.stamp_actor_columns() is
  'BEFORE INSERT/UPDATE trigger: stamps created_by/updated_by from the session and makes created_by immutable.';

-- ---------------------------------------------------------------------------
-- DOCUMENT NUMBERING
-- All document numbers are allocated by the database. next_document_number()
-- performs a single atomic upsert that takes a row lock on the accounting
-- scope, so two simultaneous callers can never receive the same number.
-- ---------------------------------------------------------------------------
create table if not exists public.document_sequences (
  doc_type    text not null,
  scope_key   text not null,
  prefix      text not null default '',
  next_number bigint not null default 1,
  padding     int not null default 4,
  updated_at  timestamptz not null default now(),
  constraint document_sequences_pkey primary key (doc_type, scope_key),
  constraint document_sequences_doc_type_not_blank check (length(btrim(doc_type)) > 0),
  constraint document_sequences_scope_not_blank check (length(btrim(scope_key)) > 0),
  constraint document_sequences_next_number_positive check (next_number >= 1),
  constraint document_sequences_padding_range check (padding between 1 and 10)
);

comment on table public.document_sequences is
  'Atomic counter per (document type, scope). Scope is normally the financial year so numbering restarts each April.';

-- Allocate the next number. The ON CONFLICT DO UPDATE clause locks the row for
-- the remainder of the transaction, which serialises concurrent callers.
create or replace function public.next_document_number(
  p_doc_type   text,
  p_prefix     text,
  p_scope_key  text default null,
  p_padding    int default 4
)
returns table (document_number text, sequence_value bigint, scope_key text, prefix text)
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_scope    text := coalesce(nullif(btrim(p_scope_key), ''), public.financial_year(current_date));
  v_row      public.document_sequences;
begin
  if p_doc_type is null or length(btrim(p_doc_type)) = 0 then
    raise exception 'document type is required';
  end if;

  insert into public.document_sequences as ds (doc_type, scope_key, prefix, next_number, padding)
  values (btrim(p_doc_type), v_scope, coalesce(p_prefix, ''), 2, greatest(coalesce(p_padding, 4), 1))
  on conflict on constraint document_sequences_pkey do update
     set next_number = ds.next_number + 1,
         prefix      = excluded.prefix,
         padding     = excluded.padding,
         updated_at  = now()
  returning ds.* into v_row;

  return query
    select format(
             '%s/%s/%s',
             nullif(v_row.prefix, ''),
             v_row.scope_key,
             lpad((v_row.next_number - 1)::text, v_row.padding, '0')
           ) as document_number,
           v_row.next_number - 1,
           v_row.scope_key,
           v_row.prefix;
end $$;

comment on function public.next_document_number(text, text, text, int) is
  'Atomically allocates and returns the next document number for a scope (default: current financial year).';

-- Read-only preview used by forms. Never consumes a number.
create or replace function public.peek_next_document_number(
  p_doc_type   text,
  p_prefix     text,
  p_scope_key  text default null,
  p_padding    int default 4
)
returns text
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select format(
           '%s/%s/%s',
           nullif(coalesce(s.prefix, p_prefix, ''), ''),
           coalesce(s.scope_key, nullif(btrim(p_scope_key), ''), public.financial_year(current_date)),
           lpad(coalesce(s.next_number, 1)::text, greatest(coalesce(s.padding, p_padding, 4), 1), '0')
         )
  from (select 1) dummy
  left join public.document_sequences s
         on s.doc_type = btrim(p_doc_type)
        and s.scope_key = coalesce(nullif(btrim(p_scope_key), ''), public.financial_year(current_date));
$$;

comment on function public.peek_next_document_number(text, text, text, int) is
  'Returns the number the next allocation would produce, without consuming it.';

-- ---------------------------------------------------------------------------
-- RBAC: permission catalogue + role matrix.
-- The database enforces authorization; the frontend only mirrors this matrix
-- to decide what to render.
-- ---------------------------------------------------------------------------
insert into public.role_permissions (role, permission) values
  -- ADMIN : everything ------------------------------------------------------------------
  ('ADMIN', 'clients.view'), ('ADMIN', 'clients.create'), ('ADMIN', 'clients.update'), ('ADMIN', 'clients.delete'),
  ('ADMIN', 'projects.view'), ('ADMIN', 'projects.create'), ('ADMIN', 'projects.update'), ('ADMIN', 'projects.delete'),
  ('ADMIN', 'quotations.view'), ('ADMIN', 'quotations.create'), ('ADMIN', 'quotations.update'),
  ('ADMIN', 'quotations.delete'), ('ADMIN', 'quotations.issue'), ('ADMIN', 'quotations.convert'),
  ('ADMIN', 'invoices.view'), ('ADMIN', 'invoices.create'), ('ADMIN', 'invoices.update'),
  ('ADMIN', 'invoices.issue'), ('ADMIN', 'invoices.cancel'),
  ('ADMIN', 'payments.view'), ('ADMIN', 'payments.create'), ('ADMIN', 'payments.void'),
  ('ADMIN', 'credit_notes.view'), ('ADMIN', 'credit_notes.create'),
  ('ADMIN', 'credit_notes.issue'), ('ADMIN', 'credit_notes.cancel'),
  ('ADMIN', 'expenses.view'), ('ADMIN', 'expenses.create'), ('ADMIN', 'expenses.update'),
  ('ADMIN', 'expenses.approve'), ('ADMIN', 'expenses.void'),
  ('ADMIN', 'hdd.view'), ('ADMIN', 'hdd.create'), ('ADMIN', 'hdd.update'), ('ADMIN', 'hdd.delete'),
  ('ADMIN', 'hdd.checkout'), ('ADMIN', 'hdd.checkin'), ('ADMIN', 'hdd.archive'),
  ('ADMIN', 'attachments.upload'), ('ADMIN', 'attachments.delete'),
  ('ADMIN', 'reports.view'), ('ADMIN', 'reports.financial'),
  ('ADMIN', 'audit.view'),
  ('ADMIN', 'settings.view'), ('ADMIN', 'settings.update'),
  ('ADMIN', 'users.view'), ('ADMIN', 'users.manage'),

  -- MANAGER : delivery + commercial ownership, no financial posting ------------
  ('MANAGER', 'clients.view'), ('MANAGER', 'clients.create'), ('MANAGER', 'clients.update'),
  ('MANAGER', 'projects.view'), ('MANAGER', 'projects.create'), ('MANAGER', 'projects.update'), ('MANAGER', 'projects.delete'),
  ('MANAGER', 'quotations.view'), ('MANAGER', 'quotations.create'), ('MANAGER', 'quotations.update'),
  ('MANAGER', 'quotations.delete'), ('MANAGER', 'quotations.issue'), ('MANAGER', 'quotations.convert'),
  ('MANAGER', 'invoices.view'),
  ('MANAGER', 'payments.view'),
  ('MANAGER', 'credit_notes.view'),
  ('MANAGER', 'expenses.view'), ('MANAGER', 'expenses.create'), ('MANAGER', 'expenses.update'), ('MANAGER', 'expenses.approve'),
  ('MANAGER', 'hdd.view'), ('MANAGER', 'hdd.create'), ('MANAGER', 'hdd.update'),
  ('MANAGER', 'hdd.checkout'), ('MANAGER', 'hdd.checkin'),
  ('MANAGER', 'attachments.upload'), ('MANAGER', 'attachments.delete'),
  ('MANAGER', 'reports.view'), ('MANAGER', 'reports.financial'),
  ('MANAGER', 'settings.view'),
  ('MANAGER', 'users.view'),

  -- FINANCE : billing, collections, statutory ---------------------------------
  ('FINANCE', 'clients.view'), ('FINANCE', 'clients.create'), ('FINANCE', 'clients.update'),
  ('FINANCE', 'projects.view'),
  ('FINANCE', 'quotations.view'),
  ('FINANCE', 'invoices.view'), ('FINANCE', 'invoices.create'), ('FINANCE', 'invoices.update'),
  ('FINANCE', 'invoices.issue'), ('FINANCE', 'invoices.cancel'),
  ('FINANCE', 'payments.view'), ('FINANCE', 'payments.create'), ('FINANCE', 'payments.void'),
  ('FINANCE', 'credit_notes.view'), ('FINANCE', 'credit_notes.create'),
  ('FINANCE', 'credit_notes.issue'), ('FINANCE', 'credit_notes.cancel'),
  ('FINANCE', 'expenses.view'), ('FINANCE', 'expenses.create'), ('FINANCE', 'expenses.update'),
  ('FINANCE', 'expenses.approve'), ('FINANCE', 'expenses.void'),
  ('FINANCE', 'hdd.view'),
  ('FINANCE', 'attachments.upload'),
  ('FINANCE', 'reports.view'), ('FINANCE', 'reports.financial'),
  ('FINANCE', 'audit.view'),
  ('FINANCE', 'settings.view'),
  ('FINANCE', 'users.view'),

  -- PRODUCTION : shoots, media, custody ---------------------------------------
  ('PRODUCTION', 'clients.view'),
  ('PRODUCTION', 'projects.view'), ('PRODUCTION', 'projects.update'),
  ('PRODUCTION', 'quotations.view'),
  ('PRODUCTION', 'expenses.view'), ('PRODUCTION', 'expenses.create'), ('PRODUCTION', 'expenses.update'),
  ('PRODUCTION', 'hdd.view'), ('PRODUCTION', 'hdd.create'), ('PRODUCTION', 'hdd.update'),
  ('PRODUCTION', 'hdd.checkout'), ('PRODUCTION', 'hdd.checkin'),
  ('PRODUCTION', 'attachments.upload'),
  ('PRODUCTION', 'reports.view'),
  ('PRODUCTION', 'settings.view'),

  -- VIEWER : read-only ---------------------------------------------------------
  ('VIEWER', 'clients.view'),
  ('VIEWER', 'projects.view'),
  ('VIEWER', 'quotations.view'),
  ('VIEWER', 'invoices.view'),
  ('VIEWER', 'payments.view'),
  ('VIEWER', 'credit_notes.view'),
  ('VIEWER', 'expenses.view'),
  ('VIEWER', 'hdd.view'),
  ('VIEWER', 'reports.view'),
  ('VIEWER', 'settings.view')
on conflict (role, permission) do nothing;

create index if not exists role_permissions_permission_idx on public.role_permissions (permission);

-- Short business codes (client code, project code, HDD asset tag). Uses the
-- same atomic counter mechanism but a global scope and a dash separator.
create or replace function public.next_sequence_code(
  p_doc_type text,
  p_prefix   text,
  p_padding  int default 4
)
returns text
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_scope text := 'GLOBAL';
  v_row   public.document_sequences;
begin
  insert into public.document_sequences as ds (doc_type, scope_key, prefix, next_number, padding)
  values (btrim(p_doc_type), v_scope, coalesce(p_prefix, ''), 2, greatest(coalesce(p_padding, 4), 1))
  on conflict (doc_type, scope_key) do update
     set next_number = ds.next_number + 1,
         prefix      = excluded.prefix,
         padding     = excluded.padding,
         updated_at  = now()
  returning ds.* into v_row;

  return format(
           '%s-%s',
           nullif(v_row.prefix, ''),
           lpad((v_row.next_number - 1)::text, v_row.padding, '0')
         );
end $$;

comment on function public.next_sequence_code(text, text, int) is
  'Atomically allocates a business code such as CL-0001, PRJ-0001 or HDD-0001.';

-- ---------------------------------------------------------------------------
-- Permission assertion for trigger-level authorisation.
-- A NULL session (service_role, migrations, background jobs) is a trusted
-- server context and passes; a real user session must hold the permission.
-- ---------------------------------------------------------------------------
create or replace function public.require_permission(p_permission text)
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if auth.uid() is null then
    return; -- trusted server-side context
  end if;

  if not public.has_permission(p_permission) then
    raise exception 'permission denied: % is required', p_permission
      using errcode = 'insufficient_privilege';
  end if;
end $$;

comment on function public.require_permission(text) is
  'Raises insufficient_privilege when the session user lacks the permission; no-op without a session.';

create or replace function public.require_role(variadic p_roles public.user_role[])
returns void
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if auth.uid() is null then
    return;
  end if;

  if not public.has_role(variadic p_roles) then
    raise exception 'permission denied: one of % is required', array_to_string(p_roles, ', ')
      using errcode = 'insufficient_privilege';
  end if;
end $$;
