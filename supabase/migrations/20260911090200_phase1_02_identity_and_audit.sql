-- ============================================================================
-- JJ MEDIA ERP — PHASE 1 : DATABASE FOUNDATION
-- Migration 02 : user profiles, identity helpers, audit infrastructure
-- ----------------------------------------------------------------------------
-- ERP users live in auth.users (Supabase Auth) with an application profile in
-- public.user_profiles. Roles are resolved server-side from that table only —
-- a role supplied by the browser is never trusted.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- public.user_profiles
-- ---------------------------------------------------------------------------
create table if not exists public.user_profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  email         text not null,
  full_name     text not null default '',
  role          public.user_role not null default 'VIEWER',
  phone         text,
  designation   text,
  is_active     boolean not null default true,
  last_login_at timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid,
  updated_by    uuid,
  constraint user_profiles_email_not_blank check (length(btrim(email)) > 0)
);

comment on table public.user_profiles is
  'ERP user profile and role. One row per auth.users row. Role here is authoritative; browser-supplied roles are never trusted.';

create unique index if not exists user_profiles_email_key on public.user_profiles (lower(email));
create index if not exists user_profiles_role_idx on public.user_profiles (role) where is_active;

drop trigger if exists user_profiles_set_updated_at on public.user_profiles;
create trigger user_profiles_set_updated_at
  before update on public.user_profiles
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Identity helpers.
-- auth.uid() is supplied by Supabase; on plain PostgreSQL the local test
-- harness provides an identical stub. All helpers are SECURITY DEFINER so RLS
-- policies can resolve the caller's role without recursing into
-- user_profiles policies, and all fail closed when there is no session.
-- ---------------------------------------------------------------------------
create or replace function public.app_current_user_id()
returns uuid
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select auth.uid();
$$;

comment on function public.app_current_user_id() is
  'UUID of the authenticated ERP user, or NULL when anonymous.';

create or replace function public.app_current_user_role()
returns public.user_role
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select p.role
  from public.user_profiles p
  where p.id = auth.uid()
    and p.is_active
  limit 1;
$$;

comment on function public.app_current_user_role() is
  'Server-resolved ERP role of the caller. NULL for anonymous or deactivated users.';

create or replace function public.is_authenticated_user()
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select exists (
    select 1 from public.user_profiles p
    where p.id = auth.uid() and p.is_active
  );
$$;

comment on function public.is_authenticated_user() is
  'True when the caller has an active ERP profile.';

create or replace function public.has_role(variadic p_roles public.user_role[])
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select exists (
    select 1 from public.user_profiles p
    where p.id = auth.uid()
      and p.is_active
      and p.role = any (p_roles)
  );
$$;

comment on function public.has_role(public.user_role[]) is
  'Role membership test against the server-side profile. Used by RLS policies.';

-- ---------------------------------------------------------------------------
-- Role -> permission matrix (RBAC). The database is the source of truth for
-- authorization; the frontend only mirrors this for navigation.
-- ---------------------------------------------------------------------------
create table if not exists public.role_permissions (
  role       public.user_role not null,
  permission text not null,
  created_at timestamptz not null default now(),
  primary key (role, permission)
);

comment on table public.role_permissions is
  'Role -> permission matrix enforced by the database (see public.has_permission).';

create or replace function public.has_permission(p_permission text)
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select exists (
    select 1
    from public.user_profiles p
    join public.role_permissions rp on rp.role = p.role
    where p.id = auth.uid()
      and p.is_active
      and rp.permission = p_permission
  );
$$;

comment on function public.has_permission(text) is
  'True when the caller''s ERP role grants the named permission.';

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select public.has_role('ADMIN');
$$;

-- ---------------------------------------------------------------------------
-- Profile bootstrap. A trigger on auth.users keeps public.user_profiles in
-- step with Supabase Auth. The very first account to sign up becomes ADMIN;
-- every later account starts as VIEWER and must be promoted by an admin.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_role public.user_role;
begin
  if exists (select 1 from public.user_profiles) then
    v_role := 'VIEWER';
  else
    v_role := 'ADMIN';
  end if;

  insert into public.user_profiles (id, email, full_name, role, is_active)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(nullif(btrim(coalesce(new.raw_user_meta_data ->> 'full_name', '')), ''),
             nullif(btrim(coalesce(new.raw_user_meta_data ->> 'name', '')), ''),
             split_part(coalesce(new.email, ''), '@', 1)),
    v_role,
    true
  )
  on conflict do nothing;

  return new;
end $$;

comment on function public.handle_new_auth_user() is
  'Creates the ERP profile for a new Supabase Auth user. First user becomes ADMIN.';

create or replace function public.handle_updated_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  update public.user_profiles
     set email = coalesce(new.email, email),
         full_name = coalesce(
           nullif(btrim(coalesce(new.raw_user_meta_data ->> 'full_name', '')), ''),
           full_name
         )
   where id = new.id;

  return new;
end $$;

do $$
begin
  if exists (
    select 1 from information_schema.tables
    where table_schema = 'auth' and table_name = 'users'
  ) then
    execute 'drop trigger if exists on_auth_user_created on auth.users';
    execute 'create trigger on_auth_user_created after insert on auth.users
             for each row execute function public.handle_new_auth_user()';
    execute 'drop trigger if exists on_auth_user_updated on auth.users';
    execute 'create trigger on_auth_user_updated after update on auth.users
             for each row execute function public.handle_updated_auth_user()';
    raise notice 'auth.users triggers installed';
  else
    raise notice 'auth.users not present — skipping auth triggers';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- AUDIT LOG — append-only.
-- public.audit_logs records business-critical operations.
-- public.hdd_logs (created in the HDD migration) is kept separate as the HDD
-- custody history ledger.
-- ---------------------------------------------------------------------------
create table if not exists public.audit_logs (
  id              bigint generated always as identity primary key,
  created_at      timestamptz not null default now(),
  actor_id        uuid references public.user_profiles (id) on delete set null,
  actor_email     text,
  actor_role      public.user_role,
  action          public.audit_action not null,
  entity_table    text not null,
  entity_id       uuid,
  entity_label    text,
  project_id      uuid,
  summary         text,
  changed_fields  text[],
  before_data     jsonb,
  after_data      jsonb,
  ip_address      inet,
  user_agent      text,
  request_id      text,
  constraint audit_logs_entity_table_not_blank check (length(btrim(entity_table)) > 0)
);

comment on table public.audit_logs is
  'Append-only audit trail of business operations. UPDATE and DELETE are blocked by trigger; only an explicitly flagged maintenance session may purge.';

create index if not exists audit_logs_created_at_idx on public.audit_logs (created_at desc);
create index if not exists audit_logs_entity_idx on public.audit_logs (entity_table, entity_id, created_at desc);
create index if not exists audit_logs_actor_idx on public.audit_logs (actor_id, created_at desc);
create index if not exists audit_logs_action_idx on public.audit_logs (action, created_at desc);
create index if not exists audit_logs_project_idx on public.audit_logs (project_id, created_at desc) where project_id is not null;

-- Append-only enforcement.
create or replace function public.audit_logs_block_mutation()
returns trigger
language plpgsql
as $$
begin
  -- A maintenance session must opt in explicitly:
  --   set local app.allow_audit_maintenance = 'on';
  if coalesce(current_setting('app.allow_audit_maintenance', true), 'off') = 'on' then
    return null;
  end if;

  raise exception
    'public.audit_logs is append-only; % is not permitted', tg_op
    using errcode = 'insufficient_privilege',
          hint = 'Audit records are immutable. Use a flagged maintenance session for retention operations.';
end $$;

comment on function public.audit_logs_block_mutation() is
  'Blocks UPDATE/DELETE on public.audit_logs unless app.allow_audit_maintenance is set.';

drop trigger if exists audit_logs_immutable_update on public.audit_logs;
create trigger audit_logs_immutable_update
  before update on public.audit_logs
  for each statement execute function public.audit_logs_block_mutation();

drop trigger if exists audit_logs_immutable_delete on public.audit_logs;
create trigger audit_logs_immutable_delete
  before delete on public.audit_logs
  for each statement execute function public.audit_logs_block_mutation();

-- ---------------------------------------------------------------------------
-- Audit writer. SECURITY DEFINER so the application can record an event
-- without holding INSERT rights on the ledger itself.
-- ---------------------------------------------------------------------------
create or replace function public.write_audit_log(
  p_action         public.audit_action,
  p_entity_table   text,
  p_entity_id      uuid default null,
  p_entity_label   text default null,
  p_project_id     uuid default null,
  p_summary        text default null,
  p_changed_fields text[] default null,
  p_before         jsonb default null,
  p_after          jsonb default null,
  p_actor_id       uuid default null
)
returns bigint
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_actor   uuid := coalesce(p_actor_id, auth.uid());
  v_email   text;
  v_role    public.user_role;
  v_id      bigint;
begin
  if p_entity_table is null or length(btrim(p_entity_table)) = 0 then
    raise exception 'audit entity_table is required';
  end if;

  select p.email, p.role into v_email, v_role
  from public.user_profiles p
  where p.id = v_actor;

  insert into public.audit_logs (
    actor_id, actor_email, actor_role, action, entity_table, entity_id,
    entity_label, project_id, summary, changed_fields, before_data, after_data,
    ip_address, user_agent, request_id
  )
  values (
    v_actor, v_email, v_role, p_action, p_entity_table, p_entity_id,
    p_entity_label, p_project_id, p_summary, p_changed_fields, p_before, p_after,
    public.try_inet(nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-forwarded-for'),
    nullif(current_setting('request.headers', true), '')::jsonb ->> 'user-agent',
    nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-request-id'
  )
  returning id into v_id;

  return v_id;
end $$;

comment on function public.write_audit_log is
  'Appends an audit record. Safe for application use; resolves actor from the session.';

-- ---------------------------------------------------------------------------
-- Generic row-level audit trigger for business tables.
-- ---------------------------------------------------------------------------
create or replace function public.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_before    jsonb;
  v_after     jsonb;
  v_changed   text[];
  v_entity_id uuid;
  v_label     text;
  v_action    public.audit_action;
begin
  if tg_op = 'INSERT' then
    v_after := to_jsonb(new);
    v_entity_id := new.id;
    v_action := 'INSERT';
  elsif tg_op = 'UPDATE' then
    v_before := to_jsonb(old);
    v_after := to_jsonb(new);
    v_entity_id := new.id;
    v_action := 'UPDATE';

    select array_agg(key order by key) into v_changed
    from jsonb_each(v_after) a
    where a.value is distinct from (v_before -> a.key);

    if v_changed is null then
      return new; -- nothing actually changed
    end if;
  else
    v_before := to_jsonb(old);
    v_entity_id := old.id;
    v_action := 'DELETE';
  end if;

  -- Preferred human-readable label columns, in order of usefulness.
  v_label := coalesce(
    v_after ->> 'document_number',
    v_after ->> 'invoice_number',
    v_after ->> 'quotation_number',
    v_after ->> 'credit_note_number',
    v_after ->> 'payment_number',
    v_after ->> 'expense_number',
    v_after ->> 'number',
    v_after ->> 'name',
    v_after ->> 'project_code',
    v_after ->> 'serial_number',
    v_after ->> 'title',
    v_after ->> 'client_name',
    v_before ->> 'document_number',
    v_before ->> 'name'
  );

  perform public.write_audit_log(
    p_action         => v_action,
    p_entity_table   => tg_table_name,
    p_entity_id      => v_entity_id,
    p_entity_label   => v_label,
    p_project_id     => case
                          when tg_table_name = 'projects' then v_entity_id
                          when v_after ? 'project_id' then nullif(v_after ->> 'project_id', '')::uuid
                          when v_before ? 'project_id' then nullif(v_before ->> 'project_id', '')::uuid
                          else null
                        end,
    p_summary        => initcap(lower(tg_op)) || ' on ' || tg_table_name
                        || coalesce(' ' || v_label, ''),
    p_changed_fields => v_changed,
    p_before         => v_before,
    p_after          => v_after
  );

  return coalesce(new, old);
end $$;

comment on function public.audit_row_change() is
  'AFTER INSERT/UPDATE/DELETE trigger: appends an audit record with before/after snapshots.';
