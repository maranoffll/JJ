-- ============================================================================
-- PHASE 1 TEST — schema foundation, enums, constraints, helper functions
-- Runs inside the rolled-back transaction created by `npm run db:test`.
-- ============================================================================

select db_test.plan_start('phase1: schema & helpers');

-- ---------------------------------------------------------------------------
-- Enum catalogue
-- ---------------------------------------------------------------------------
select db_test.eq(
  (select array_agg(e.enumlabel::text order by e.enumsortorder)
     from pg_enum e join pg_type t on t.oid = e.enumtypid
    where t.typname = 'user_role'),
  array['ADMIN', 'MANAGER', 'FINANCE', 'PRODUCTION', 'VIEWER'],
  'user_role enum exposes the five ERP roles'
);

select db_test.eq(
  (select array_agg(e.enumlabel::text order by e.enumsortorder)
     from pg_enum e join pg_type t on t.oid = e.enumtypid
    where t.typname = 'hdd_status'),
  array['AVAILABLE', 'CHECKED_OUT', 'IN_TRANSIT', 'MAINTENANCE', 'ARCHIVED'],
  'hdd_status enum matches the eight-state custody model'
);

select db_test.eq(
  (select array_agg(e.enumlabel::text order by e.enumsortorder)
     from pg_enum e join pg_type t on t.oid = e.enumtypid
    where t.typname = 'payment_status'),
  array['POSTED', 'VOIDED'],
  'payment_status enum is POSTED/VOIDED'
);

-- ---------------------------------------------------------------------------
-- Required tables
-- ---------------------------------------------------------------------------
select db_test.ok(
  (select count(*) from information_schema.tables
    where table_schema = 'public' and table_type = 'BASE TABLE') >= 21,
  'core tables exist'
);

select db_test.eq(
  (select count(*)::int
     from unnest(array[
       'company_settings', 'user_profiles', 'clients', 'projects', 'quotations',
       'quotation_line_items', 'invoices', 'invoice_line_items', 'payments',
       'credit_notes', 'credit_note_line_items', 'expenses', 'expense_categories',
       'hdd_locations', 'hdds', 'hdd_assignments', 'hdd_logs', 'attachments',
       'audit_logs', 'document_sequences', 'role_permissions'
     ]) t(name)
    where to_regclass('public.' || t.name) is null),
  0,
  'every entity required by the specification exists'
);

-- ---------------------------------------------------------------------------
-- Money helpers are deterministic
-- ---------------------------------------------------------------------------
select db_test.eq(public.round_money(1234.565), 1234.57::numeric, 'round_money rounds half up');
select db_test.eq(public.round_money(0.005), 0.01::numeric, 'round_money handles sub-paise values');
select db_test.eq(public.round_money(-10.005), -10.01::numeric, 'round_money handles negatives symmetrically');
select db_test.eq(public.financial_year('2026-04-01'::date), '2026-27', 'financial year starts on 1 April');
select db_test.eq(public.financial_year('2026-03-31'::date), '2025-26', 'financial year before April belongs to the previous FY');

select db_test.eq(public.amount_in_words(1234567.50),
  'Rupees Twelve Lakh Thirty Four Thousand Five Hundred Sixty Seven and Fifty Paise Only',
  'amount in words uses the Indian numbering system');
select db_test.eq(public.amount_in_words(10000000), 'Rupees One Crore Only', 'amount in words handles crore');
select db_test.eq(public.amount_in_words(101.05), 'Rupees One Hundred One and Five Paise Only', 'amount in words handles hundreds and paise');
select db_test.eq(public.amount_in_words(0), 'Rupees Zero Only', 'amount in words handles zero');

-- ---------------------------------------------------------------------------
-- GST engine
-- ---------------------------------------------------------------------------
select db_test.eq((select total_tax from public.split_gst(1000, 18, 'INTRA_STATE')), 180.00::numeric, 'intra-state GST total');
select db_test.eq((select cgst from public.split_gst(1000, 18, 'INTRA_STATE')), 90.00::numeric, 'intra-state CGST is half');
select db_test.eq((select sgst from public.split_gst(1000, 18, 'INTRA_STATE')), 90.00::numeric, 'intra-state SGST is half');
select db_test.eq((select igst from public.split_gst(1000, 18, 'INTRA_STATE')), 0::numeric, 'intra-state has no IGST');

select db_test.eq((select cgst from public.split_gst(999.99, 18, 'INTER_STATE')), 0::numeric, 'inter-state has no CGST');
select db_test.eq((select igst from public.split_gst(999.99, 18, 'INTER_STATE')), 180.00::numeric, 'inter-state IGST is the whole tax');

-- Odd amounts must still balance: CGST + SGST = tax total exactly.
select db_test.eq(
  (select cgst + sgst from public.split_gst(1234.57, 18, 'INTRA_STATE')),
  (select total_tax from public.split_gst(1234.57, 18, 'INTRA_STATE')),
  'CGST + SGST always equals the total tax exactly'
);

select db_test.eq(
  (select array_agg(rate order by rate) from public.gst_rates),
  array[0, 5, 12, 18, 28]::numeric[],
  'only the five statutory GST rates are available'
);

select db_test.throws(
  $sql$ insert into public.gst_rates (rate, label) values (7, 'Invalid') $sql$,
  'a non-statutory GST rate is rejected'
);

-- ---------------------------------------------------------------------------
-- Statutory identifier validation
-- ---------------------------------------------------------------------------
select db_test.ok(public.is_valid_gstin('27AAPFU0939F1ZV'), 'valid GSTIN accepted');
select db_test.ok(not public.is_valid_gstin('27AAPFU0939F12V'), 'malformed GSTIN rejected');
select db_test.ok(not public.is_valid_gstin(''), 'empty GSTIN rejected');
select db_test.ok(public.is_valid_pan('AAPFU0939F'), 'valid PAN accepted');
select db_test.ok(not public.is_valid_pan('AAPFU09391'), 'malformed PAN rejected');

-- ---------------------------------------------------------------------------
-- Concurrency-safe numbering primitives
-- ---------------------------------------------------------------------------
do $$
declare
  v_first  text;
  v_second text;
  v_peek   text;
begin
  v_first  := (select document_number from public.next_document_number('testdoc', 'TST', 'SCOPE1', 4));
  v_peek   := public.peek_next_document_number('testdoc', 'TST', 'SCOPE1', 4);
  v_second := (select document_number from public.next_document_number('testdoc', 'TST', 'SCOPE1', 4));

  perform db_test.eq(v_first, 'TST/SCOPE1/0001', 'first allocated number starts at 0001');
  perform db_test.eq(v_peek, 'TST/SCOPE1/0002', 'peek previews the next number without consuming it');
  perform db_test.eq(v_second, 'TST/SCOPE1/0002', 'second allocation increments the sequence');
end $$;

select db_test.eq(
  public.next_sequence_code('testcode', 'TC', 4),
  'TC-0001',
  'business codes use prefix-dash-number format'
);

-- Numbering tables are not writable by application roles.
select db_test.eq(
  (select count(*)::int from pg_policies
    where schemaname = 'public' and tablename = 'document_sequences'),
  0,
  'document_sequences has no RLS policy (numbers cannot be burned directly)'
);

-- ---------------------------------------------------------------------------
-- Constraint behaviour on master data
-- ---------------------------------------------------------------------------
select db_test.throws(
  $sql$ insert into public.clients (name, gstin) values ('Bad GSTIN Co', 'NOTAGSTIN') $sql$,
  'a malformed GSTIN is rejected on clients'
);

select db_test.throws(
  $sql$ insert into public.clients (name, billing_state_code) values ('Bad State Co', 'ABC') $sql$,
  'a malformed state code is rejected on clients'
);

select db_test.throws(
  $sql$ insert into public.clients (name, credit_limit) values ('Negative Limit Co', -1) $sql$,
  'a negative credit limit is rejected'
);

-- ---------------------------------------------------------------------------
-- audit_logs is append-only
-- ---------------------------------------------------------------------------
do $$
declare
  v_id bigint;
begin
  v_id := public.write_audit_log(
    p_action => 'OTHER',
    p_entity_table => 'db_test',
    p_summary => 'phase 1 append-only probe'
  );

  perform db_test.ok(v_id is not null, 'write_audit_log appends a record');

  perform db_test.throws(
    format('update public.audit_logs set summary = %L where id = %s', 'tampered', v_id),
    'audit_logs UPDATE is blocked (append-only)'
  );

  perform db_test.throws(
    format('delete from public.audit_logs where id = %s', v_id),
    'audit_logs DELETE is blocked (append-only)'
  );
end $$;
