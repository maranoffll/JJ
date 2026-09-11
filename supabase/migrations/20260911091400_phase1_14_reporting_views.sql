-- ============================================================================
-- JJ MEDIA ERP — PHASE 1 : DATABASE FOUNDATION
-- Migration 14 : reporting views & dashboard aggregates
-- ----------------------------------------------------------------------------
-- Rules encoded here (and reused by every later report):
--   * only POSTED payments count towards collection
--   * VOIDED payments are excluded everywhere
--   * CANCELLED invoices are excluded from receivables and revenue
--   * ISSUED credit notes reduce receivable and revenue
--   * only APPROVED expenses count towards cost
-- All views use security_invoker so the caller's RLS applies — the views can
-- never widen access.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Invoice level financials.
-- ---------------------------------------------------------------------------
create or replace view public.v_invoice_financials
with (security_invoker = true)
as
select
  i.id,
  i.invoice_number,
  i.status,
  i.invoice_date,
  i.due_date,
  i.client_id,
  c.name                          as client_name,
  c.client_code,
  i.project_id,
  p.name                          as project_name,
  p.project_code,
  i.quotation_id,
  i.tax_type,
  i.currency,
  i.subtotal,
  i.discount_total,
  i.taxable_total,
  i.cgst_total,
  i.sgst_total,
  i.igst_total,
  i.tax_total,
  i.round_off,
  i.grand_total,
  i.amount_paid,
  i.amount_credited,
  coalesce(pm.voided_amount, 0)   as amount_voided,
  public.round_money(i.grand_total - i.amount_paid - i.amount_credited) as outstanding,
  case
    when i.status <> 'ISSUED' then 0
    else greatest(current_date - i.due_date, 0)
  end                             as days_overdue,
  case
    when i.status <> 'ISSUED' then 'NOT_APPLICABLE'
    when i.grand_total - i.amount_paid - i.amount_credited <= 0 then 'PAID'
    when i.amount_paid > 0 or i.amount_credited > 0 then 'PARTIAL'
    when i.due_date is not null and i.due_date < current_date then 'OVERDUE'
    else 'UNPAID'
  end                             as payment_state,
  i.issued_at,
  i.cancelled_at,
  i.created_at,
  i.updated_at
from public.invoices i
join public.clients c on c.id = i.client_id
left join public.projects p on p.id = i.project_id
left join (
  select invoice_id, sum(amount) as voided_amount
  from public.payments
  where status = 'VOIDED' and invoice_id is not null
  group by invoice_id
) pm on pm.invoice_id = i.id;

comment on view public.v_invoice_financials is
  'Invoice with derived collection state. outstanding = grand_total - POSTED payments - ISSUED credit notes.';

-- ---------------------------------------------------------------------------
-- Receivables ageing (issued invoices only, oldest first).
-- ---------------------------------------------------------------------------
create or replace view public.v_receivables_aging
with (security_invoker = true)
as
select
  f.id,
  f.invoice_number,
  f.invoice_date,
  f.due_date,
  f.client_id,
  f.client_name,
  f.project_id,
  f.project_name,
  f.grand_total,
  f.amount_paid,
  f.amount_credited,
  f.outstanding,
  f.days_overdue,
  case
    when f.outstanding <= 0 then 'SETTLED'
    when f.days_overdue = 0 then 'CURRENT'
    when f.days_overdue <= 30 then '1-30'
    when f.days_overdue <= 60 then '31-60'
    when f.days_overdue <= 90 then '61-90'
    else '90+'
  end as ageing_bucket
from public.v_invoice_financials f
where f.status = 'ISSUED'
  and f.outstanding > 0;

comment on view public.v_receivables_aging is 'Outstanding issued invoices bucketed by days past due.';

-- ---------------------------------------------------------------------------
-- Client level roll-up (revenue, collection, outstanding, credited).
-- ---------------------------------------------------------------------------
create or replace view public.v_client_financials
with (security_invoker = true)
as
select
  c.id                                as client_id,
  c.client_code,
  c.name                              as client_name,
  c.status                            as client_status,
  c.billing_state_code,
  coalesce(inv.invoice_count, 0)      as invoice_count,
  coalesce(inv.revenue, 0)            as revenue,
  coalesce(inv.credited, 0)           as credited,
  coalesce(inv.collected, 0)          as collected,
  coalesce(inv.outstanding, 0)        as outstanding,
  coalesce(adv.advance_received, 0)   as advance_received,
  coalesce(exp.cost, 0)               as direct_cost,
  public.round_money(coalesce(inv.revenue, 0) - coalesce(exp.cost, 0)) as gross_profit
from public.clients c
left join (
  select
    i.client_id,
    count(*) filter (where i.status = 'ISSUED')                  as invoice_count,
    sum(case when i.status = 'ISSUED' then i.grand_total else 0 end) as revenue,
    sum(case when i.status = 'ISSUED' then i.amount_credited else 0 end) as credited,
    sum(case when i.status = 'ISSUED' then i.amount_paid else 0 end)     as collected,
    sum(case when i.status = 'ISSUED' then i.grand_total - i.amount_paid - i.amount_credited else 0 end) as outstanding
  from public.invoices i
  where i.status <> 'CANCELLED'
  group by i.client_id
) inv on inv.client_id = c.id
left join (
  select p.client_id, sum(p.amount) as advance_received
  from public.payments p
  where p.status = 'POSTED' and p.is_advance
  group by p.client_id
) adv on adv.client_id = c.id
left join (
  select e.client_id, sum(e.total_amount) as cost
  from public.expenses e
  where e.status = 'APPROVED' and e.client_id is not null
  group by e.client_id
) exp on exp.client_id = c.id;

comment on view public.v_client_financials is
  'Per-client revenue, collection, outstanding and cost roll-up (POSTED payments only).';

-- ---------------------------------------------------------------------------
-- Project profitability. Revenue is recognised from issued invoices on the
-- project; cost from approved expenses.
-- ---------------------------------------------------------------------------
create or replace view public.v_project_profitability
with (security_invoker = true)
as
select
  p.id                                   as project_id,
  p.project_code,
  p.name                                 as project_name,
  p.status,
  p.client_id,
  c.name                                 as client_name,
  p.start_date,
  p.end_date,
  p.deadline,
  p.contract_value,
  p.budget,
  coalesce(inv.invoiced, 0)              as invoiced,
  coalesce(inv.credited, 0)              as credited,
  public.round_money(coalesce(inv.invoiced, 0) - coalesce(inv.credited, 0)) as net_revenue,
  coalesce(inv.collected, 0)             as collected,
  coalesce(inv.outstanding, 0)           as outstanding,
  coalesce(exp.total_cost, 0)            as total_cost,
  coalesce(exp.direct_cost, 0)           as direct_cost,
  coalesce(exp.overhead_cost, 0)         as overhead_cost,
  public.round_money(
    coalesce(inv.invoiced, 0) - coalesce(inv.credited, 0) - coalesce(exp.total_cost, 0)
  )                                      as gross_profit,
  case
    when coalesce(inv.invoiced, 0) - coalesce(inv.credited, 0) > 0
      then public.round_money(
        ((coalesce(inv.invoiced, 0) - coalesce(inv.credited, 0) - coalesce(exp.total_cost, 0))
         / (coalesce(inv.invoiced, 0) - coalesce(inv.credited, 0))) * 100,
        2)
    else null
  end                                    as margin_percent,
  case
    when p.budget is not null and p.budget > 0
      then public.round_money((coalesce(exp.total_cost, 0) / p.budget) * 100, 2)
    else null
  end                                    as budget_used_percent,
  coalesce(hdd.active_assignments, 0)    as active_hdd_assignments
from public.projects p
join public.clients c on c.id = p.client_id
left join (
  select
    i.project_id,
    sum(case when i.status = 'ISSUED' then i.grand_total else 0 end)      as invoiced,
    sum(case when i.status = 'ISSUED' then i.amount_credited else 0 end)  as credited,
    sum(case when i.status = 'ISSUED' then i.amount_paid else 0 end)      as collected,
    sum(case when i.status = 'ISSUED' then i.grand_total - i.amount_paid - i.amount_credited else 0 end) as outstanding
  from public.invoices i
  where i.status <> 'CANCELLED' and i.project_id is not null
  group by i.project_id
) inv on inv.project_id = p.id
left join (
  select
    e.project_id,
    sum(e.total_amount)                                                   as total_cost,
    sum(case when coalesce(ec.is_direct_cost, true) then e.total_amount else 0 end) as direct_cost,
    sum(case when coalesce(ec.is_direct_cost, false) then e.total_amount else 0 end) as overhead_cost
  from public.expenses e
  left join public.expense_categories ec on ec.id = e.category_id
  where e.status = 'APPROVED' and e.project_id is not null
  group by e.project_id
) exp on exp.project_id = p.id
left join (
  select a.project_id, count(*) as active_assignments
  from public.hdd_assignments a
  where a.status = 'ACTIVE' and a.project_id is not null
  group by a.project_id
) hdd on hdd.project_id = p.id;

comment on view public.v_project_profitability is
  'Project revenue (issued invoices net of credit notes) vs approved cost, margin and budget consumption.';

-- ---------------------------------------------------------------------------
-- Monthly revenue for the executive dashboard / trend charts.
-- ---------------------------------------------------------------------------
create or replace view public.v_revenue_monthly
with (security_invoker = true)
as
select
  date_trunc('month', i.invoice_date)::date                     as month,
  count(*) filter (where i.status = 'ISSUED')                    as invoice_count,
  sum(case when i.status = 'ISSUED' then i.taxable_total else 0 end) as taxable_revenue,
  sum(case when i.status = 'ISSUED' then i.tax_total else 0 end)      as tax_collected,
  sum(case when i.status = 'ISSUED' then i.grand_total else 0 end)    as gross_revenue,
  sum(case when i.status = 'ISSUED' then i.amount_credited else 0 end) as credited,
  sum(case when i.status = 'ISSUED' then i.amount_paid else 0 end)     as collected
from public.invoices i
where i.status <> 'CANCELLED'
group by 1
order by 1 desc;

comment on view public.v_revenue_monthly is 'Monthly issued-invoice revenue, tax, credits and collections.';

-- ---------------------------------------------------------------------------
-- GST summary (GSTR-1 style output, net of issued credit notes).
-- ---------------------------------------------------------------------------
create or replace view public.v_gst_summary
with (security_invoker = true)
as
with sales as (
  select
    date_trunc('month', i.invoice_date)::date as month,
    i.tax_type,
    i.taxable_total,
    i.cgst_total,
    i.sgst_total,
    i.igst_total,
    i.tax_total,
    i.grand_total,
    i.invoice_number as document_number,
    'INVOICE'::text   as document_type
  from public.invoices i
  where i.status = 'ISSUED'
),
credits as (
  select
    date_trunc('month', cn.credit_note_date)::date as month,
    cn.tax_type,
    -cn.taxable_total as taxable_total,
    -cn.cgst_total    as cgst_total,
    -cn.sgst_total    as sgst_total,
    -cn.igst_total    as igst_total,
    -cn.tax_total     as tax_total,
    -cn.grand_total   as grand_total,
    cn.credit_note_number as document_number,
    'CREDIT_NOTE'::text   as document_type
  from public.credit_notes cn
  where cn.status = 'ISSUED'
)
select
  month,
  document_type,
  document_number,
  tax_type,
  taxable_total,
  cgst_total,
  sgst_total,
  igst_total,
  tax_total,
  grand_total
from (
  select * from sales
  union all
  select * from credits
) d;

comment on view public.v_gst_summary is 'GST document register (issued invoices less issued credit notes) for GSTR-1 style reporting.';

-- ---------------------------------------------------------------------------
-- Expense roll-up by category and project.
-- ---------------------------------------------------------------------------
create or replace view public.v_expense_summary
with (security_invoker = true)
as
select
  date_trunc('month', e.expense_date)::date as month,
  e.category_id,
  coalesce(ec.name, 'Uncategorised')      as category_name,
  coalesce(ec.is_direct_cost, true)       as is_direct_cost,
  e.project_id,
  p.name                                  as project_name,
  count(*)                                as expense_count,
  sum(e.amount)                           as net_amount,
  sum(e.tax_amount)                       as tax_amount,
  sum(e.total_amount)                     as gross_amount,
  sum(case when e.is_itc_eligible then e.tax_amount else 0 end) as itc_eligible_tax
from public.expenses e
left join public.expense_categories ec on ec.id = e.category_id
left join public.projects p on p.id = e.project_id
where e.status = 'APPROVED'
group by 1, 2, 3, 4, 5, 6;

comment on view public.v_expense_summary is 'Approved expense roll-up by month, category and project.';

-- ---------------------------------------------------------------------------
-- HDD custody view: current state, holder and overdue flag.
-- ---------------------------------------------------------------------------
create or replace view public.v_hdd_custody
with (security_invoker = true)
as
select
  h.id                    as hdd_id,
  h.asset_tag,
  h.serial_number,
  h.label,
  h.brand,
  h.model,
  h.capacity_gb,
  h.status,
  h.condition,
  h.qr_token,
  h.current_location_id,
  l.name                  as current_location_name,
  a.id                    as assignment_id,
  a.project_id,
  p.name                  as project_name,
  p.project_code,
  coalesce(up.full_name, a.assigned_to_name) as holder_name,
  a.assigned_to           as holder_id,
  a.checked_out_at,
  a.expected_return_date,
  case
    when a.status = 'ACTIVE' and a.expected_return_date is not null
      then greatest(current_date - a.expected_return_date, 0)
    else 0
  end                     as days_overdue,
  case
    when a.status = 'ACTIVE' and a.expected_return_date is not null
         and a.expected_return_date < current_date then true
    else false
  end                     as is_overdue,
  h.last_verified_at,
  h.is_deleted
from public.hdds h
left join public.hdd_locations l on l.id = h.current_location_id
left join public.hdd_assignments a on a.hdd_id = h.id and a.status = 'ACTIVE'
left join public.projects p on p.id = a.project_id
left join public.user_profiles up on up.id = a.assigned_to;

comment on view public.v_hdd_custody is 'Drive inventory with its active custodian, location and overdue status.';

-- ---------------------------------------------------------------------------
-- Dashboard aggregates, computed in the database (no client-side aggregation
-- and no full-table downloads).
-- ---------------------------------------------------------------------------
create or replace function public.dashboard_metrics(
  p_from date default null,
  p_to   date default null
)
returns jsonb
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  with bounds as (
    select
      coalesce(p_from, date_trunc('year', current_date)::date) as from_date,
      coalesce(p_to, current_date) as to_date
  ),
  invoices_scoped as (
    select i.*
    from public.invoices i, bounds b
    where i.invoice_date between b.from_date and b.to_date
  ),
  payments_scoped as (
    select p.*
    from public.payments p, bounds b
    where p.received_on between b.from_date and b.to_date
  ),
  expenses_scoped as (
    select e.*
    from public.expenses e, bounds b
    where e.expense_date between b.from_date and b.to_date
  )
  select jsonb_build_object(
    'range', jsonb_build_object('from', (select from_date from bounds), 'to', (select to_date from bounds)),
    'invoices', jsonb_build_object(
      'draft',        (select count(*) from public.invoices where status = 'DRAFT'),
      'issued',       (select count(*) from invoices_scoped where status = 'ISSUED'),
      'cancelled',    (select count(*) from invoices_scoped where status = 'CANCELLED'),
      'issued_value', (select coalesce(sum(grand_total), 0) from invoices_scoped where status = 'ISSUED'),
      'taxable',      (select coalesce(sum(taxable_total), 0) from invoices_scoped where status = 'ISSUED'),
      'gst',          (select coalesce(sum(tax_total), 0) from invoices_scoped where status = 'ISSUED')
    ),
    'collections', jsonb_build_object(
      'received',     (select coalesce(sum(amount), 0) from payments_scoped where status = 'POSTED'),
      'voided',       (select coalesce(sum(amount), 0) from payments_scoped where status = 'VOIDED'),
      'advance',      (select coalesce(sum(amount), 0) from payments_scoped where status = 'POSTED' and is_advance),
      'receipts',     (select count(*) from payments_scoped where status = 'POSTED')
    ),
    'receivables', jsonb_build_object(
      'outstanding',  (select coalesce(sum(grand_total - amount_paid - amount_credited), 0)
                         from public.invoices where status = 'ISSUED'),
      'overdue',      (select coalesce(sum(grand_total - amount_paid - amount_credited), 0)
                         from public.invoices
                        where status = 'ISSUED' and due_date < current_date
                          and grand_total - amount_paid - amount_credited > 0),
      'overdue_count',(select count(*) from public.invoices
                        where status = 'ISSUED' and due_date < current_date
                          and grand_total - amount_paid - amount_credited > 0)
    ),
    'expenses', jsonb_build_object(
      'approved_total', (select coalesce(sum(total_amount), 0) from expenses_scoped where status = 'APPROVED'),
      'pending_count',  (select count(*) from public.expenses where status = 'DRAFT'),
      'itc_eligible',   (select coalesce(sum(tax_amount), 0) from expenses_scoped where status = 'APPROVED' and is_itc_eligible)
    ),
    'pipeline', jsonb_build_object(
      'open_quotations',      (select count(*) from public.quotations where status in ('DRAFT', 'SENT')),
      'open_quotation_value', (select coalesce(sum(grand_total), 0) from public.quotations where status in ('DRAFT', 'SENT')),
      'accepted_count',       (select count(*) from public.quotations where status = 'ACCEPTED'),
      'converted_count',      (select count(*) from public.quotations where status = 'CONVERTED')
    ),
    'projects', jsonb_build_object(
      'active',    (select count(*) from public.projects where status = 'IN_PROGRESS' and not is_deleted),
      'completed', (select count(*) from public.projects where status = 'COMPLETED' and not is_deleted),
      'on_hold',   (select count(*) from public.projects where status = 'ON_HOLD' and not is_deleted),
      'overdue',   (select count(*) from public.projects
                     where status in ('DRAFT', 'IN_PROGRESS', 'ON_HOLD')
                       and deadline is not null and deadline < current_date
                       and not is_deleted)
    ),
    'clients', jsonb_build_object(
      'active',   (select count(*) from public.clients where status = 'ACTIVE' and not is_deleted),
      'prospect', (select count(*) from public.clients where status = 'PROSPECT' and not is_deleted)
    ),
    'hdd', jsonb_build_object(
      'available',   (select count(*) from public.hdds where status = 'AVAILABLE' and not is_deleted),
      'checked_out', (select count(*) from public.hdds where status = 'CHECKED_OUT' and not is_deleted),
      'maintenance', (select count(*) from public.hdds where status = 'MAINTENANCE' and not is_deleted),
      'overdue',     (select count(*) from public.hdd_assignments
                       where status = 'ACTIVE' and expected_return_date is not null
                         and expected_return_date < current_date),
      'archived',    (select count(*) from public.hdds where status = 'ARCHIVED')
    )
  );
$$;

comment on function public.dashboard_metrics(date, date) is
  'Single-round-trip dashboard aggregate. POSTED payments only; VOIDED payments and CANCELLED invoices excluded.';

-- ---------------------------------------------------------------------------
-- Project activity feed (audit + HDD custody events).
-- ---------------------------------------------------------------------------
create or replace view public.v_project_activity
with (security_invoker = true)
as
select
  a.id::text       as activity_id,
  a.project_id,
  a.created_at,
  'AUDIT'::text   as source,
  a.action::text  as event,
  a.entity_table,
  a.entity_label,
  a.summary,
  a.actor_email   as actor
from public.audit_logs a
where a.project_id is not null
union all
select
  l.id::text,
  l.project_id,
  l.created_at,
  'HDD'::text,
  l.event::text,
  'hdds'::text,
  h.asset_tag,
  coalesce(l.note, l.event::text),
  coalesce(l.actor_name, 'system')
from public.hdd_logs l
join public.hdds h on h.id = l.hdd_id
where l.project_id is not null;

comment on view public.v_project_activity is 'Unified project timeline of audit and HDD custody events.';
