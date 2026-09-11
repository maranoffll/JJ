-- ============================================================================
-- PHASE 1 TEST — financial engine
--   * deterministic GST arithmetic (intra/inter state, discount, round-off)
--   * quotation lifecycle, numbering and conversion
--   * ISSUED invoice immutability
--   * payment posting, voiding and over-collection prevention
--   * credit note controls and their effect on receivables
-- ============================================================================

select db_test.plan_start('phase1: financial engine');

create temporary table tt_ids (k text primary key, v uuid) on commit drop;

-- ---------------------------------------------------------------------------
-- Fixtures: company in Maharashtra (27), one intra-state and one inter-state client
-- ---------------------------------------------------------------------------
do $$
declare
  v_company uuid;
  v_client_a uuid;
  v_client_b uuid;
begin
  insert into public.company_settings (
    legal_name, display_name, state, state_code, gstin, pan,
    invoice_prefix, quotation_prefix, credit_note_prefix, payment_prefix,
    default_gst_rate, default_tax_type, round_off_enabled
  )
  values (
    'JJ Media Productions Pvt Ltd', 'JJ Media', 'Maharashtra', '27',
    '27AAPFU0939F1ZV', 'AAPFU0939F', 'INV', 'QT', 'CN', 'RCPT',
    18, 'INTRA_STATE', true
  )
  returning id into v_company;

  insert into public.clients (name, billing_state_code, billing_state, gstin, payment_terms_days)
  values ('Mumbai Intra Client', '27', 'Maharashtra', null, 30)
  returning id into v_client_a;

  insert into public.clients (name, billing_state_code, billing_state, gstin, payment_terms_days)
  values ('Bengaluru Inter Client', '29', 'Karnataka', null, 15)
  returning id into v_client_b;

  insert into tt_ids values ('company', v_company), ('client_intra', v_client_a), ('client_inter', v_client_b);

  perform db_test.eq(v_company is not null, true, 'company settings singleton created');
  perform db_test.eq(v_client_a is not null, true, 'intra-state client created');
end $$;

select db_test.eq((select client_code ~ '^CL-[0-9]{4}$' from public.clients where id = (select v from tt_ids where k = 'client_intra')), true,
  'client code is allocated by the database');

-- ---------------------------------------------------------------------------
-- GST treatment is derived from master data, never supplied by the client
-- ---------------------------------------------------------------------------
select db_test.eq(public.client_tax_type((select v from tt_ids where k = 'client_intra')), 'INTRA_STATE'::public.tax_type,
  'Maharashtra client resolves to INTRA_STATE');
select db_test.eq(public.client_tax_type((select v from tt_ids where k = 'client_inter')), 'INTER_STATE'::public.tax_type,
  'Karnataka client resolves to INTER_STATE');

-- ---------------------------------------------------------------------------
-- Quotation arithmetic
--   L1: 10 x 1000.00, 10% discount  -> taxable  9000.00, tax 1620.00 (810/810)
--   L2:  1 x 5000.00, no discount   -> taxable  5000.00, tax  900.00 (450/450)
--   totals: gross 15000, discount 1000, taxable 14000, tax 2520, grand 16520
-- ---------------------------------------------------------------------------
do $$
declare
  v_quotation uuid;
  v_q public.quotations;
begin
  insert into public.quotations (client_id, title, subject, tax_type)
  values ((select v from tt_ids where k = 'client_intra'), 'Brand film', 'Quarterly campaign', 'INTRA_STATE')
  returning id into v_quotation;

  insert into public.quotation_line_items (quotation_id, sort_order, description, quantity, unit_price, discount_percent, gst_rate)
  values
    (v_quotation, 1, 'Direction & production', 10, 1000.00, 10, 18),
    (v_quotation, 2, 'Post production',         1, 5000.00,  0, 18);

  insert into tt_ids values ('quotation', v_quotation);

  -- An explicit attempt to tamper with tax_type is overwritten from master data.
  update public.quotations set tax_type = 'INTER_STATE' where id = v_quotation;
  select * into v_q from public.quotations where id = v_quotation;

  perform db_test.eq(v_q.quotation_number ~ '^QT/[0-9]{4}-[0-9]{2}/[0-9]{4}$', true, 'quotation number uses PREFIX/FY/SEQUENCE format');
  perform db_test.eq(v_q.tax_type, 'INTRA_STATE'::public.tax_type, 'quotation tax type is taken from the client state');
  perform db_test.eq(v_q.subtotal, 15000.00::numeric, 'quotation gross subtotal');
  perform db_test.eq(v_q.discount_total, 1000.00::numeric, 'quotation discount total');
  perform db_test.eq(v_q.taxable_total, 14000.00::numeric, 'quotation taxable total');
  perform db_test.eq(v_q.cgst_total, 1260.00::numeric, 'quotation CGST total');
  perform db_test.eq(v_q.sgst_total, 1260.00::numeric, 'quotation SGST total');
  perform db_test.eq(v_q.igst_total, 0::numeric, 'quotation has no IGST intra-state');
  perform db_test.eq(v_q.tax_total, 2520.00::numeric, 'quotation GST total');
  perform db_test.eq(v_q.round_off, 0::numeric, 'no round-off when the total is already whole');
  perform db_test.eq(v_q.grand_total, 16520.00::numeric, 'quotation grand total');
  perform db_test.eq(v_q.valid_until, v_q.quotation_date + 15, 'validity defaults to 15 days from settings');
end $$;

-- Round-off: 1000.33 + 18% = 1180.3894 -> 1180.39, rounded total 1180, round_off -0.39
do $$
declare
  v_q uuid;
  v_qrow public.quotations;
begin
  insert into public.quotations (client_id, title) values ((select v from tt_ids where k = 'client_intra'), 'Round off probe')
  returning id into v_q;

  insert into public.quotation_line_items (quotation_id, description, quantity, unit_price, gst_rate)
  values (v_q, 'Odd amount', 1, 1000.33, 18);

  select * into v_qrow from public.quotations where id = v_q;

  perform db_test.eq(v_qrow.taxable_total, 1000.33::numeric, 'round-off probe taxable value');
  perform db_test.eq(v_qrow.tax_total, 180.06::numeric, 'GST is computed on the exact taxable value');
  perform db_test.eq(v_qrow.grand_total, 1180.00::numeric, 'grand total is rounded to the nearest rupee');
  perform db_test.eq(v_qrow.round_off, -0.39::numeric, 'round-off records the adjustment');
  perform db_test.eq(v_qrow.grand_total - (v_qrow.taxable_total + v_qrow.tax_total), v_qrow.round_off,
    'grand total always equals taxable + tax + round off');
end $$;

-- Inter-state quotation carries IGST only.
do $$
declare
  v_q uuid;
  v_qrow public.quotations;
begin
  insert into public.quotations (client_id, title) values ((select v from tt_ids where k = 'client_inter'), 'Inter-state shoot')
  returning id into v_q;

  insert into public.quotation_line_items (quotation_id, description, quantity, unit_price, gst_rate)
  values (v_q, 'Location shoot', 2, 2500, 18);

  select * into v_qrow from public.quotations where id = v_q;

  perform db_test.eq(v_qrow.tax_type, 'INTER_STATE'::public.tax_type, 'inter-state quotation flagged correctly');
  perform db_test.eq(v_qrow.cgst_total, 0::numeric, 'inter-state quotation has no CGST');
  perform db_test.eq(v_qrow.sgst_total, 0::numeric, 'inter-state quotation has no SGST');
  perform db_test.eq(v_qrow.igst_total, 900.00::numeric, 'inter-state IGST is the full 18%');
  perform db_test.eq(v_qrow.grand_total, 5900.00::numeric, 'inter-state quotation total');
end $$;

-- GST rate must come from the statutory catalogue.
select db_test.throws(
  format($sql$ insert into public.quotation_line_items (quotation_id, description, quantity, unit_price, gst_rate)
               values ('%s', 'Illegal rate', 1, 100, 7) $sql$, (select v from tt_ids where k = 'quotation')),
  'a line item with a non-statutory GST rate is rejected'
);

select db_test.throws(
  format($sql$ insert into public.quotation_line_items (quotation_id, description, quantity, unit_price)
               values ('%s', 'Zero quantity', 0, 100) $sql$, (select v from tt_ids where k = 'quotation')),
  'a zero-quantity line item is rejected'
);

-- ---------------------------------------------------------------------------
-- Quotation lifecycle
-- ---------------------------------------------------------------------------
do $$
declare
  v_empty uuid;
begin
  insert into public.quotations (client_id, title) values ((select v from tt_ids where k = 'client_intra'), 'Empty quotation')
  returning id into v_empty;
  insert into tt_ids values ('quotation_empty', v_empty);

  perform db_test.throws(
    format($sql$ update public.quotations set status = 'SENT' where id = '%s' $sql$, v_empty),
    'a quotation without line items cannot be sent'
  );
end $$;

do $$
declare
  v_q public.quotations;
begin
  update public.quotations set status = 'SENT' where id = (select v from tt_ids where k = 'quotation');
  select * into v_q from public.quotations where id = (select v from tt_ids where k = 'quotation');

  perform db_test.eq(v_q.status, 'SENT'::public.quotation_status, 'quotation moves DRAFT -> SENT');
  perform db_test.ok(v_q.sent_at is not null, 'sent_at is stamped by the database');

  perform db_test.throws(
    format($sql$ update public.quotations set status = 'DRAFT' where id = '%s' $sql$, v_q.id),
    'invalid backward status transition is rejected'
  );

  perform db_test.throws(
    format($sql$ update public.quotations set status = 'CANCELLED', cancelled_reason = null where id = '%s' $sql$, v_q.id),
    'cancelling a quotation requires a reason'
  );
end $$;

-- ---------------------------------------------------------------------------
-- Quotation -> invoice conversion
-- ---------------------------------------------------------------------------
do $$
declare
  v_invoice_id uuid;
  v_invoice public.invoices;
  v_q public.quotations;
begin
  v_invoice_id := public.convert_quotation_to_invoice((select v from tt_ids where k = 'quotation'));
  insert into tt_ids values ('invoice', v_invoice_id);

  select * into v_invoice from public.invoices where id = v_invoice_id;
  select * into v_q from public.quotations where id = (select v from tt_ids where k = 'quotation');

  perform db_test.eq(v_invoice.status, 'DRAFT'::public.invoice_status, 'conversion produces a draft invoice');
  perform db_test.eq(v_invoice.grand_total, 16520.00::numeric, 'converted invoice keeps the quotation totals');
  perform db_test.eq(v_invoice.taxable_total, 14000.00::numeric, 'converted invoice taxable value');
  perform db_test.eq(v_invoice.quotation_id, v_q.id, 'invoice links back to the quotation');
  perform db_test.eq(v_q.status, 'CONVERTED'::public.quotation_status, 'quotation is marked CONVERTED');
  perform db_test.eq(v_q.converted_invoice_id, v_invoice_id, 'quotation stores the created invoice');
  perform db_test.eq(v_invoice.due_date, v_invoice.invoice_date + 30, 'due date follows client payment terms');

  perform db_test.throws(
    format($sql$ select public.convert_quotation_to_invoice('%s') $sql$, v_q.id),
    'a quotation cannot be converted twice'
  );

  perform db_test.throws(
    format($sql$ update public.quotations set grand_total = 1 where id = '%s' $sql$, v_q.id),
    'a converted quotation is frozen'
  );
end $$;

-- ---------------------------------------------------------------------------
-- Draft invoice editing, then issuing
-- ---------------------------------------------------------------------------
do $$
declare
  v_invoice_id uuid := (select v from tt_ids where k = 'invoice');
begin
  -- Drafts stay editable.
  update public.invoice_line_items
     set quantity = 11
   where invoice_id = v_invoice_id and sort_order = 1;

  -- 10 -> 11 units: gross 11000, 10% discount -> taxable 9900, 18% GST 1782 -> 11682; plus 5900 = 17582
  perform db_test.eq((select grand_total from public.invoices where id = v_invoice_id), 17582.00::numeric,
    'editing a draft line item recalculates the invoice');

  update public.invoice_line_items set quantity = 10 where invoice_id = v_invoice_id and sort_order = 1;

  perform db_test.throws(
    format($sql$ insert into public.invoices (client_id, status) values ('%s', 'ISSUED') $sql$,
           (select v from tt_ids where k = 'client_intra')),
    'an invoice cannot be issued without line items'
  );
end $$;

do $$
declare
  v_invoice public.invoices;
begin
  update public.invoices set status = 'ISSUED' where id = (select v from tt_ids where k = 'invoice');
  select * into v_invoice from public.invoices where id = (select v from tt_ids where k = 'invoice');

  perform db_test.eq(v_invoice.status, 'ISSUED'::public.invoice_status, 'invoice is issued');
  perform db_test.ok(v_invoice.issued_at is not null, 'issued_at is stamped by the database');
  perform db_test.eq(v_invoice.invoice_number ~ '^INV/[0-9]{4}-[0-9]{2}/[0-9]{4}$', true, 'invoice number uses the company prefix and FY scope');
end $$;

-- ---------------------------------------------------------------------------
-- ISSUED invoice immutability
-- ---------------------------------------------------------------------------
select db_test.throws(
  format($sql$ update public.invoices set grand_total = 1 where id = '%s' $sql$, (select v from tt_ids where k = 'invoice')),
  'an issued invoice total cannot be changed'
);

select db_test.throws(
  format($sql$ update public.invoices set client_id = '%s' where id = '%s' $sql$,
         (select v from tt_ids where k = 'client_inter'), (select v from tt_ids where k = 'invoice')),
  'an issued invoice client cannot be changed'
);

select db_test.throws(
  format($sql$ update public.invoices set invoice_date = invoice_date - 5 where id = '%s' $sql$, (select v from tt_ids where k = 'invoice')),
  'an issued invoice date cannot be changed'
);

select db_test.throws(
  format($sql$ update public.invoice_line_items set unit_price = 1 where invoice_id = '%s' $sql$, (select v from tt_ids where k = 'invoice')),
  'issued invoice line items cannot be changed'
);

select db_test.throws(
  format($sql$ insert into public.invoice_line_items (invoice_id, description, quantity, unit_price)
               values ('%s', 'Sneaky line', 1, 100) $sql$, (select v from tt_ids where k = 'invoice')),
  'line items cannot be added to an issued invoice'
);

select db_test.throws(
  format($sql$ delete from public.invoice_line_items where invoice_id = '%s' $sql$, (select v from tt_ids where k = 'invoice')),
  'line items cannot be deleted from an issued invoice'
);

select db_test.throws(
  format($sql$ delete from public.invoices where id = '%s' $sql$, (select v from tt_ids where k = 'invoice')),
  'an issued invoice can never be deleted'
);

-- ---------------------------------------------------------------------------
-- Payments
-- ---------------------------------------------------------------------------
select db_test.throws(
  format($sql$ insert into public.payments (invoice_id, client_id, amount) values ('%s', '%s', 100) $sql$,
         (select v from tt_ids where k = 'quotation'), (select v from tt_ids where k = 'client_intra')),
  'a payment against a non-invoice document is rejected'
);

select db_test.throws(
  format($sql$ insert into public.payments (invoice_id, client_id, amount) values ('%s', '%s', 0) $sql$,
         (select v from tt_ids where k = 'invoice'), (select v from tt_ids where k = 'client_intra')),
  'a zero-value payment is rejected'
);

select db_test.throws(
  format($sql$ insert into public.payments (invoice_id, client_id, amount) values ('%s', '%s', 20000) $sql$,
         (select v from tt_ids where k = 'invoice'), (select v from tt_ids where k = 'client_intra')),
  'a payment larger than the outstanding balance is rejected'
);

do $$
declare
  v_payment uuid;
  v_invoice public.invoices;
  v_number  text;
begin
  v_payment := public.post_payment(
    p_amount     => 6520.00,
    p_invoice_id => (select v from tt_ids where k = 'invoice'),
    p_method     => 'BANK_TRANSFER',
    p_reference  => 'UTR123456'
  );
  insert into tt_ids values ('payment_posted', v_payment);

  select * into v_invoice from public.invoices where id = (select v from tt_ids where k = 'invoice');
  select payment_number into v_number from public.payments where id = v_payment;

  perform db_test.eq(v_invoice.amount_paid, 6520.00::numeric, 'posted payment increases amount_paid');
  perform db_test.eq(v_invoice.grand_total - v_invoice.amount_paid - v_invoice.amount_credited, 10000.00::numeric,
    'outstanding balance reflects the posted payment');
  perform db_test.ok(v_number ~ '^RCPT/[0-9]{4}-[0-9]{2}/[0-9]{4}$', 'payment receipt number is allocated by the database');
  perform db_test.eq(public.payment_receipt_allowed(v_payment), true, 'a posted payment can produce a receipt');
end $$;

-- A payment may not be attributed to another client.
do $$
declare
  v_payment uuid;
  v_stored  uuid;
begin
  insert into public.payments (invoice_id, client_id, amount)
  values ((select v from tt_ids where k = 'invoice'), (select v from tt_ids where k = 'client_inter'), 10)
  returning id, client_id into v_payment, v_stored;

  perform db_test.eq(v_stored,
                     (select client_id from public.invoices where id = (select v from tt_ids where k = 'invoice')),
                     'payment client is forced to match the invoice client');

  -- Void the probe so it never contributes to collection totals.
  perform public.void_payment(v_payment, 'test probe');
  perform db_test.eq((select amount_paid from public.invoices where id = (select v from tt_ids where k = 'invoice')),
                     6520.00::numeric, 'probe payment does not affect collection once voided');
end $$;

-- Posted payments are immutable: the amount cannot be edited.
select db_test.throws(
  format($sql$ update public.payments set amount = 100 where id = '%s' $sql$, (select v from tt_ids where k = 'payment_posted')),
  'a posted payment amount cannot be changed'
);

select db_test.throws(
  format($sql$ delete from public.payments where id = '%s' $sql$, (select v from tt_ids where k = 'payment_posted')),
  'payments can never be deleted'
);

select db_test.throws(
  format($sql$ update public.payments set status = 'VOIDED' where id = '%s' $sql$, (select v from tt_ids where k = 'payment_posted')),
  'voiding a payment requires a reason'
);

-- Void the payment and confirm it stops counting towards collection.
do $$
declare
  v_invoice public.invoices;
  v_payment public.payments;
  v_financials record;
begin
  perform public.void_payment((select v from tt_ids where k = 'payment_posted'), 'Cheque bounced');

  select * into v_payment from public.payments where id = (select v from tt_ids where k = 'payment_posted');
  select * into v_invoice from public.invoices where id = (select v from tt_ids where k = 'invoice');
  select amount_paid, amount_credited, outstanding into v_financials
  from public.v_invoice_financials where id = v_invoice.id;

  perform db_test.eq(v_payment.status, 'VOIDED'::public.payment_status, 'payment is voided');
  perform db_test.ok(v_payment.voided_at is not null, 'voided_at is stamped');
  perform db_test.eq(v_payment.void_reason, 'Cheque bounced', 'void reason is stored');
  perform db_test.eq(v_invoice.amount_paid, 0::numeric, 'a voided payment no longer counts as collected');
  perform db_test.eq(v_financials.outstanding, 16520.00::numeric, 'outstanding returns to the full invoice value');
  perform db_test.eq(public.payment_receipt_allowed((select v from tt_ids where k = 'payment_posted')), false,
    'a voided payment cannot produce an official receipt');

  perform db_test.throws(
    format($sql$ update public.payments set void_reason = 'again' where id = '%s' $sql$, v_payment.id),
    'a voided payment is terminal'
  );
end $$;

-- Replace it with a genuine collection: 10000 of 16520.
do $$
declare
  v_payment uuid;
  v_invoice public.invoices;
begin
  v_payment := public.post_payment(
    p_amount     => 10000.00,
    p_invoice_id => (select v from tt_ids where k = 'invoice'),
    p_method     => 'NEFT',
    p_reference  => 'UTR999888'
  );
  insert into tt_ids values ('payment_live', v_payment);

  select * into v_invoice from public.invoices where id = (select v from tt_ids where k = 'invoice');

  perform db_test.eq(v_invoice.amount_paid, 10000.00::numeric, 'collection reflects only posted payments');
  perform db_test.eq(v_invoice.grand_total - v_invoice.amount_paid - v_invoice.amount_credited, 6520.00::numeric,
    'outstanding after partial collection');
end $$;

-- ---------------------------------------------------------------------------
-- Credit notes
-- ---------------------------------------------------------------------------
select db_test.throws(
  format($sql$ insert into public.credit_notes (client_id, invoice_id, status, reason)
               values ('%s', '%s', 'ISSUED', 'too early') $sql$,
         (select v from tt_ids where k = 'client_intra'), (select v from tt_ids where k = 'invoice')),
  'a credit note cannot be issued without line items'
);

do $$
declare
  v_cn uuid;
  v_invoice public.invoices;
begin
  insert into public.credit_notes (invoice_id, client_id, reason)
  values ((select v from tt_ids where k = 'invoice'), (select v from tt_ids where k = 'client_intra'), 'Rate revision')
  returning id into v_cn;
  insert into tt_ids values ('credit_note', v_cn);

  insert into public.credit_note_line_items (credit_note_id, description, quantity, unit_price, gst_rate)
  values (v_cn, 'Rate difference', 1, 1000.00, 18);

  perform db_test.eq((select grand_total from public.credit_notes where id = v_cn), 1180.00::numeric,
    'credit note totals are computed from its lines');

  update public.credit_notes set status = 'ISSUED' where id = v_cn;

  select * into v_invoice from public.invoices where id = (select v from tt_ids where k = 'invoice');

  perform db_test.eq(v_invoice.amount_credited, 1180.00::numeric, 'an issued credit note reduces the invoice receivable');
  perform db_test.eq(v_invoice.grand_total - v_invoice.amount_paid - v_invoice.amount_credited, 5340.00::numeric,
    'outstanding nets off the credit note');

  -- A draft credit note may be created freely; the value cap is enforced at issue.
  perform db_test.throws(
    format($sql$ update public.credit_notes set grand_total = 999999 where id = '%s' $sql$, v_cn),
    'an issued credit note is immutable'
  );

  perform db_test.throws(
    format($sql$ delete from public.credit_notes where id = '%s' $sql$, v_cn),
    'an issued credit note cannot be deleted'
  );
end $$;

-- A credit note for more than the invoice value is refused at issue time.
do $$
declare
  v_cn uuid;
  v_invoice_id uuid := (select v from tt_ids where k = 'invoice');
begin
  insert into public.credit_notes (invoice_id, client_id, reason)
  values (v_invoice_id, (select v from tt_ids where k = 'client_intra'), 'Over-credit probe')
  returning id into v_cn;

  insert into public.credit_note_line_items (credit_note_id, description, quantity, unit_price, gst_rate)
  values (v_cn, 'Excess', 1, 20000.00, 18);

  perform db_test.throws(
    format($sql$ update public.credit_notes set status = 'ISSUED' where id = '%s' $sql$, v_cn),
    'credit notes cannot exceed the invoice value'
  );
end $$;

-- ---------------------------------------------------------------------------
-- Cancellation is the only escape hatch for an issued invoice
-- ---------------------------------------------------------------------------
do $$
declare
  v_invoice public.invoices;
begin
  perform db_test.throws(
    format($sql$ update public.invoices set status = 'CANCELLED', cancelled_reason = null where id = '%s' $sql$,
           (select v from tt_ids where k = 'invoice')),
    'cancelling an invoice requires a reason'
  );

  select * into v_invoice from public.invoices where id = (select v from tt_ids where k = 'invoice');
  perform db_test.eq(v_invoice.status, 'ISSUED'::public.invoice_status, 'invoice is still issued after the failed cancel');
end $$;

-- ---------------------------------------------------------------------------
-- Expenses: draft -> approved -> void
-- ---------------------------------------------------------------------------
do $$
declare
  v_project uuid;
  v_expense uuid;
  v_exp public.expenses;
begin
  insert into public.projects (name, client_id, status, budget, contract_value)
  values ('Brand Film Q3', (select v from tt_ids where k = 'client_intra'), 'IN_PROGRESS', 100000, 250000)
  returning id into v_project;
  insert into tt_ids values ('project', v_project);

  insert into public.expenses (project_id, client_id, description, amount, gst_rate, vendor_state_code, status)
  values (v_project, (select v from tt_ids where k = 'client_intra'), 'Camera rental', 50000.00, 18, '27', 'DRAFT')
  returning id into v_expense;
  insert into tt_ids values ('expense', v_expense);

  select * into v_exp from public.expenses where id = v_expense;

  perform db_test.eq(v_exp.tax_type, 'INTRA_STATE'::public.tax_type, 'expense GST treatment follows the vendor state');
  perform db_test.eq(v_exp.cgst_amount, 4500.00::numeric, 'expense CGST computed');
  perform db_test.eq(v_exp.sgst_amount, 4500.00::numeric, 'expense SGST computed');
  perform db_test.eq(v_exp.total_amount, 59000.00::numeric, 'expense gross includes tax');

  update public.expenses set status = 'APPROVED' where id = v_expense;

  perform db_test.ok((select approved_at from public.expenses where id = v_expense) is not null,
    'approving an expense stamps approved_at');

  perform db_test.throws(
    format($sql$ update public.expenses set amount = 1 where id = '%s' $sql$, v_expense),
    'an approved expense is frozen'
  );

  perform db_test.throws(
    format($sql$ update public.expenses set status = 'VOID' where id = '%s' $sql$, v_expense),
    'voiding an expense requires a reason'
  );
end $$;
