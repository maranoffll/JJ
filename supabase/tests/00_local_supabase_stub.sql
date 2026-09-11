-- ============================================================================
-- LOCAL / CI ONLY — NOT A PRODUCTION MIGRATION
-- ----------------------------------------------------------------------------
-- Minimal emulation of the Supabase-managed pieces that JJ Media ERP
-- migrations depend on:
--   * schema `auth` with `auth.users`
--   * `auth.uid()`, `auth.role()`, `auth.email()`, `auth.jwt()`
--   * roles anon / authenticated / service_role (created in migration 00)
--
-- This file is applied by `npm run db:test` before the migrations so the exact
-- production migration set can be executed and RLS can be tested against a
-- plain PostgreSQL instance. It is NEVER applied to the live Supabase project,
-- where these objects are provided by the platform.
-- ============================================================================

create schema if not exists auth;

create table if not exists auth.users (
  id                  uuid primary key default gen_random_uuid(),
  email               text,
  encrypted_password  text,
  raw_user_meta_data  jsonb not null default '{}'::jsonb,
  raw_app_meta_data   jsonb not null default '{}'::jsonb,
  email_confirmed_at  timestamptz,
  last_sign_in_at     timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create unique index if not exists auth_users_email_key on auth.users (lower(email));

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

create or replace function auth.role()
returns text
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.role', true), '');
$$;

create or replace function auth.email()
returns text
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.email', true), '');
$$;

create or replace function auth.jwt()
returns jsonb
language sql
stable
as $$
  select coalesce(
           nullif(current_setting('request.jwt.claims', true), '')::jsonb,
           jsonb_build_object(
             'sub',  auth.uid(),
             'role', auth.role(),
             'email', auth.email()
           )
         );
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.role(), auth.email(), auth.jwt() to anon, authenticated, service_role;
