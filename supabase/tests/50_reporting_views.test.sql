-- ============================================================================
-- PHASE 1 TEST — reporting views & dashboard aggregates
-- Builds an isolated client/project scenario and checks that revenue,
-- collection, receivable, GST and profitability figures follow the rules:
--   only POSTED payments count, VOIDED payments are excluded,
--   CANCELLED invoices are excluded, ISSUED credit notes reduce revenue,
--   only APPROVED expenses count as cost.
-- ============================================================================

select db_test.plan_start('phase1: reporting views');

create temporary table tt5 (k text primary key, v uuid) on commit drop;

do $$
declare
  v_settings public.company_settings;
begin
  -- Ensure the singleton exists regardless of test-file ordering.
  select * into v_settings from public.company_settings limit 1;
  if not found then
    insert into public.company_settings (legal_name, display_name, state, state_code, default_gst_rate)
    values ('Reporting Test Pvt Ltd', 'Reporting Test', 'Maharashtra', '27', 18);
  end if;
end $$;

do $$
declare
  v_client uuid;
  v_project uuid;
  v_invoice uuid;
  v_invoice_cancelled uuid;
  v_payment uuid;
begin
  insert into public.clients (name, billing_state_code) values ('Reporting Client', '27') returning id into v_client;
  insert into public.projects (name, client_id, status, budget, contract_value)
  values ('Reporting Project', v_client, 'IN_PROGRESS', 100000, 300000) returning id into v_project;

  -- Invoice 1: 2 x 10000 @18% intra-state -> taxable 20000, tax 3600, total 23600
  insert into public.invoices (client_id, project_id, status) values (v_client, v_project, 'DRAFT') returning id into v_invoice;
  insert into public.invoice_line_items (invoice_id, description, quantity, unit_price, gst_rate)
  values (v_invoice, 'Reporting line', 2, 10000, 18);
  update public.invoices set status = 'ISSUED' where id = v_invoice;

  -- Invoice 2: issued then cancelled -> must not appear in revenue at all
  insert into public.invoices (client_id, project_id, status, invoice_date) values (v_client, v_project, 'DRAFT', current_date - 40) returning id into v_invoice_cancelled;
  insert into public.invoice_line_items (invoice_id, description, quantity, unit_price, gst_rate)
  values (v_invoice_cancelled, 'Cancelled line', 1, 5000, 18);
  update public.invoices set status = 'ISSUED' where id = v_invoice_cancelled;
  update public.invoices set status = 'CANCELLED', cancelled_reason = 'Duplicate' where id = v_invoice_cancelled;

  -- Collection: 10000 posted, 5000 posted then voided
  v_payment := public.post_payment(p_amount => 10000.00, p_invoice_id => v_invoice, p_method => 'NEFT');
  v_payment := public.post_payment(p_amount => 5000.00, p_invoice_id => v_invoice, p_method => 'CASH');
  perform public.void_payment(v_payment, 'Cash not received');

  -- Approved cost: 20000 + 18% = 23600
  insert into public.expenses (project_id, client_id, description, amount, gst_rate, vendor_state_code, status)
  values (v_project, v_client, 'Reporting expense', 20000, 18, '27', 'APPROVED');

  -- A draft expense must not count as cost.
  insert into public.expenses (project_id, client_id, description, amount, gst_rate, vendor_state_code, status)
  values (v_project, v_client, 'Draft expense', 5000, 18, '27', 'DRAFT');

  insert into tt5 values ('client', v_client), ('project', v_project), ('invoice', v_invoice),
                         ('invoice_cancelled', v_invoice_cancelled);
end $$;

-- ---------------------------------------------------------------------------
-- Invoice financials
-- ---------------------------------------------------------------------------
do $$
declare
  v_invoice uuid := (select v from tt5 where k = 'invoice');
  v_f record;
begin
  select * into v_f from public.v_invoice_financials where id = v_invoice;

  perform db_test.eq(v_f.grand_total, 23600.00::numeric, 'view: invoice grand total');
  perform db_test.eq(v_f.taxable_total, 20000.00::numeric, 'view: invoice taxable value');
  perform db_test.eq(v_f.cgst_total, 1800.00::numeric, 'view: intra-state CGST');
  perform db_test.eq(v_f.sgst_total, 1800.00::numeric, 'view: intra-state SGST');
  perform db_test.eq(v_f.igst_total, 0::numeric, 'view: no IGST intra-state');
  perform db_test.eq(v_f.amount_paid, 10000.00::numeric, 'view: only posted payments count');
  perform db_test.eq(v_f.amount_voided, 5000.00::numeric, 'view: voided payments are reported separately');
  perform db_test.eq(v_f.outstanding, 13600.00::numeric, 'view: outstanding excludes voided payments');
  perform db_test.eq(v_f.payment_state, 'PARTIAL', 'view: payment state is partial');
  perform db_test.eq(v_f.days_overdue, 0, 'view: not overdue before the due date');
end $$;

do $$
declare
  v_cancelled uuid := (select v from tt5 where k = 'invoice_cancelled');
  v_f record;
begin
  select * into v_f from public.v_invoice_financials where id = v_cancelled;

  perform db_test.eq(v_f.status, 'CANCELLED'::public.invoice_status, 'view: cancelled invoice keeps its status');
  perform db_test.eq(v_f.payment_state, 'NOT_APPLICABLE', 'view: cancelled invoices have no payment state');
  perform db_test.eq(
    (select count(*)::int from public.v_receivables_aging where id = v_cancelled),
    0,
    'view: cancelled invoices are excluded from receivables'
  );
end $$;

-- ---------------------------------------------------------------------------
-- Ageing buckets
-- ---------------------------------------------------------------------------
do $$
declare
  v_client uuid := (select v from tt5 where k = 'client');
  v_project uuid;
  v_old uuid;
begin
  -- Isolated project so the ageing scenario cannot affect profitability figures.
  insert into public.projects (name, client_id, status) values ('Ageing Project', v_client, 'IN_PROGRESS')
  returning id into v_project;

  -- Issued 100 days ago, unpaid -> 90+ bucket.
  insert into public.invoices (client_id, project_id, status, invoice_date, due_date)
  values (v_client, v_project, 'DRAFT', current_date - 100, current_date - 95) returning id into v_old;
  insert into public.invoice_line_items (invoice_id, description, quantity, unit_price, gst_rate)
  values (v_old, 'Overdue line', 1, 1000, 18);
  update public.invoices set status = 'ISSUED' where id = v_old;

  perform db_test.eq(
    (select ageing_bucket from public.v_receivables_aging where id = v_old),
    '90+',
    'view: invoices 90+ days past due land in the oldest bucket'
  );

  perform db_test.eq(
    (select days_overdue from public.v_receivables_aging where id = v_old),
    95,
    'view: days overdue is measured from the due date'
  );
end $$;

-- ---------------------------------------------------------------------------
-- Project profitability
-- ---------------------------------------------------------------------------
do $$
declare
  v_project uuid := (select v from tt5 where k = 'project');
  v_p record;
begin
  select * into v_p from public.v_project_profitability where project_id = v_project;

  perform db_test.eq(v_p.invoiced, 23600.00::numeric, 'profitability: only issued, non-cancelled invoices count as invoiced');
  perform db_test.eq(v_p.net_revenue, 23600.00::numeric, 'profitability: net revenue equals invoiced less credits');
  perform db_test.eq(v_p.collected, 10000.00::numeric, 'profitability: collected uses posted payments only');
  perform db_test.eq(v_p.outstanding, 13600.00::numeric, 'profitability: outstanding matches receivables');
  perform db_test.eq(v_p.total_cost, 23600.00::numeric, 'profitability: cost includes GST and only approved expenses');
  perform db_test.eq(v_p.direct_cost, 23600.00::numeric, 'profitability: direct cost for a direct-cost category');
  perform db_test.eq(v_p.gross_profit, 0.00::numeric, 'profitability: gross profit = net revenue - cost');
  perform db_test.eq(v_p.margin_percent, 0.00::numeric, 'profitability: margin percentage');
  perform db_test.eq(v_p.budget_used_percent, 23.60::numeric, 'profitability: budget consumption');
end $$;

-- ---------------------------------------------------------------------------
-- Client roll-up
-- ---------------------------------------------------------------------------
do $$
declare
  v_client uuid := (select v from tt5 where k = 'client');
  v_c record;
begin
  select * into v_c from public.v_client_financials where client_id = v_client;

  -- Client-level figures span BOTH issued invoices of this client:
  --   23600 (main scenario) + 1180 (100-day-old ageing invoice) = 24780
  perform db_test.eq(v_c.revenue, 24780.00::numeric, 'client financials: revenue covers all issued invoices and excludes the cancelled one');
  perform db_test.eq(v_c.collected, 10000.00::numeric, 'client financials: collection excludes voided payments');
  perform db_test.eq(v_c.outstanding, 14780.00::numeric, 'client financials: outstanding includes the overdue invoice');
  perform db_test.eq(v_c.invoice_count, 2::bigint, 'client financials: the cancelled invoice is not counted');
end $$;

-- ---------------------------------------------------------------------------
-- GST summary
-- ---------------------------------------------------------------------------
do $$
declare
  v_client uuid := (select v from tt5 where k = 'client');
  v_invoice uuid := (select v from tt5 where k = 'invoice');
  v_cn uuid;
  v_before numeric;
  v_after numeric;
begin
  select coalesce(sum(tax_total), 0) into v_before from public.v_gst_summary where document_type = 'INVOICE';

  insert into public.credit_notes (invoice_id, client_id, reason)
  values (v_invoice, v_client, 'GST adjustment') returning id into v_cn;

  insert into public.credit_note_line_items (credit_note_id, description, quantity, unit_price, gst_rate)
  values (v_cn, 'Adjustment', 1, 1000, 18);

  update public.credit_notes set status = 'ISSUED' where id = v_cn;

  perform db_test.eq(
    (select tax_total from public.v_gst_summary where document_number = (select credit_note_number from public.credit_notes where id = v_cn)),
    -180.00::numeric,
    'GST summary: an issued credit note reduces the GST liability'
  );

  select coalesce(sum(tax_total), 0) into v_after from public.v_gst_summary where document_type = 'INVOICE';
  perform db_test.eq(v_after, v_before, 'GST summary: invoice rows are unaffected by the credit note');

  perform db_test.eq(
    (select amount_credited from public.v_invoice_financials where id = v_invoice),
    1180.00::numeric,
    'invoice financials: the issued credit note is reflected'
  );
  perform db_test.eq(
    (select outstanding from public.v_invoice_financials where id = v_invoice),
    12420.00::numeric,
    'invoice financials: outstanding nets the credit note'
  );
end $$;

-- ---------------------------------------------------------------------------
-- Expense summary
-- ---------------------------------------------------------------------------
select db_test.eq(
  (select coalesce(sum(gross_amount), 0) from public.v_expense_summary
    where project_id = (select v from tt5 where k = 'project')),
  23600.00::numeric,
  'expense summary: only approved expenses are summarised'
);

-- ---------------------------------------------------------------------------
-- Dashboard aggregate (single JSON round trip, database-side aggregation)
-- ---------------------------------------------------------------------------
do $$
declare
  v_metrics jsonb;
begin
  v_metrics := public.dashboard_metrics(current_date - 400, current_date + 1);

  perform db_test.ok(v_metrics -> 'receivables' -> 'outstanding' is not null, 'dashboard: receivables block is present');
  perform db_test.eq((v_metrics -> 'receivables' -> 'overdue_count')::text::int > 0, true,
    'dashboard: overdue invoices are detected');
  perform db_test.eq((v_metrics -> 'collections' -> 'receipts')::text::int > 0, true,
    'dashboard: posted receipts are counted');
  perform db_test.eq((v_metrics -> 'hdd' -> 'checked_out')::text::int > 0, true,
    'dashboard: checked-out drives are counted');
  perform db_test.eq((v_metrics -> 'expenses' -> 'pending_count')::text::int > 0, true,
    'dashboard: pending (draft) expenses are counted');
  perform db_test.ok((v_metrics -> 'invoices' -> 'issued_value')::text::numeric > 0, 'dashboard: issued value is populated');
end $$;

-- The dashboard must never report a voided payment as collected.
do $$
declare
  v_metrics jsonb;
  v_voided numeric;
begin
  v_metrics := public.dashboard_metrics(current_date - 400, current_date + 1);
  select coalesce(sum(amount), 0) into v_voided from public.payments where status = 'VOIDED';

  perform db_test.ok(v_voided > 0, 'there is at least one voided payment in the fixture');
  perform db_test.eq(
    (v_metrics -> 'collections' -> 'voided')::text::numeric,
    v_voided,
    'dashboard reports voided payments separately from collections'
  );
  perform db_test.eq(
    round((v_metrics -> 'collections' -> 'received')::text::numeric, 2),
    (select round(coalesce(sum(amount), 0), 2) from public.payments where status = 'POSTED'),
    'dashboard collected total equals the sum of posted payments'
  );
end $$;

-- ---------------------------------------------------------------------------
-- Project activity feed merges audit and custody events
-- ---------------------------------------------------------------------------
do $$
declare
  v_project uuid := (select v from tt5 where k = 'project');
  v_hdd uuid;
begin
  insert into public.hdds (label) values ('Activity feed drive') returning id into v_hdd;
  perform public.checkout_hdd(p_hdd_id => v_hdd, p_project_id => v_project, p_assigned_to_name => 'Activity Crew');

  perform db_test.ok(
    (select count(*) from public.v_project_activity where project_id = v_project and source = 'AUDIT') > 0,
    'activity feed: audit events for the project are listed'
  );

  perform db_test.ok(
    (select count(*) from public.v_project_activity where project_id = v_project and source = 'HDD') > 0,
    'activity feed: HDD custody events for the project are listed'
  );
end $$;
