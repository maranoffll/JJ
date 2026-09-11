-- ============================================================================
-- JJ MEDIA ERP — PHASE 1 : DATABASE FOUNDATION
-- Migration 15 : privileges, user management, function exposure hardening
-- ----------------------------------------------------------------------------
-- Authorization model:
--   anon          no access to any public table or function
--   authenticated table privileges + RLS policies + SECURITY DEFINER RPCs
--   service_role  full table access (server-side only, key never shipped)
-- Function EXECUTE is revoked from PUBLIC/anon and granted explicitly, so the
-- browser cannot call internal helpers (numbering, audit writing, triggers).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Schema access
-- ---------------------------------------------------------------------------
grant usage on schema public to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Table privileges
--   anon: none (fail closed at the privilege layer, before RLS is even reached)
--   authenticated: DML, filtered by RLS
--   service_role: full access for trusted server-side jobs
-- ---------------------------------------------------------------------------
revoke all on all tables in schema public from anon;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to authenticated, service_role;

alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public grant select, insert, update, delete on tables to service_role;

-- ---------------------------------------------------------------------------
-- Function exposure.
-- Everything is revoked from PUBLIC and anon. EXECUTE is then granted to
-- authenticated for every function EXCEPT:
--   * trigger functions (unusable outside a trigger context)
--   * internal helpers: numbering counters and ledger writers (a client must
--     never be able to burn a document number or forge an audit entry)
--   * authorisation internals and row-guard/assertion helpers
-- Helpers referenced by CHECK constraints (is_valid_gstin, is_valid_pan, …)
-- MUST stay executable by application roles, otherwise inserts would fail.
-- ---------------------------------------------------------------------------
revoke all on all functions in schema public from public;
revoke all on all functions in schema public from anon;

grant execute on all functions in schema public to service_role;

do $$
declare
  v_fn record;
  v_internal constant text[] := array[
    -- numbering: allocated only inside SECURITY DEFINER writers
    'next_document_number',
    'next_sequence_code',
    -- ledgers: written only by triggers/RPCs
    'write_audit_log',
    'write_hdd_log',
    -- authorisation internals
    'require_permission',
    'require_role',
    -- auth bootstrap triggers
    'handle_new_auth_user',
    'handle_updated_auth_user',
    -- assertion helpers used inside guards
    'credit_notes_assert_issuable'
  ];
begin
  for v_fn in
    select
      p.oid::regprocedure as signature,
      p.proname           as name,
      p.prorettype        as return_type
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
  loop
    if v_fn.return_type = 'trigger'::regtype
       or v_fn.name = any (v_internal)
       or v_fn.name like '%\_guard\_%'
       or v_fn.name like 'recalc\_%'
       or v_fn.name like '%\_block\_mutation'
       or v_fn.name like '\_%'
    then
      execute format('revoke all on function %s from authenticated', v_fn.signature);
    else
      execute format('grant execute on function %s to authenticated', v_fn.signature);
    end if;
  end loop;
end $$;

-- The signup trigger must be able to run regardless of the invoking role.
grant execute on function public.handle_new_auth_user() to service_role;

-- ---------------------------------------------------------------------------
-- user_profiles: read/update policies + field-level protection.
--   * every user may read their own profile
--   * users.view may read the directory
--   * a user may edit their own name/phone only
--   * role, is_active and email changes require users.manage
-- ---------------------------------------------------------------------------
alter table public.user_profiles enable row level security;

drop policy if exists user_profiles_select_self on public.user_profiles;
create policy user_profiles_select_self on public.user_profiles
  for select to authenticated
  using (id = auth.uid());

drop policy if exists user_profiles_select_directory on public.user_profiles;
create policy user_profiles_select_directory on public.user_profiles
  for select to authenticated
  using (public.has_permission('users.view'));

drop policy if exists user_profiles_update_self on public.user_profiles;
create policy user_profiles_update_self on public.user_profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

drop policy if exists user_profiles_update_admin on public.user_profiles;
create policy user_profiles_update_admin on public.user_profiles
  for update to authenticated
  using (public.has_permission('users.manage'))
  with check (public.has_permission('users.manage'));

drop policy if exists user_profiles_insert_admin on public.user_profiles;
create policy user_profiles_insert_admin on public.user_profiles
  for insert to authenticated
  with check (public.has_permission('users.manage'));

drop policy if exists user_profiles_delete_admin on public.user_profiles;
create policy user_profiles_delete_admin on public.user_profiles
  for delete to authenticated
  using (public.has_permission('users.manage'));

create or replace function public.user_profiles_guard_privileged_fields()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_is_self boolean := (old.id = auth.uid());
begin
  -- No session: trusted server context (migrations, service_role jobs).
  if auth.uid() is null then
    return new;
  end if;

  -- A user with users.manage may change anything.
  if public.has_permission('users.manage') then
    -- Never allow the last active admin to be demoted or deactivated.
    if old.role = 'ADMIN' and (new.role <> 'ADMIN' or not new.is_active) then
      if (select count(*) from public.user_profiles where role = 'ADMIN' and is_active) <= 1 then
        raise exception 'the last active ADMIN cannot be demoted or deactivated'
          using errcode = 'check_violation';
      end if;
    end if;
    return new;
  end if;

  if not v_is_self then
    raise exception 'permission denied: users.manage is required to edit another profile'
      using errcode = 'insufficient_privilege';
  end if;

  -- A user editing their own profile may only change presentation fields.
  if new.role is distinct from old.role
     or new.is_active is distinct from old.is_active
     or new.email is distinct from old.email
     or new.id is distinct from old.id then
    raise exception 'permission denied: users.manage is required to change role, status or email'
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end $$;

drop trigger if exists user_profiles_guard_privileged_fields on public.user_profiles;
create trigger user_profiles_guard_privileged_fields
  before update on public.user_profiles
  for each row execute function public.user_profiles_guard_privileged_fields();

-- Prevent deletion of the last admin through DELETE as well.
create or replace function public.user_profiles_guard_delete()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_permission('users.manage');

  if old.role = 'ADMIN'
     and (select count(*) from public.user_profiles where role = 'ADMIN' and is_active) <= 1 then
    raise exception 'the last active ADMIN cannot be removed' using errcode = 'check_violation';
  end if;

  return old;
end $$;

drop trigger if exists user_profiles_guard_delete on public.user_profiles;
create trigger user_profiles_guard_delete
  before delete on public.user_profiles
  for each row execute function public.user_profiles_guard_delete();

-- ---------------------------------------------------------------------------
-- role_permissions: readable by authenticated users (the UI mirrors the matrix
-- to build navigation), mutable by ADMIN only.
-- ---------------------------------------------------------------------------
alter table public.role_permissions enable row level security;

drop policy if exists role_permissions_select on public.role_permissions;
create policy role_permissions_select on public.role_permissions
  for select to authenticated
  using (public.is_authenticated_user());

drop policy if exists role_permissions_write on public.role_permissions;
create policy role_permissions_write on public.role_permissions
  for all to authenticated
  using (public.has_permission('users.manage'))
  with check (public.has_permission('users.manage'));

-- ---------------------------------------------------------------------------
-- audit_logs: append-only and readable only with audit.view. Inserts happen
-- through SECURITY DEFINER functions, so no INSERT policy is defined.
-- ---------------------------------------------------------------------------
alter table public.audit_logs enable row level security;

drop policy if exists audit_logs_select on public.audit_logs;
create policy audit_logs_select on public.audit_logs
  for select to authenticated
  using (public.has_permission('audit.view'));

-- ---------------------------------------------------------------------------
-- document_sequences: internal counters. No policy grants access to any
-- application role; numbering is only reachable through the SECURITY DEFINER
-- allocation functions, which prevents number burning by direct writes.
-- ---------------------------------------------------------------------------
alter table public.document_sequences enable row level security;

-- ---------------------------------------------------------------------------
-- Login / session tracking (used by the authentication phase). Written through
-- a definer function so no INSERT policy on user_profiles is needed.
-- ---------------------------------------------------------------------------
create or replace function public.record_login()
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if auth.uid() is null then
    return;
  end if;

  update public.user_profiles
     set last_login_at = now()
   where id = auth.uid();

  perform public.write_audit_log(
    p_action       => 'LOGIN',
    p_entity_table => 'user_profiles',
    p_entity_id    => auth.uid(),
    p_summary      => 'User signed in'
  );
end $$;

comment on function public.record_login() is 'Stamps last_login_at and appends a LOGIN audit record.';

-- ---------------------------------------------------------------------------
-- Admin RPCs for user administration (Phase 3 surface, secured here).
-- ---------------------------------------------------------------------------
create or replace function public.set_user_role(p_user_id uuid, p_role public.user_role)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_old public.user_role;
begin
  perform public.require_permission('users.manage');

  select role into v_old from public.user_profiles where id = p_user_id for update;

  if not found then
    raise exception 'user % not found', p_user_id using errcode = 'no_data_found';
  end if;

  update public.user_profiles set role = p_role where id = p_user_id;

  perform public.write_audit_log(
    p_action         => 'UPDATE',
    p_entity_table   => 'user_profiles',
    p_entity_id      => p_user_id,
    p_summary        => format('Role changed from %s to %s', v_old, p_role),
    p_changed_fields => array['role']
  );
end $$;

create or replace function public.set_user_active(p_user_id uuid, p_is_active boolean)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  perform public.require_permission('users.manage');

  if not exists (select 1 from public.user_profiles where id = p_user_id) then
    raise exception 'user % not found', p_user_id using errcode = 'no_data_found';
  end if;

  update public.user_profiles set is_active = p_is_active where id = p_user_id;

  perform public.write_audit_log(
    p_action         => 'UPDATE',
    p_entity_table   => 'user_profiles',
    p_entity_id      => p_user_id,
    p_summary        => case when p_is_active then 'User activated' else 'User deactivated' end,
    p_changed_fields => array['is_active']
  );
end $$;

-- ---------------------------------------------------------------------------
-- Company settings bootstrap (used by the settings screen when the singleton
-- row has not been created yet). ADMIN only.
-- ---------------------------------------------------------------------------
create or replace function public.bootstrap_company_settings(
  p_legal_name   text,
  p_display_name text default null,
  p_state        text default null,
  p_state_code   char(2) default null,
  p_gstin        text default null,
  p_pan          text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_id uuid;
begin
  perform public.require_permission('settings.update');

  if exists (select 1 from public.company_settings) then
    raise exception 'company settings already exist' using errcode = 'unique_violation';
  end if;

  insert into public.company_settings (legal_name, display_name, state, state_code, gstin, pan)
  values (
    p_legal_name,
    coalesce(nullif(btrim(coalesce(p_display_name, '')), ''), p_legal_name),
    p_state, p_state_code, nullif(btrim(coalesce(p_gstin, '')), ''), nullif(btrim(coalesce(p_pan, '')), '')
  )
  returning id into v_id;

  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Final consistency checks -------------------------------------------------
-- ---------------------------------------------------------------------------

-- Every business table must have RLS enabled (document_sequences is internal
-- and has no policies at all, which denies every application role by default).
do $$
declare
  v_table text;
  v_missing text[] := array[]::text[];
begin
  for v_table in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and c.relname not in ('document_sequences')
      and not c.relrowsecurity
    order by c.relname
  loop
    v_missing := v_missing || v_table;
  end loop;

  if array_length(v_missing, 1) > 0 then
    raise exception 'row level security is not enabled on: %', array_to_string(v_missing, ', ');
  end if;
end $$;

-- Tables must not be reachable by the anonymous role.
do $$
declare
  v_leak text;
begin
  select string_agg(table_name, ', ') into v_leak
  from information_schema.role_table_grants
  where grantee = 'anon'
    and table_schema = 'public';

  if v_leak is not null then
    raise exception 'anonymous role holds table privileges on: %', v_leak;
  end if;
end $$;
