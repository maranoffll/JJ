-- ============================================================================
-- JJ MEDIA ERP — PHASE 1 : DATABASE FOUNDATION
-- Migration 12 : HDD & media asset management
-- ----------------------------------------------------------------------------
-- Custody model:
--   hdds             current state of each physical drive
--   hdd_assignments  one row per checkout; at most ONE ACTIVE row per drive
--   hdd_logs         append-only custody history (separate from audit_logs)
-- Checkout/check-in are atomic and concurrency-safe.
-- ============================================================================

create table if not exists public.hdd_locations (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  location_type text not null default 'OFFICE',
  address      text,
  contact_name text,
  contact_phone text,
  is_active    boolean not null default true,
  notes        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  created_by   uuid,
  updated_by   uuid,

  constraint hdd_locations_name_not_blank check (length(btrim(name)) > 0)
);

comment on table public.hdd_locations is 'Physical places a drive can live (office, studio, client site, warehouse).';

create unique index if not exists hdd_locations_name_key on public.hdd_locations (lower(name));
create index if not exists hdd_locations_active_idx on public.hdd_locations (name) where is_active;

-- ---------------------------------------------------------------------------
create table if not exists public.hdds (
  id                 uuid primary key default gen_random_uuid(),
  asset_tag          text not null,
  serial_number      text,
  label              text,
  brand              text,
  model              text,
  capacity_gb        numeric(12,2),
  interface          text,
  drive_type         text not null default 'HDD',

  purchase_date      date,
  purchase_price     numeric(12,2),
  vendor_name        text,
  warranty_until     date,

  status             public.hdd_status not null default 'AVAILABLE',
  current_location_id uuid references public.hdd_locations (id) on delete set null,
  condition          text not null default 'GOOD',
  qr_token           text not null default replace(gen_random_uuid()::text, '-', ''),

  last_verified_at   timestamptz,
  notes              text,

  is_deleted         boolean not null default false,
  deleted_at         timestamptz,

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  created_by         uuid,
  updated_by         uuid,

  constraint hdds_asset_tag_not_blank check (length(btrim(asset_tag)) > 0),
  constraint hdds_capacity_positive check (capacity_gb is null or capacity_gb > 0),
  constraint hdds_purchase_price_non_negative check (purchase_price is null or purchase_price >= 0),
  constraint hdds_condition_values check (condition in ('NEW', 'GOOD', 'FAIR', 'DAMAGED', 'FAILING', 'RETIRED')),
  constraint hdds_deleted_consistency check ((is_deleted and deleted_at is not null) or (not is_deleted))
);

comment on table public.hdds is 'Physical media asset (drive) with its current custody status and location.';

create unique index if not exists hdds_asset_tag_key on public.hdds (asset_tag);
create unique index if not exists hdds_serial_key on public.hdds (serial_number) where serial_number is not null and serial_number <> '';
create unique index if not exists hdds_qr_token_key on public.hdds (qr_token);
create index if not exists hdds_status_idx on public.hdds (status) where not is_deleted;
create index if not exists hdds_location_idx on public.hdds (current_location_id) where not is_deleted;
create index if not exists hdds_label_trgm_idx on public.hdds using gin (coalesce(label, '') extensions.gin_trgm_ops);

-- ---------------------------------------------------------------------------
create table if not exists public.hdd_assignments (
  id                   uuid primary key default gen_random_uuid(),
  hdd_id               uuid not null references public.hdds (id) on delete restrict,
  project_id           uuid references public.projects (id) on delete set null,

  assigned_to          uuid references public.user_profiles (id) on delete set null,
  assigned_to_name     text,
  assigned_to_phone    text,

  status               public.hdd_assignment_status not null default 'ACTIVE',
  checked_out_at       timestamptz not null default now(),
  expected_return_date date,
  returned_at          timestamptz,

  checkout_location_id uuid references public.hdd_locations (id) on delete set null,
  return_location_id   uuid references public.hdd_locations (id) on delete set null,

  condition_out        text,
  condition_in         text,
  checkout_notes       text,
  return_notes         text,

  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  created_by           uuid,
  updated_by           uuid,

  constraint hdd_assignments_holder_required check (
    assigned_to is not null or coalesce(btrim(assigned_to_name), '') <> ''
  ),
  constraint hdd_assignments_return_consistency check (
    (status = 'ACTIVE' and returned_at is null)
    or (status = 'RETURNED' and returned_at is not null)
    or (status = 'CANCELLED')
  ),
  constraint hdd_assignments_expected_return_order check (
    expected_return_date is null or expected_return_date >= checked_out_at::date
  )
);

comment on table public.hdd_assignments is
  'Checkout record. A partial unique index guarantees at most one ACTIVE assignment per drive.';

create unique index if not exists hdd_assignments_one_active_per_hdd
  on public.hdd_assignments (hdd_id)
  where status = 'ACTIVE';

create index if not exists hdd_assignments_project_idx on public.hdd_assignments (project_id, status);
create index if not exists hdd_assignments_overdue_idx on public.hdd_assignments (expected_return_date)
  where status = 'ACTIVE';
create index if not exists hdd_assignments_assignee_idx on public.hdd_assignments (assigned_to, status);

-- ---------------------------------------------------------------------------
-- HDD custody ledger — append-only.
-- ---------------------------------------------------------------------------
create table if not exists public.hdd_logs (
  id               uuid primary key default gen_random_uuid(),
  hdd_id           uuid not null references public.hdds (id) on delete cascade,
  event            public.hdd_event_type not null,
  from_status      public.hdd_status,
  to_status        public.hdd_status,
  from_location_id uuid references public.hdd_locations (id) on delete set null,
  to_location_id   uuid references public.hdd_locations (id) on delete set null,
  project_id       uuid references public.projects (id) on delete set null,
  assignment_id    uuid references public.hdd_assignments (id) on delete set null,
  actor_id         uuid references public.user_profiles (id) on delete set null,
  actor_name       text,
  note             text,
  created_at       timestamptz not null default now()
);

comment on table public.hdd_logs is
  'Append-only HDD custody history. Deliberately separate from public.audit_logs (business audit trail).';

create index if not exists hdd_logs_hdd_idx on public.hdd_logs (hdd_id, created_at desc);
create index if not exists hdd_logs_project_idx on public.hdd_logs (project_id, created_at desc) where project_id is not null;
create index if not exists hdd_logs_event_idx on public.hdd_logs (event, created_at desc);

create or replace function public.hdd_logs_block_mutation()
returns trigger
language plpgsql
as $$
begin
  if coalesce(current_setting('app.allow_hdd_log_maintenance', true), 'off') = 'on' then
    return null;
  end if;

  raise exception 'public.hdd_logs is append-only; % is not permitted', tg_op
    using errcode = 'insufficient_privilege';
end $$;

drop trigger if exists hdd_logs_immutable_update on public.hdd_logs;
create trigger hdd_logs_immutable_update
  before update on public.hdd_logs
  for each statement execute function public.hdd_logs_block_mutation();

drop trigger if exists hdd_logs_immutable_delete on public.hdd_logs;
create trigger hdd_logs_immutable_delete
  before delete on public.hdd_logs
  for each statement execute function public.hdd_logs_block_mutation();

-- ---------------------------------------------------------------------------
-- Internal helper: append a custody event.
-- ---------------------------------------------------------------------------
create or replace function public.write_hdd_log(
  p_hdd_id          uuid,
  p_event           public.hdd_event_type,
  p_from_status     public.hdd_status default null,
  p_to_status       public.hdd_status default null,
  p_from_location   uuid default null,
  p_to_location     uuid default null,
  p_project_id      uuid default null,
  p_assignment_id   uuid default null,
  p_note            text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_id    uuid;
  v_name  text;
begin
  select p.full_name into v_name from public.user_profiles p where p.id = auth.uid();

  insert into public.hdd_logs (
    hdd_id, event, from_status, to_status, from_location_id, to_location_id,
    project_id, assignment_id, actor_id, actor_name, note
  )
  values (
    p_hdd_id, p_event, p_from_status, p_to_status, p_from_location, p_to_location,
    p_project_id, p_assignment_id, auth.uid(), v_name, p_note
  )
  returning id into v_id;

  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- HDD state machine guard: status may only move through the supported graph,
-- and CHECKED_OUT is only valid while an ACTIVE assignment exists.
-- ---------------------------------------------------------------------------
create or replace function public.hdds_guard_status()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_active int;
begin
  if new.status is distinct from old.status then
    if new.status = 'CHECKED_OUT' then
      select count(*) into v_active
      from public.hdd_assignments a
      where a.hdd_id = new.id and a.status = 'ACTIVE';

      if v_active = 0 then
        raise exception 'drive % cannot be marked CHECKED_OUT without an active assignment; use checkout_hdd()',
          new.asset_tag
          using errcode = 'check_violation';
      end if;
    end if;

    if old.status = 'CHECKED_OUT' and new.status = 'AVAILABLE' then
      select count(*) into v_active
      from public.hdd_assignments a
      where a.hdd_id = new.id and a.status = 'ACTIVE';

      if v_active > 0 then
        raise exception 'drive % still has an active assignment; use checkin_hdd()',
          new.asset_tag
          using errcode = 'check_violation';
      end if;
    end if;
  end if;

  if new.is_deleted and not old.is_deleted then
    perform public.require_permission('hdd.archive');
    new.deleted_at := coalesce(new.deleted_at, now());
    if new.status <> 'ARCHIVED' then
      new.status := 'ARCHIVED';
    end if;
  end if;

  return new;
end $$;

create or replace function public.hdds_assign_tag()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if new.asset_tag is null or btrim(new.asset_tag) = '' then
    new.asset_tag := public.next_sequence_code('hdd', 'HDD', 4);
  end if;
  return new;
end $$;

drop trigger if exists hdds_assign_tag on public.hdds;
create trigger hdds_assign_tag
  before insert on public.hdds
  for each row execute function public.hdds_assign_tag();

drop trigger if exists hdds_set_updated_at on public.hdds;
create trigger hdds_set_updated_at
  before update on public.hdds
  for each row execute function public.set_updated_at();

drop trigger if exists hdds_stamp_actor on public.hdds;
create trigger hdds_stamp_actor
  before insert or update on public.hdds
  for each row execute function public.stamp_actor_columns();

drop trigger if exists hdds_guard_status on public.hdds;
create trigger hdds_guard_status
  before update on public.hdds
  for each row execute function public.hdds_guard_status();

drop trigger if exists hdds_audit on public.hdds;
create trigger hdds_audit
  after insert or update on public.hdds
  for each row execute function public.audit_row_change();

create or replace function public.hdds_record_change()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    perform public.write_hdd_log(
      p_hdd_id      => new.id,
      p_event       => 'CREATED',
      p_to_status   => new.status,
      p_to_location => new.current_location_id,
      p_note        => format('Drive %s registered', new.asset_tag)
    );
    return null;
  end if;

  if new.status is distinct from old.status then
    perform public.write_hdd_log(
      p_hdd_id        => new.id,
      p_event         => 'STATUS_CHANGED',
      p_from_status   => old.status,
      p_to_status     => new.status,
      p_from_location => old.current_location_id,
      p_to_location   => new.current_location_id
    );
  elsif new.current_location_id is distinct from old.current_location_id then
    perform public.write_hdd_log(
      p_hdd_id        => new.id,
      p_event         => 'LOCATION_CHANGED',
      p_from_status   => old.status,
      p_to_status     => new.status,
      p_from_location => old.current_location_id,
      p_to_location   => new.current_location_id
    );
  end if;

  return null;
end $$;

drop trigger if exists hdds_log_status_change on public.hdds;
create trigger hdds_log_status_change
  after insert or update on public.hdds
  for each row execute function public.hdds_record_change();

drop trigger if exists hdd_assignments_set_updated_at on public.hdd_assignments;
create trigger hdd_assignments_set_updated_at
  before update on public.hdd_assignments
  for each row execute function public.set_updated_at();

drop trigger if exists hdd_assignments_stamp_actor on public.hdd_assignments;
create trigger hdd_assignments_stamp_actor
  before insert or update on public.hdd_assignments
  for each row execute function public.stamp_actor_columns();

-- ---------------------------------------------------------------------------
-- Checkout / check-in — atomic and concurrency-safe.
-- ---------------------------------------------------------------------------
create or replace function public.checkout_hdd(
  p_hdd_id             uuid,
  p_project_id         uuid default null,
  p_assigned_to        uuid default null,
  p_assigned_to_name   text default null,
  p_assigned_to_phone  text default null,
  p_expected_return    date default null,
  p_location_id        uuid default null,
  p_condition_out      text default null,
  p_notes              text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_hdd        public.hdds;
  v_active     int;
  v_assignment uuid;
begin
  perform public.require_permission('hdd.checkout');

  -- Lock the drive: concurrent checkouts serialise here.
  select * into v_hdd from public.hdds where id = p_hdd_id for update;

  if not found then
    raise exception 'drive % not found', p_hdd_id using errcode = 'no_data_found';
  end if;

  if v_hdd.is_deleted then
    raise exception 'drive % is archived and cannot be checked out', v_hdd.asset_tag
      using errcode = 'check_violation';
  end if;

  if v_hdd.status <> 'AVAILABLE' then
    raise exception 'drive % is % and cannot be checked out', v_hdd.asset_tag, v_hdd.status
      using errcode = 'check_violation';
  end if;

  select count(*) into v_active
  from public.hdd_assignments a
  where a.hdd_id = p_hdd_id and a.status = 'ACTIVE';

  if v_active > 0 then
    raise exception 'drive % already has an active assignment', v_hdd.asset_tag
      using errcode = 'unique_violation';
  end if;

  if p_assigned_to is null and coalesce(btrim(p_assigned_to_name), '') = '' then
    raise exception 'a custodian (user or name) is required for checkout'
      using errcode = 'check_violation';
  end if;

  insert into public.hdd_assignments (
    hdd_id, project_id, assigned_to, assigned_to_name, assigned_to_phone,
    status, checked_out_at, expected_return_date, checkout_location_id,
    condition_out, checkout_notes
  )
  values (
    p_hdd_id, p_project_id, p_assigned_to, nullif(btrim(coalesce(p_assigned_to_name, '')), ''),
    nullif(btrim(coalesce(p_assigned_to_phone, '')), ''),
    'ACTIVE', now(), p_expected_return,
    coalesce(p_location_id, v_hdd.current_location_id),
    coalesce(p_condition_out, v_hdd.condition),
    nullif(btrim(coalesce(p_notes, '')), '')
  )
  returning id into v_assignment;

  update public.hdds
     set status = 'CHECKED_OUT'
   where id = p_hdd_id;

  perform public.write_hdd_log(
    p_hdd_id        => p_hdd_id,
    p_event         => 'CHECKED_OUT',
    p_from_status   => 'AVAILABLE',
    p_to_status     => 'CHECKED_OUT',
    p_from_location => v_hdd.current_location_id,
    p_to_location   => coalesce(p_location_id, v_hdd.current_location_id),
    p_project_id    => p_project_id,
    p_assignment_id => v_assignment,
    p_note          => coalesce(nullif(btrim(coalesce(p_notes, '')), ''), 'Checked out')
  );

  perform public.write_audit_log(
    p_action       => 'OTHER',
    p_entity_table => 'hdds',
    p_entity_id    => p_hdd_id,
    p_entity_label => v_hdd.asset_tag,
    p_project_id   => p_project_id,
    p_summary      => format('Drive %s checked out', v_hdd.asset_tag)
  );

  return v_assignment;
end $$;

comment on function public.checkout_hdd is
  'Atomically checks a drive out. Locks the drive row and enforces one ACTIVE assignment per drive.';

create or replace function public.checkin_hdd(
  p_assignment_id   uuid,
  p_condition_in    text default null,
  p_location_id     uuid default null,
  p_notes           text default null,
  p_needs_maintenance boolean default false
)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_assignment public.hdd_assignments;
  v_hdd        public.hdds;
  v_new_status public.hdd_status;
begin
  perform public.require_permission('hdd.checkin');

  select * into v_assignment from public.hdd_assignments where id = p_assignment_id for update;

  if not found then
    raise exception 'assignment % not found', p_assignment_id using errcode = 'no_data_found';
  end if;

  if v_assignment.status <> 'ACTIVE' then
    raise exception 'assignment is % and cannot be checked in', v_assignment.status
      using errcode = 'check_violation';
  end if;

  select * into v_hdd from public.hdds where id = v_assignment.hdd_id for update;

  if not found then
    raise exception 'drive % not found', v_assignment.hdd_id using errcode = 'no_data_found';
  end if;

  v_new_status := case
    when p_needs_maintenance then 'MAINTENANCE'::public.hdd_status
    when coalesce(p_condition_in, v_hdd.condition) in ('DAMAGED', 'FAILING', 'RETIRED') then 'MAINTENANCE'::public.hdd_status
    when v_hdd.status = 'ARCHIVED' then 'ARCHIVED'::public.hdd_status
    else 'AVAILABLE'::public.hdd_status
  end;

  update public.hdd_assignments
     set status = 'RETURNED',
         returned_at = now(),
         condition_in = coalesce(p_condition_in, condition_out),
         return_location_id = p_location_id,
         return_notes = nullif(btrim(coalesce(p_notes, '')), '')
   where id = p_assignment_id;

  update public.hdds
     set status = v_new_status,
         condition = coalesce(p_condition_in, condition),
         current_location_id = coalesce(p_location_id, current_location_id),
         last_verified_at = now()
   where id = v_assignment.hdd_id;

  perform public.write_hdd_log(
    p_hdd_id        => v_assignment.hdd_id,
    p_event         => 'CHECKED_IN',
    p_from_status   => v_hdd.status,
    p_to_status     => v_new_status,
    p_from_location => v_hdd.current_location_id,
    p_to_location   => coalesce(p_location_id, v_hdd.current_location_id),
    p_project_id    => v_assignment.project_id,
    p_assignment_id => p_assignment_id,
    p_note          => coalesce(nullif(btrim(coalesce(p_notes, '')), ''), 'Checked in')
  );

  perform public.write_audit_log(
    p_action       => 'OTHER',
    p_entity_table => 'hdds',
    p_entity_id    => v_assignment.hdd_id,
    p_entity_label => v_hdd.asset_tag,
    p_project_id   => v_assignment.project_id,
    p_summary      => format('Drive %s checked in as %s', v_hdd.asset_tag, v_new_status)
  );
end $$;

comment on function public.checkin_hdd is
  'Atomically returns a drive: closes the assignment, updates custody state and appends the custody log.';

-- Move a drive between locations (logs a LOCATION_CHANGED custody event).
create or replace function public.transfer_hdd_location(
  p_hdd_id      uuid,
  p_location_id uuid,
  p_note        text default null
)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_hdd public.hdds;
begin
  perform public.require_permission('hdd.update');

  select * into v_hdd from public.hdds where id = p_hdd_id for update;

  if not found then
    raise exception 'drive % not found', p_hdd_id using errcode = 'no_data_found';
  end if;

  if v_hdd.current_location_id is not distinct from p_location_id then
    return;
  end if;

  update public.hdds set current_location_id = p_location_id where id = p_hdd_id;
end $$;

create or replace function public.set_hdd_maintenance(
  p_hdd_id uuid,
  p_note    text default null
)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_hdd public.hdds;
begin
  perform public.require_permission('hdd.update');

  select * into v_hdd from public.hdds where id = p_hdd_id for update;

  if not found then
    raise exception 'drive % not found', p_hdd_id using errcode = 'no_data_found';
  end if;

  if v_hdd.status = 'CHECKED_OUT' then
    raise exception 'drive % is checked out — check it in first', v_hdd.asset_tag
      using errcode = 'check_violation';
  end if;

  update public.hdds set status = 'MAINTENANCE' where id = p_hdd_id;

  perform public.write_hdd_log(
    p_hdd_id      => p_hdd_id,
    p_event       => 'MAINTENANCE',
    p_from_status => v_hdd.status,
    p_to_status   => 'MAINTENANCE',
    p_note        => p_note
  );
end $$;

create or replace function public.archive_hdd(
  p_hdd_id uuid,
  p_note    text default null
)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_hdd public.hdds;
begin
  perform public.require_permission('hdd.archive');

  select * into v_hdd from public.hdds where id = p_hdd_id for update;

  if not found then
    raise exception 'drive % not found', p_hdd_id using errcode = 'no_data_found';
  end if;

  if v_hdd.status = 'CHECKED_OUT' then
    raise exception 'drive % is checked out — check it in before archiving', v_hdd.asset_tag
      using errcode = 'check_violation';
  end if;

  update public.hdds
     set status = 'ARCHIVED',
         is_deleted = true,
         deleted_at = coalesce(deleted_at, now())
   where id = p_hdd_id;

  perform public.write_hdd_log(
    p_hdd_id      => p_hdd_id,
    p_event       => 'ARCHIVED',
    p_from_status => v_hdd.status,
    p_to_status   => 'ARCHIVED',
    p_note        => p_note
  );
end $$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.hdds enable row level security;
alter table public.hdd_assignments enable row level security;
alter table public.hdd_locations enable row level security;
alter table public.hdd_logs enable row level security;

drop policy if exists hdds_select on public.hdds;
create policy hdds_select on public.hdds
  for select to authenticated
  using (public.has_permission('hdd.view'));

drop policy if exists hdds_insert on public.hdds;
create policy hdds_insert on public.hdds
  for insert to authenticated
  with check (public.has_permission('hdd.create'));

drop policy if exists hdds_update on public.hdds;
create policy hdds_update on public.hdds
  for update to authenticated
  using (public.has_permission('hdd.update') or public.has_permission('hdd.checkout') or public.has_permission('hdd.checkin') or public.has_permission('hdd.archive'))
  with check (public.has_permission('hdd.update') or public.has_permission('hdd.checkout') or public.has_permission('hdd.checkin') or public.has_permission('hdd.archive'));

drop policy if exists hdd_assignments_select on public.hdd_assignments;
create policy hdd_assignments_select on public.hdd_assignments
  for select to authenticated
  using (public.has_permission('hdd.view'));

drop policy if exists hdd_assignments_insert on public.hdd_assignments;
create policy hdd_assignments_insert on public.hdd_assignments
  for insert to authenticated
  with check (public.has_permission('hdd.checkout'));

drop policy if exists hdd_assignments_update on public.hdd_assignments;
create policy hdd_assignments_update on public.hdd_assignments
  for update to authenticated
  using (public.has_permission('hdd.update') or public.has_permission('hdd.checkin'))
  with check (public.has_permission('hdd.update') or public.has_permission('hdd.checkin'));

drop policy if exists hdd_locations_select on public.hdd_locations;
create policy hdd_locations_select on public.hdd_locations
  for select to authenticated
  using (public.has_permission('hdd.view'));

drop policy if exists hdd_locations_write on public.hdd_locations;
create policy hdd_locations_write on public.hdd_locations
  for all to authenticated
  using (public.has_permission('hdd.update'))
  with check (public.has_permission('hdd.update'));

drop policy if exists hdd_logs_select on public.hdd_logs;
create policy hdd_logs_select on public.hdd_logs
  for select to authenticated
  using (public.has_permission('hdd.view'));

-- hdd_logs has no INSERT policy: custody events are written by SECURITY DEFINER
-- functions only. UPDATE/DELETE are blocked by the append-only triggers.
