-- ============================================================================
-- JJ MEDIA ERP — PHASE 1 : DATABASE FOUNDATION
-- Migration 00 : extensions, prerequisite roles, domain enum types
-- ----------------------------------------------------------------------------
-- Idempotent. Safe to apply to the live Supabase project (project ref
-- zfrgzunauxozqgdjghso). Everything here is additive; nothing existing is
-- dropped or weakened.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Extensions
-- Supabase hosts extensions in the `extensions` schema; we only need trigram
-- search support for client/project lookup. gen_random_uuid() is core
-- PostgreSQL (13+) so pgcrypto is not required.
-- ---------------------------------------------------------------------------
create schema if not exists extensions;
create extension if not exists pg_trgm with schema extensions;

comment on schema extensions is 'Host schema for PostgreSQL extensions (Supabase convention).';

-- ---------------------------------------------------------------------------
-- Prerequisite roles.
-- On Supabase these roles already exist (anon / authenticated / service_role)
-- and this block is a no-op. On a plain PostgreSQL instance (local database
-- tests, CI) it provisions the same role names so migrations are portable.
-- ---------------------------------------------------------------------------
do $$
declare
  v_role text;
begin
  foreach v_role in array array['anon', 'authenticated', 'service_role']
  loop
    if not exists (select 1 from pg_roles where rolname = v_role) then
      execute format('create role %I nologin noinherit', v_role);
      raise notice 'Created prerequisite role %', v_role;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Domain enum types (create-if-missing so re-running is harmless)
-- ---------------------------------------------------------------------------
do $$
begin
  -- Application user roles. This is the ERP role model; it is deliberately
  -- independent from anything in the Supabase dashboard.
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where t.typname = 'user_role' and n.nspname = 'public') then
    create type public.user_role as enum ('ADMIN', 'MANAGER', 'FINANCE', 'PRODUCTION', 'VIEWER');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where t.typname = 'tax_type' and n.nspname = 'public') then
    create type public.tax_type as enum ('INTRA_STATE', 'INTER_STATE');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where t.typname = 'client_status' and n.nspname = 'public') then
    create type public.client_status as enum ('PROSPECT', 'ACTIVE', 'INACTIVE', 'ARCHIVED');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where t.typname = 'client_type' and n.nspname = 'public') then
    create type public.client_type as enum ('CORPORATE', 'INDIVIDUAL', 'GOVERNMENT', 'NON_PROFIT', 'AGENCY');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where t.typname = 'project_status' and n.nspname = 'public') then
    create type public.project_status as enum ('DRAFT', 'IN_PROGRESS', 'ON_HOLD', 'COMPLETED', 'CANCELLED', 'ARCHIVED');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where t.typname = 'quotation_status' and n.nspname = 'public') then
    create type public.quotation_status as enum ('DRAFT', 'SENT', 'ACCEPTED', 'REJECTED', 'EXPIRED', 'CONVERTED', 'CANCELLED');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where t.typname = 'invoice_status' and n.nspname = 'public') then
    create type public.invoice_status as enum ('DRAFT', 'ISSUED', 'CANCELLED');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where t.typname = 'credit_note_status' and n.nspname = 'public') then
    create type public.credit_note_status as enum ('DRAFT', 'ISSUED', 'CANCELLED');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where t.typname = 'payment_status' and n.nspname = 'public') then
    create type public.payment_status as enum ('POSTED', 'VOIDED');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where t.typname = 'payment_method' and n.nspname = 'public') then
    create type public.payment_method as enum ('CASH', 'CHEQUE', 'BANK_TRANSFER', 'NEFT', 'RTGS', 'IMPS', 'UPI', 'CARD', 'OTHER');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where t.typname = 'expense_status' and n.nspname = 'public') then
    create type public.expense_status as enum ('DRAFT', 'APPROVED', 'VOID');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where t.typname = 'hdd_status' and n.nspname = 'public') then
    create type public.hdd_status as enum ('AVAILABLE', 'CHECKED_OUT', 'IN_TRANSIT', 'MAINTENANCE', 'ARCHIVED');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where t.typname = 'hdd_assignment_status' and n.nspname = 'public') then
    create type public.hdd_assignment_status as enum ('ACTIVE', 'RETURNED', 'CANCELLED');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where t.typname = 'hdd_event_type' and n.nspname = 'public') then
    create type public.hdd_event_type as enum (
      'CREATED', 'STATUS_CHANGED', 'CHECKED_OUT', 'CHECKED_IN', 'LOCATION_CHANGED',
      'MAINTENANCE', 'ARCHIVED', 'RESTORED', 'NOTE'
    );
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where t.typname = 'attachment_entity' and n.nspname = 'public') then
    create type public.attachment_entity as enum (
      'CLIENT', 'PROJECT', 'QUOTATION', 'INVOICE', 'CREDIT_NOTE', 'PAYMENT', 'EXPENSE', 'HDD'
    );
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where t.typname = 'audit_action' and n.nspname = 'public') then
    create type public.audit_action as enum ('INSERT', 'UPDATE', 'DELETE', 'ISSUE', 'CANCEL', 'VOID', 'LOGIN', 'OTHER');
  end if;
end $$;
