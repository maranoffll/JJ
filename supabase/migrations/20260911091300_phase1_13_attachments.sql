-- ============================================================================
-- JJ MEDIA ERP — PHASE 1 : DATABASE FOUNDATION
-- Migration 13 : attachments (polymorphic file links to Supabase Storage)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Entity access helpers. Attachment visibility always follows the visibility of
-- the entity it is attached to — a user cannot see a file on a record they
-- cannot see, and cannot attach a file to a record they cannot edit.
-- ---------------------------------------------------------------------------
create or replace function public.entity_view_permission(p_entity public.attachment_entity)
returns text
language sql
immutable
as $$
  select case p_entity
    when 'CLIENT'      then 'clients.view'
    when 'PROJECT'     then 'projects.view'
    when 'QUOTATION'   then 'quotations.view'
    when 'INVOICE'     then 'invoices.view'
    when 'CREDIT_NOTE' then 'credit_notes.view'
    when 'PAYMENT'     then 'payments.view'
    when 'EXPENSE'     then 'expenses.view'
    when 'HDD'         then 'hdd.view'
  end;
$$;

create or replace function public.entity_write_permission(p_entity public.attachment_entity)
returns text
language sql
immutable
as $$
  select case p_entity
    when 'CLIENT'      then 'clients.update'
    when 'PROJECT'     then 'projects.update'
    when 'QUOTATION'   then 'quotations.update'
    when 'INVOICE'     then 'invoices.update'
    when 'CREDIT_NOTE' then 'credit_notes.create'
    when 'PAYMENT'     then 'payments.create'
    when 'EXPENSE'     then 'expenses.update'
    when 'HDD'         then 'hdd.update'
  end;
$$;

create or replace function public.entity_exists(p_entity public.attachment_entity, p_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_exists boolean := false;
begin
  case p_entity
    when 'CLIENT'      then select exists (select 1 from public.clients where id = p_id) into v_exists;
    when 'PROJECT'     then select exists (select 1 from public.projects where id = p_id) into v_exists;
    when 'QUOTATION'   then select exists (select 1 from public.quotations where id = p_id) into v_exists;
    when 'INVOICE'     then select exists (select 1 from public.invoices where id = p_id) into v_exists;
    when 'CREDIT_NOTE' then select exists (select 1 from public.credit_notes where id = p_id) into v_exists;
    when 'PAYMENT'     then select exists (select 1 from public.payments where id = p_id) into v_exists;
    when 'EXPENSE'     then select exists (select 1 from public.expenses where id = p_id) into v_exists;
    when 'HDD'         then select exists (select 1 from public.hdds where id = p_id) into v_exists;
  end case;

  return v_exists;
end $$;

create or replace function public.can_view_entity(p_entity public.attachment_entity, p_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select public.has_permission(public.entity_view_permission(p_entity))
     and public.entity_exists(p_entity, p_id);
$$;

create or replace function public.can_write_entity(p_entity public.attachment_entity, p_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select public.has_permission(public.entity_write_permission(p_entity))
     and public.entity_exists(p_entity, p_id);
$$;

-- ---------------------------------------------------------------------------
create table if not exists public.attachments (
  id            uuid primary key default gen_random_uuid(),
  entity_type   public.attachment_entity not null,
  entity_id     uuid not null,
  file_name     text not null,
  title         text,
  description   text,
  storage_bucket text not null default 'erp-attachments',
  storage_path  text not null,
  mime_type     text,
  size_bytes    bigint,
  checksum      text,
  is_deleted    boolean not null default false,
  deleted_at    timestamptz,
  uploaded_by   uuid references public.user_profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid,
  updated_by    uuid,

  constraint attachments_file_name_not_blank check (length(btrim(file_name)) > 0),
  constraint attachments_storage_path_not_blank check (length(btrim(storage_path)) > 0),
  constraint attachments_size_non_negative check (size_bytes is null or size_bytes >= 0)
);

comment on table public.attachments is
  'File metadata for Supabase Storage objects, linked to a business entity. Visibility follows the entity.';

create unique index if not exists attachments_storage_key on public.attachments (storage_bucket, storage_path);
create index if not exists attachments_entity_idx on public.attachments (entity_type, entity_id) where not is_deleted;
create index if not exists attachments_uploader_idx on public.attachments (uploaded_by, created_at desc);

create or replace function public.attachments_validate()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_invoice public.invoices;
begin
  if not public.entity_exists(new.entity_type, new.entity_id) then
    raise exception 'cannot attach a file to a % that does not exist', new.entity_type
      using errcode = 'foreign_key_violation';
  end if;

  -- Issued invoices are immutable documents: their attachments are frozen too.
  if new.entity_type = 'INVOICE' then
    select * into v_invoice from public.invoices where id = new.entity_id;
    if v_invoice.status <> 'DRAFT' and tg_op = 'UPDATE' then
      raise exception 'invoice % is % — its attachments cannot be changed',
        v_invoice.invoice_number, v_invoice.status
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  if tg_op = 'INSERT' then
    perform public.require_permission('attachments.upload');
  end if;

  if new.is_deleted and not old.is_deleted then
    perform public.require_permission('attachments.delete');
    new.deleted_at := coalesce(new.deleted_at, now());
  end if;

  return new;
end $$;

drop trigger if exists attachments_validate on public.attachments;
create trigger attachments_validate
  before insert or update on public.attachments
  for each row execute function public.attachments_validate();

drop trigger if exists attachments_set_updated_at on public.attachments;
create trigger attachments_set_updated_at
  before update on public.attachments
  for each row execute function public.set_updated_at();

drop trigger if exists attachments_stamp_actor on public.attachments;
create trigger attachments_stamp_actor
  before insert or update on public.attachments
  for each row execute function public.stamp_actor_columns();

drop trigger if exists attachments_audit on public.attachments;
create trigger attachments_audit
  after insert or update on public.attachments
  for each row execute function public.audit_row_change();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.attachments enable row level security;

drop policy if exists attachments_select on public.attachments;
create policy attachments_select on public.attachments
  for select to authenticated
  using (not is_deleted and public.can_view_entity(entity_type, entity_id));

drop policy if exists attachments_insert on public.attachments;
create policy attachments_insert on public.attachments
  for insert to authenticated
  with check (public.can_write_entity(entity_type, entity_id));

drop policy if exists attachments_update on public.attachments;
create policy attachments_update on public.attachments
  for update to authenticated
  using (public.can_view_entity(entity_type, entity_id))
  with check (public.can_view_entity(entity_type, entity_id));

-- ---------------------------------------------------------------------------
-- Supabase Storage. Object-level policies mirror the table policies so a file
-- cannot be fetched directly from Storage without the matching ERP permission.
-- The storage schema only exists on Supabase, so this block is skipped on a
-- plain PostgreSQL instance.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bucket text := 'erp-attachments';
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'storage schema not present — skipping storage bucket/policies';
    return;
  end if;

  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values (
    v_bucket, v_bucket, false,
    52428800,
    array['application/pdf', 'image/png', 'image/jpeg', 'image/webp', 'image/heic',
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          'text/csv', 'application/zip', 'video/mp4', 'audio/wav', 'audio/mpeg']
  )
  on conflict (id) do nothing;

  execute 'drop policy if exists erp_attachments_read on storage.objects';
  execute $pol$
    create policy erp_attachments_read on storage.objects
      for select to authenticated
      using (
        bucket_id = 'erp-attachments'
        and exists (
          select 1 from public.attachments a
          where a.storage_bucket = bucket_id
            and a.storage_path = name
            and not a.is_deleted
            and public.can_view_entity(a.entity_type, a.entity_id)
        )
      )
  $pol$;

  execute 'drop policy if exists erp_attachments_write on storage.objects';
  execute $pol$
    create policy erp_attachments_write on storage.objects
      for insert to authenticated
      with check (bucket_id = 'erp-attachments' and public.is_authenticated_user())
  $pol$;

  execute 'drop policy if exists erp_attachments_delete on storage.objects';
  execute $pol$
    create policy erp_attachments_delete on storage.objects
      for delete to authenticated
      using (
        bucket_id = 'erp-attachments'
        and exists (
          select 1 from public.attachments a
          where a.storage_bucket = bucket_id
            and a.storage_path = name
            and public.has_permission('attachments.delete')
        )
      )
  $pol$;
end $$;
