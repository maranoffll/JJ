-- ============================================================================
-- PHASE 1 TEST — HDD custody & attachments
--   * asset tagging, custody state machine, single active assignment
--   * check-in with damage routing to maintenance
--   * overdue detection, custody ledger (append-only), project linkage
--   * attachment entity validation and permission inheritance
-- ============================================================================

select db_test.plan_start('phase1: hdd & attachments');

create temporary table tt4 (k text primary key, v uuid) on commit drop;

do $$
declare
  v_client uuid;
  v_project uuid;
  v_location uuid;
  v_hdd uuid;
begin
  insert into public.clients (name, billing_state_code) values ('HDD Test Client', '27') returning id into v_client;
  insert into public.projects (name, client_id, status) values ('HDD Test Project', v_client, 'IN_PROGRESS') returning id into v_project;
  insert into public.hdd_locations (name, location_type) values ('HDD Test Studio', 'STUDIO') returning id into v_location;

  insert into public.hdds (label, capacity_gb, brand, current_location_id)
  values ('Test drive A', 2000, 'Seagate', v_location)
  returning id into v_hdd;

  insert into tt4 values
    ('client', v_client), ('project', v_project), ('location', v_location), ('hdd', v_hdd);
end $$;

-- ---------------------------------------------------------------------------
-- Asset tagging and creation
-- ---------------------------------------------------------------------------
select db_test.eq(
  (select asset_tag ~ '^HDD-[0-9]{4}$' from public.hdds where id = (select v from tt4 where k = 'hdd')),
  true,
  'the drive asset tag is allocated by the database'
);

select db_test.eq(
  (select status from public.hdds where id = (select v from tt4 where k = 'hdd')),
  'AVAILABLE'::public.hdd_status,
  'a new drive starts as AVAILABLE'
);

select db_test.eq(
  (select count(*)::int from public.hdd_logs where hdd_id = (select v from tt4 where k = 'hdd') and event = 'CREATED'),
  1,
  'drive creation writes a custody log entry'
);

select db_test.ok(
  (select qr_token ~ '^[0-9a-f]{32}$' from public.hdds where id = (select v from tt4 where k = 'hdd')),
  'every drive carries a QR token for label printing'
);

-- ---------------------------------------------------------------------------
-- Checkout
-- ---------------------------------------------------------------------------
do $$
declare
  v_hdd uuid := (select v from tt4 where k = 'hdd');
  v_project uuid := (select v from tt4 where k = 'project');
  v_assignment uuid;
  v_status public.hdd_status;
begin
  v_assignment := public.checkout_hdd(
    p_hdd_id          => v_hdd,
    p_project_id      => v_project,
    p_assigned_to_name => 'Field Crew',
    p_expected_return => current_date + 7
  );
  insert into tt4 values ('assignment', v_assignment);

  select status into v_status from public.hdds where id = v_hdd;

  perform db_test.eq(v_status, 'CHECKED_OUT'::public.hdd_status, 'checkout marks the drive CHECKED_OUT');
  perform db_test.eq((select status from public.hdd_assignments where id = v_assignment), 'ACTIVE'::public.hdd_assignment_status,
    'checkout creates an ACTIVE assignment');
  perform db_test.eq((select project_id from public.hdd_assignments where id = v_assignment), v_project,
    'the assignment is linked to the project');
  perform db_test.eq((select count(*)::int from public.hdd_logs where hdd_id = v_hdd and event = 'CHECKED_OUT'), 1,
    'checkout appends a custody log entry');
end $$;

-- A second checkout of the same drive is refused.
select db_test.throws(
  format($sql$ select public.checkout_hdd('%s', assigned_to_name => 'Second Crew') $sql$, (select v from tt4 where k = 'hdd')),
  'a checked-out drive cannot be checked out again'
);

-- The database itself refuses a second ACTIVE assignment.
select db_test.throws(
  format($sql$ insert into public.hdd_assignments (hdd_id, assigned_to_name, status)
               values ('%s', 'Direct insert', 'ACTIVE') $sql$, (select v from tt4 where k = 'hdd')),
  'the partial unique index allows only one ACTIVE assignment per drive'
);

-- Marking a drive CHECKED_OUT by hand (without an assignment) is refused once
-- the assignment is gone; here the guard must reject a manual status change
-- while the assignment is still ACTIVE-consistent, and a manual AVAILABLE flip
-- while it is out.
select db_test.throws(
  format($sql$ update public.hdds set status = 'AVAILABLE' where id = '%s' $sql$, (select v from tt4 where k = 'hdd')),
  'a drive with an active assignment cannot be forced back to AVAILABLE'
);

-- ---------------------------------------------------------------------------
-- Overdue detection (historical assignment: checked out 30 days ago, due 10
-- days ago — the constraint only forbids a due date BEFORE the checkout date)
-- ---------------------------------------------------------------------------
do $$
declare
  v_hdd uuid;
  v_assignment uuid;
  v_client uuid := (select v from tt4 where k = 'client');
  v_project uuid := (select v from tt4 where k = 'project');
begin
  insert into public.hdds (label, capacity_gb) values ('Test drive B (overdue)', 4000)
  returning id into v_hdd;
  insert into tt4 values ('hdd_overdue', v_hdd);

  insert into public.hdd_assignments (
    hdd_id, project_id, assigned_to_name, status, checked_out_at, expected_return_date
  )
  values (v_hdd, v_project, 'Overdue Crew', 'ACTIVE', now() - interval '30 days', current_date - 10)
  returning id into v_assignment;
  insert into tt4 values ('assignment_overdue', v_assignment);

  update public.hdds set status = 'CHECKED_OUT' where id = v_hdd;

  perform db_test.eq(
    (select is_overdue from public.v_hdd_custody where hdd_id = v_hdd),
    true,
    'an assignment past its expected return date is flagged overdue'
  );

  perform db_test.eq(
    (select days_overdue from public.v_hdd_custody where hdd_id = v_hdd),
    10,
    'overdue drives report the exact number of days late'
  );

  perform db_test.eq(
    (select count(*)::int from public.v_hdd_custody where is_overdue),
    (select count(*)::int from public.hdd_assignments
      where status = 'ACTIVE' and expected_return_date < current_date),
    'the overdue flag matches the underlying assignments'
  );
end $$;

-- ---------------------------------------------------------------------------
-- Project completion is blocked while media is out
-- ---------------------------------------------------------------------------
select db_test.throws(
  format($sql$ update public.projects set status = 'COMPLETED' where id = '%s' $sql$, (select v from tt4 where k = 'project')),
  'a project cannot be completed while a drive is still checked out'
);

-- ---------------------------------------------------------------------------
-- Check-in with damage routing
-- ---------------------------------------------------------------------------
do $$
declare
  v_hdd uuid := (select v from tt4 where k = 'hdd');
  v_assignment uuid := (select v from tt4 where k = 'assignment');
  v_location uuid := (select v from tt4 where k = 'location');
begin
  perform public.checkin_hdd(
    p_assignment_id  => v_assignment,
    p_condition_in   => 'DAMAGED',
    p_location_id    => v_location,
    p_notes          => 'Dropped on location'
  );

  perform db_test.eq((select status from public.hdd_assignments where id = v_assignment), 'RETURNED'::public.hdd_assignment_status,
    'check-in closes the assignment');
  perform db_test.ok((select returned_at is not null from public.hdd_assignments where id = v_assignment),
    'check-in stamps the return time');
  perform db_test.eq((select status from public.hdds where id = v_hdd), 'MAINTENANCE'::public.hdd_status,
    'a damaged drive is routed to maintenance instead of AVAILABLE');
  perform db_test.eq((select condition from public.hdds where id = v_hdd), 'DAMAGED',
    'the recorded condition follows the check-in report');
  perform db_test.eq((select count(*)::int from public.hdd_logs where hdd_id = v_hdd and event = 'CHECKED_IN'), 1,
    'check-in appends a custody log entry');
end $$;

select db_test.throws(
  format($sql$ select public.checkin_hdd('%s') $sql$, (select v from tt4 where k = 'assignment')),
  'an assignment cannot be checked in twice'
);

-- A drive in maintenance cannot be checked out.
select db_test.throws(
  format($sql$ select public.checkout_hdd('%s', assigned_to_name => 'Crew') $sql$, (select v from tt4 where k = 'hdd')),
  'a drive under maintenance cannot be checked out'
);

-- ---------------------------------------------------------------------------
-- Movement, maintenance and archival
-- ---------------------------------------------------------------------------
do $$
declare
  v_hdd uuid := (select v from tt4 where k = 'hdd');
  v_location uuid := (select v from tt4 where k = 'location');
  v_other_location uuid;
begin
  insert into public.hdd_locations (name) values ('HDD Test Warehouse') returning id into v_other_location;

  perform public.transfer_hdd_location(v_hdd, v_other_location, 'Moved to warehouse');

  perform db_test.eq((select current_location_id from public.hdds where id = v_hdd), v_other_location,
    'a drive can be moved between locations');
  perform db_test.eq((select count(*)::int from public.hdd_logs where hdd_id = v_hdd and event = 'LOCATION_CHANGED'), 1,
    'a location change appends a custody event');

  -- Back to available, then archive.
  update public.hdds set status = 'AVAILABLE', condition = 'GOOD' where id = v_hdd;
  perform public.archive_hdd(v_hdd, 'Retired after 5 years');

  perform db_test.eq((select status from public.hdds where id = v_hdd), 'ARCHIVED'::public.hdd_status,
    'archiving sets the terminal status');
  perform db_test.eq((select true from public.hdds where id = v_hdd and is_deleted),
    true, 'an archived drive is soft deleted');
end $$;

select db_test.throws(
  format($sql$ select public.checkout_hdd('%s', assigned_to_name => 'Crew') $sql$, (select v from tt4 where k = 'hdd')),
  'an archived drive cannot be checked out'
);

-- The custody ledger is append-only.
select db_test.throws(
  format($sql$ update public.hdd_logs set note = 'tampered' where hdd_id = '%s' $sql$, (select v from tt4 where k = 'hdd')),
  'hdd_logs cannot be updated (custody history is append-only)'
);

select db_test.throws(
  format($sql$ delete from public.hdd_logs where hdd_id = '%s' $sql$, (select v from tt4 where k = 'hdd')),
  'hdd_logs cannot be deleted (custody history is append-only)'
);

-- ---------------------------------------------------------------------------
-- Attachments
-- ---------------------------------------------------------------------------
do $$
declare
  v_client uuid := (select v from tt4 where k = 'client');
  v_project uuid := (select v from tt4 where k = 'project');
  v_id uuid;
begin
  insert into public.attachments (entity_type, entity_id, file_name, storage_path, mime_type, size_bytes)
  values ('CLIENT', v_client, 'agreement.pdf', 'clients/agreement.pdf', 'application/pdf', 10240)
  returning id into v_id;
  insert into tt4 values ('attachment', v_id);

  perform db_test.ok(v_id is not null, 'a file can be attached to a client');

  insert into public.attachments (entity_type, entity_id, file_name, storage_path)
  values ('PROJECT', v_project, 'shotlist.xlsx', 'projects/shotlist.xlsx')
  returning id into v_id;

  perform db_test.ok(v_id is not null, 'a file can be attached to a project');
end $$;

select db_test.throws(
  format($sql$ insert into public.attachments (entity_type, entity_id, file_name, storage_path)
               values ('CLIENT', gen_random_uuid(), 'orphan.pdf', 'clients/orphan.pdf') $sql$),
  'a file cannot be attached to an entity that does not exist'
);

select db_test.throws(
  format($sql$ insert into public.attachments (entity_type, entity_id, file_name, storage_path)
               values ('CLIENT', '%s', 'dup.pdf', 'clients/agreement.pdf') $sql$, (select v from tt4 where k = 'client')),
  'the same storage object cannot be attached twice'
);

-- Attachment writes require the write permission for the underlying entity.
do $$
declare
  v_viewer uuid;
  v_client uuid := (select v from tt4 where k = 'client');
  v_blocked boolean := false;
begin
  select id into v_viewer from public.user_profiles where role = 'VIEWER' limit 1;
  insert into tt4 values ('viewer', v_viewer);

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_viewer::text, true);

  begin
    insert into public.attachments (entity_type, entity_id, file_name, storage_path)
    values ('CLIENT', v_client, 'viewer-upload.pdf', 'clients/viewer-upload.pdf');
  exception when insufficient_privilege then
    v_blocked := true;
  end;

  reset role;
  perform db_test.ok(v_blocked, 'a viewer cannot attach files to a client');
end $$;

do $$
declare
  v_manager uuid;
  v_client uuid := (select v from tt4 where k = 'client');
  v_id uuid;
begin
  select id into v_manager from public.user_profiles where role = 'MANAGER' limit 1;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_manager::text, true);

  begin
    insert into public.attachments (entity_type, entity_id, file_name, storage_path)
    values ('CLIENT', v_client, 'manager-upload.pdf', 'clients/manager-upload.pdf')
    returning id into v_id;
  exception when others then
    v_id := null;
  end;

  reset role;
  perform db_test.ok(v_id is not null, 'a manager can attach files to a client');
end $$;
