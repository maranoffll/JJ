-- ============================================================================
-- JJ MEDIA ERP — PHASE 1 : DATABASE FOUNDATION
-- Migration 06 : projects & production
-- ============================================================================

create table if not exists public.projects (
  id                  uuid primary key default gen_random_uuid(),
  project_code        text not null,
  name                text not null,
  client_id           uuid not null references public.clients (id) on delete restrict,
  status              public.project_status not null default 'DRAFT',
  project_type        text,
  description         text,

  -- schedule
  start_date          date,
  end_date            date,
  deadline            date,
  shoot_start_date    date,
  shoot_end_date      date,
  completed_at        timestamptz,

  -- commercials
  contract_value      numeric(14,2),
  budget              numeric(14,2),
  currency            char(3) not null default 'INR',

  -- delivery
  location            text,
  deliverables        text,
  project_manager_id  uuid references public.user_profiles (id) on delete set null,

  is_deleted          boolean not null default false,
  deleted_at          timestamptz,
  deleted_by          uuid references public.user_profiles (id) on delete set null,

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid,
  updated_by          uuid,

  constraint projects_name_not_blank check (length(btrim(name)) > 0),
  constraint projects_contract_value_non_negative check (contract_value is null or contract_value >= 0),
  constraint projects_budget_non_negative check (budget is null or budget >= 0),
  constraint projects_date_order check (start_date is null or end_date is null or end_date >= start_date),
  constraint projects_shoot_date_order check (shoot_start_date is null or shoot_end_date is null or shoot_end_date >= shoot_start_date),
  constraint projects_deleted_consistency check ((is_deleted and deleted_at is not null) or (not is_deleted)),
  constraint projects_completed_consistency check ((status = 'COMPLETED') = (completed_at is not null))
);

comment on table public.projects is
  'Production project. Commercial value is recognised through issued invoices; costs come from approved expenses.';

create unique index if not exists projects_project_code_key on public.projects (project_code);
create index if not exists projects_client_idx on public.projects (client_id) where not is_deleted;
create index if not exists projects_status_idx on public.projects (status) where not is_deleted;
create index if not exists projects_manager_idx on public.projects (project_manager_id) where not is_deleted;
create index if not exists projects_name_trgm_idx on public.projects using gin (name extensions.gin_trgm_ops);
create index if not exists projects_open_deadline_idx on public.projects (deadline)
  where not is_deleted and status in ('DRAFT', 'IN_PROGRESS', 'ON_HOLD');

create or replace function public.projects_assign_code()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if new.project_code is null or btrim(new.project_code) = '' then
    new.project_code := public.next_sequence_code('project', 'PRJ', 4);
  end if;
  return new;
end $$;

drop trigger if exists projects_assign_code on public.projects;
create trigger projects_assign_code
  before insert on public.projects
  for each row execute function public.projects_assign_code();

-- Status lifecycle guard + completion timestamp bookkeeping.
create or replace function public.projects_guard_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_active_hdds int;
begin
  if new.status = 'COMPLETED' and old.status <> 'COMPLETED' then
    new.completed_at := coalesce(new.completed_at, now());

    -- hdd_assignments is created later in the migration set; resolve it lazily
    -- so the trigger is valid regardless of migration order.
    if to_regclass('public.hdd_assignments') is not null then
      select count(*) into v_active_hdds
      from public.hdd_assignments a
      where a.project_id = new.id and a.status = 'ACTIVE';
    else
      v_active_hdds := 0;
    end if;

    if v_active_hdds > 0 then
      raise exception
        'project % still has % active HDD assignment(s); check the media in before completing',
        new.project_code, v_active_hdds
        using errcode = 'check_violation';
    end if;
  elsif new.status <> 'COMPLETED' then
    new.completed_at := null;
  end if;

  return new;
end $$;

drop trigger if exists projects_guard_lifecycle on public.projects;
create trigger projects_guard_lifecycle
  before update on public.projects
  for each row execute function public.projects_guard_lifecycle();

drop trigger if exists projects_set_updated_at on public.projects;
create trigger projects_set_updated_at
  before update on public.projects
  for each row execute function public.set_updated_at();

drop trigger if exists projects_stamp_actor on public.projects;
create trigger projects_stamp_actor
  before insert or update on public.projects
  for each row execute function public.stamp_actor_columns();

-- Soft delete only, and only with permission. A project that has financial
-- documents (quotations, invoices) can never be removed from the ledger.
create or replace function public.projects_guard_delete()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_docs int;
begin
  if tg_op = 'DELETE' then
    raise exception 'projects cannot be hard deleted; cancel or archive the project instead'
      using errcode = 'insufficient_privilege';
  end if;

  if new.is_deleted is distinct from old.is_deleted then
    perform public.require_permission('projects.delete');

    if new.is_deleted then
      select count(*) into v_docs
      from public.invoices i
      where i.project_id = new.id and i.status <> 'DRAFT';

      if v_docs > 0 then
        raise exception 'project % has % issued invoice(s) and cannot be deleted', new.project_code, v_docs
          using errcode = 'check_violation';
      end if;

      new.deleted_at := coalesce(new.deleted_at, now());
      new.deleted_by := coalesce(new.deleted_by, auth.uid());
    else
      new.deleted_at := null;
      new.deleted_by := null;
    end if;
  end if;

  return new;
end $$;

drop trigger if exists projects_guard_delete on public.projects;
create trigger projects_guard_delete
  before update or delete on public.projects
  for each row execute function public.projects_guard_delete();

drop trigger if exists projects_audit on public.projects;
create trigger projects_audit
  after insert or update on public.projects
  for each row execute function public.audit_row_change();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.projects enable row level security;

drop policy if exists projects_select on public.projects;
create policy projects_select on public.projects
  for select to authenticated
  using (public.has_permission('projects.view'));

drop policy if exists projects_insert on public.projects;
create policy projects_insert on public.projects
  for insert to authenticated
  with check (public.has_permission('projects.create'));

drop policy if exists projects_update on public.projects;
create policy projects_update on public.projects
  for update to authenticated
  using (public.has_permission('projects.update'))
  with check (public.has_permission('projects.update'));

-- Intentionally no DELETE policy: deletion is a permission-guarded soft delete.
