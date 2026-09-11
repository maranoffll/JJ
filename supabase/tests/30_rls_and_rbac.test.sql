-- ============================================================================
-- PHASE 1 TEST — RLS & RBAC
-- Verifies that PostgreSQL (not the frontend) enforces authorisation:
--   * anonymous callers hold no privileges at all
--   * authenticated callers are filtered by RLS policies per role
--   * browser-supplied roles/claims have no effect
--   * internal functions and ledgers are not reachable from the client
--
-- NOTE: every identifier is captured into a plpgsql variable *before* the
-- session role is switched, because the fixture temp table is not readable by
-- application roles (which is itself part of the guarantee under test).
-- ============================================================================

select db_test.plan_start('phase1: rls & rbac');

create temporary table tt2 (k text primary key, v uuid) on commit drop;

-- ---------------------------------------------------------------------------
-- Fixtures: one ERP user per role plus a deactivated user
-- ---------------------------------------------------------------------------
do $$
declare
  v_admin uuid; v_manager uuid; v_finance uuid; v_production uuid; v_viewer uuid; v_inactive uuid;
  v_client uuid; v_project uuid; v_invoice uuid; v_hdd uuid;
begin
  insert into auth.users (email, raw_user_meta_data) values ('admin@jjmedia.test', '{"full_name":"Admin One"}') returning id into v_admin;
  insert into auth.users (email, raw_user_meta_data) values ('manager@jjmedia.test', '{"full_name":"Manager One"}') returning id into v_manager;
  insert into auth.users (email, raw_user_meta_data) values ('finance@jjmedia.test', '{"full_name":"Finance One"}') returning id into v_finance;
  insert into auth.users (email, raw_user_meta_data) values ('production@jjmedia.test', '{"full_name":"Production One"}') returning id into v_production;
  insert into auth.users (email, raw_user_meta_data) values ('viewer@jjmedia.test', '{"full_name":"Viewer One"}') returning id into v_viewer;
  insert into auth.users (email, raw_user_meta_data) values ('inactive@jjmedia.test', '{"full_name":"Inactive One"}') returning id into v_inactive;

  insert into tt2 values
    ('admin', v_admin), ('manager', v_manager), ('finance', v_finance),
    ('production', v_production), ('viewer', v_viewer), ('inactive', v_inactive);

  -- The first signup is bootstrapped as ADMIN; the rest are promoted here.
  update public.user_profiles set role = 'MANAGER'    where id = v_manager;
  update public.user_profiles set role = 'FINANCE'    where id = v_finance;
  update public.user_profiles set role = 'PRODUCTION' where id = v_production;
  update public.user_profiles set role = 'VIEWER'     where id = v_viewer;
  update public.user_profiles set role = 'VIEWER', is_active = false where id = v_inactive;

  -- Business fixtures.
  insert into public.clients (name, billing_state_code) values ('RLS Test Client', '27') returning id into v_client;
  insert into public.projects (name, client_id, status) values ('RLS Test Project', v_client, 'IN_PROGRESS') returning id into v_project;

  insert into public.invoices (client_id, project_id, status) values (v_client, v_project, 'DRAFT') returning id into v_invoice;
  insert into public.invoice_line_items (invoice_id, description, quantity, unit_price, gst_rate)
  values (v_invoice, 'RLS line', 1, 10000, 18);
  update public.invoices set status = 'ISSUED' where id = v_invoice;

  insert into public.hdds (asset_tag, label) values ('HDD-RLS-1', 'RLS drive') returning id into v_hdd;
  insert into public.hdd_locations (name) values ('RLS Studio');

  insert into tt2 values
    ('client', v_client), ('project', v_project), ('invoice', v_invoice), ('hdd', v_hdd);
end $$;

-- ---------------------------------------------------------------------------
-- Bootstrap and role storage
-- ---------------------------------------------------------------------------
select db_test.eq(
  (select count(*)::int from public.user_profiles where role = 'ADMIN'),
  1,
  'the first registered account is the only ADMIN'
);

select db_test.eq(
  (select role from public.user_profiles where id = (select v from tt2 where k = 'finance')),
  'FINANCE'::public.user_role,
  'roles live in public.user_profiles'
);

select db_test.eq(
  (select count(*)::int
     from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public'),
  0,
  'the anonymous role holds no privileges on any public table'
);

-- ---------------------------------------------------------------------------
-- ANONYMOUS: no privileges at all
-- ---------------------------------------------------------------------------
do $$
declare
  v_denied_select boolean := false;
  v_denied_insert boolean := false;
begin
  set local role anon;

  begin
    perform count(*) from public.clients;
  exception when insufficient_privilege then
    v_denied_select := true;
  end;

  begin
    insert into public.clients (name) values ('Anonymous intrusion');
  exception when insufficient_privilege then
    v_denied_insert := true;
  end;

  reset role;

  perform db_test.ok(v_denied_select, 'anonymous SELECT on clients is denied');
  perform db_test.ok(v_denied_insert, 'anonymous INSERT on clients is denied');
end $$;

-- ---------------------------------------------------------------------------
-- AUTHENTICATED WITHOUT A SESSION: RLS fails closed
-- ---------------------------------------------------------------------------
do $$
declare
  v_rows bigint;
  v_insert_blocked boolean := false;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', '', true);

  select count(*) into v_rows from public.clients;

  begin
    insert into public.clients (name) values ('No session insert');
  exception when insufficient_privilege or check_violation then
    v_insert_blocked := true;
  end;

  reset role;

  perform db_test.eq(v_rows, 0::bigint, 'a session without a profile sees no clients');
  perform db_test.ok(v_insert_blocked, 'a session without a profile cannot insert clients');
end $$;

-- ---------------------------------------------------------------------------
-- VIEWER: read-only
-- ---------------------------------------------------------------------------
do $$
declare
  v_viewer uuid := (select v from tt2 where k = 'viewer');
  v_invoice uuid := (select v from tt2 where k = 'invoice');
  v_visible bigint;
  v_insert_blocked boolean := false;
  v_status public.invoice_status;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_viewer::text, true);

  select count(*) into v_visible from public.clients;

  begin
    insert into public.clients (name) values ('Viewer intrusion');
  exception when insufficient_privilege then
    v_insert_blocked := true;
  end;

  update public.invoices set status = 'CANCELLED', cancelled_reason = 'viewer attempt' where id = v_invoice;

  reset role;

  perform db_test.ok(v_visible > 0, 'a viewer can read clients');
  perform db_test.ok(v_insert_blocked, 'a viewer cannot insert a client');

  select status into v_status from public.invoices where id = v_invoice;
  perform db_test.eq(v_status, 'ISSUED'::public.invoice_status, 'a viewer cannot cancel an issued invoice');
end $$;

-- ---------------------------------------------------------------------------
-- MANAGER: commercial access, no financial posting
-- ---------------------------------------------------------------------------
do $$
declare
  v_manager uuid := (select v from tt2 where k = 'manager');
  v_invoice uuid := (select v from tt2 where k = 'invoice');
  v_client uuid := (select v from tt2 where k = 'client');
  v_inserted uuid;
  v_payment_blocked boolean := false;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_manager::text, true);

  insert into public.clients (name, billing_state_code) values ('Manager Created Client', '27')
  returning id into v_inserted;

  begin
    insert into public.payments (invoice_id, client_id, amount) values (v_invoice, v_client, 100);
  exception when insufficient_privilege then
    v_payment_blocked := true;
  end;

  reset role;

  perform db_test.ok(v_inserted is not null, 'a manager can create a client');
  perform db_test.ok(v_payment_blocked, 'a manager cannot post a payment (no payments.create)');
end $$;

-- ---------------------------------------------------------------------------
-- FINANCE: billing and collections
-- ---------------------------------------------------------------------------
do $$
declare
  v_finance uuid := (select v from tt2 where k = 'finance');
  v_invoice uuid := (select v from tt2 where k = 'invoice');
  v_payment_id uuid;
  v_ok boolean := false;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_finance::text, true);

  begin
    v_payment_id := public.post_payment(
      p_amount     => 1000.00,
      p_invoice_id => v_invoice,
      p_method     => 'UPI',
      p_reference  => 'RLS-UPI-1'
    );
    v_ok := v_payment_id is not null;
  exception when others then
    v_ok := false;
  end;

  reset role;

  perform db_test.ok(v_ok, 'finance can post a payment through the RPC');
  perform db_test.eq(
    (select amount_paid from public.invoices where id = v_invoice),
    1000.00::numeric,
    'the posted payment is reflected on the invoice'
  );
end $$;

do $$
declare
  v_viewer uuid := (select v from tt2 where k = 'viewer');
  v_invoice uuid := (select v from tt2 where k = 'invoice');
  v_blocked boolean := false;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_viewer::text, true);

  begin
    perform public.post_payment(p_amount => 100.00, p_invoice_id => v_invoice);
  exception when insufficient_privilege then
    v_blocked := true;
  end;

  reset role;
  perform db_test.ok(v_blocked, 'a viewer cannot post a payment through the RPC');
end $$;

-- ---------------------------------------------------------------------------
-- PRODUCTION: HDD custody, no financial visibility
-- ---------------------------------------------------------------------------
do $$
declare
  v_production uuid := (select v from tt2 where k = 'production');
  v_hdd uuid := (select v from tt2 where k = 'hdd');
  v_hdd_visible bigint;
  v_invoice_visible bigint;
  v_checkout_ok boolean := false;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_production::text, true);

  select count(*) into v_hdd_visible from public.hdds;
  select count(*) into v_invoice_visible from public.invoices;

  begin
    perform public.checkout_hdd(p_hdd_id => v_hdd, p_assigned_to_name => 'Production One');
    v_checkout_ok := true;
  exception when others then
    v_checkout_ok := false;
  end;

  reset role;

  perform db_test.ok(v_hdd_visible > 0, 'production can see the drive inventory');
  perform db_test.eq(v_invoice_visible, 0::bigint, 'production cannot read invoices');
  perform db_test.ok(v_checkout_ok, 'production can check a drive out');
end $$;

do $$
declare
  v_viewer uuid := (select v from tt2 where k = 'viewer');
  v_hdd uuid := (select v from tt2 where k = 'hdd');
  v_blocked boolean := false;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_viewer::text, true);

  begin
    perform public.checkout_hdd(p_hdd_id => v_hdd, p_assigned_to_name => 'Viewer');
  exception when insufficient_privilege then
    v_blocked := true;
  end;

  reset role;
  perform db_test.ok(v_blocked, 'a viewer cannot check a drive out');
end $$;

-- ---------------------------------------------------------------------------
-- Escalation attempts
-- ---------------------------------------------------------------------------
do $$
declare
  v_viewer uuid := (select v from tt2 where k = 'viewer');
  v_self_role_blocked boolean := false;
  v_role public.user_role;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_viewer::text, true);

  begin
    update public.user_profiles set role = 'ADMIN' where id = v_viewer;
  exception when insufficient_privilege then
    v_self_role_blocked := true;
  end;

  reset role;

  select role into v_role from public.user_profiles where id = v_viewer;
  perform db_test.ok(v_self_role_blocked, 'a user cannot promote themselves to ADMIN');
  perform db_test.eq(v_role, 'VIEWER'::public.user_role, 'the viewer role is unchanged');
end $$;

do $$
declare
  v_viewer uuid := (select v from tt2 where k = 'viewer');
  v_blocked boolean := false;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_viewer::text, true);
  -- Forged browser-supplied identity hints.
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('request.jwt.claims', '{"role":"ADMIN"}', true);

  begin
    insert into public.clients (name) values ('Forged claim intrusion');
  exception when insufficient_privilege then
    v_blocked := true;
  end;

  reset role;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.role', '', true);

  perform db_test.ok(v_blocked, 'a forged role claim does not grant write access');
end $$;

do $$
declare
  v_viewer uuid := (select v from tt2 where k = 'viewer');
  v_invoice uuid := (select v from tt2 where k = 'invoice');
  v_status public.invoice_status;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_viewer::text, true);
  perform set_config('request.jwt.claims', '{"role":"ADMIN"}', true);

  update public.invoices set status = 'CANCELLED', cancelled_reason = 'forged' where id = v_invoice;

  reset role;
  perform set_config('request.jwt.claims', '', true);

  select status into v_status from public.invoices where id = v_invoice;
  perform db_test.eq(v_status, 'ISSUED'::public.invoice_status, 'forged claims cannot cancel an invoice');
end $$;

-- ---------------------------------------------------------------------------
-- Deactivated users lose access immediately
-- ---------------------------------------------------------------------------
do $$
declare
  v_inactive uuid := (select v from tt2 where k = 'inactive');
  v_invoice uuid := (select v from tt2 where k = 'invoice');
  v_rows bigint;
  v_rpc_blocked boolean := false;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_inactive::text, true);

  select count(*) into v_rows from public.clients;

  begin
    perform public.post_payment(p_amount => 10.00, p_invoice_id => v_invoice);
  exception when insufficient_privilege then
    v_rpc_blocked := true;
  end;

  reset role;

  perform db_test.eq(v_rows, 0::bigint, 'a deactivated user sees nothing');
  perform db_test.ok(v_rpc_blocked, 'a deactivated user cannot call business RPCs');
end $$;

-- ---------------------------------------------------------------------------
-- Ledgers, counters and internal functions are out of reach
-- ---------------------------------------------------------------------------
do $$
declare
  v_finance uuid := (select v from tt2 where k = 'finance');
  v_seq_rows bigint;
  v_audit_rows bigint;
  v_updated integer := 0;
  v_update_blocked boolean := false;
  v_delete_blocked boolean := false;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_finance::text, true);

  select count(*) into v_seq_rows from public.document_sequences;
  select count(*) into v_audit_rows from public.audit_logs;

  -- The append-only guard raises for ANY UPDATE/DELETE attempt, even one that
  -- RLS would have filtered down to zero rows.
  begin
    update public.audit_logs set summary = 'tampered';
    v_updated := 1;
  exception when insufficient_privilege then
    v_update_blocked := true;
  end;

  begin
    delete from public.audit_logs;
    v_delete_blocked := true;
  exception when insufficient_privilege then
    v_delete_blocked := true;
  end;

  reset role;

  perform db_test.eq(v_seq_rows, 0::bigint, 'authenticated callers cannot read the numbering counters');
  perform db_test.ok(v_audit_rows > 0, 'finance can read the audit trail (audit.view)');
  perform db_test.ok(v_update_blocked, 'no audit row can be modified by an application role');
  perform db_test.ok(v_delete_blocked, 'no audit row can be deleted by an application role');
end $$;

do $$
declare
  v_finance uuid := (select v from tt2 where k = 'finance');
  v_viewer uuid := (select v from tt2 where k = 'viewer');
  v_admin uuid := (select v from tt2 where k = 'admin');
  v_rows bigint;
begin
  -- A viewer holds no audit.view permission.
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_viewer::text, true);
  select count(*) into v_rows from public.audit_logs;
  reset role;

  perform db_test.eq(v_rows, 0::bigint, 'a viewer cannot read the audit trail');
end $$;

do $$
declare
  v_admin uuid := (select v from tt2 where k = 'admin');
  v_fn_blocked boolean := false;
  v_audit_blocked boolean := false;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  begin
    perform public.next_document_number('client', 'XX');
  exception when insufficient_privilege then
    v_fn_blocked := true;
  end;

  begin
    perform public.write_audit_log('OTHER', 'clients', null, null, null, 'forged audit entry');
  exception when insufficient_privilege then
    v_audit_blocked := true;
  end;

  reset role;

  perform db_test.ok(v_fn_blocked, 'an ADMIN session cannot call the internal numbering function directly');
  perform db_test.ok(v_audit_blocked, 'the audit ledger cannot be written directly from a client session');
end $$;

-- ---------------------------------------------------------------------------
-- Company settings: readable by all, writable by ADMIN only
-- ---------------------------------------------------------------------------
do $$
declare
  v_viewer uuid := (select v from tt2 where k = 'viewer');
  v_visible bigint;
  v_updated integer;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_viewer::text, true);

  select count(*) into v_visible from public.company_settings;
  update public.company_settings set legal_name = 'Hijacked Pvt Ltd';
  get diagnostics v_updated = row_count;

  reset role;

  perform db_test.ok(v_visible > 0, 'every active user can read company settings for documents');
  perform db_test.eq(v_updated, 0, 'only ADMIN can change company settings');
end $$;

do $$
declare
  v_admin uuid := (select v from tt2 where k = 'admin');
  v_updated integer;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  update public.company_settings set tagline = 'Production house';
  get diagnostics v_updated = row_count;

  reset role;
  perform db_test.eq(v_updated, 1, 'an ADMIN can change company settings');
end $$;

-- ---------------------------------------------------------------------------
-- Profile visibility
-- ---------------------------------------------------------------------------
do $$
declare
  v_viewer uuid := (select v from tt2 where k = 'viewer');
  v_admin uuid := (select v from tt2 where k = 'admin');
  v_viewer_rows bigint;
  v_admin_rows bigint;
  v_total bigint;
begin
  select count(*) into v_total from public.user_profiles;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_viewer::text, true);
  select count(*) into v_viewer_rows from public.user_profiles;
  reset role;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  select count(*) into v_admin_rows from public.user_profiles;
  reset role;

  perform db_test.eq(v_viewer_rows, 1::bigint, 'a viewer sees only their own profile');
  perform db_test.eq(v_admin_rows, v_total, 'an ADMIN sees the whole user directory');
end $$;

-- ---------------------------------------------------------------------------
-- The last active ADMIN cannot be locked out
-- ---------------------------------------------------------------------------
do $$
declare
  v_admin uuid := (select v from tt2 where k = 'admin');
  v_blocked boolean := false;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  begin
    update public.user_profiles set is_active = false where id = v_admin;
  exception when check_violation then
    v_blocked := true;
  end;

  reset role;
  perform db_test.ok(v_blocked, 'the last active ADMIN cannot be deactivated');
end $$;
